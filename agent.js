import WebSocket from 'ws';
import { spawn } from 'child_process';
import { dispatchTool } from './tools.js';
import { playEarcon } from './lib/sound-effects.js';
import { buildLlmRoutes, resolveLlmConfig } from './lib/model-router.js';
import { initStore, loadSession, saveSession, cfg } from './lib/store.js';
import dotenv from 'dotenv';

dotenv.config();

const GRACE_WINDOW_MS = 30_000; // AssemblyAI 30s grace window after disconnect
const MAX_RECONNECT_ATTEMPTS = 10;
const BASE_BACKOFF_MS = 1000;
const AUDIO_FRAME_BYTES = 5120; // 160ms @ 16kHz 16-bit mono — fewer, larger WS messages
const MAX_BUFFERED_FRAMES = 32; // ~5s of audio held while disconnected
const BARGE_IN_THRESHOLD = Number(process.env.BARGE_IN_THRESHOLD || 2800);

function rmsInt16(buf) {
  let sum = 0;
  const n = Math.floor(buf.length / 2);
  for (let i = 0; i < n; i++) {
    const v = buf.readInt16LE(i * 2);
    sum += v * v;
  }
  return Math.sqrt(sum / Math.max(1, n));
}

async function loadState() {
  try {
    return (await loadSession()) || {};
  } catch {
    return {};
  }
}

async function saveState(state) {
  try {
    await saveSession({ ...state, updatedAt: new Date().toISOString() });
  } catch (err) {
    console.error('Failed to persist session state:', err.message);
  }
}

class VoiceAgent {
  constructor() {
    this.ws = null;
    this.recordingProcess = null;
    this.sessionId = null;
    this.isRecording = false;
    this.reconnectAttempts = 0;
    this.shouldRun = true;
    this.audioBuffer = []; // base64 frames queued while socket is down
    this._frameAcc = Buffer.alloc(0);
    this._heartbeat = null;
    this._graceTimer = null;
    this._disconnectAt = null;
    this.playQueue = Promise.resolve();
    this.isPlayingAudio = false;
    this.currentPlayProcess = null;
    this._unmuteTimer = null;
  }

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

  async start() {
    await this._connectWithBackoff();
  }

  async _fetchToken() {
    const res = await fetch(`http://localhost:${cfg('PORT', '3000')}/api/voice-token`);
    if (!res.ok) throw new Error(`voice-token endpoint returned ${res.status}`);
    const { token } = await res.json();
    if (!token) throw new Error('Failed to obtain voice token');
    return token;
  }

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

  _startHeartbeat() {
    clearInterval(this._heartbeat);
    this._heartbeat = setInterval(() => {
      if (this.ws && this.ws.readyState === WebSocket.OPEN) {
        this.ws.ping();
      }
    }, 15_000);
  }

  _flushAudioBuffer() {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
    while (this.audioBuffer.length > 0) {
      const audio = this.audioBuffer.shift();
      this.ws.send(JSON.stringify({ type: 'input.audio', audio }));
    }
  }

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

  _wsSend(obj) {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(obj));
      return true;
    }
    console.warn(`WS not open; dropped message: ${obj.type}`);
    return false;
  }

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

      this._wsSend({
        type: 'tool.result',
        call_id: call_id,
        result: JSON.stringify({ error: error.message }),
      });
    }
  }

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

    this.recordingProcess = spawn('ffmpeg', ffmpegArgs);

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
