import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { VoiceActivityDetector } from '../lib/vad.js';

describe('VoiceActivityDetector (VAD) & Echo Ducking', () => {
  it('calculates RMS and ZCR accurately', () => {
    const vad = new VoiceActivityDetector();
    // Silence buffer
    const silence = Buffer.alloc(4800, 0);
    assert.equal(vad.calculateRms(silence), 0);
    assert.equal(vad.calculateZcr(silence), 0);

    // Sine wave buffer (approx 1kHz at 24kHz)
    const sine = Buffer.alloc(4800);
    for (let i = 0; i < 2400; i++) {
      const val = Math.sin((2 * Math.PI * 1000 * i) / 24000) * 10000;
      sine.writeInt16LE(Math.floor(val), i * 2);
    }
    const rms = vad.calculateRms(sine);
    assert.ok(rms > 6000 && rms < 8000, `Expected RMS ~7071, got ${rms}`);
    const zcr = vad.calculateZcr(sine);
    assert.ok(zcr > 0.05 && zcr < 0.15, `Expected ZCR ~0.083, got ${zcr}`);
  });

  it('ducks microphone audio while assistant is speaking (no self-interruption)', () => {
    const vad = new VoiceActivityDetector({ bargeInThreshold: 8000 });
    vad.onPlaybackStarted();

    // Generate moderate speaker bleed (RMS ~4000)
    const speakerBleed = Buffer.alloc(4800);
    for (let i = 0; i < 2400; i++) {
      const val = Math.sin((2 * Math.PI * 400 * i) / 24000) * 5600;
      speakerBleed.writeInt16LE(Math.floor(val), i * 2);
    }

    // Process 10 frames of speaker bleed while assistant is speaking
    for (let i = 0; i < 10; i++) {
      const res = vad.process(speakerBleed, true);
      assert.equal(res.shouldSend, false, 'Mic audio must be ducked while assistant speaks');
      assert.equal(res.shouldBargeIn, false, 'Speaker bleed must not trigger barge-in');
    }
  });

  it('triggers barge-in only on sustained loud speech after warmup delay', () => {
    const vad = new VoiceActivityDetector({
      bargeInThreshold: 8000,
      bargeInConsecutiveFrames: 3,
    });
    vad.onPlaybackStarted();
    // Simulate playback has been active for 500ms (past 400ms warmup)
    vad.playbackStartTime = Date.now() - 500;

    // Loud user shouting buffer (RMS ~12000)
    const loudSpeech = Buffer.alloc(4800);
    for (let i = 0; i < 2400; i++) {
      const val = Math.sin((2 * Math.PI * 300 * i) / 24000) * 17000;
      loudSpeech.writeInt16LE(Math.floor(val), i * 2);
    }

    // First 2 frames: should not barge in yet (requires 3 consecutive)
    assert.equal(vad.process(loudSpeech, true).shouldBargeIn, false);
    assert.equal(vad.process(loudSpeech, true).shouldBargeIn, false);
    // 3rd frame: reaches threshold
    assert.equal(vad.process(loudSpeech, true).shouldBargeIn, true);
  });

  it('detects user speech in listening mode and handles hangover', () => {
    const vad = new VoiceActivityDetector({
      minSpeechRms: 1000,
      hangoverMaxFrames: 2,
    });

    const speech = Buffer.alloc(4800);
    for (let i = 0; i < 2400; i++) {
      const val = Math.sin((2 * Math.PI * 250 * i) / 24000) * 4000;
      speech.writeInt16LE(Math.floor(val), i * 2);
    }
    const quiet = Buffer.alloc(4800, 0);

    const r1 = vad.process(speech, false);
    assert.equal(r1.isSpeech, true);
    assert.equal(r1.shouldSend, true);

    // Frame after speech: hangover keeps isSpeech true
    const r2 = vad.process(quiet, false);
    assert.equal(r2.isSpeech, true);

    // Next hangover frame
    const r3 = vad.process(quiet, false);
    assert.equal(r3.isSpeech, true);

    // Hangover exhausted: isSpeech becomes false
    const r4 = vad.process(quiet, false);
    assert.equal(r4.isSpeech, false);
  });
});
