// Pretty terminal output helpers — zero dependencies.
// Colors auto-disable when stdout isn't a TTY (piped logs, CI) so output stays grep-friendly.
// The DuckDB audit trail keeps full fidelity; these helpers only shape what humans see.

const ENABLED = process.stdout.isTTY === true;

const code = (c) => (ENABLED ? `\x1b[${c}m` : '');
const RESET = code('0');
const DIM = code('2');
const BOLD = code('1');

const paint = (c) => (s) => `${c}${s}${RESET}`;

export const colors = {
  reset: RESET,
  dim: DIM,
  bold: BOLD,
  red: paint(code('31')),
  green: paint(code('32')),
  yellow: paint(code('33')),
  blue: paint(code('34')),
  magenta: paint(code('35')),
  cyan: paint(code('36')),
  gray: paint(code('90')),
};

export const SYMBOLS = {
  ok: '✓',
  fail: '✗',
  warn: '⚠',
  info: 'ℹ',
  tool: '🔧',
  lock: '🔒',
  robot: '🤖',
  speech: '💬',
  wait: '⏳',
};

/** Short local timestamp, e.g. 14:05:09 */
export function stamp(date = new Date()) {
  const t = date instanceof Date ? date : new Date(date);
  return `${colors.gray(String(t.getHours()).padStart(2, '0') + ':' + String(t.getMinutes()).padStart(2, '0') + ':' + String(t.getSeconds()).padStart(2, '0') + colors.reset)}`;
}

/**
 * Compact, human-readable rendering of a value for one-line console output.
 * Objects/arrays collapse to "key=value, key=value"; strings truncate.
 * Strings whose keys suggest secrets are masked.
 */
export function summarize(value, { maxLen = 120 } = {}) {
  if (value == null) return '';
  if (typeof value === 'string') return truncate(value, maxLen);
  if (typeof value === 'number' || typeof value === 'boolean') return String(value);

  let text;
  if (Array.isArray(value)) {
    text = value.length > 4
      ? `[${value.slice(0, 4).map((v) => summarize(v, { maxLen: 40 })).join(', ')}, +${value.length - 4} more]`
      : `[${value.map((v) => summarize(v, { maxLen: 40 })).join(', ')}]`;
  } else {
    const entries = Object.entries(value).filter(([, v]) => v !== undefined);
    text = entries
      .slice(0, 6)
      .map(([k, v]) => `${k}=${summarize(v, { maxLen: 48 })}`)
      .join(', ');
    if (entries.length > 6) text += `, +${entries.length - 6} more`;
  }
  return truncate(text, maxLen);
}

const SECRET_KEY_RE = /pass|secret|token|key|credential|auth|bearer|authorization|cookie/i;

function truncate(s, maxLen) {
  if (s.length <= maxLen) return s;
  return `${s.slice(0, Math.max(0, maxLen - 1))}…`;
}

/** Mask values of secret-looking keys (used when logging raw args). */
export function redactArgs(args) {
  if (!args || typeof args !== 'object' || Array.isArray(args)) return args;
  const out = {};
  for (const [k, v] of Object.entries(args)) {
    if (SECRET_KEY_RE.test(k) && typeof v === 'string' && v.length > 0) {
      out[k] = `${String(v).slice(0, 3)}•••`;
    } else if (v && typeof v === 'object' && !Array.isArray(v)) {
      out[k] = redactArgs(v);
    } else {
      out[k] = v;
    }
  }
  return out;
}

/** `HH:MM:SS 🔧 tool key=value` one-liner. */
export function logEvent(symbol, message, detail, { stream = console.log, colorFn = null, maxLen = 120 } = {}) {
  const parts = [stamp(), symbol, colorFn ? colorFn(message) : message];
  if (detail) parts.push(colors.gray(summarize(detail, { maxLen })));
  stream(parts.filter(Boolean).join(' '));
}
