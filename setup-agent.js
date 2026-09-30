import { buildAllTools } from './tools.js';
import { buildLlmRoutes, resolveLlmConfig } from './lib/model-router.js';
import { vetAllTools, signToolManifest } from './lib/security-extras.js';
import { initStore, cfg } from './lib/store.js';
import { gatherDeviceContext, formatDeviceContext } from './lib/device-context.js';
import dotenv from 'dotenv';

dotenv.config(process.env.DOTENV_PATH ? { path: process.env.DOTENV_PATH } : undefined);

async function createAgent() {
  await initStore(); // local store (seeds from legacy files); config via cfg()
  const apiKey = cfg('ASSEMBLYAI_API_KEY');
  // Voice LLM defaults to OpenRouter (base + free model baked in); only the
  // key is required. OPENAI_API_KEY/OPENAI_BASE_URL still work as fallback.
  const llmCfg = resolveLlmConfig();

  if (!apiKey) {
    console.error('ASSEMBLYAI_API_KEY not found in environment variables');
    process.exit(1);
  }

  if (!llmCfg.apiKey) {
    console.error('No LLM API key found — set LLM_API_KEY (your OpenRouter key) at /setup.');
    console.error('Local no-auth servers (Ollama/LM Studio) are detected from a localhost LLM_BASE_URL.');
    process.exit(1);
  }

  const tools = buildAllTools();

  // Host device context: which apps actually exist here. Injected into the
  // system prompt so the agent launches real apps by name instead of guessing
  // (a failed "Open Control Panel" used to bounce through computer_use →
  // open_application → run_command before anything worked).
  console.log('Gathering host device context (installed apps)…');
  const deviceContext = await gatherDeviceContext();
  const deviceBlock = formatDeviceContext(deviceContext);
  if (deviceBlock) {
    console.log(`✅ Device context ready (${deviceContext.apps.length} apps found)`);
  } else {
    console.warn('⚠️  No device context gathered — publishing the agent without it.');
  }

  const systemPrompt = [
    // Knowledge & search: the assistant is a source of knowledge first and a
    // PC controller second — conceptual questions get answered directly,
    // time-sensitive ones get web_search first.
    `You are a personal assistant on the user's PC and a knowledgeable general assistant. For conceptual or factual questions (for example "Tell me about Transformer model architecture"), answer directly from your own knowledge with a clear, well-structured explanation at the depth the question implies — do not treat it as a command to control the PC. When information could be time-sensitive (news, prices, software versions, sports results) or the user explicitly asks for something current, call web_search first and summarize the results with their sources. It is fine to combine both: explain from knowledge, then search to confirm or extend.`,
    deviceBlock
      ? `ABOUT THIS PC
${deviceBlock}

When the user asks to open or use an application, prefer the exact installed names above (including URI apps like Settings). If an app is not in the list, do not guess: say it is not installed (offer to search the web for an installer) or use computer_use to find it visually on screen.`
      : '',
    `You can search the web, launch applications, control media playback and audio volume, read/write clipboard, control the desktop (mouse, keyboard, windows), monitor system health, and operate the computer autonomously with the computer_use tool (it sees the screen and acts with mouse and keyboard — use it for UI tasks like checking or composing email in the browser, managing calendars, filling forms, opening apps, or navigating websites).`,
    `HOW TO PLAN AND EXECUTE MULTI-STEP WORK
For simple requests act directly with the single right tool (prefer dedicated tools over computer_use). Reach for planning when a request needs several coordinated steps or will be repeated: call plan_task with the goal (it decomposes into validated steps and can ground them in remembered context), then execute_plan to run it — execution goes step by step through the normal safety gates, verifies each state-changing step, checkpoints progress, retries a transient failure once, and resumes from the last checkpoint if interrupted. Report progress and the final outcome to the user. If a request will recur (a daily routine, a project setup), save_workflow it once and run_workflow it thereafter. Do not plan for single simple actions — a one-tool answer needs no plan.`,
    `IMPORTANT SECURITY RULES:
- Before moving the mouse, clicking, typing text, opening applications, killing processes, or running shell commands, describe what you're about to do and wait for explicit confirmation.
- When computer_use pauses for a confirmation, tell the user what is being asked and wait — approvals happen in the local approval UI, and the tool result will tell you the outcome.
- After a computer_use task finishes, relay its summary to the user in your own words.
- Never attempt to kill system processes (PID 1) or the assistant's own process.
- Only run commands that are in the allowlist.
- Be cautious with device control operations.`,

  `SCREEN AWARENESS (your eyes)
- You can SEE the user's screen with the screen_context tool — it captures what is visible right now and reads it back to you as text.
- Use it whenever the user says "this", "that", "on my screen", or refers to anything visible: check what is actually there before acting.
- Use it after launching apps or during computer_use follow-ups to verify state, and to answer questions like "what am I looking at?".
- If screen_context returns an error, say you could not see the screen and suggest trying again — never invent what might be on screen.`,
  ].filter(Boolean).join('\n\n');

  // Semantic vetting + integrity manifest before publishing tools to the cloud agent
  console.log('Vetting tool descriptors…');
  const vet = await vetAllTools(tools);
  const bad = vet.filter((v) => !v.ok);
  if (bad.length > 0) {
    console.error('❌ Tool vetting failed:', bad);
    process.exit(1);
  }
  console.log('✅ All tool descriptors passed vetting');
  const manifest = await signToolManifest(tools);
  console.log(`✅ Manifest signed (${manifest.sha256.slice(0, 12)}…)`);

  const llm = buildLlmRoutes();
  if (llm.length === 0) {
    console.error('Could not build BYOK llm routes — set LLM_API_KEY (OpenRouter) at /setup.');
    process.exit(1);
  }
  console.log(`LLM provider: ${llmCfg.baseUrl} (fast=${llmCfg.fast}, strong=${llmCfg.strong})`);

  const agentConfig = {
    name: 'PC Personal Assistant',
    system_prompt: systemPrompt,
    greeting: "Hello there, I'm your PC Assistant. How can I help you today?",
    voice: {
      voice_id: cfg('VOICE_ID', 'alba'),
    },
    llm,
    tools: tools,
  };

  try {
    console.log('Creating AssemblyAI agent...');
    const response = await fetch('https://agents.assemblyai.com/v1/agents', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${apiKey}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(agentConfig)
    });

    if (!response.ok) {
      const error = await response.text();
      throw new Error(`Failed to create agent: ${response.status} - ${error}`);
    }

    const agent = await response.json();

    // The create endpoint returns the full agent record; accept any common
    // id field shape so a renamed upstream field can't silently publish
    // "AGENT_ID=undefined" (which the launcher would then store as real).
    const agentId = agent?.id || agent?.agent_id || agent?.agentId || agent?.data?.id || agent?.data?.agent_id || null;
    if (!agentId || typeof agentId !== 'string' || /^(undefined|null)$/i.test(agentId)) {
      console.error('❌ Agent created, but no agent id found in the response.');
      console.error(`Response keys: ${Object.keys(agent || {}).join(', ') || '(none)'}`);
      console.error(`Raw response: ${JSON.stringify(agent).slice(0, 600)}`);
      process.exit(1);
    }

    console.log('✅ Agent created successfully!');
    console.log(`Agent ID: ${agentId}`);
    console.log(`Agent Name: ${agent?.name || '(unnamed)'}`);
    console.log('\nAdd this to your .env file:');
    console.log(`AGENT_ID=${agentId}`);

    return agent;
  } catch (error) {
    console.error('Error creating agent:', error.message);
    process.exit(1);
  }
}

// Run the setup
createAgent();
