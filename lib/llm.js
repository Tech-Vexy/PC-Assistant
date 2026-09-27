// Minimal OpenAI-compatible chat helper (vision §39–41).
// Uses the configured provider (resolveLlmConfig: OpenRouter default, or any
// BYOK base URL) for planner/reasoning calls that aren't voice turns.
// Not a streaming voice path — single request/response with JSON support.
import { resolveLlmConfig } from './model-router.js';

export async function chatComplete({ system, user, model = null, json = false, timeoutMs = 60000 } = {}) {
  const cfg = resolveLlmConfig();
  // Prefer an explicit key; fall back to local no-auth servers like elsewhere.
  const apiKey = cfg.apiKey || cfg.geminiKey;
  if (!apiKey) {
    throw new Error('No LLM configured — set LLM_API_KEY (OpenRouter) at /setup.');
  }
  const chosen = model || cfg.fast;
  const body = {
    model: chosen,
    messages: [
      ...(system ? [{ role: 'system', content: system }] : []),
      { role: 'user', content: user },
    ],
  };
  if (json) {
    body.response_format = { type: 'json_object' };
  }
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(`${cfg.baseUrl}/chat/completions`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      signal: controller.signal,
      body: JSON.stringify(body),
    });
    if (!res.ok) {
      const text = await res.text().catch(() => '');
      throw new Error(`LLM request failed (${res.status}): ${text.slice(0, 200)}`);
    }
    const data = await res.json();
    const content = data.choices?.[0]?.message?.content || '';
    if (!json) return content;
    const match = String(content).match(/\{[\s\S]*\}/);
    if (!match) throw new Error('LLM did not return JSON');
    return JSON.parse(match[0]);
  } catch (err) {
    if (err.name === 'AbortError') throw new Error(`LLM request timed out after ${timeoutMs}ms`);
    throw err;
  } finally {
    clearTimeout(timer);
  }
}
