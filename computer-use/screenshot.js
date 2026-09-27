// Screenshot capture for the Computer Use loop (spec §4.7).
// Desktop: screenshot-desktop package (returns PNG Buffer). Browser shots
// come from the Playwright page (see browser-executor.js).

export async function captureDesktopScreenshot() {
  try {
    const { default: screenshot } = await import('screenshot-desktop');
    const buf = await screenshot({ format: 'png' });
    if (!buf || buf.length === 0) throw new Error('empty capture');
    return buf.toString('base64');
  } catch (err) {
    throw new Error(`Desktop screenshot failed: ${err.message}`);
  }
}

export function pngBase64ToBytes(b64) {
  return Buffer.from(b64, 'base64');
}
