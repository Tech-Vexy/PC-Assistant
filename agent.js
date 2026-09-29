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
import { dispatchTool, buildAllTools } from './tools.js';
import { playEarcon } from './lib/sound-effects.js';
import { buildLlmRoutes, resolveLlmConfig } from './lib/model-router.js';
import { initStore, loadSession, saveSession, cfg } from './lib/store.js';
import { VoiceActivityDetector } from './lib/vad.js';
import dotenv from 'dotenv';

dotenv.config(process.env.DOTENV_PATH ? { path: process.env.DOTENV_PATH } : undefined);

// AssemblyAI grace window allows session resume within 30s of disconnect
const GRACE_WINDOW_MS = 30_000;
const MAX_RECONNECT_ATTEMPTS = 10;
const BASE_BACKOFF_MS = 1000;
// Voice Agent API standard sample rate: 24kHz 16-bit mono PCM
const AUDIO_SAMPLE_RATE = 24000;
// Audio frame size: 100ms @ 24kHz 16-bit mono = 4800 bytes
// Larger frames reduce WebSocket message overhead while maintaining low latency
const AUDIO_FRAME_BYTES = 4800;
// Buffer ~5s of audio during disconnections to avoid speech loss
const MAX_BUFFERED_FRAMES = 50;
// RMS threshold for barge-in detection (user interrupting assistant)
// Default 8000 prevents laptop speaker bleed from triggering self-interruption; 0 disables
const BARGE_IN_THRESHOLD = Number(process.env.BARGE_IN_THRESHOLD ?? 8000);

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
 * Windows dshow has no "default" pseudo-device (unlike ALSA): capture with
 * `audio=default` always fails. Resolve the first real audio input device
 * once and cache the result. Returns null when no microphone is found.
 */
let _dshowDevicePromise = null;
function resolveWindowsAudioDevice() {
  if (!_dshowDevicePromise) {
    _dshowDevicePromise = new Promise((resolve) => {
      const p = spawn('ffmpeg', ['-hide_banner', '-f', 'dshow', '-list_devices', 'true', '-i', 'dummy'], { stdio: ['ignore', 'ignore', 'pipe'] });
      let stderr = '';
      p.stderr.on('data', (d) => (stderr += d.toString()));
      p.on('close', () => {
        const m = stderr.match(/"(.+?)"\s+\(audio\)/);
        resolve(m ? m[1] : null);
      });
      p.on('error', () => resolve(null));
    });
  }
  return _dshowDevicePromise;
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
    this._chunkList = []; // Buffered audio chunks from ffmpeg
    this._chunkTotalBytes = 0; // Running total of buffered bytes
    this._heartbeat = null; // WebSocket heartbeat interval
    this._graceTimer = null; // Timer for grace window expiration
    this._disconnectAt = null; // Timestamp of last disconnection
    this.playQueue = Promise.resolve(); // Serialized audio playback queue
    this.isPlayingAudio = false; // Current playback state
    this.currentPlayProcess = null; // Current ffplay process
    this._unmuteTimer = null; // Timer for post-playback microphone unmute delay
    this.vad = new VoiceActivityDetector({
      sampleRate: AUDIO_SAMPLE_RATE,
      bargeInThreshold: BARGE_IN_THRESHOLD,
    });
  }

  /**
   * Ensure a streaming ffplay process is active to receive synthesized PCM audio
   * AssemblyAI streams 24kHz 16-bit mono PCM chunks in real time
   * @returns {import('child_process').ChildProcess} Active ffplay process
   */
  _ensureAudioPlayer() {
    if (this.currentPlayProcess && !this.currentPlayProcess.killed && this.currentPlayProcess.stdin && !this.currentPlayProcess.stdin.destroyed) {
      return this.currentPlayProcess;
    }
    clearTimeout(this._unmuteTimer);
    this.isPlayingAudio = true;
    this.vad.onPlaybackStarted();

    // Stream raw PCM16 at 24000Hz mono directly to ffplay
    // -ch_layout mono is the modern FFmpeg option (replacing deprecated -ac)
    const proc = spawn('ffplay', ['-nodisp', '-autoexit', '-f', 's16le', '-ar', String(AUDIO_SAMPLE_RATE), '-ch_layout', 'mono', '-'], {
      stdio: ['pipe', 'ignore', 'ignore'],
    });

    // Prevent uncaught EPIPE exceptions if ffplay exits or is interrupted
    proc.stdin?.on('error', (err) => {
      if (err.code !== 'EPIPE') {
        console.error('Audio playback stdin error:', err.message);
      }
    });

    this.currentPlayProcess = proc;

    const cleanup = () => {
      if (this.currentPlayProcess === proc) {
        this.currentPlayProcess = null;
      }
      clearTimeout(this._unmuteTimer);
      this._unmuteTimer = setTimeout(() => {
        this.isPlayingAudio = false;
        this.vad.onPlaybackEnded();
      }, 250);
    };

    proc.on('close', cleanup);
    proc.on('error', (err) => {
      console.error('Audio playback stream error:', err.message);
      cleanup();
    });

    return proc;
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
    this.vad.onPlaybackEnded();
    this.playQueue = Promise.resolve();
    this._chunkList = [];
    this._chunkTotalBytes = 0;
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
        // NOTE: reconnectAttempts is NOT reset here — a socket can open and
        // then be immediately rejected (session.error → close), and resetting
        // on open makes the backoff counter never advance. The counter resets
        // in the session.ready/resumed handlers instead.
        clearTimeout(this._graceTimer);
        if (this.sessionId && this._disconnectAt && Date.now() - this._disconnectAt < GRACE_WINDOW_MS) {
          console.log(`Resuming session ${this.sessionId} within grace window`);
          this._wsSend({ type: 'session.resume', session_id: this.sessionId });
        } else {
          if (this.sessionId) {
            console.log('Previous session outside grace window; starting fresh');
            this.sessionId = null;
          }
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
   * Initialize session configuration per the Voice Agent API protocol
   * (docs: Events reference → session.update).
   *
   * `session.agent_id` binds a stored agent and is FIRST-update-only and
   * MUTUALLY EXCLUSIVE with inline session fields (system_prompt, tools, llm…)
   * — there is no llm field in session config at all. LLM routes therefore
   * live on the published agent record (setup-agent.js embeds them), so
   * switching providers is a re-publish, not a session field.
   */
  initializeSession() {
    const agentId = cfg('AGENT_ID');
    if (agentId) {
      this._wsSend({
        type: 'session.update',
        session: { agent_id: agentId },
      });
      console.log(`Session bound to stored agent ${agentId}`);
      return;
    }

    // No stored agent: degraded inline mode — client-side tools + local LLM
    // routes, AssemblyAI's default prompt/voice. Publish (`npm run publish`)
    // to get the full agent.
    console.warn('⚠️  No AGENT_ID configured — connecting in inline mode with client-side tools only. Run `npm run publish`.');
    const session = { tools: buildAllTools() };
    try {
      const llm = buildLlmRoutes();
      if (llm.length > 0) {
        session.llm = llm;
        const llmCfg = resolveLlmConfig();
        console.log(`Inline LLM: ${llmCfg.baseUrl} (fast=${llmCfg.fast}, strong=${llmCfg.strong})`);
      }
    } catch (err) {
      console.warn(`Could not build LLM routes, using managed LLM: ${err.message}`);
    }
    this._wsSend({ type: 'session.update', session });
    console.log('Session configuration sent (inline mode)');
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
      this.ws.send('{"type":"input.audio","audio":"' + audio + '"}');
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
      this.ws.send('{"type":"input.audio","audio":"' + base64Audio + '"}');
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
      if (
        message.type !== 'reply.audio' &&
        message.type !== 'transcript.agent.delta' &&
        message.type !== 'transcript.user.delta'
      ) {
        console.log('Received message type:', message.type);
      }

      switch (message.type) {
        case 'session.ready':
          console.log('Session ready, starting audio capture');
          this.sessionId = message.session_id;
          process.env.AGENT_SESSION_ID = this.sessionId; // tags undo journal rows
          await saveState({ sessionId: this.sessionId });
          this._disconnectAt = null;
          this.reconnectAttempts = 0; // session established — reset backoff
          this.startRecording();
          playEarcon('listening');
          break;

        case 'session.resumed':
          console.log(`Session resumed: ${message.session_id}`);
          this.sessionId = message.session_id;
          process.env.AGENT_SESSION_ID = this.sessionId; // tags undo journal rows
          await saveState({ sessionId: this.sessionId });
          this._disconnectAt = null;
          this.reconnectAttempts = 0; // session established — reset backoff
          this.startRecording();
          playEarcon('listening');
          break;

        case 'session.updated':
          console.log('Session updated');
          break;

        case 'reply.started':
          // Prepare the streaming audio player for the assistant's speech turn
          this._ensureAudioPlayer();
          break;

        case 'reply.audio': {
          const audio = message.data || message.audio;
          if (audio) {
            await this.playAudio(audio);
          }
          break;
        }

        case 'transcript.agent.delta': {
          const delta = message.text_delta || message.delta || message.text || '';
          if (delta) {
            process.stdout.write(delta);
          }
          break;
        }

        case 'transcript.agent': {
          const text = message.transcript || message.text || '';
          if (text) {
            console.log(`\nAssistant: ${text}`);
          }
          break;
        }

        case 'transcript.user.delta':
        case 'user.transcript.delta':
        case 'input.speech.started':
        case 'input.speech.stopped':
          break;

        case 'transcript.user':
        case 'user.transcript': {
          const text = message.transcript || message.text || '';
          console.log(`\nUser: ${text}`);
          await saveState({ sessionId: this.sessionId, lastTranscript: text });
          break;
        }

        case 'reply.done': {
          const status = message.status || 'completed';
          console.log(`\nReply ${status}`);
          if (status === 'interrupted') {
            this.interruptPlayback();
          } else {
            // Signal EOF on stdin so ffplay plays remaining buffered PCM and exits cleanly
            if (this.currentPlayProcess?.stdin && !this.currentPlayProcess.stdin.destroyed) {
              this.currentPlayProcess.stdin.end();
            }
          }
          break;
        }

        case 'tool.call':
          await this.handleToolCall(message);
          break;

        case 'session.error': {
          const errDetail = message.error || message.message || JSON.stringify(message);
          console.error('Session error:', errDetail);
          this.sessionId = null;
          this._disconnectAt = null;
          await saveState({ sessionId: null });
          // A rejected session.update recurs on every reconnect — close now
          // so the backoff loop advances and eventually exhausts instead of
          // connect→error→close spinning at attempt 1 forever.
          if (this.ws && this.ws.readyState === WebSocket.OPEN) {
            try { this.ws.close(1000, 'session.error'); } catch { /* noop */ }
          }
          break;
        }

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
  async startRecording() {
    if (this.isRecording) return;

    this.isRecording = true;
    this._chunkList = [];
    this._chunkTotalBytes = 0;

    const isWindows = process.platform === 'win32';
    let device = process.env.AUDIO_DEVICE || (isWindows ? await resolveWindowsAudioDevice() : ':default');
    if (!device) device = 'default'; // last resort: will fail loudly in ffmpeg stderr
    console.log(`Starting audio capture (device: ${device})`);
    const ffmpegArgs = isWindows
      ? ['-f', 'dshow', '-i', `audio=${device}`, '-ar', String(AUDIO_SAMPLE_RATE), '-ac', '1', '-f', 's16le', '-']
      : process.platform === 'darwin'
        ? ['-f', 'avfoundation', '-i', device, '-ar', String(AUDIO_SAMPLE_RATE), '-ac', '1', '-f', 's16le', '-']
        : ['-f', 'alsa', '-i', process.env.AUDIO_DEVICE || 'default', '-ar', String(AUDIO_SAMPLE_RATE), '-ac', '1', '-f', 's16le', '-'];

    try {
      this.recordingProcess = spawn('ffmpeg', ffmpegArgs);
    } catch (err) {
      console.error('Failed to spawn FFmpeg:', err.message);
      this.isRecording = false;
      return;
    }

    this.recordingProcess.stdout.on('data', (data) => {
      // Accumulate into fixed-size frames to reduce WS message rate and feed VAD
      this._chunkList.push(data);
      this._chunkTotalBytes += data.length;
      if (this._chunkTotalBytes >= AUDIO_FRAME_BYTES) {
        const merged = Buffer.concat(this._chunkList);
        let offset = 0;
        while (merged.length - offset >= AUDIO_FRAME_BYTES) {
          const frame = merged.subarray(offset, offset + AUDIO_FRAME_BYTES);
          offset += AUDIO_FRAME_BYTES;

          // Process frame through VAD and acoustic echo ducking
          const vadRes = this.vad.process(frame, this.isPlayingAudio);

          if (vadRes.shouldBargeIn) {
            this.interruptPlayback();
          }

          if (vadRes.shouldSend) {
            // Send any pre-roll frames to preserve word onset
            if (vadRes.preRollFrames && vadRes.preRollFrames.length > 0) {
              for (const preRoll of vadRes.preRollFrames) {
                this._sendAudioFrame(preRoll.toString('base64'));
              }
            }
            this._sendAudioFrame(frame.toString('base64'));
          }
        }
        const remaining = merged.subarray(offset);
        if (remaining.length > 0) {
          this._chunkList = [remaining];
          this._chunkTotalBytes = remaining.length;
        } else {
          this._chunkList = [];
          this._chunkTotalBytes = 0;
        }
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
    if (this._chunkTotalBytes > 0) {
      const merged = Buffer.concat(this._chunkList);
      this._sendAudioFrame(merged.toString('base64'));
      this._chunkList = [];
      this._chunkTotalBytes = 0;
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
   * Play audio response by streaming PCM chunks to ffplay
   * Writes base64-decoded PCM16 frames directly to the active audio player process
   * @param {string} base64Audio - Base64-encoded audio data
   */
  async playAudio(base64Audio) {
    if (!base64Audio || typeof base64Audio !== 'string') return;
    try {
      const proc = this._ensureAudioPlayer();
      const audioBuffer = Buffer.from(base64Audio, 'base64');
      if (proc?.stdin && !proc.stdin.destroyed && proc.stdin.writable) {
        proc.stdin.write(audioBuffer, (err) => {
          if (err && err.code !== 'EPIPE') {
            console.error('Audio write error:', err.message);
          }
        });
      }
    } catch (error) {
      console.error('Error writing audio chunk:', error.message);
    }
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
