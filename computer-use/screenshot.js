// Screenshot capture for the Computer Use loop (spec §4.7).
//
// Primary path: the ScreenWatcher's live ffmpeg gdigrab feed (recorder-grade,
// already warm when the assistant has been "looking" at the screen). Fallbacks:
//   1. single-shot ffmpeg gdigrab (same backend, no live feed),
//   2. the screenshot-desktop package (original path; fails on some setups).
// Browser shots come from the Playwright page (see browser-executor.js).

import { spawn } from 'child_process';
import { screenWatcher } from '../lib/screen-watcher.js';

const GDIGRAB_ARGS = [
  '-hide_banner', '-loglevel', 'error',
  '-f', 'gdigrab', '-framerate', '2', '-i', 'desktop',
  '-frames:v', '1', '-c:v', 'mjpeg', '-q:v', '5',
  '-f', 'image2pipe', 'pipe:1',
];

// Single-shot capture: gdigrab on Windows, platform fallbacks elsewhere.
function ffmpegScreenGrab(timeoutMs = 8000) {
  return new Promise((resolve, reject) => {
    const isWin = process.platform === 'win32';
    const isMac = process.platform === 'darwin';
    const args = isWin
      ? GDIGRAB_ARGS
      : isMac
        ? ['-hide_banner', '-loglevel', 'error', '-f', 'avfoundation', '-i', '1', '-frames:v', '1', '-c:v', 'mjpeg', '-f', 'image2pipe', 'pipe:1']
        : ['-hide_banner', '-loglevel', 'error', '-f', 'x11grab', '-i', process.env.DISPLAY || ':0', '-frames:v', '1', '-c:v', 'mjpeg', '-f', 'image2pipe', 'pipe:1'];
    const proc = spawn('ffmpeg', args, { windowsHide: true });
    const chunks = [];
    let settled = false;
    const done = (fn, arg) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      fn(arg);
    };
    const timer = setTimeout(() => {
      try { proc.kill('SIGKILL'); } catch { /* noop */ }
      done(reject, new Error('ffmpeg screen grab timed out'));
    }, timeoutMs);
    proc.stdout.on('data', (c) => chunks.push(c));
    proc.on('error', (err) => done(reject, err));
    proc.on('close', (code) => {
      const buf = Buffer.concat(chunks);
      if (code === 0 && buf.length > 2) done(resolve, buf);
      else done(reject, new Error(`ffmpeg exited ${code}${buf.length ? ' (empty capture)' : ''}`));
    });
  });
}

/**
 * Capture the current screen. Returns { data: base64, mime_type }.
 * Order: live watcher frame → single-shot gdigrab → screenshot-desktop pkg.
 */
export async function captureDesktopScreenshot({ preferWatcher = true } = {}) {
  const errors = [];

  if (preferWatcher && screenWatcher.running) {
    const frame = screenWatcher.latestFrame();
    if (frame) return { data: frame.data.toString('base64'), mime_type: frame.mime };
    errors.push('watcher running but no frames yet');
  }

  // Single-shot ffmpeg — same backend as the recorder feed, no feed needed.
  if (process.platform === 'win32' || process.platform === 'linux' || process.platform === 'darwin') {
    try {
      const buf = await ffmpegScreenGrab();
      return { data: buf.toString('base64'), mime_type: 'image/jpeg' };
    } catch (err) {
      errors.push(`gdigrab: ${err.message}`);
    }
  }

  // Legacy package (kept as last resort).
  try {
    const { default: screenshot } = await import('screenshot-desktop');
    const buf = await screenshot({ format: 'png' });
    if (!buf || buf.length === 0) throw new Error('empty capture');
    return { data: buf.toString('base64'), mime_type: 'image/png' };
  } catch (err) {
    errors.push(`screenshot-desktop: ${err.message}`);
  }

  throw new Error(`Desktop screenshot failed (${errors.join('; ')})`);
}

export function pngBase64ToBytes(b64) {
  return Buffer.from(b64, 'base64');
}
