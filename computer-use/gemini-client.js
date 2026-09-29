// Gemini Computer Use client (spec §4.3).
//
// NOTE ON API SHAPE: the spec's `ai.interactions.create({ model, input,
// tools })` transport does not exist in @google/genai v2.24.0 (its
// Interactions surface is agent-oriented with different params). What DOES
// exist is `ai.models.generateContent` with `tools: [{ computerUse:
// { environment, enablePromptInjectionDetection } }]` — the same
// screenshot → functionCall → execute → screenshot loop. This module speaks
// generateContent to the real API but exposes the spec's
// `interactions.create({ input, previous_interaction_id, function_results })`
// interface, so dispatch.js (and its tests) are transport-agnostic.
// Only this file needs to change if the SDK gains the doc's shape.
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
  // Use gemini-2.5-pro as it's more stable for computer use, but allow override
  const model =
    cfg('GEMINI_VISION_MODEL') || cfg('COMPUTER_USE_MODEL') || cfg('GEMINI_MODEL', 'gemini-2.5-pro');
  const stepTimeoutMs = Number(cfg('COMPUTER_USE_STEP_TIMEOUT_MS', '30000')) || 30000;
  return { apiKey, model, environment: environment === 'browser' ? 'browser' : 'desktop', stepTimeoutMs };
}

// Default factory: real Gemini client using the correct interactions API.
export async function defaultClientFactory({ environment = 'desktop' } = {}) {
  const resolved = resolveComputerUse({ environment });
  const { GoogleGenAI } = await import('@google/genai');
  const ai = new GoogleGenAI({ apiKey: resolved.apiKey });
  let callSeq = 0;

  // Convert the interactions API response to our internal step format
  function toSteps(interaction) {
    const steps = [];
    
    // Extract function calls from the interaction
    if (interaction && interaction.replies) {
      for (const reply of interaction.replies) {
        if (reply && reply.functionCalls && reply.functionCalls.length > 0) {
          for (const fc of reply.functionCalls) {
            steps.push({
              type: 'function_call',
              name: fc.name,
              id: fc.id || `c${steps.length + 1}`,
              arguments: fc.args || {},
            });
          }
        }
        // Check for safety decisions
        if (reply && reply.safetyDecision) {
          steps.push({
            type: 'safety_decision',
            decision: reply.safetyDecision,
          });
        }
        // Check for intents (reasoning in Gemini 3.x)
        if (reply && reply.intent) {
          steps.push({
            type: 'intent',
            content: reply.intent,
          });
        }
      }
    }
    
    // If no function calls, check for text response
    if (steps.length === 0 && interaction && interaction.replies) {
      for (const reply of interaction.replies) {
        if (reply && reply.content) {
          for (const part of reply.content.parts || []) {
            if (part && part.text) {
              steps.push({
                type: 'model_output',
                content: [{ type: 'text', text: part.text }],
              });
            }
          }
        }
      }
    }
    
    return steps;
  }

  // Convert our internal input format to the interactions API format
  function toInteractionsInput(input) {
    const parts = [];
    for (const item of input || []) {
      if (item.type === 'text') {
        parts.push({ text: item.text });
      } else if (item.type === 'image') {
        parts.push({ inlineData: { mimeType: 'image/png', data: item.data } });
      } else if (typeof item.text === 'string') {
        parts.push({ text: item.text });
      }
    }
    return parts;
  }

  // Convert function results to the interactions API format
  function toFunctionResults(functionResults) {
    return functionResults.map(fr => {
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
      return { name: fr.name, parts };
    });
  }

  return {
    interactions: {
      create: async (params = {}) => {
        try {
          // Use the real interactions API
          const interactionParams = {
            model: resolved.model,
            input: toInteractionsInput(params.input),
            tools: [{ type: 'computer_use', environment: resolved.environment }],
            config: {
              systemInstruction: buildSafetyInstruction(),
            },
          };

          // Handle function results for continuation
          if (Array.isArray(params.function_results) && params.function_results.length > 0) {
            interactionParams.functionResults = toFunctionResults(params.function_results);
          }

          // Step timeout as a race
          const timeout = new Promise((_, reject) =>
            setTimeout(() => reject(new Error(`Gemini step timed out after ${resolved.stepTimeoutMs}ms`)), resolved.stepTimeoutMs)
          );

          // Add retry logic for 503 errors (high demand)
          let lastError;
          const maxRetries = 3;
          for (let attempt = 0; attempt < maxRetries; attempt++) {
            try {
              const interactionPromise = ai.interactions.create(interactionParams);
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

          return {
            id: interaction.id || `gen-${++callSeq}`,
            steps: toSteps(interaction),
          };
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
  const toolConfig = {
    computerUse: {
      environment: computerUseEnvName(resolved.environment),
      enablePromptInjectionDetection: true,
    },
  };
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
