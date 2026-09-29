// Gemini Computer Use client (spec §4.3).
//
// NOTE ON API SHAPE: @google/genai v2.24.0 ships the interactions API
// (`ai.interactions.create`) with snake_case params —
// `enable_prompt_injection_detection`, `system_instruction` — which is the
// primary transport here. The camelCase `ComputerUse` tool interface
// (`ai.models.generateContent` with `tools: [{ computerUse: {...} }]`) is kept
// as the fallback transport. Both drive the same screenshot → functionCall →
// execute → screenshot loop. This module exposes the spec's
// `interactions.create({ input, previous_interaction_id, function_results })`
// interface, so dispatch.js (and its tests) are transport-agnostic.
//
// setClientFactory(fn)/resetClient() let tests inject a fully fake client.

import { cfg } from '../lib/store.js';
import { buildSafetyInstruction } from './safety.js';

let clientFactoryOverride = null;

export function setClientFactory(fn) {
  clientFactoryOverride = fn;
}

export function resetClient() {
  clientFactoryOverride = null;
}

export function computerUseEnvName(environment) {
  return environment === 'browser' ? 'ENVIRONMENT_BROWSER' : 'ENVIRONMENT_DESKTOP';
}

export function resolveComputerUse({ environment = 'desktop' } = {}) {
  const apiKey = cfg('GEMINI_API_KEY');
  if (!apiKey) {
    throw new Error('GEMINI_API_KEY is not configured — set it at /setup or in the environment.');
  }
  const model =
    cfg('GEMINI_VISION_MODEL') || cfg('COMPUTER_USE_MODEL') || cfg('GEMINI_MODEL', 'gemini-3.8-flash');
  const stepTimeoutMs = Number(cfg('COMPUTER_USE_STEP_TIMEOUT_MS', '30000')) || 30000;
  const enablePromptInjectionDetection = cfg('COMPUTER_USE_ENABLE_PROMPT_INJECTION_DETECTION', 'true') === 'true';
  const disabledSafetyPolicies = cfg('COMPUTER_USE_DISABLED_SAFETY_POLICIES', '')
    .split(',')
    .map(s => s.trim().toUpperCase())
    .filter(Boolean);
  const excludedPredefinedFunctions = cfg('COMPUTER_USE_EXCLUDED_FUNCTIONS', '')
    .split(',')
    .map(s => s.trim())
    .filter(Boolean);
  
  return { 
    apiKey, 
    model, 
    environment: environment === 'browser' ? 'browser' : 'desktop', 
    stepTimeoutMs,
    enablePromptInjectionDetection,
    disabledSafetyPolicies,
    excludedPredefinedFunctions
  };
}

// Default factory: real Gemini client using the correct interactions API.
export async function defaultClientFactory({ environment = 'desktop' } = {}) {
  const resolved = resolveComputerUse({ environment });
  const { GoogleGenAI } = await import('@google/genai');
  const ai = new GoogleGenAI({ apiKey: resolved.apiKey });
  let callSeq = 0;

  // Convert the interactions API response (typed `steps` array) to our
  // internal step format. Function-call steps carry {name, id, arguments};
  // model-output steps carry content items of the form {type:'text', text}.
  function toSteps(interaction) {
    const steps = [];

    for (const step of interaction?.steps || []) {
      if (step?.type === 'function_call') {
        steps.push({
          type: 'function_call',
          name: step.name,
          id: step.id || `c${steps.length + 1}`,
          arguments: step.arguments || {},
        });
      } else if (step?.type === 'safety_decision') {
        steps.push({ type: 'safety_decision', decision: step });
      } else if (step?.type === 'model_output') {
        for (const c of step.content || []) {
          if (c?.type === 'text' && c.text) {
            steps.push({ type: 'model_output', content: [{ type: 'text', text: c.text }] });
          }
        }
      }
      // thought / other step types are intentionally ignored
    }

    // Some completions surface the final text only as output_text.
    if (steps.length === 0 && typeof interaction?.output_text === 'string' && interaction.output_text) {
      steps.push({ type: 'model_output', content: [{ type: 'text', text: interaction.output_text }] });
    }

    return steps;
  }

  // Convert our internal input format to typed interactions content
  // ({type:'text', text} / {type:'image', mime_type, data}).
  function toInteractionsInput(input) {
    const parts = [];
    for (const item of input || []) {
      if (item.type === 'text') {
        parts.push({ type: 'text', text: item.text });
      } else if (item.type === 'image') {
        parts.push({ type: 'image', mime_type: item.mime_type || 'image/png', data: item.data });
      } else if (typeof item.text === 'string') {
        parts.push({ type: 'text', text: item.text });
      }
    }
    return parts;
  }

  // Convert function results to interactions input steps: a function_result
  // step per result, matching the originating function_call via call_id.
  function toResultSteps(functionResults) {
    return functionResults.map((fr) => {
      const result = [];
      const textPart = (fr.result || []).find((p) => typeof p.text === 'string');
      result.push({ type: 'text', text: textPart?.text || '' });
      const shot = (fr.result || []).find((p) => p.data);
      if (shot) result.push({ type: 'image', mime_type: shot.mime_type || 'image/png', data: shot.data });
      return {
        type: 'function_result',
        call_id: fr.call_id || fr.id,
        name: fr.name,
        result,
      };
    });
  }

  return {
    interactions: {
      create: async (params = {}) => {
        try {
          // Use the real interactions API
          const computerUseTool = {
            type: 'computer_use',
            environment: resolved.environment,
            enable_prompt_injection_detection: resolved.enablePromptInjectionDetection,
          };

          // Add disabled safety policies if configured
          if (resolved.disabledSafetyPolicies.length > 0) {
            computerUseTool.disabled_safety_policies = resolved.disabledSafetyPolicies;
          }

          // Add excluded predefined functions if configured
          if (resolved.excludedPredefinedFunctions.length > 0) {
            computerUseTool.excluded_predefined_functions = resolved.excludedPredefinedFunctions;
          }

          // The interactions API takes the system instruction as a top-level
          // snake_case field (`system_instruction`); a `config.systemInstruction`
          // wrapper is silently dropped by the REST backend.
          const interactionParams = {
            model: resolved.model,
            input: toInteractionsInput(params.input),
            tools: [computerUseTool],
            system_instruction: buildSafetyInstruction(),
          };

          // Continuation: thread the prior interaction id so the server has
          // the conversation history.
          if (params.previous_interaction_id) {
            interactionParams.previous_interaction_id = params.previous_interaction_id;
          }

          // Continuation: function results are passed as function_result
          // INPUT steps (the API has no top-level function_results field).
          if (Array.isArray(params.function_results) && params.function_results.length > 0) {
            interactionParams.input = toResultSteps(params.function_results);
          }

          // Add retry logic for 503 errors (high demand)
          let lastError;
          const maxRetries = 3;
          for (let attempt = 0; attempt < maxRetries; attempt++) {
            try {
              const interactionPromise = ai.interactions.create(interactionParams);
              // Step timeout as a race — a fresh timer per attempt so a retry
              // after 503 backoff gets a full window.
              const timeout = new Promise((_, reject) =>
                setTimeout(() => reject(new Error(`Gemini step timed out after ${resolved.stepTimeoutMs}ms`)), resolved.stepTimeoutMs)
              );
              const interaction = await Promise.race([interactionPromise, timeout]);
              return {
                id: interaction.id || `gen-${++callSeq}`,
                steps: toSteps(interaction),
              };
            } catch (retryError) {
              lastError = retryError;
              // Check if it's a 503 error (high demand)
              if (retryError.message && retryError.message.includes('503')) {
                if (attempt < maxRetries - 1) {
                  console.warn(`Gemini API experiencing high demand (503), retrying attempt ${attempt + 1}/${maxRetries}...`);
                  await new Promise(resolve => setTimeout(resolve, 2000 * (attempt + 1))); // Exponential backoff
                  continue;
                }
              }
              throw retryError;
            }
          }
          throw lastError;
        } catch (error) {
          // If interactions API is not available, fall back to generateContent
          if (error.message && error.message.includes('interactions')) {
            console.warn('Falling back to generateContent API for computer use');
            return fallbackToGenerateContent(params, resolved, ai, callSeq);
          }
          throw error;
        }
      },
    },
  };
}

// Fallback to generateContent if interactions API is not available
async function fallbackToGenerateContent(params, resolved, ai, callSeq) {
  const contents = [];
  // generateContent uses the camelCase ComputerUse tool interface (the SDK
  // converts to snake_case on the wire) — respect the configured flags here.
  const toolConfig = {
    computerUse: {
      environment: computerUseEnvName(resolved.environment),
      enablePromptInjectionDetection: resolved.enablePromptInjectionDetection,
    },
  };
  if (resolved.disabledSafetyPolicies.length > 0) {
    toolConfig.computerUse.disabledSafetyPolicies = resolved.disabledSafetyPolicies;
  }
  if (resolved.excludedPredefinedFunctions.length > 0) {
    toolConfig.computerUse.excludedPredefinedFunctions = resolved.excludedPredefinedFunctions;
  }
  const safetyInstruction = buildSafetyInstruction();

  function toSteps(res) {
    const fcs = extractFunctionCalls(res);
    if (fcs.length > 0) {
      contents.push({
        role: 'model',
        parts: fcs.map((fc) => ({ functionCall: { name: fc.name, args: fc.args } })),
      });
      return fcs.map((fc) => ({
        type: 'function_call',
        name: fc.name,
        id: fc.id,
        arguments: fc.args,
      }));
    }
    const text = typeof res?.text === 'string' ? res.text : '';
    return [{ type: 'model_output', content: [{ type: 'text', text }] }];
  }

  async function generate(userParts) {
    contents.push({ role: 'user', parts: userParts });
    const generateOnce = () =>
      ai.models.generateContent({
        model: resolved.model,
        contents,
        config: { tools: [toolConfig], systemInstruction: safetyInstruction },
      });
    const timeout = new Promise((_, reject) =>
      setTimeout(() => reject(new Error(`Gemini step timed out after ${resolved.stepTimeoutMs}ms`)), resolved.stepTimeoutMs)
    );
    return Promise.race([generateOnce(), timeout]);
  }

  if (Array.isArray(params.function_results)) {
    for (const fr of params.function_results) {
      const parts = [];
      const textPart = (fr.result || []).find((p) => typeof p.text === 'string');
      let response = {};
      try {
        response = textPart ? JSON.parse(textPart.text) : {};
      } catch {
        response = { raw: textPart?.text || '' };
      }
      parts.push({ functionResponse: { name: fr.name, response } });
      const shot = (fr.result || []).find((p) => p.data);
      if (shot) parts.push({ inlineData: { mimeType: 'image/png', data: shot.data } });
      contents.push({ role: 'user', parts });
    }
    const res = await generate([]);
    return { id: `gen-${++callSeq}`, steps: toSteps(res) };
  }
  const parts = [];
  for (const item of params.input || []) {
    if (item.type === 'text') parts.push({ text: item.text });
    else if (item.type === 'image') parts.push({ inlineData: { mimeType: 'image/png', data: item.data } });
    else if (typeof item.text === 'string') parts.push({ text: item.text });
  }
  const res = await generate(parts);
  return { id: `gen-${++callSeq}`, steps: toSteps(res) };
}

export async function getClient(opts = {}) {
  if (clientFactoryOverride) return clientFactoryOverride(opts);
  return defaultClientFactory(opts);
}

function extractFunctionCalls(res) {
  if (Array.isArray(res?.functionCalls) && res.functionCalls.length > 0) {
    return res.functionCalls.map((fc, i) => ({
      name: String(fc.name || ''),
      args: fc.args || {},
      id: fc.id || `c${i + 1}`,
    }));
  }
  const out = [];
  try {
    for (const cand of res?.candidates || []) {
      for (const part of cand?.content?.parts || []) {
        if (part?.functionCall) {
          out.push({
            name: String(part.functionCall.name || ''),
            args: part.functionCall.args || {},
            id: `c${out.length + 1}`,
          });
        }
      }
    }
  } catch {
    /* ignore malformed responses */
  }
  return out;
}
