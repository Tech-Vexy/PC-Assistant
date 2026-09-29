// Voice Activity Detection (VAD) and Acoustic Echo Ducking for Voice Agent
// Protects against self-interruption (assistant hearing itself) and ambient noise.

export class VoiceActivityDetector {
  /**
   * @param {Object} [options]
   * @param {number} [options.sampleRate=24000] Audio sample rate in Hz
   * @param {number} [options.minSpeechRms=1200] Minimum RMS energy to qualify as speech
   * @param {number} [options.snrMultiplier=2.2] Multiplier above noise floor for speech threshold
   * @param {number} [options.bargeInThreshold=8000] Energy threshold to interrupt speaking assistant (0 to disable)
   * @param {number} [options.bargeInConsecutiveFrames=3] Consecutive loud frames needed to confirm intentional barge-in
   * @param {number} [options.preRollMaxFrames=3] Max pre-roll frames to retain (~300ms)
   * @param {number} [options.hangoverMaxFrames=5] Hangover frames after speech ends (~500ms)
   * @param {number} [options.initialNoiseFloor=400] Initial ambient noise floor estimate
   */
  constructor(options = {}) {
    this.sampleRate = options.sampleRate || 24000;
    this.minSpeechRms = options.minSpeechRms ?? 1200;
    this.snrMultiplier = options.snrMultiplier ?? 2.2;
    this.bargeInThreshold = options.bargeInThreshold !== undefined ? Number(options.bargeInThreshold) : 8000;
    this.bargeInConsecutiveFrames = options.bargeInConsecutiveFrames ?? 3;
    this.preRollMaxFrames = options.preRollMaxFrames ?? 3;
    this.hangoverMaxFrames = options.hangoverMaxFrames ?? 5;

    this.noiseFloor = options.initialNoiseFloor ?? 400;
    this.isSpeechActive = false;
    this.hangoverCount = 0;
    this.bargeInCount = 0;
    this.playbackStartTime = 0;
    this.preRollBuffer = [];
  }

  /**
   * Calculate Root Mean Square (RMS) of PCM16 buffer
   * @param {Buffer} buffer
   * @returns {number}
   */
  calculateRms(buffer) {
    if (!buffer || buffer.length < 2) return 0;
    let sum = 0;
    const n = Math.floor(buffer.length / 2);
    for (let i = 0; i < n; i++) {
      const v = buffer.readInt16LE(i * 2);
      sum += v * v;
    }
    return Math.sqrt(sum / Math.max(1, n));
  }

  /**
   * Calculate Zero-Crossing Rate (ZCR) of PCM16 buffer
   * @param {Buffer} buffer
   * @returns {number} Fraction of sample sign transitions
   */
  calculateZcr(buffer) {
    if (!buffer || buffer.length < 4) return 0;
    const n = Math.floor(buffer.length / 2);
    let crossings = 0;
    let prevSign = buffer.readInt16LE(0) >= 0;
    for (let i = 1; i < n; i++) {
      const currentSign = buffer.readInt16LE(i * 2) >= 0;
      if (currentSign !== prevSign) {
        crossings++;
        prevSign = currentSign;
      }
    }
    return crossings / Math.max(1, n);
  }

  /**
   * Notify VAD that assistant audio playback has started
   */
  onPlaybackStarted() {
    this.playbackStartTime = Date.now();
    this.bargeInCount = 0;
    this.isSpeechActive = false;
    this.hangoverCount = 0;
    this.preRollBuffer = [];
  }

  /**
   * Notify VAD that assistant audio playback has ended
   */
  onPlaybackEnded() {
    this.playbackStartTime = 0;
    this.bargeInCount = 0;
  }

  /**
   * Process a PCM16 audio frame
   * @param {Buffer} frameBuffer
   * @param {boolean} isAssistantSpeaking
   * @returns {{ shouldSend: boolean, shouldBargeIn: boolean, isSpeech: boolean, rms: number, noiseFloor: number, preRollFrames: Buffer[] }}
   */
  process(frameBuffer, isAssistantSpeaking = false) {
    const rms = this.calculateRms(frameBuffer);
    const zcr = this.calculateZcr(frameBuffer);

    // Case 1: Assistant is speaking (Acoustic Echo Ducking)
    if (isAssistantSpeaking) {
      this.isSpeechActive = false;
      this.hangoverCount = 0;
      this.preRollBuffer = [];

      let shouldBargeIn = false;
      const playbackDuration = Date.now() - (this.playbackStartTime || 0);

      // Guard: Ignore initial 400ms to allow speaker transient to dissipate
      // Require deliberate, sustained loud speech over the speaker audio
      if (this.bargeInThreshold > 0 && playbackDuration > 400) {
        if (rms >= this.bargeInThreshold) {
          this.bargeInCount++;
          if (this.bargeInCount >= this.bargeInConsecutiveFrames) {
            shouldBargeIn = true;
            this.bargeInCount = 0;
          }
        } else {
          this.bargeInCount = 0;
        }
      } else {
        this.bargeInCount = 0;
      }

      // Always duck mic audio during assistant speech so it never hears itself
      return {
        shouldSend: false,
        shouldBargeIn,
        isSpeech: false,
        rms,
        noiseFloor: this.noiseFloor,
        preRollFrames: [],
      };
    }

    // Case 2: Listening mode
    this.bargeInCount = 0;

    // Adapt background noise floor on quiet frames
    const speechThreshold = Math.max(this.minSpeechRms, this.noiseFloor * this.snrMultiplier);
    if (rms < speechThreshold) {
      this.noiseFloor = 0.95 * this.noiseFloor + 0.05 * rms;
    }

    // Determine voice presence (energy + zero-crossing rate)
    const isVoice = rms >= speechThreshold && zcr >= 0.01 && zcr <= 0.65;
    const wasSpeechActive = this.isSpeechActive;
    let preRollFrames = [];

    if (isVoice) {
      this.isSpeechActive = true;
      this.hangoverCount = this.hangoverMaxFrames;
      // If voice just started, emit stored pre-roll frames to avoid clipping the start
      if (!wasSpeechActive && this.preRollBuffer.length > 0) {
        preRollFrames = [...this.preRollBuffer];
        this.preRollBuffer = [];
      }
    } else if (this.hangoverCount > 0) {
      this.hangoverCount--;
      this.isSpeechActive = true;
    } else {
      this.isSpeechActive = false;
      // Keep pre-roll buffer updated while quiet
      this.preRollBuffer.push(frameBuffer);
      if (this.preRollBuffer.length > this.preRollMaxFrames) {
        this.preRollBuffer.shift();
      }
    }

    return {
      shouldSend: true,
      shouldBargeIn: false,
      isSpeech: this.isSpeechActive,
      rms,
      noiseFloor: this.noiseFloor,
      preRollFrames,
    };
  }
}
