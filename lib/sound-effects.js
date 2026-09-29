// Audio earcons (chimes/feedback sounds) synthesized on the fly via PCM16
// Played through ffplay without requiring any external audio files.

import { spawn } from 'child_process';

const SAMPLE_RATE = 16000;

function createPcmBuffer(notes, sampleRate = SAMPLE_RATE) {
  // notes: array of { freq, durationMs, volume }
  const totalDurationMs = notes.reduce((acc, n) => acc + n.durationMs, 0);
  const totalSamples = Math.floor((sampleRate * totalDurationMs) / 1000);
  const buffer = Buffer.alloc(totalSamples * 2); // 16-bit = 2 bytes per sample

  let sampleOffset = 0;
  for (const note of notes) {
    const noteSamples = Math.floor((sampleRate * note.durationMs) / 1000);
    const freq = note.freq;
    const vol = note.volume || 0.25;

    for (let i = 0; i < noteSamples; i++) {
      const t = i / sampleRate;
      // Linear attack and release envelope to prevent clicks
      let env = 1.0;
      const attackSamples = Math.min(Math.floor(sampleRate * 0.01), noteSamples / 2);
      const releaseSamples = Math.min(Math.floor(sampleRate * 0.03), noteSamples / 2);
      if (i < attackSamples) {
        env = i / attackSamples;
      } else if (i > noteSamples - releaseSamples) {
        env = (noteSamples - i) / releaseSamples;
      }

      const sampleVal = Math.sin(2 * Math.PI * freq * t) * vol * env * 32767;
      const clamped = Math.max(-32768, Math.min(32767, Math.floor(sampleVal)));
      const byteIdx = (sampleOffset + i) * 2;
      if (byteIdx + 1 < buffer.length) {
        buffer.writeInt16LE(clamped, byteIdx);
      }
    }
    sampleOffset += noteSamples;
  }

  return buffer;
}

// Pre-render earcon audio buffers
const EARCONS = {
  // Pleasant ascending two-tone chime when listening starts
  listening: createPcmBuffer([
    { freq: 587.33, durationMs: 70, volume: 0.2 }, // D5
    { freq: 880.00, durationMs: 110, volume: 0.25 }, // A5
  ]),
  // Subtle confirmation chime
  success: createPcmBuffer([
    { freq: 783.99, durationMs: 60, volume: 0.2 }, // G5
    { freq: 1046.50, durationMs: 120, volume: 0.22 }, // C6
  ]),
  // Soft attention alert for dangerous approval needed
  attention: createPcmBuffer([
    { freq: 659.25, durationMs: 90, volume: 0.25 }, // E5
    { freq: 523.25, durationMs: 120, volume: 0.25 }, // C5
  ]),
  // Short down-tone when user interrupts speech (barge-in)
  interrupted: createPcmBuffer([
    { freq: 620.00, durationMs: 50, volume: 0.18 },
    { freq: 380.00, durationMs: 70, volume: 0.18 },
  ]),
};

export function playEarcon(name = 'listening') {
  if ((process.env.EARCONS || 'true').toLowerCase() === 'false') return Promise.resolve();

  const buf = EARCONS[name] || EARCONS.listening;
  return new Promise((resolve) => {
    try {
      const proc = spawn('ffplay', ['-nodisp', '-autoexit', '-f', 's16le', '-ar', String(SAMPLE_RATE), '-ch_layout', 'mono', '-'], {
        stdio: ['pipe', 'ignore', 'ignore'],
      });
      proc.stdin.on('error', () => {});
      proc.stdin.write(buf);
      proc.stdin.end();
      proc.on('close', () => resolve());
      proc.on('error', () => resolve()); // Degrade gracefully if ffplay isn't on PATH
    } catch {
      resolve();
    }
  });
}
