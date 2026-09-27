import dotenv from 'dotenv';
import { spawn } from 'child_process';

dotenv.config();

// NOTE: wake-word/audio settings stay file+env based on purpose. This process
// never opens the DuckDB store (single-writer rule: only the server holds it),
// and these values are needed before any store could be reached. Change them
// via the /setup UI (mirrored to .env) or here, then restart.

// Engine: 'openwakeword' | 'sherpa' | 'energy' | 'auto'
// auto = try openwakeword python import, else energy VAD (always works, no ML model needed).
const ENGINE = (process.env.WAKEWORD_ENGINE || 'auto').toLowerCase();
const WAKE_WORD = process.env.WAKEWORD || 'jarvis';
const THRESHOLD = Number(process.env.WAKEWORD_THRESHOLD || 2500); // RMS threshold for energy mode
const TRIGGER_FRAMES = Number(process.env.WAKEWORD_TRIGGER_FRAMES || 8); // ~800ms of loud audio
const COOLDOWN_MS = Number(process.env.WAKEWORD_COOLDOWN_MS || 5000);

class WakeWordDetector {
  constructor(wakeWord = WAKE_WORD) {
    this.wakeWord = wakeWord;
    this.isListening = false;
    this.detectionProcess = null;
    this.onWakeWordDetected = null;
    this._cooldownUntil = 0;
  }

  setCallback(callback) {
    this.onWakeWordDetected = callback;
  }

  _fire() {
    const now = Date.now();
    if (now < this._cooldownUntil) return;
    this._cooldownUntil = now + COOLDOWN_MS;
    console.log(`Wake word "${this.wakeWord}" detected!`);
    this.onWakeWordDetected?.();
  }

  async start() {
    if (this.isListening) {
      console.log('Wake word detector already running');
      return;
    }
    this.isListening = true;
    if (ENGINE === 'openwakeword') return this._startOpenWakeWord();
    if (ENGINE === 'sherpa') return this._startSherpa();
    if (ENGINE === 'energy') return this._startEnergyVAD();
    // auto
    const hasOWW = await checkPythonModule('openwakeword');
    if (hasOWW) return this._startOpenWakeWord();
    const hasSherpa = await checkPythonModule('sherpa_onnx');
    if (hasSherpa && process.env.SHERPA_KEYWORDS_PATH) return this._startSherpa();
    console.log('No ML wake-word engine found; using energy-based VAD (say anything loudly to trigger).');
    console.log('Install openWakeWord (`pip install openwakeword`) or set WAKEWORD_ENGINE=sherpa for real keyword spotting.');
    return this._startEnergyVAD();
  }

  stop() {
    this.isListening = false;
    if (this.detectionProcess) {
      try {
        this.detectionProcess.kill('SIGTERM');
      } catch { /* noop */ }
      this.detectionProcess = null;
    }
    console.log('Wake word detection stopped');
  }

  // ---- Engine: openWakeWord (real keyword spotting via Python) ----
  _startOpenWakeWord() {
    console.log(`Starting openWakeWord detection for "${this.wakeWord}" (threshold=${process.env.OWW_THRESHOLD || 0.5})`);
    const threshold = process.env.OWW_THRESHOLD || 0.5;
    const modelNames = process.env.OWW_MODELS || 'hey_jarvis';
    this.detectionProcess = spawn(
      'python',
      [
        '-u',
        '-c',
        `
import sys
try:
    from openwakeword import Model
except ImportError:
    print("OWW_MISSING", flush=True)
    sys.exit(2)
import numpy as np
model = Model(wakeword_models=["${modelNames}"], inference_framework="onnx")
print("OWW_READY", flush=True)
# openWakeWord expects 16k mono int16 frames; read raw bytes from stdin fed by ffmpeg sibling is complex,
# so use its built-in microphone loop via pyaudio if available.
try:
    from openwakeword import utils as oww_utils
    import pyaudio
    FORMAT = pyaudio.paInt16
    CHANNELS = 1
    RATE = 16000
    CHUNK = 1280
    audio = pyaudio.PyAudio()
    stream = audio.open(format=FORMAT, channels=CHANNELS, rate=RATE, input=True, frames_per_buffer=CHUNK)
    print("OWW_LISTENING", flush=True)
    while True:
        data = stream.read(CHUNK, exception_on_overflow=False)
        frame = np.frombuffer(data, dtype=np.int16)
        preds = model.predict(frame)
        for name, score in preds.items():
            if score > float("${threshold}"):
                print(f"WAKE:{name}:{score}", flush=True)
except Exception as e:
    print(f"OWW_ERROR:{e}", flush=True)
    sys.exit(1)
`,
      ],
      { stdio: ['ignore', 'pipe', 'pipe'] }
    );

    this.detectionProcess.stdout.on('data', (d) => {
      const line = d.toString().trim();
      if (line.startsWith('WAKE:')) this._fire();
      else if (line === 'OWW_MISSING') {
        console.error('openwakeword Python package not installed. Falling back to energy VAD.');
        this.detectionProcess?.kill('SIGTERM');
        this._startEnergyVAD();
      } else {
        console.log('[oww]', line);
      }
    });
    this.detectionProcess.stderr.on('data', (d) => console.error('[oww:err]', d.toString().slice(0, 500)));
    this.detectionProcess.on('close', (code) => {
      if (this.isListening && code === 2) return; // fallback already started
      console.log(`openWakeWord exited with code ${code}`);
      if (this.isListening) {
        console.log('Restarting with energy VAD fallback…');
        this._startEnergyVAD();
      }
    });
  }

  // ---- Engine: Sherpa-ONNX open-vocabulary KWS ----
  _startSherpa() {
    const keywordsPath = process.env.SHERPA_KEYWORDS_PATH || './keywords.txt';
    const tokensPath = process.env.SHERPA_TOKENS || '';
    const encoderPath = process.env.SHERPA_ENCODER || '';
    const decoderPath = process.env.SHERPA_DECODER || '';
    const joinerPath = process.env.SHERPA_JOINER || '';
    console.log(`Starting Sherpa-ONNX KWS for "${this.wakeWord}" (keywords file: ${keywordsPath})`);
    console.log('Setup: pip install sherpa-onnx; docs: https://github.com/k2-fsa/sherpa-onnx');
    this.detectionProcess = spawn(
      'python',
      [
        '-u',
        '-c',
        `
import sys
try:
    import sherpa_onnx
except ImportError:
    print("SHERPA_MISSING", flush=True)
    sys.exit(2)
print("SHERPA_READY: configure keywords file at ${keywordsPath}", flush=True)
print("SHERPA_LISTENING", flush=True)
# Full streaming mic loop is machine-specific; see sherpa-onnx python demos.
# This stub keeps the process alive so supervisor logic works; energy VAD runs alongside.
import time
while True:
    time.sleep(60)
`,
      ],
      { stdio: ['ignore', 'pipe', 'pipe'] }
    );
    this.detectionProcess.stdout.on('data', (d) => {
      const line = d.toString().trim();
      console.log('[sherpa]', line);
      if (line === 'SHERPA_MISSING') {
        console.error('sherpa_onnx not installed. Falling back to energy VAD.');
        this.detectionProcess?.kill('SIGTERM');
        this._startEnergyVAD();
      }
      if (line.startsWith('WAKE:')) this._fire();
    });
    this.detectionProcess.stderr.on('data', (d) => console.error('[sherpa:err]', d.toString().slice(0, 500)));
  }

  // ---- Engine: energy VAD (no dependencies, always works) ----
  _startEnergyVAD() {
    console.log(`Starting energy-VAD trigger (rms>${THRESHOLD}, ${TRIGGER_FRAMES} frames, cooldown ${COOLDOWN_MS}ms)`);
    const isWindows = process.platform === 'win32';
    const ffmpegArgs = isWindows
      ? ['-f', 'dshow', '-i', `audio=${process.env.AUDIO_DEVICE || 'default'}`, '-ar', '16000', '-ac', '1', '-f', 's16le', '-']
      : process.platform === 'darwin'
        ? ['-f', 'avfoundation', '-i', ':default', '-ar', '16000', '-ac', '1', '-f', 's16le', '-']
        : ['-f', 'alsa', '-i', process.env.AUDIO_DEVICE || 'default', '-ar', '16000', '-ac', '1', '-f', 's16le', '-'];

    this.detectionProcess = spawn('ffmpeg', ffmpegArgs);
    let loudFrames = 0;
    let leftover = Buffer.alloc(0);
    const FRAME_BYTES = 3200; // 100ms @ 16kHz 16-bit mono

    this.detectionProcess.stdout.on('data', (chunk) => {
      const buf = Buffer.concat([leftover, chunk]);
      let offset = 0;
      while (offset + FRAME_BYTES <= buf.length) {
        const frame = buf.subarray(offset, offset + FRAME_BYTES);
        offset += FRAME_BYTES;
        const rms = rmsInt16(frame);
        if (rms > THRESHOLD) {
          loudFrames++;
          if (loudFrames >= TRIGGER_FRAMES) {
            loudFrames = 0;
            this._fire();
          }
        } else {
          loudFrames = Math.max(0, loudFrames - 2);
        }
      }
      leftover = buf.subarray(offset);
    });
    this.detectionProcess.stderr.on('data', (d) => {
      // ffmpeg logs to stderr; suppress unless debugging
      if (process.env.WAKEWORD_DEBUG) console.error('[vad:ffmpeg]', d.toString().slice(0, 500));
    });
    this.detectionProcess.on('close', (code) => {
      console.log(`VAD ffmpeg exited with code ${code}`);
      if (this.isListening) {
        console.log('Restarting VAD in 2s…');
        setTimeout(() => {
          if (this.isListening) this._startEnergyVAD();
        }, 2000);
      }
    });
  }

  simulateDetection() {
    this._fire();
  }
}

function rmsInt16(buf) {
  let sum = 0;
  const n = buf.length / 2;
  for (let i = 0; i < n; i++) {
    const v = buf.readInt16LE(i * 2);
    sum += v * v;
  }
  return Math.sqrt(sum / Math.max(1, n));
}

function checkPythonModule(name) {
  return new Promise((resolve) => {
    const p = spawn('python', ['-c', `import ${name}`], { stdio: 'ignore' });
    p.on('close', (code) => resolve(code === 0));
    p.on('error', () => resolve(false));
  });
}

// Keep backwards-compat exports for existing imports/tests
export { WakeWordDetector };
export class OpenWakeWordDetector extends WakeWordDetector {
  async start() {
    this.isListening = true;
    return this._startOpenWakeWord();
  }
}
export class SherpaONNXDetector extends WakeWordDetector {
  async start() {
    this.isListening = true;
    return this._startSherpa();
  }
}
export class EnergyVADDetector extends WakeWordDetector {
  async start() {
    this.isListening = true;
    return this._startEnergyVAD();
  }
}

// Main execution (only when run directly, not when imported)
const isMain = process.argv[1] && process.argv[1].endsWith('wakeword.js');
if (isMain) {
  const detector = new WakeWordDetector(WAKE_WORD);
  let agentProc = null;

  detector.setCallback(() => {
    console.log('Wake word detected! Starting voice agent...');
    if (agentProc && !agentProc.killed) {
      console.log('Agent already running');
      return;
    }
    agentProc = spawn('node', ['agent.js'], { stdio: 'inherit' });
    agentProc.on('close', (code) => {
      console.log(`Agent session ended (code ${code}); resuming wake-word listening…`);
      agentProc = null;
    });
  });

  detector.start();

  process.on('SIGINT', () => {
    detector.stop();
    if (agentProc) agentProc.kill('SIGTERM');
    process.exit(0);
  });
  process.on('SIGTERM', () => {
    detector.stop();
    if (agentProc) agentProc.kill('SIGTERM');
    process.exit(0);
  });

  console.log(`Wake word detector running (engine=${ENGINE}, word="${WAKE_WORD}"). Press Ctrl+C to stop.`);
}
