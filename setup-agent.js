import { buildAllTools } from './tools.js';
import { buildLlmRoutes, resolveLlmConfig } from './lib/model-router.js';
import { vetAllTools, signToolManifest } from './lib/security-extras.js';
import { initStore, cfg } from './lib/store.js';
import dotenv from 'dotenv';

dotenv.config();

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
    system_prompt: `You are a personal assistant on the user's PC. You can search the web, launch applications, control media playback and audio volume, read/write clipboard, control the desktop (mouse, keyboard, windows), monitor system health, and operate the computer autonomously with the computer_use tool (it sees the screen and acts with mouse and keyboard — use it for UI tasks like checking or composing email in the browser, managing calendars, filling forms, opening apps, or navigating websites).

IMPORTANT SECURITY RULES:
- Before moving the mouse, clicking, typing text, opening applications, killing processes, or running shell commands, describe what you're about to do and wait for explicit confirmation.
- When computer_use pauses for a confirmation, tell the user what is being asked and wait — approvals happen in the local approval UI, and the tool result will tell you the outcome.
- After a computer_use task finishes, relay its summary to the user in your own words.
- Never attempt to kill system processes (PID 1) or the assistant's own process.
- Only run commands that are in the allowlist.
- Be cautious with device control operations.`,
    greeting: "Hello! I'm your PC voice assistant. I can help you search the web, operate your browser and desktop apps, launch tools, control media, and monitor your system. What would you like to do?",
    voice: { 
      voice_id: "alba" 
    },
    llm,
    tools: tools
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
    
    console.log('✅ Agent created successfully!');
    console.log(`Agent ID: ${agent.agent_id}`);
    console.log(`Agent Name: ${agent.name}`);
    console.log('\nAdd this to your .env file:');
    console.log(`AGENT_ID=${agent.agent_id}`);
    
    return agent;
  } catch (error) {
    console.error('Error creating agent:', error.message);
    process.exit(1);
  }
}

// Run the setup
createAgent();