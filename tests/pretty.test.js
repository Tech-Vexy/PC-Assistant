// Tests for the compact terminal-output helpers in lib/pretty.js
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { summarize, redactArgs, stamp, logEvent } from '../lib/pretty.js';

describe('lib/pretty', () => {
  it('summarize truncates long strings with an ellipsis', () => {
    const out = summarize('x'.repeat(300), { maxLen: 120 });
    assert.equal(out.length, 120);
    assert.ok(out.endsWith('…'));
  });

  it('summarize flattens objects to key=value pairs', () => {
    const out = summarize({ command: 'echo hi', timeout: 5 });
    assert.ok(out.includes('command=echo hi'));
    assert.ok(out.includes('timeout=5'));
    assert.ok(!out.includes('"')); // no raw JSON noise
  });

  it('summarize summarizes long arrays with a +N more tail', () => {
    const out = summarize([1, 2, 3, 4, 5, 6]);
    assert.ok(out.startsWith('['));
    assert.ok(out.includes('+2 more'));
  });

  it('redactArgs masks secret-looking keys but keeps the rest', () => {
    const out = redactArgs({ password: 'hunter2supersecret', apiKey: 'sk-abcdef0123456789', command: 'echo hi', nested: { token: 'zzz' } });
    assert.equal(out.command, 'echo hi');
    assert.ok(out.password.startsWith('hun'));
    assert.ok(out.password.endsWith('•••'));
    assert.ok(out.apiKey.startsWith('sk-'));
    assert.ok(out.apiKey.endsWith('•••'));
    assert.ok(out.nested.token.endsWith('•••'));
    // input untouched
    assert.equal(out.command, 'echo hi');
    assert.equal(out.password.length, 6);
  });

  it('redactArgs passes through non-objects', () => {
    assert.equal(redactArgs(null), null);
    assert.equal(redactArgs('plain'), 'plain');
    const arr = redactArgs([1, 2]);
    assert.deepEqual(arr, [1, 2]);
  });

  it('stamp returns an HH:MM:SS shape', () => {
    assert.match(stamp(new Date('2026-01-02T03:04:05')), /^\d{2}:\d{2}:\d{2}/);
  });

  it('logEvent emits one line with symbol, message, and compact detail', () => {
    const lines = [];
    logEvent('🔧', 'tool.name', { a: 1 }, { stream: (l) => lines.push(l) });
    assert.equal(lines.length, 1);
    assert.ok(lines[0].includes('🔧'));
    assert.ok(lines[0].includes('tool.name'));
    assert.ok(lines[0].includes('a=1'));
  });

  it('logEvent omits the detail segment when empty', () => {
    const lines = [];
    logEvent('·', 'quiet', '', { stream: (l) => lines.push(l) });
    assert.equal(lines.length, 1);
    assert.ok(lines[0].includes('quiet'));
    assert.ok(!lines[0].trimEnd().endsWith('=')); // no dangling empty detail
  });
});
