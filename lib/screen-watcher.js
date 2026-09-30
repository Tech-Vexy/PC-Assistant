// ScreenWatcher — continuous, recorder-grade screen awareness.
//
// An ffmpeg gdigrab feed (the same capture backend screen recorders use)
// runs at a low framerate into an in-memory ring buffer of JPEG frames.
// Consumers:
//   - describeScreen(): the assistant "looks" at the recent frames and
//     answers a question about them via Gemini multimodal vision.
//   - latestFrame(): a fresh PNG/JPEG for computer_use and tools.
//
// Frames never touch disk. The feed is lazy: it starts on first use and
// idles down when no one has consumed frames for SCREEN_WATCHER_IDLE_S.

import { spawn } from 'child_process';
import { cfg } from './store.js';

const DEFAULT_FPS = 2; // recorder feed rate — cheap, smooth enough for context
const DEFAULT_BUFFER_S = 8; // seconds of history kept (~2*8 = 16 frames)
const IDLE_S = 60; // auto-stop after this many seconds without a consumer
const MAX_CONSUMERS = 8;

class ScreenWatcher {
  constructor() {
    this.frames = []; // { data: Buffer, ts: number, mime: string }
    this.proc = null;
    this.consumers = new Set();
    this.idleTimer = null;
    this.restartTimer = null;
    this.lastError = '';
    this.startedAt = 0;
  }

  get running() {
    return !!this.proc && this.proc.exitCode === null;
  }

  get fps() {
    const n = Number(cfg('SCREEN_WATCHER_FPS', String(DEFAULT_FPS)));
    return Number.isFinite(n) && n >= 0.2 && n <= 10 ? n : DEFAULT_FPS;
  }

  get bufferSeconds() {
    const n = Number(cfg('SCREEN_WATCHER_BUFFER_S', String(DEFAULT_BUFFER_S)));
    return Number.isFinite(n) && n >= 2 && n <= 120 ? n : DEFAULT_BUFFER_S;
  }

  /**
   * Register a consumer so the feed keeps running. Returns a release fn.
   */
  acquire(id) {
    this.consumers.add(id);
    clearTimeout(this.idleTimer);
    if (!this.running) this.start();
    return () => {
      this.consumers.delete(id);
      this._armIdle();
    };
  }

  _armIdle() {
    clearTimeout(this.idleTimer);
    if (this.consumers.size > 0 || !this.running) return;
    this.idleTimer = setTimeout(() => this.stop(), IDLE_S * 1000);
    if (this.idleTimer.unref) this.idleTimer.unref();
  }

  start() {
    if (this.running) return true;
    if (process.platform !== 'win32') {
      // macOS: avfoundation '1'; Linux: x11grab. Keep win32 first-class; others
      // fall back to on-demand single-shot captures instead of a live feed.
      return false;
    }
    try {
      const args = [
        '-hide_banner', '-loglevel', 'error',
        '-f', 'gdigrab', '-framerate', String(this.fps), '-i', 'desktop',
        '-vf', 'scale=1280:-2',
        '-c:v', 'mjpeg', '-q:v', '5',
        '-f', 'image2pipe',
        'pipe:1',
      ];
      this.proc = spawn('ffmpeg', args, { windowsHide: true });
      this.startedAt = Date.now();
      this.lastError = '';

      let buf = Buffer.alloc(0);
      this.proc.stdout.on('data', (chunk) => {
        buf = Buffer.concat([buf, chunk]);
        // Extract complete JPEGs from the stream (SOI 0xFFD8 … EOI 0xFFD9).
        let start = buf.indexOf(Buffer.from([0xff, 0xd8, 0xff]));
        while (start !== -1) {
          const end = buf.indexOf(Buffer.from([0xff, 0xd9]), start + 2);
          if (end === -1) break;
          const frame = buf.subarray(start, end + 2);
          buf = buf.subarray(end + 2);
          this.frames.push({ data: Buffer.from(frame), ts: Date.now(), mime: 'image/jpeg' });
          start = buf.indexOf(Buffer.from([0xff, 0xd8, 0xff]));
        }
        // Discard stale prefix if no SOI was found and buffer has grown large (>512KB)
        if (start === -1 && buf.length > 512 * 1024) {
          buf = buf.subarray(-4);
        }
        // Ring buffer bound: keep ~bufferSeconds of history.
        const cap = Math.max(4, Math.ceil(this.bufferSeconds * this.fps));
        while (this.frames.length > cap) this.frames.shift();
      });

      this.proc.stderr.on('data', (d) => {
        const msg = d.toString().trim();
        if (msg) this.lastError = msg.slice(0, 300);
      });
      this.proc.on('error', (err) => {
        this.lastError = err.message;
        this.proc = null;
      });
      this.proc.on('close', () => {
        this.proc = null;
      });
      this._armIdle();
      return true;
    } catch (err) {
      this.lastError = err.message;
      this.proc = null;
      return false;
    }
  }

  stop() {
    clearTimeout(this.idleTimer);
    if (this.proc) {
      try { this.proc.kill('SIGTERM'); } catch { /* noop */ }
      this.proc = null;
    }
    this.consumers.clear();
  }

  status() {
    return {
      running: this.running,
      frames: this.frames.length,
      consumers: this.consumers.size,
      fps: this.fps,
      bufferSeconds: this.bufferSeconds,
      lastError: this.lastError || undefined,
      uptimeS: this.running ? Math.round((Date.now() - this.startedAt) / 1000) : 0,
    };
  }

  /**
   * Most recent frame (Buffer, may be null if feed not running yet).
   */
  latestFrame() {
    return this.frames.length ? this.frames[this.frames.length - 1] : null;
  }

  /**
   * Frames spanning the last `windowMs` (for multimodal context).
   */
  recentFrames(windowMs = 4000, maxCount = 3) {
    const cutoff = Date.now() - windowMs;
    const picked = this.frames.filter((f) => f.ts >= cutoff);
    // Thin: first, middle, last of the window.
    if (picked.length <= maxCount) return picked;
    const mid = Math.floor(picked.length / 2);
    return [picked[0], picked[mid], picked[picked.length - 1]].filter(Boolean);
  }
}

// Singleton — one recorder feed for the whole agent process.
export const screenWatcher = new ScreenWatcher();

// ---------- Gemini multimodal screen understanding ----------

let visionModel = null;
let cachedApiKey = null;
let cachedVisionModelName = null;

async function getVisionModel() {
  const apiKey = cfg('GEMINI_API_KEY') || '';
  if (!apiKey) return null;
  const model = cfg('GEMINI_VISION_MODEL', 'gemini-3.8-flash');
  if (visionModel && cachedApiKey === apiKey && cachedVisionModelName === model) {
    return visionModel;
  }
  try {
    const { GoogleGenAI } = await import('@google/genai');
    const ai = new GoogleGenAI({ apiKey });
    visionModel = { ai, model };
    cachedApiKey = apiKey;
    cachedVisionModelName = model;
    return visionModel;
  } catch {
    return null;
  }
}

/**
 * Ask a multimodal model what's on screen.
 * @param {string} question - What to look for / describe
 * @param {Object} opts - { windowMs, frames, vision } (frames/vision are test seams)
 * @returns {Promise<{ok:boolean, description?:string, error?:string, frames?:number}>}
 */
export async function describeScreen(question = 'Describe what is currently on the screen.', { windowMs = 4000, frames: injectedFrames = null, vision: injectedVision = null } = {}) {
  let release = null;
  try {
    let frames;
    if (injectedFrames) {
      frames = injectedFrames;
    } else {
      release = screenWatcher.acquire('describe');
      // Give a cold feed a moment to produce its first frames.
      if (!screenWatcher.frames.length) {
        await new Promise((r) => setTimeout(r, 700));
      }
      frames = screenWatcher.recentFrames(windowMs);
    }
    if (!frames.length) {
      return { ok: false, error: screenWatcher.lastError || 'screen feed has no frames yet — retry shortly' };
    }

    const vision = injectedVision || (await getVisionModel());
    if (!vision) {
      return { ok: false, error: 'Gemini API key is not configured — set GEMINI_API_KEY at /setup.' };
    }

    const parts = [
      { text: `You are the eyes of a PC assistant. Question: ${question}\nAnswer concisely (max ~80 words), factually, from what is visible. If the screen shows the answer (window titles, text, UI state), say it.` },
      ...frames.slice(-2).map((f) => ({ inlineData: { mimeType: f.mime, data: f.data.toString('base64') } })),
    ];
    const generatePromise = vision.ai.models.generateContent({ model: vision.model, contents: [{ role: 'user', parts }] });
    const timeoutPromise = new Promise((_, reject) => setTimeout(() => reject(new Error('vision request timed out after 15s')), 15000));
    const res = await Promise.race([generatePromise, timeoutPromise]);
    const text = typeof res?.text === 'string' ? res.text.trim() : '';
    if (!text) return { ok: false, error: 'vision model returned no description' };
    return { ok: true, description: text, frames: frames.length };
  } catch (err) {
    return { ok: false, error: `screen vision failed: ${err.message}` };
  } finally {
    if (release) release();
  }
}

// Test hooks
export function __resetWatcher() {
  screenWatcher.stop();
  screenWatcher.frames = [];
  visionModel = null;
  cachedApiKey = null;
  cachedVisionModelName = null;
}

export { IDLE_S, DEFAULT_FPS, DEFAULT_BUFFER_S };
