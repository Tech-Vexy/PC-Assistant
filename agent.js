/**
 * PC Personal Voice Agent - AssemblyAI WebSocket Client
 * 
 * This module handles the real-time voice interaction with AssemblyAI's Voice Agent API.
 * It manages WebSocket connections, audio capture/playback, tool dispatching, and session
 * persistence with reconnection logic and barge-in interruption support.
 * 
 * Key Features:
 * - WebSocket connection with exponential backoff reconnection
 * - Session persistence across restarts with grace window
 * - Audio frame buffering during disconnections
 * - Barge-in interruption (user can interrupt assistant speech)
 * - Real-time audio capture using FFmpeg
 * - Tool call dispatching to local handlers
 * - Graceful shutdown with explicit session termination
 * 
 * Architecture:
 * - Uses remote store mode (HTTP delegation to server) for DuckDB access
 * - Approvals delegated to server's /api/confirm endpoint
 * - Audio frames accumulated to reduce WebSocket message rate
 * - Recording auto-restarts on process exit if session is active
 */

import WebSocket from 'ws';
import { spawn } from 'child_process';
import { dispatchTool } from './tools.js';
import { playEarcon } from './lib/sound-effects.js';
import { buildLlmRoutes, resolveLlmConfig } from './lib/model-router.js';
import { initStore, loadSession, saveSession, cfg } from './lib/store.js';
import dotenv from 'dotenv';

dotenv.config();

// AssemblyAI grace window allows session resume within 30s of disconnect
const GRACE_WINDOW_MS = 30_000;
const MAX_RECONNECT_ATTEMPTS = 10;
const BASE_BACKOFF_MS = 1000;
// Audio frame size: 160ms @ 16kHz 16-bit mono = 5120 bytes
// Larger frames reduce WebSocket message overhead
const AUDIO_FRAME_BYTES = 5120;
// Buffer ~5s of audio during disconnections to avoid speech loss
const MAX_BUFFERED_FRAMES = 32;
// RMS threshold for barge-in detection (user interrupting assistant)
const BARGE_IN_THRESHOLD = Number(process.env.BARGE_IN_THRESHOLD || 2800);

/**
 * Calculate Root Mean Square (RMS) of PCM16 audio buffer
 * Used for barge-in detection - measuring audio energy to detect when user speaks
 * @param {Buffer} buf - PCM16 audio buffer
 * @returns {number} RMS value (audio energy level)
 */
function rmsInt16(buf) {
  let sum = 0;
  const n = Math.floor(buf.length / 2);
  for (let i = 0; i < n; i++) {
    const v = buf.readInt16LE(i * 2);
    sum += v * v;
  }
  return Math.sqrt(sum / Math.max(1, n));
}

/**
 * Load session state from persistent storage
 * Gracefully handles storage failures by returning empty state
 * @returns {Promise<Object>} Session state with sessionId and lastTranscript
 */
async function loadState() {
  try {
    return (await loadSession()) || {};
  } catch {
    return {};
  }
}

/**
 * Save session state to persistent storage
 * Gracefully handles storage failures (logging only)
 * @param {Object} state - Session state to persist
 */
async function saveState(state) {
  try {
    await saveSession({ ...state, updatedAt: new Date().toISOString() });
  } catch (err) {
    console.error('Failed to persist session state:', err.message);
  }
}

/**
 * VoiceAgent class manages the AssemblyAI WebSocket connection and audio pipeline
 * Handles session lifecycle, audio capture/playback, tool dispatching, and reconnection logic
 */
class VoiceAgent {
  constructor() {
    this.ws = null; // WebSocket connection to AssemblyAI
    this.recordingProcess = null; // FFmpeg process for audio capture
    this.sessionId = null; // Current session ID for resume capability
    this.isRecording = false; // Audio capture state
    this.reconnectAttempts = 0; // Current reconnection attempt count
    this.shouldRun = true; // Flag for graceful shutdown
    this.audioBuffer = []; // Base64 audio frames queued during disconnection
    this._frameAcc = Buffer.alloc(0); // Accumulator for audio frame building
    this._heartbeat = null; // WebSocket heartbeat interval
    this._graceTimer = null; // Timer for grace window expiration
    this._disconnectAt = null; // Timestamp of last disconnection
    this.playQueue = Promise.resolve(); // Serialized audio playback queue
    this.isPlayingAudio = false; // Current playback state
    this.currentPlayProcess = null; // Current ffplay process
    this._unmuteTimer = null; // Timer for post-playback microphone unmute delay
  }

  /**
   * Interrupt current audio playback (barge-in)
   * Called when user speaks while assistant is talking
   * Stops ffplay process, resets audio state, and plays interruption earcon
   */
  interruptPlayback() {
    if (!this.isPlayingAudio && !this.currentPlayProcess) return;
    console.log('⚡ [Barge-In] Assistant speech interrupted by user');
    if (this.currentPlayProcess) {
      try {
        this.currentPlayProcess.kill('SIGTERM');
      } catch { /* noop */ }
      this.currentPlayProcess = null;
    }
    clearTimeout(this._unmuteTimer);
    this.isPlayingAudio = false;
    this.playQueue = Promise.resolve();
    this._frameAcc = Buffer.alloc(0);
    playEarcon('interrupted');
  }

  /**
   * Start the voice agent
   * Initiates WebSocket connection with reconnection logic
   */
  async start() {
    await this._connectWithBackoff();
  }

  /**
   * Fetch temporary AssemblyAI token from local server
   * The server mints a 5-minute token using the stored API key
   * @returns {Promise<string>} Temporary access token
   * @throws {Error} If token fetch fails with specific error details
   */
  async _fetchToken() {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 10000);
    
    try {
      const res = await fetch(`http://localhost:${cfg('PORT', '3000')}/api/voice-token`, {
        signal: controller.signal
      });
      clearTimeout(timeout);
      
      if (!res.ok) {
        const errorText = await res.text().catch(() => 'No error details');
        throw new Error(`voice-token endpoint returned ${res.status}: ${errorText}`);
      }
      const data = await res.json();
      if (!data.token) {
        throw new Error('Server response missing token field');
      }
      return data.token;
    } catch (err) {
      clearTimeout(timeout);
      if (err.name === 'AbortError') {
        throw new Error('Token fetch timed out - server may be unresponsive');
      }
      if (err.code === 'ECONNREFUSED' || err.cause?.code === 'ECONNREFUSED') {
        throw new Error('Cannot connect to local server - ensure npm start is running');
      }
      throw err; // Re-throw original error if it's already descriptive
    }
  }

  /**
   * Connect to AssemblyAI WebSocket with exponential backoff reconnection
   * Attempts to restore previous session if within grace window
   * @throws {Error} If all reconnection attempts fail
   */
  async _connectWithBackoff() {
    const saved = await loadState();
    if (saved.sessionId) {
      this.sessionId = saved.sessionId;
      console.log(`Restored previous session ${this.sessionId} from the store`);
    }
    while (this.shouldRun && this.reconnectAttempts <= MAX_RECONNECT_ATTEMPTS) {
      try {
        await this._connectOnce();
        return; // _connectOnce resolves only on intentional shutdown
      } catch (err) {
        this.reconnectAttempts++;
        if (!this.shouldRun || this.reconnectAttempts > MAX_RECONNECT_ATTEMPTS) throw err;
        const delay = Math.min(BASE_BACKOFF_MS * 2 ** (this.reconnectAttempts - 1), 30_000);
        console.log(`Reconnect attempt ${this.reconnectAttempts}/${MAX_RECONNECT_ATTEMPTS} in ${delay}ms (${err.message})`);
        await new Promise((r) => setTimeout(r, delay));
      }
    }
  }

  /**
   * Establish a single WebSocket connection to AssemblyAI
   * Handles session resume if within grace window, otherwise starts fresh session
   * @returns {Promise<void>} Resolves on intentional shutdown, rejects on connection failure
   */
  _connectOnce() {
    return new Promise(async (resolve, reject) => {
      let settled = false;
      const fail = (err) => {
        if (!settled) {
          settled = true;
          reject(err);
        }
      };
      try {
        const token = await this._fetchToken();
        const wsUrl = `wss://agents.assemblyai.com/v1/ws?token=${token}`;
        console.log('Connecting to AssemblyAI…');
        this.ws = new WebSocket(wsUrl);
      } catch (err) {
        fail(err);
        return;
      }

      this.ws.on('open', () => {
        console.log('WebSocket connected to AssemblyAI');
        this.reconnectAttempts = 0;
        clearTimeout(this._graceTimer);
        if (this.sessionId && this._disconnectAt && Date.now() - this._disconnectAt < GRACE_WINDOW_MS) {
          console.log(`Resuming session ${this.sessionId} within grace window`);
          this._wsSend({ type: 'session.resume', session_id: this.sessionId });
        } else {
          if (this.sessionId) console.log('Previous session outside grace window; starting fresh');
          this.initializeSession();
        }
        this._flushAudioBuffer();
        this._startHeartbeat();
      });

      this.ws.on('message', async (data) => {
        await this.handleMessage(data);
      });

      this.ws.on('error', (error) => {
        console.error('WebSocket error:', error.message);
      });

      this.ws.on('close', (code, reason) => {
        console.log(`WebSocket closed (code=${code}, reason=${reason || 'n/a'})`);
        clearInterval(this._heartbeat);
        this._disconnectAt = Date.now();
        // Keep recording during grace window so no speech is lost; buffer instead of sending.
        if (!this.shouldRun) {
          if (!settled) {
            settled = true;
            resolve();
          }
          return;
        }
        // Schedule reconnect within grace window
        clearTimeout(this._graceTimer);
        this._graceTimer = setTimeout(() => {
          console.log('Grace window expired; starting fresh session on next connect');
          this.sessionId = null;
          saveState({ sessionId: null });
        }, GRACE_WINDOW_MS);
        if (!settled) {
          settled = true;
          reject(new Error(`WebSocket closed: ${code}`));
        }
      });
    });
  }

  /**
   * Initialize or update session configuration
   * Sends LLM provider configuration for BYOK (Bring Your Own Key) support
   * Allows switching LLM providers without re-publishing the agent
   */
  initializeSession() {
    // Client-side session config: the LLM provider/models come from the local
    // env on every connect, so switching providers needs no re-publish.
    // The stored agent (AGENT_ID) remains the fallback for prompt/voice/tools.
    const session = {
      agent_id: cfg('AGENT_ID'),
    };
    try {
      const llm = buildLlmRoutes();
      if (llm.length > 0) {
        session.llm = llm;
        const cfg = resolveLlmConfig();
        console.log(`Session LLM override: ${cfg.baseUrl} (fast=${cfg.fast}, strong=${cfg.strong})`);
      } else {
        console.log('No local LLM provider configured; using stored agent LLM');
      }
    } catch (err) {
      console.warn(`Could not build session LLM override, using stored agent LLM: ${err.message}`);
    }
    this._wsSend({
      type: 'session.update',
      session,
    });
    console.log('Session configuration sent');
  }

  /**
   * Start WebSocket heartbeat to keep connection alive
   * Sends ping every 15 seconds when connection is open
   */
  _startHeartbeat() {
    clearInterval(this._heartbeat);
    this._heartbeat = setInterval(() => {
      if (this.ws && this.ws.readyState === WebSocket.OPEN) {
        this.ws.ping();
      }
    }, 15_000);
  }

  /**
   * Flush buffered audio frames to WebSocket
   * Called when connection is re-established after disconnection
   */
  _flushAudioBuffer() {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
    while (this.audioBuffer.length > 0) {
      const audio = this.audioBuffer.shift();
      this.ws.send(JSON.stringify({ type: 'input.audio', audio }));
    }
  }

  /**
   * Send audio frame to AssemblyAI or buffer if disconnected
   * Maintains bounded buffer during disconnections to avoid memory issues
   * @param {string} base64Audio - Base64-encoded audio frame
   */
  _sendAudioFrame(base64Audio) {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this._flushAudioBuffer();
      this.ws.send(JSON.stringify({ type: 'input.audio', audio: base64Audio }));
    } else {
      // Buffer during outages (bounded) so speech in the grace window isn't lost
      if (this.audioBuffer.length < MAX_BUFFERED_FRAMES) {
        this.audioBuffer.push(base64Audio);
      } else {
        this.audioBuffer.shift();
        this.audioBuffer.push(base64Audio);
      }
    }
  }

  /**
   * Handle incoming WebSocket messages from AssemblyAI
   * Routes message types to appropriate handlers (session, audio, tools)
   * @param {Buffer} data - Raw message data from WebSocket
   */
  async handleMessage(data) {
    try {
      const message = JSON.parse(data.toString());
      console.log('Received message type:', message.type);

      switch (message.type) {
        case 'session.ready':
          console.log('Session ready, starting audio capture');
          this.sessionId = message.session_id;
          await saveState({ sessionId: this.sessionId });
          this._disconnectAt = null;
          this.startRecording();
          playEarcon('listening');
          break;

        case 'session.resumed':
          console.log(`Session resumed: ${message.session_id}`);
          this.sessionId = message.session_id;
          await saveState({ sessionId: this.sessionId });
          this._disconnectAt = null;
          this.startRecording();
          playEarcon('listening');
          break;

        case 'session.updated':
          console.log('Session updated');
          break;

        case 'user.transcript':
          console.log(`User: ${message.transcript}`);
          await saveState({ sessionId: this.sessionId, lastTranscript: message.transcript });
          break;

        case 'user.transcript.delta':
          break;

        case 'reply.audio':
          await this.playAudio(message.audio);
          break;

        case 'reply.done':
          console.log('Reply completed');
          break;

        case 'tool.call':
          await this.handleToolCall(message);
          break;

        case 'session.error':
          console.error('Session error:', message.error);
          break;

        case 'session.ended':
          console.log('Session ended');
          this.sessionId = null;
          await saveState({ sessionId: null });
          this.stopRecording();
          break;

        default:
          console.log('Unhandled message type:', message.type);
      }
    } catch (error) {
      console.error('Error handling message:', error);
    }
  }

  /**
   * Send message to WebSocket if connection is open
   * @param {Object} obj - Message object to send
   * @returns {boolean} True if sent, false if connection not open
   */
  _wsSend(obj) {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(obj));
      return true;
    }
    console.warn(`WS not open; dropped message: ${obj.type}`);
    return false;
  }

  /**
   * Handle tool call requests from AssemblyAI
   * Dispatches to local tool handlers and sends results back
   * @param {Object} message - Tool call message with call_id, name, and arguments
   */
  async handleToolCall(message) {
    const { call_id, name, arguments: args } = message;
    console.log(`Tool call: ${name}`, args);

    try {
      const result = await dispatchTool(name, args);

      this._wsSend({
        type: 'tool.result',
        call_id: call_id,
        result: JSON.stringify(result),
      });

      console.log(`Tool result sent for ${name}`);
    } catch (error) {
      console.error(`Error executing tool ${name}:`, error);

      // Send structured error response with fallback
      const errorResponse = {
        error: error.message || 'Unknown error occurred',
        tool: name,
        timestamp: new Date().toISOString()
      };

      this._wsSend({
        type: 'tool.result',
        call_id: call_id,
        result: JSON.stringify(errorResponse),
      });
    }
  }

  /**
   * Start audio capture using FFmpeg
   * Platform-specific device selection (Windows dshow, macOS avfoundation, Linux ALSA)
   * Implements barge-in detection and audio frame accumulation
   * Auto-restarts on process exit if session is still active
   */
  startRecording() {
    if (this.isRecording) return;

    console.log('Starting audio capture');
    this.isRecording = true;
    this._frameAcc = Buffer.alloc(0);

    const isWindows = process.platform === 'win32';
    const device = process.env.AUDIO_DEVICE || (isWindows ? 'default' : ':default');
    const ffmpegArgs = isWindows
      ? ['-f', 'dshow', '-i', `audio=${device}`, '-ar', '16000', '-ac', '1', '-f', 's16le', '-']
      : process.platform === 'darwin'
        ? ['-f', 'avfoundation', '-i', device, '-ar', '16000', '-ac', '1', '-f', 's16le', '-']
        : ['-f', 'alsa', '-i', process.env.AUDIO_DEVICE || 'default', '-ar', '16000', '-ac', '1', '-f', 's16le', '-'];

    try {
      this.recordingProcess = spawn('ffmpeg', ffmpegArgs);
    } catch (err) {
      console.error('Failed to spawn FFmpeg:', err.message);
      this.isRecording = false;
      return;
    }

    this.recordingProcess.stdout.on('data', (data) => {
      // Check for user barge-in / interruption while assistant is speaking
      if (this.isPlayingAudio) {
        const rms = rmsInt16(data);
        if (rms > BARGE_IN_THRESHOLD) {
          this.interruptPlayback();
        } else {
          // Duck microphone speaker echo while audio is playing
          this._frameAcc = Buffer.alloc(0);
          return;
        }
      }
      // Accumulate into fixed-size frames to reduce WS message rate (perf optimization)
      this._frameAcc = Buffer.concat([this._frameAcc, data]);
      while (this._frameAcc.length >= AUDIO_FRAME_BYTES) {
        const frame = this._frameAcc.subarray(0, AUDIO_FRAME_BYTES);
        this._frameAcc = this._frameAcc.subarray(AUDIO_FRAME_BYTES);
        this._sendAudioFrame(frame.toString('base64'));
      }
    });

    this.recordingProcess.stderr.on('data', (data) => {
      const msg = data.toString();
      // ffmpeg writes progress to stderr; only surface real errors
      if (/error|failed|invalid/i.test(msg)) console.error('Recording error:', msg.slice(0, 300));
    });

    this.recordingProcess.on('error', (err) => {
      console.error('Recording process error:', err.message);
      this.isRecording = false;
    });

    this.recordingProcess.on('close', (code) => {
      console.log(`Recording process exited with code ${code}`);
      this.isRecording = false;
      // Auto-restart capture if the agent is still supposed to run
      if (this.shouldRun && this.sessionId) {
        console.log('Restarting audio capture in 1s…');
        setTimeout(() => {
          if (this.shouldRun && !this.isRecording) this.startRecording();
        }, 1000);
      }
    });
  }

  /**
   * Stop audio capture and flush any partial audio frame
   * Sends remaining audio data before terminating FFmpeg process
   */
  stopRecording() {
    // Flush any partial frame first
    if (this._frameAcc && this._frameAcc.length > 0) {
      this._sendAudioFrame(this._frameAcc.toString('base64'));
      this._frameAcc = Buffer.alloc(0);
    }
    if (!this.isRecording || !this.recordingProcess) return;

    console.log('Stopping audio capture');
    try {
      this.recordingProcess.kill('SIGTERM');
    } catch { /* noop */ }
    this.recordingProcess = null;
    this.isRecording = false;
  }

  /**
   * Play audio response using ffplay
   * Serializes playback to prevent overlapping TTS chunks
   * Implements 250ms post-playback delay for room reverb dissipation
   * @param {string} base64Audio - Base64-encoded audio data
   */
  async playAudio(base64Audio) {
    // Serialize playback so overlapping TTS chunks don't spawn competing ffplay instances
    this.playQueue = this.playQueue.then(
      () =>
        new Promise((resolve) => {
          try {
            clearTimeout(this._unmuteTimer);
            this.isPlayingAudio = true;
            const audioBuffer = Buffer.from(base64Audio, 'base64');
            const playProcess = spawn('ffplay', ['-nodisp', '-autoexit', '-'], {
              stdio: ['pipe', 'ignore', 'ignore'],
            });
            this.currentPlayProcess = playProcess;

            const onDone = () => {
              if (this.currentPlayProcess === playProcess) {
                this.currentPlayProcess = null;
              }
              // 250ms grace period so room reverb dissipates before microphone re-opens
              clearTimeout(this._unmuteTimer);
              this._unmuteTimer = setTimeout(() => {
                this.isPlayingAudio = false;
              }, 250);
              resolve();
            };

            playProcess.stdin.write(audioBuffer);
            playProcess.stdin.end();
            playProcess.on('close', () => onDone());
            playProcess.on('error', (err) => {
              console.error('Audio playback error:', err.message);
              onDone();
            });
          } catch (error) {
            console.error('Error playing audio:', error);
            this.isPlayingAudio = false;
            this.currentPlayProcess = null;
            resolve();
          }
        })
    );
    return this.playQueue;
  }

  /**
   * End the current session gracefully
   * Sends explicit session.end to avoid idle billing
   * Stops recording, clears session state, and closes WebSocket
   */
  endSession() {
    this.shouldRun = false;
    clearTimeout(this._graceTimer);
    clearInterval(this._heartbeat);
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      // Explicit end avoids idle billing past the grace window
      this._wsSend({ type: 'session.end' });
      setTimeout(() => this.ws?.close(), 500);
    }
    this.stopRecording();
    this.sessionId = null;
    saveState({ sessionId: null });
  }
}

// Main execution (only when run directly, so tests can import VoiceAgent)
export { VoiceAgent };
const isMain = process.argv[1] && process.argv[1].endsWith('agent.js');
if (isMain) {
  // Dangerous-tool approvals are resolved in the server process (which owns the
  // /api/confirm browser UI), so delegate there when running standalone.
  // The agent also uses the server as its DuckDB gateway (remote store mode) —
  // this process never opens the database file itself (single-writer rule).
  if (!process.env.APPROVAL_HTTP_URL) {
    process.env.APPROVAL_HTTP_URL = `http://localhost:${cfg('PORT', '3000')}`;
  }
  const agent = new VoiceAgent();

  process.on('SIGINT', () => {
    console.log('Shutting down gracefully...');
    agent.endSession();
    setTimeout(() => process.exit(0), 800);
  });

  process.on('SIGTERM', () => {
    console.log('Shutting down gracefully...');
    agent.endSession();
    setTimeout(() => process.exit(0), 800);
  });

  initStore({ remote: process.env.APPROVAL_HTTP_URL })
    .then(() => agent.start())
    .catch((error) => {
      console.error('Failed to start agent:', error);
      process.exit(1);
    });
}
