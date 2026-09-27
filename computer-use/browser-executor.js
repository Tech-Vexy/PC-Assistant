// Browser action executor (spec §4.6): Playwright drives a headed Chromium
// at a fixed 1440x900 viewport; Gemini sees page screenshots and emits the
// same click_at/type_text_at/navigate vocabulary as desktop.
// Playwright is imported lazily so desktop-only installs never pay for it.
// Users need one extra step after install: `npx playwright install chromium`.
import { denormalizeX, denormalizeY } from './desktop-executor.js';

export const BROWSER_WIDTH = 1440;
export const BROWSER_HEIGHT = 900;

async function loadPlaywright() {
  try {
    return await import('playwright');
  } catch {
    throw new Error('Playwright is not installed (or browsers missing). Run `npm install` then `npx playwright install chromium`.');
  }
}

export async function launchBrowser() {
  const { chromium } = await loadPlaywright();
  const browser = await chromium.launch({ headless: false });
  const context = await browser.newContext({ viewport: { width: BROWSER_WIDTH, height: BROWSER_HEIGHT } });
  const page = await context.newPage();
  return { browser, page, width: BROWSER_WIDTH, height: BROWSER_HEIGHT };
}

export async function captureBrowserScreenshot(page) {
  const buf = await page.screenshot({ type: 'png' });
  return buf.toString('base64');
}

// Execute one Computer Use function call against a Playwright page.
// Coordinates are denormalized against the fixed viewport.
export async function executeBrowserAction(functionCall, page) {
  const name = String(functionCall?.name || '');
  const args = functionCall?.args || {};
  try {
    switch (name) {
      case 'click_at':
      case 'click': {
        await page.mouse.click(denormalizeX(args.x, BROWSER_WIDTH), denormalizeY(args.y, BROWSER_HEIGHT));
        break;
      }
      case 'double_click': {
        await page.mouse.dblclick(denormalizeX(args.x, BROWSER_WIDTH), denormalizeY(args.y, BROWSER_HEIGHT));
        break;
      }
      case 'type_text_at':
      case 'type': {
        if (args.x !== undefined && args.y !== undefined) {
          await page.mouse.click(denormalizeX(args.x, BROWSER_WIDTH), denormalizeY(args.y, BROWSER_HEIGHT));
        }
        if (args.text) await page.keyboard.type(String(args.text));
        if (args.press_enter) await page.keyboard.press('Enter');
        break;
      }
      case 'press_key':
      case 'key': {
        const key = String(args.keys || args.key || 'Enter');
        await page.keyboard.press(key.includes('+') ? key.split('+').map((k) => k.trim()).join('+') : key);
        break;
      }
      case 'navigate': {
        const url = String(args.url || '');
        if (!/^https?:\/\//i.test(url)) return { ok: false, detail: 'navigate needs an http(s) url' };
        await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
        break;
      }
      case 'go_back':
        await page.goBack({ waitUntil: 'domcontentloaded' }).catch(() => {});
        break;
      case 'go_forward':
        await page.goForward({ waitUntil: 'domcontentloaded' }).catch(() => {});
        break;
      case 'wait': {
        const ms = Math.min(Math.max(Number(args.seconds || 1), 0.1), 30) * 1000;
        await page.waitForTimeout(ms);
        break;
      }
      case 'scroll': {
        const dy = Number(args.amount ?? args.delta ?? 300) || 300;
        await page.mouse.wheel(0, -dy);
        break;
      }
      default:
        return { ok: false, detail: `Unhandled browser action: ${name}` };
    }
    return { ok: true, detail: `${name} (${args.intent || 'no intent'})` };
  } catch (err) {
    return { ok: false, detail: `${name} failed: ${err.message}` };
  }
}
