// Desktop action executor (spec §4.5): denormalize Gemini's 0–1000
// coordinates to pixels and drive the real OS cursor via nut.js.
import { mouse, keyboard, Button, Key, screen } from '@nut-tree-fork/nut-js';
import { denormalizeX as scaleX, denormalizeY as scaleY } from './coordinates.js';

// Viewport clamp: model coordinates occasionally overshoot; keep the cursor on-screen.
function denormalizeX(x, screenWidth) {
  return Math.max(0, Math.min(screenWidth - 1, scaleX(x, screenWidth)));
}

function denormalizeY(y, screenHeight) {
  return Math.max(0, Math.min(screenHeight - 1, scaleY(y, screenHeight)));
}

export async function getScreenSize() {
  try {
    const width = await screen.width();
    const height = await screen.height();
    if (Number.isFinite(width) && Number.isFinite(height) && width > 0 && height > 0) {
      return { width, height };
    }
  } catch {
    /* fall through to default */
  }
  return { width: 1920, height: 1080 }; // safe fallback when probing fails
}

function keyFromName(name) {
  if (!name) return null;
  const n = String(name).toLowerCase();
  if (Key[n] !== undefined) return Key[n];
  const upper = n.toUpperCase();
  if (Key[upper] !== undefined) return Key[upper];
  const alias = {
    enter: Key.Enter, return: Key.Enter, esc: Key.Escape, escape: Key.Escape,
    space: Key.Space, tab: Key.Tab, backspace: Key.Backspace, delete: Key.Delete,
    up: Key.Up, down: Key.Down, left: Key.Left, right: Key.Right,
  };
  return alias[n] ?? null;
}

// Execute one Computer Use function call. Returns { ok, detail }.
// Unknown actions return ok:false (caller ends the loop) instead of throwing.
export async function executeDesktopAction(functionCall, size = null) {
  const { width, height } = size || (await getScreenSize());
  const name = String(functionCall?.name || '');
  const args = functionCall?.args || {};
  const at = (v, max, axis) => (axis === 'x' ? denormalizeX(v, max) : denormalizeY(v, max));

  try {
    switch (name) {
      case 'click_at':
      case 'click': {
        await mouse.setPosition({ x: at(args.x, width, 'x'), y: at(args.y, height, 'y') });
        await mouse.click(args.button === 'right' ? Button.RIGHT : Button.LEFT);
        break;
      }
      case 'double_click': {
        await mouse.setPosition({ x: at(args.x, width, 'x'), y: at(args.y, height, 'y') });
        await mouse.doubleClick(Button.LEFT);
        break;
      }
      case 'type_text_at':
      case 'type': {
        if (args.x !== undefined && args.y !== undefined) {
          await mouse.setPosition({ x: at(args.x, width, 'x'), y: at(args.y, height, 'y') });
          await mouse.click(Button.LEFT);
        }
        if (args.text) await keyboard.type(String(args.text));
        if (args.press_enter) {
          await keyboard.pressKey(Key.Enter);
          await keyboard.releaseKey(Key.Enter);
        }
        break;
      }
      case 'press_key':
      case 'key': {
        const keys = String(args.keys || args.key || '')
          .split('+')
          .map((k) => k.trim())
          .map(keyFromName)
          .filter(Boolean);
        if (!keys.length) return { ok: false, detail: `Unrecognized key: ${args.keys || args.key}` };
        await keyboard.pressKey(...keys);
        await keyboard.releaseKey(...keys);
        break;
      }
      case 'scroll': {
        const amount = Number(args.amount ?? args.delta ?? 3) || 3;
        await mouse.scrollUp(Math.abs(amount));
        break;
      }
      case 'wait': {
        const ms = Math.min(Math.max(Number(args.seconds || args.ms / 1000 || 1), 0.1), 30) * 1000;
        await new Promise((r) => setTimeout(r, ms));
        break;
      }
      case 'navigate': {
        const url = String(args.url || '');
        if (!/^https?:\/\//i.test(url)) return { ok: false, detail: 'navigate needs an http(s) url' };
        const { execFile } = await import('child_process');
        const { promisify } = await import('util');
        const run = promisify(execFile);
        if (process.platform === 'win32') await run('cmd', ['/c', 'start', '', url], { timeout: 10000 });
        else if (process.platform === 'darwin') await run('open', [url], { timeout: 10000 });
        else await run('xdg-open', [url], { timeout: 10000 });
        break;
      }
      default:
        return { ok: false, detail: `Unhandled desktop action: ${name}` };
    }
    return { ok: true, detail: `${name} (${args.intent || 'no intent'})` };
  } catch (err) {
    return { ok: false, detail: `${name} failed: ${err.message}` };
  }
}
