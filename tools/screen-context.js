// screen_context — the assistant's passive eyes (read-only, no approval needed).
// Backed by the ScreenWatcher recorder feed + Gemini multimodal vision.

import { describeScreen, screenWatcher } from '../lib/screen-watcher.js';

const DEFAULT_QUESTION =
  'Describe what is currently on the screen: the active window, visible apps, and any on-screen text the user might be referring to.';

// Test seam (same pattern as computer-use/dispatch.js __setOverrides).
let overrides = {};
export function __setOverrides(next = {}) {
  overrides = { ...next };
}

/**
 * @param {{question?: string}} args
 * @returns {Promise<{success:boolean, description?:string, watching?:boolean, frames?:number, error?:string}>}
 */
export async function screenContext(args = {}) {
  const question = typeof args.question === 'string' && args.question.trim() ? args.question.trim().slice(0, 500) : DEFAULT_QUESTION;
  const result = overrides.describeScreen ? await overrides.describeScreen(question) : await describeScreen(question);
  if (!result.ok) {
    return { success: false, error: result.error, watching: screenWatcher.running };
  }
  return {
    success: true,
    description: result.description,
    watching: screenWatcher.running,
    frames: result.frames,
  };
}
