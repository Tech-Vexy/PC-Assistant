// Model routing: pick a cheap/fast model for simple queries, stronger model for complex ones.
// Used by setup-agent.js (BYOK llm list) and documented for AssemblyAI session config.
// No network calls here — pure heuristic so it works offline and is testable.
//
// Config values come from cfg(): process.env wins when set, else the DuckDB
// config table (managed at /setup), else built-in defaults.
import { cfg } from './store.js';

const COMPLEXITY_SIGNALS = [
  /summariz|analyz|compare|plan|research|debug|explain|write (an? )?(email|report|essay|code)/i,
  /step.by.step|pros and cons|tradeoff/i,
];

const LONG_QUERY_THRESHOLD = 220; // chars
const MULTI_TASK_SIGNALS = [/\band\b.*\band\b/i, /\?.*\?/, /;.*;/];

export function estimateComplexity(query = '') {
  const q = String(query);
  let score = 0;
  if (q.length > LONG_QUERY_THRESHOLD) score += 2;
  if (q.length > 600) score += 2;
  for (const re of COMPLEXITY_SIGNALS) if (re.test(q)) score += 2;
  for (const re of MULTI_TASK_SIGNALS) if (re.test(q)) score += 1;
  // Code / structured output requests tend to need stronger models
  if (/```|json|sql|python|javascript|typescript|function|class /i.test(q)) score += 1;
  return score;
}

export function routeModel(query = '', { fast, strong, threshold = 3 } = {}) {
  const fastModel = fast || cfg('FAST_MODEL', DEFAULT_FREE_MODEL);
  const strongModel = strong || cfg('STRONG_MODEL', DEFAULT_FREE_MODEL);
  const score = estimateComplexity(query);
  const model = score >= threshold ? strongModel : fastModel;
  // Tier follows the score, not model identity (fast and strong may be equal).
  return { model, score, tier: score >= threshold ? 'strong' : 'fast' };
}

// Resolve the configured OpenAI-compatible LLM provider.
// Canonical vars: LLM_API_KEY / LLM_BASE_URL.
// Legacy fallbacks: OPENAI_API_KEY / OPENAI_BASE_URL (kept for backwards compat).
// Any base_url speaking the OpenAI chat-completions API works:
// OpenAI, Azure OpenAI, Ollama, LM Studio, vLLM, Together, Groq, Mistral, etc.
// DEFAULTS ARE OPENROUTER: base https://openrouter.ai/api/v1 with the free
// router model, so only an OpenRouter API key is needed out of the box.
export const DEFAULT_LLM_BASE_URL = 'https://openrouter.ai/api/v1';
export const DEFAULT_FREE_MODEL = 'openrouter/free'; // Free Models Router (tools + vision)

// Gemini (Google AI Studio) also speaks the OpenAI chat-completions protocol
// at this endpoint, so it slots into the same BYOK route shape.
export const GEMINI_OPENAI_BASE_URL = 'https://generativelanguage.googleapis.com/v1beta/openai';
export const DEFAULT_GEMINI_MODEL = 'gemini-3.8-flash';

// AssemblyAI LLM Gateway: OpenAI-compatible, authed with the AssemblyAI key.
export const LLM_GATEWAY_BASE_URL = 'https://llm-gateway.assemblyai.com/v1';

function isGeminiBaseUrl(baseUrl = '') {
  const b = String(baseUrl).toLowerCase();
  return b.includes('generativelanguage.googleapis.com') || b.includes('llm-gateway.assemblyai.com');
}

export function resolveLlmConfig(overrides = {}) {
  const apiKey =
    overrides.apiKey ||
    cfg('LLM_API_KEY') ||
    cfg('OPENAI_API_KEY') ||
    '';
  const rawBase =
    overrides.baseUrl ||
    cfg('LLM_BASE_URL') ||
    cfg('OPENAI_BASE_URL') ||
    DEFAULT_LLM_BASE_URL;
  // Normalise: drop trailing slashes so `${baseUrl}/chat/completions` is stable.
  const baseUrl = String(rawBase).replace(/\/+$/, '');
  const fast = overrides.fast || cfg('FAST_MODEL', DEFAULT_FREE_MODEL);
  const strong = overrides.strong || cfg('STRONG_MODEL', DEFAULT_FREE_MODEL);
  // Gemini key precedence: explicit GEMINI_API_KEY, else the LLM key when the
  // provider already speaks to Gemini (direct endpoint or the LLM Gateway).
  const geminiKey =
    overrides.geminiKey ||
    cfg('GEMINI_API_KEY') ||
    (isGeminiBaseUrl(baseUrl) ? apiKey : '') ||
    '';
  return { apiKey, baseUrl, fast, strong, geminiKey };
}

function isLocalBaseUrl(baseUrl) {
  return /^(https?:\/\/)?(localhost|127\.0\.0\.1|0\.0\.0\.0)(:\d+)?(\/|$)/i.test(baseUrl) ||
    /ollama/i.test(baseUrl);
}

// Optional cross-provider fallback chain for the voice LLM.
// LLM_FALLBACK_MODELS is a comma list of "provider:model" entries, e.g.
//   LLM_FALLBACK_MODELS=gateway:claude-sonnet-4-6,gateway:gpt-5-mini
// Providers: gateway (AssemblyAI key), google (GEMINI_API_KEY),
// openai (OPENAI_API_KEY), openrouter (LLM_API_KEY), anthropic (ANTHROPIC_API_KEY).
const FALLBACK_PROVIDERS = {
  gateway: { baseUrl: LLM_GATEWAY_BASE_URL, keyVar: 'ASSEMBLYAI_API_KEY' },
  google: { baseUrl: GEMINI_OPENAI_BASE_URL, keyVar: 'GEMINI_API_KEY' },
  openai: { baseUrl: 'https://api.openai.com/v1', keyVar: 'OPENAI_API_KEY' },
  openrouter: { baseUrl: DEFAULT_LLM_BASE_URL, keyVar: 'LLM_API_KEY' },
  anthropic: { baseUrl: 'https://api.anthropic.com/v1', keyVar: 'ANTHROPIC_API_KEY' },
};

function parseFallbackModels(raw) {
  const out = [];
  for (const part of String(raw || '').split(',')) {
    const entry = part.trim();
    if (!entry) continue;
    const idx = entry.indexOf(':');
    if (idx <= 0) {
      console.warn(`Ignoring LLM_FALLBACK_MODELS entry "${entry}" — expected provider:model`);
      continue;
    }
    const provider = entry.slice(0, idx).trim().toLowerCase();
    const model = entry.slice(idx + 1).trim();
    const spec = FALLBACK_PROVIDERS[provider];
    if (!spec || !model) {
      console.warn(`Ignoring LLM_FALLBACK_MODELS entry "${entry}" — unknown provider "${provider}"`);
      continue;
    }
    const apiKey = cfg(spec.keyVar) || '';
    if (!apiKey) {
      console.warn(`Skipping LLM fallback ${provider}:${model} — ${spec.keyVar} not set`);
      continue;
    }
    out.push({ base_url: spec.baseUrl, model, api_key: apiKey });
  }
  return out;
}

// Build the BYOK llm array for AssemblyAI agent config. Gemini-first when a
// Gemini key is available, followed by any configured cross-provider
// fallbacks. Without a Gemini key this is the historical fast/strong pair on
// one provider (first entry is the default the agent uses).
export function buildLlmRoutes({ fast, strong, apiKey, baseUrl } = {}) {
  const cfgv = resolveLlmConfig({ fast, strong, apiKey, baseUrl });
  const routes = [];

  let key = cfgv.apiKey;
  if (!key && isLocalBaseUrl(cfgv.baseUrl)) {
    key = 'not-needed';
  }

  // 1. Primary route: user's configured LLM provider (e.g. OpenRouter, OpenAI, local)
  // unless the base URL specifically points to Gemini.
  if (key && !isGeminiBaseUrl(cfgv.baseUrl)) {
    if (cfgv.fast === cfgv.strong) {
      routes.push({ base_url: cfgv.baseUrl, model: cfgv.fast, api_key: key });
    } else {
      routes.push(
        { base_url: cfgv.baseUrl, model: cfgv.fast, api_key: key },
        { base_url: cfgv.baseUrl, model: cfgv.strong, api_key: key }
      );
    }
    routes.push(...parseFallbackModels(cfg('LLM_FALLBACK_MODELS')));
    return routes;
  }

  // 2. Gemini-primary: when no LLM_API_KEY is provided (only GEMINI_API_KEY)
  // or when LLM_BASE_URL explicitly points to the Gemini OpenAI endpoint.
  if (cfgv.geminiKey) {
    const geminiModel = cfg('GEMINI_MODEL') || DEFAULT_GEMINI_MODEL;
    routes.push({ base_url: GEMINI_OPENAI_BASE_URL, model: geminiModel, api_key: cfgv.geminiKey });
    routes.push(...parseFallbackModels(cfg('LLM_FALLBACK_MODELS')));
    return routes;
  }

  if (!key) {
    return [];
  }

  // Fallback for any other custom provider
  if (cfgv.fast === cfgv.strong) {
    return [{ base_url: cfgv.baseUrl, model: cfgv.fast, api_key: key }];
  }
  return [
    { base_url: cfgv.baseUrl, model: cfgv.fast, api_key: key },
    { base_url: cfgv.baseUrl, model: cfgv.strong, api_key: key },
  ];
}
