import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { TTLCache } from '../lib/cache.js';
import { routeModel, estimateComplexity } from '../lib/model-router.js';
import { normalizeMCPResult } from '../lib/mcp-client.js';

describe('TTLCache', () => {
  it('stores, hits, expires, and evicts LRU', async () => {
    const c = new TTLCache({ maxEntries: 2, defaultTtlMs: 50 });
    c.set('a', 1);
    assert.equal(c.get('a'), 1);
    await new Promise((r) => setTimeout(r, 70));
    assert.equal(c.get('a'), undefined);
    c.set('x', 1);
    c.set('y', 2);
    c.set('z', 3); // evicts x
    assert.equal(c.get('x'), undefined);
    assert.equal(c.get('z'), 3);
  });
});

describe('model-router', () => {
  it('routes simple queries to fast tier', () => {
    const r = routeModel('what time is it?');
    assert.equal(r.tier, 'fast');
  });
  it('routes complex research queries to strong tier', () => {
    const r = routeModel('Summarize these 10 emails, compare tradeoffs, and write a step-by-step plan with code: ```python``` ' + 'x'.repeat(300));
    assert.equal(r.tier, 'strong');
    assert.ok(estimateComplexity('short') < estimateComplexity('summarize and analyze with step-by-step research plan'));
  });
});

describe('normalizeMCPResult', () => {
  it('unwraps content/text envelopes', () => {
    const out = normalizeMCPResult({ content: [{ text: '{"a":1}' }] });
    assert.deepEqual(out, { a: 1 });
    const txt = normalizeMCPResult({ content: [{ text: 'hello' }] });
    assert.deepEqual(txt, { text: 'hello' });
    assert.deepEqual(normalizeMCPResult({ ok: true }), { ok: true });
  });
});
