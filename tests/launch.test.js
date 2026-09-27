// Launcher helper tests (pure file/env logic — never spawns processes).
import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs/promises';

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { hasRealValue, isLocalBaseUrl, setEnvKey, configStatus } from '../scripts/launch.js';

describe('launch helpers', () => {
  it('hasRealValue rejects blanks, placeholders, and non-strings', () => {
    assert.equal(hasRealValue('sk-abc'), true);
    assert.equal(hasRealValue(''), false);
    assert.equal(hasRealValue('   '), false);
    assert.equal(hasRealValue('your_assemblyai_api_key_here'), false);
    assert.equal(hasRealValue(undefined), false);
    assert.equal(hasRealValue(null), false);
  });

  it('configStatus flags missing keys and detects local LLM servers', () => {
    const missing = configStatus({});
    assert.ok(missing.missing.includes('ASSEMBLYAI_API_KEY'));
    assert.ok(missing.missing.includes('LLM_API_KEY (OpenRouter)'));
    assert.equal(missing.hasLlm, false);
    assert.equal(missing.hasAgent, false);

    const local = configStatus({
      ASSEMBLYAI_API_KEY: 'aai-x',
      LLM_BASE_URL: 'http://localhost:11434/v1',
    });
    assert.deepEqual(local.missing, []);
    assert.equal(local.hasLlm, true);

    const cloud = configStatus({ ASSEMBLYAI_API_KEY: 'a', LLM_API_KEY: 'sk-x' });
    assert.deepEqual(cloud.missing, []);
    assert.equal(cloud.hasLlm, true);
    assert.equal(configStatus({ AGENT_ID: 'agent-1' }).hasAgent, true);
  });

  it('configStatus requires no Google OAuth', () => {
    const s = configStatus({ ASSEMBLYAI_API_KEY: 'a', LLM_API_KEY: 'sk-x' });
    assert.deepEqual(s.missing, []);
    assert.deepEqual(s.warnings, []);
  });

  it('isLocalBaseUrl matches loopback hosts', () => {
    assert.equal(isLocalBaseUrl('http://localhost:11434/v1'), true);
    assert.equal(isLocalBaseUrl('http://127.0.0.1:1234/v1'), true);
    assert.equal(isLocalBaseUrl('https://api.openai.com/v1'), false);
    assert.equal(isLocalBaseUrl(''), false);
  });

  it('setEnvKey replaces in place and appends new keys', async () => {
    const file = path.join(os.tmpdir(), `test-launch-env-${process.pid}.env`);
    try {
      await fs.writeFile(file, 'PORT=3000\nAGENT_ID=old\n', { mode: 0o600 });
      await setEnvKey(file, 'AGENT_ID', 'new-123');
      await setEnvKey(file, 'LLM_API_KEY', 'sk-x');
      const text = await fs.readFile(file, 'utf8');
      assert.match(text, /^AGENT_ID=new-123$/m);
      assert.match(text, /^LLM_API_KEY=sk-x$/m);
      assert.match(text, /^PORT=3000$/m);
      assert.doesNotMatch(text, /old/);
    } finally {
      await fs.rm(file, { force: true });
    }
  });
});
