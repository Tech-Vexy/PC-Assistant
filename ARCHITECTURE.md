# PC Personal Voice Assistant with Gemini Computer Use: Architecture, Design & Implementation

**Document Version:** 2.0  
**Target Platform:** Desktop (Windows / macOS / Linux) + Browser  
**Primary LLM:** Google Gemini (default, user-supplied API key)  
**Voice Pipeline:** AssemblyAI Voice Agent API  
**Computer Control:** Gemini Computer Use (desktop + browser environments)  
**Interaction Model:** Wake word → voice conversation → vision-guided UI automation

---

## 1. Executive Summary

This document extends the original PC voice assistant architecture with three major upgrades:

1. **Gemini as the default LLM**, routed through AssemblyAI's **LLM Gateway** with automatic fallback chains (Claude → Gemini → GPT).
2. **Gemini Computer Use integration** for vision-guided desktop and browser automation — the agent "sees" the screen via screenshots and "acts" via mouse clicks and keyboard input.
3. **BYOK everywhere**: users bring their own Gemini API key, their own AssemblyAI key, and their own Google OAuth credentials. The local Node.js service brokers all secrets server-side.

The assistant now supports commands like *"Open Google Chrome"* — the voice pipeline captures the command, Gemini Computer Use takes a screenshot, identifies the Chrome icon, clicks it, and confirms the action verbally. **Every consequential action triggers a voice confirmation gate** before execution.

---

## 2. Architecture Overview

### 2.1 Layered Architecture

| Layer | Responsibility | Key Technology |
|---|---|---|
| **Voice Layer** | Real-time conversation, STT, LLM routing, TTS, tool orchestration | AssemblyAI Voice Agent WebSocket + LLM Gateway |
| **Reasoning & Computer Use Layer** | Screen understanding, UI action generation, safety decisions | Gemini Computer Use (`@google/genai`) |
| **Action Execution Layer** | Mouse, keyboard, shell, MCP tools | nut.js, Playwright, MCP servers |
| **Auth Layer** | OAuth token management, key brokering, temporary token minting | Local Node.js Express server |
| **Wake Word Gate** | On-device hotword detection | openWakeWord / Sherpa-ONNX / Porcupine |

### 2.2 End-to-End Data Flow

```
[Microphone]
    → [Wake Word Engine] (detects "hey assistant")
    → [Audio Capture PCM16 24kHz]
    → [WebSocket: wss://agents.assemblyai.com/v1/ws?token=...]
    → [AssemblyAI: STT → LLM Gateway → Tool Call?]
    → [Tool Call: "open_chrome"]
    → [Local Node.js Dispatcher]
    → [Gemini Computer Use: screenshot → decide → click]
    → [nut.js / Playwright executes action]
    → [Screenshot → verify → repeat until done]
    → [Tool Result → WebSocket tool.result]
    → [AssemblyAI: TTS]
    → [Speaker: "Chrome is now open."]
```

The **Voice Agent API handles the full voice agent pipeline — STT, LLM, TTS, turn detection, and tool calling — over a single WebSocket**. The Computer Use loop runs client-side: send a screenshot → receive a `function_call` → execute → capture new screenshot → repeat.

---

## 3. Gemini as the Default LLM

### 3.1 Default Model Selection

| Use Case | Recommended Gemini Model | Rationale |
|---|---|---|
| **Conversational reasoning** (default) | `gemini-3.8-flash` | Lowest latency for voice; supports Computer Use natively |
| **Computer Use** | `gemini-3.8-flash` | Multi-environment support (browser, mobile, desktop) |
| **Latency-critical fallback** | `gemini-2.5-flash-lite` | Sub-1.2s response for phone-like interactions |
| **Legacy Computer Use** | `gemini-2.5-computer-use-preview-10-2025` | Older but stable; supports `excluded_predefined_functions` |

### 3.2 Routing via AssemblyAI LLM Gateway (Recommended)

AssemblyAI's **LLM Gateway** is an OpenAI-compatible API that proxies Claude, GPT, and Gemini with audio context, supporting **streaming with tool calling, structured JSON output, and cross-provider routing with automatic fallback**.

**Why use the Gateway for Gemini as default:**
- One API key (your AssemblyAI key) authenticates both the streaming STT WebSocket and the LLM Gateway endpoint — no separate accounts with OpenAI, Anthropic, or Google required.
- The Gateway automatically retries failed calls on a backup model — **Claude to Gemini to GPT** — without retry logic.
- Latency-critical pipelines can use `gemini-2.5-flash-lite` as a low-latency tier.

### 3.3 Alternative: BYOK Direct to Gemini

If the user prefers to use their Gemini API key directly (bypassing the Gateway), configure the agent's `llm` field with an OpenAI-compatible Gemini endpoint:

```javascript
llm: [{
  base_url: "https://generativelanguage.googleapis.com/v1beta/openai",
  model: "gemini-3.8-flash",
  api_key: process.env.GEMINI_API_KEY,
}]
```

The `api_key` is **write-only**: encrypted at rest and never returned in any response. To rotate the key, send a new `llm` array on `PUT /v1/agents/{id}`.

### 3.4 Recommended: Gemini via LLM Gateway with Fallback Chain

```javascript
// Agent creation with Gemini default + fallback
llm: [
  { model: "gemini-3.8-flash",    provider: "google" },   // primary
  { model: "claude-sonnet-4-6",   provider: "anthropic" }, // fallback 1
  { model: "gpt-5-nano",          provider: "openai" },    // fallback 2
]
```

The Gateway transparently retries on the next model in line when the primary fails — overloaded, rate-limited, or unavailable.

---

## 4. Gemini Computer Use: Vision-Guided Desktop & Browser Control

### 4.1 How Computer Use Works

The **Computer Use tool lets you build browser, mobile, and desktop control agents** that interact with and automate tasks. Using screenshots, the model "sees" the screen and "acts" by generating specific UI actions like mouse clicks and keyboard inputs.

The loop has four steps:

1. **Send a request** — API request with the Computer Use tool, target environment, user prompt, and a screenshot.
2. **Receive the model response** — A `function_call` representing a UI action (click, scroll, keystroke). Gemini 3.x models include a reasoning `intent` explaining why the action was chosen. A `safety_decision` may classify the action as **regular/allowed**, **`require_confirmation`**, or **blocked**.
3. **Execute the action** — Parse the `function_call`, denormalize coordinates (0–1000 → pixel), and execute via automation tools.
4. **Capture new state** — Screenshot the result and send it back in a `function_result` to request the next step.

### 4.2 Desktop vs. Browser Environment

The only thing that changes between environments is the `environment` parameter you declare.

| Environment | Value | Use Case |
|---|---|---|
| **Desktop** | `"desktop"` | Open Chrome from taskbar, control native apps, file manager |
| **Browser** | `"browser"` | Navigate web pages, fill forms, click web UI elements |

For *"Open Google Chrome"*, use `environment: "desktop"` — the model screenshots the desktop, locates the Chrome icon (taskbar or desktop shortcut), and clicks it.

### 4.3 JavaScript Implementation (Node.js)

```javascript
// gemini-computer-use.js
import { GoogleGenAI } from '@google/genai';

const ai = new GoogleGenAI({ apiKey: process.env.GEMINI_API_KEY });

async function runComputerUseTask(userPrompt, environment = 'desktop') {
  const interaction = await ai.interactions.create({
    model: 'gemini-3.8-flash',
    input: userPrompt,
    tools: [{
      type: 'computer_use',
      environment: environment,
      enable_prompt_injection_detection: true, // opt-in screenshot scanning
    }],
    system_instruction: SAFETY_SYSTEM_INSTRUCTION,
  });

  return interaction;
}
```

**Critical:** the `enable_prompt_injection_detection: true` flag activates **screenshot scanning to detect hidden adversarial instructions** (e.g., "Ignore previous commands") and blocks execution when detected. Google's Chrome agent uses a parallel classifier — the **"user alignment critic"** — that independently vets proposed actions before execution.

### 4.4 Coordinate Denormalization

Gemini returns normalized coordinates (0–1000). Scale to your screen:

```javascript
function denormalizeX(x, screenWidth) {
  return Math.floor((x / 1000) * screenWidth);
}
function denormalizeY(y, screenHeight) {
  return Math.floor((y / 1000) * screenHeight);
}
```

This pattern is directly from the official JavaScript example.

### 4.5 Action Execution with nut.js (Desktop)

Replace Playwright with **nut.js** for desktop environments. Playwright is browser-only; nut.js controls the actual OS cursor.

```javascript
// desktop-executor.js
import { mouse, keyboard, Button, Key, screen } from '@nut-tree-fork/nut-js';

const { width, height } = await screen.width(); // get screen dimensions

async function executeDesktopAction(functionCall) {
  const { name, arguments: args } = functionCall;
  const intent = args.intent || 'N/A';
  console.log(`Executing: ${name} (Intent: ${intent})`);

  switch (name) {
    case 'click_at':
    case 'click': {
      const x = denormalizeX(args.x, width);
      const y = denormalizeY(args.y, height);
      await mouse.setPosition({ x, y });
      await mouse.click(Button.LEFT);
      break;
    }
    case 'double_click': {
      const x = denormalizeX(args.x, width);
      const y = denormalizeY(args.y, height);
      await mouse.setPosition({ x, y });
      await mouse.doubleClick(Button.LEFT);
      break;
    }
    case 'type_text_at':
    case 'type': {
      if (args.x !== undefined && args.y !== undefined) {
        await mouse.setPosition({
          x: denormalizeX(args.x, width),
          y: denormalizeY(args.y, height),
        });
        await mouse.click(Button.LEFT);
      }
      await keyboard.type(args.text);
      if (args.press_enter) await keyboard.pressKey(Key.Enter);
      break;
    }
    case 'navigate':
      // For desktop: open browser to URL
      await openUrlInBrowser(args.url);
      break;
    case 'go_back':
    case 'go_forward':
      // Browser-only; route to Playwright handler
      break;
    case 'wait':
      await new Promise(r => setTimeout(r, (args.seconds || 1) * 1000));
      break;
    default:
      console.warn(`Unhandled function: ${name}`);
  }
}
```

The official JavaScript example confirms the action names (`click_at`, `type_text_at`, `navigate`, `go_back`, `go_forward`, `wait`) and the denormalization pattern.

### 4.6 Browser Action Execution with Playwright

For `environment: "browser"`, use Playwright:

```javascript
// browser-executor.js
import { chromium } from 'playwright';

const browser = await chromium.launch({ headless: false });
const context = await browser.newContext({
  viewport: { width: 1440, height: 900 },
});
const page = await context.newPage();
```

The official example uses Playwright with `SCREEN_WIDTH = 1440` and `SCREEN_HEIGHT = 900`, and configures the browser context with those dimensions.

### 4.7 Screenshot Capture

For desktop, capture the full screen before each Computer Use step:

```javascript
import screenshot from 'screenshot-desktop';

async function captureDesktopScreenshot() {
  const imgBuffer = await screenshot({ format: 'png' });
  return imgBuffer.toString('base64');
}
```

For browser, use Playwright's `page.screenshot({ type: 'png' })`.

---

## 5. Safety Architecture

### 5.1 Mandatory Voice Confirmation (HITL)

The system prompt **must** implement the Gemini-recommended safety rules. The core rule is **RULE 1: Seek User Confirmation (USER_CONFIRMATION)** — the first and most important check. If the next action falls into any consequential category, the agent **MUST stop immediately and seek the user's explicit permission**.

**Procedure for seeking confirmation:** Perform all preparatory steps (navigating, filling forms, typing a message). Ask for confirmation **AFTER** all necessary information is entered, but **BEFORE** the final, irreversible action (before clicking "Send", "Submit", "Confirm Purchase", "Share").

**USER_CONFIRMATION categories** (from the official documentation):

| Category | Examples | Voice Confirmation Prompt |
|---|---|---|
| **Consent & Agreements** | ToS, Privacy Policies, Cookie banners, EULAs | "This requires accepting the terms of service. Should I proceed?" |
| **Robot Detection** | CAPTCHAs, human-verification | "There's a CAPTCHA. I can't solve it — please take over." |
| **Financial Transactions** | Purchases, transfers, payments, gambling | "You're about to purchase X for $Y. Confirm?" |
| **Sending Communications** | Emails, social media posts, chat messages | "Ready to send this email to X. Should I send it?" |
| **Sensitive Information** | Health, financial, government records; SSN, credit card | "This involves your financial records. Confirm access?" |
| **User Data Management** | Downloading files, sharing data with third parties | "This will download a file from the web. Proceed?" |
| **Browser Data** | History, bookmarks, autofill, saved passwords | "This accesses your saved passwords. Confirm?" |
| **Security & Identity** | Logging into accounts, impersonation | "This will log into your account. Confirm?" |

### 5.2 System Instruction (JavaScript)

```javascript
const SAFETY_SYSTEM_INSTRUCTION = `
## RULE 1: Seek User Confirmation (USER_CONFIRMATION)
This is your first and most important check. If the next required action falls
into any of the following categories, you MUST stop immediately, and seek the
user's explicit permission.

Procedure for Seeking Confirmation:
- For Consequential Actions: Perform all preparatory steps (navigating, filling
  out forms, typing a message). Ask for confirmation AFTER all necessary
  information is entered on the screen, but BEFORE the final, irreversible
  action (before clicking "Send", "Submit", "Confirm Purchase", "Share").
- For Prohibited Actions: If the action is strictly forbidden (accepting legal
  terms, solving a CAPTCHA), inform the user and ask for confirmation to proceed.

USER_CONFIRMATION Categories:
- Consent and Agreements: ToS, Privacy Policies, Cookie banners, EULAs
- Robot Detection: CAPTCHAs, anti-robot mechanisms
- Financial Transactions: Purchases, transfers, payments, gambling
- Sending Communications: Emails, messages, social media posts
- Accessing or Modifying Sensitive Information: Health, financial, government
  records; SSN, bank account, credit card numbers
- User Data Management: Downloading/saving files, sharing data with third parties
- Browser Data Usage: History, bookmarks, autofill, saved passwords
- Security and Identity: Logging into accounts, impersonation
- Insurmountable Obstacles: If stuck, ask the user to take over.

## RULE 2: Default Behavior (ACTUATE)
If an action does NOT fall under RULE 1, your default behavior is to ACTUATE.
Proactively perform all necessary steps to move the user's request forward.
Continue to actuate until the task is complete or you encounter RULE 1.

## Final Response Guidelines
Write a final response to the user in these cases:
- User confirmation
- When the task is complete or you have enough information to respond
`;
```

This is the exact pattern from the official JavaScript example.

### 5.3 Handling `safety_decision` in Tool Results

When the model returns a `safety_decision` with `require_confirmation`, your application must prompt the user. If the user confirms, set `safety_acknowledgement` in the `function_result`:

```javascript
if (functionCall.arguments.safety_decision) {
  const decision = await getVoiceConfirmation(
    functionCall.arguments.safety_decision.explanation
  );
  if (decision === 'TERMINATE') break;
  actionResult.safety_acknowledgement = true;
}
```

The official Python example shows this exact pattern: check for `safety_decision`, prompt the user, and include `safety_acknowledgement` inside the action result.

### 5.4 Prompt Injection Detection

Enable `enable_prompt_injection_detection: true` in the Computer Use tool configuration. This **scans screenshot pixels for hidden adversarial instructions** (e.g., "Ignore previous commands") and blocks execution when detected.

Google's Chrome agent uses a **parallel classifier** — the "user alignment critic" — that independently vets proposed actions before execution. For your local assistant, the AssemblyAI tool-call confirmation flow serves a similar role: the agent must speak the intent and wait for "yes" before executing.

### 5.5 Sandboxing (Strongly Recommended)

The official documentation recommends running your agent in a **sandboxed VM or container** to isolate it from your host system and limit its potential impact. A ready-to-use Docker-based sandbox is available in the reference implementation.

For a PC assistant that needs to control the actual desktop, a full sandbox isn't practical. Compensate with:
- **Voice confirmation gates** for every consequential action
- **Screen recording + audit log** of every action
- **Allowlisted applications** that the agent can control
- **Kill switch** — a global hotkey that terminates the Computer Use session immediately

---

## 6. Integrating Computer Use with the Voice Pipeline

### 6.1 Tool Definition

Register Computer Use as a tool the voice agent can invoke:

```javascript
{
  name: 'computer_use',
  description: 'Control the desktop or browser to complete a UI task. ' +
    'Use when the user asks to open apps, click buttons, fill forms, ' +
    'or navigate websites.',
  parameters: {
    type: 'object',
    properties: {
      task: {
        type: 'string',
        description: 'The UI task to perform, e.g. "Open Google Chrome"',
      },
      environment: {
        type: 'string',
        enum: ['desktop', 'browser'],
        default: 'desktop',
      },
    },
    required: ['task'],
  },
}
```

### 6.2 Voice-to-Computer-Use Flow

```
User: "Open Google Chrome"
  ↓
[AssemblyAI STT] → transcript
  ↓
[Gemini LLM] → decides to call tool "computer_use"
  ↓
[Local dispatcher] → starts Computer Use loop
  ↓
[Screenshot desktop] → send to Gemini Computer Use
  ↓
[Gemini] → function_call: click_at (x: 145, y: 892, intent: "Click Chrome taskbar icon")
  ↓
[safety_decision: allowed] → execute with nut.js
  ↓
[New screenshot] → send to Gemini
  ↓
[Gemini] → "Chrome is now open" (task complete)
  ↓
[Tool result] → "Chrome is now open"
  ↓
[AssemblyAI TTS] → speaker: "Chrome is now open."
```

### 6.3 Voice Confirmation for Consequential Actions

```
User: "Send an email to John about the meeting"
  ↓
[Gemini Computer Use] → navigates to Gmail, opens compose, fills recipient,
                        subject, body
  ↓
[Gemini] → safety_decision: require_confirmation
            explanation: "About to click Send on email to John"
  ↓
[Your app] → speaks: "I've drafted an email to John about the meeting.
                       Should I send it?"
  ↓
User: "Yes, send it"
  ↓
[Your app] → sets safety_acknowledgement: true
  ↓
[Gemini] → function_call: click_at (Send button)
  ↓
[Execute] → email sent
```

### 6.4 Dispatch Code

```javascript
// computer-use-dispatch.js
import { runComputerUseTask } from './gemini-computer-use.js';
import { executeDesktopAction } from './desktop-executor.js';
import { executeBrowserAction } from './browser-executor.js';
import { captureDesktopScreenshot } from './screenshot.js';

export async function handleComputerUseTool({ task, environment }) {
  let interaction = await runComputerUseTask(task, environment);
  let maxSteps = 20;

  while (maxSteps-- > 0) {
    const functionCalls = interaction.steps.filter(
      s => s.type === 'function_call'
    );
    if (functionCalls.length === 0) break;

    const results = [];

    for (const fc of functionCalls) {
      // Check safety decision
      if (fc.arguments.safety_decision?.decision === 'require_confirmation') {
        const confirmed = await askUserViaVoice(
          fc.arguments.safety_decision.explanation
        );
        if (!confirmed) {
          return { status: 'cancelled', reason: 'User declined confirmation' };
        }
      }

      // Execute the action
      if (environment === 'desktop') {
        await executeDesktopAction(fc);
      } else {
        await executeBrowserAction(fc, page);
      }

      // Capture new state
      const screenshot = environment === 'desktop'
        ? await captureDesktopScreenshot()
        : await page.screenshot({ type: 'png' }).then(b => b.toString('base64'));

      results.push({
        name: fc.name,
        id: fc.id,
        result: { screenshot },
      });
    }

    // Send results back to Gemini for next step
    interaction = await ai.interactions.create({
      model: 'gemini-3.8-flash',
      previous_interaction_id: interaction.id,
      function_results: results,
      tools: [{ type: 'computer_use', environment }],
    });
  }

  return { status: 'complete' };
}
```

---

## 7. Project Setup with AssemblyAI Skills

### 7.1 Install the AssemblyAI Skill

The AssemblyAI skill gives your AI coding assistant curated instructions and context for the Python and JavaScript SDKs, streaming, voice agents, and audio intelligence. It works with Claude Code, Cursor, Copilot, and 60+ other coding agents via the universal skills CLI.

```bash
npx skills add AssemblyAI/assemblyai-skill --global
```

For Claude Code specifically:

```bash
claude install-skill https://github.com/AssemblyAI/assemblyai-skill
```

### 7.2 Add the AssemblyAI Docs MCP Server

```bash
claude mcp add --transport http --scope user assemblyai-docs \
  https://mcp.assemblyai.com/docs
```

This gives your agent four tools: `search_docs`, `get_pages`, `list_sections`, and `get_api_reference`.

### 7.3 Project Instructions for AI Coding Agents

Add this to your `CLAUDE.md` or `.cursorrules`:

```
Always fetch https://www.assemblyai.com/docs/llms.txt before writing
AssemblyAI code. The API has changed — do not rely on memorized parameter names.
For anything AssemblyAI related, use the assemblyai-docs MCP tools first.
```

This runs on every prompt and catches breaking changes automatically.

---

## 8. Updated Project Structure

```
voice-assistant/
├── server.js                    # Auth + token minting
├── agent.js                     # AssemblyAI WebSocket + tool dispatch
├── wakeword.js                  # Wake word listener
├── llm/
│   └── gateway.js               # LLM Gateway routing (Gemini default)
├── computer-use/
│   ├── gemini-client.js         # @google/genai client
│   ├── desktop-executor.js      # nut.js action execution
│   ├── browser-executor.js      # Playwright action execution
│   ├── screenshot.js            # Desktop + browser screenshot capture
│   ├── safety.js                # Voice confirmation + safety_decision handling
│   └── dispatch.js              # Computer Use loop orchestration
├── tools/
│   ├── gmail-mcp.js
│   ├── calendar-mcp.js
│   ├── search-mcp.js
│   ├── device-control.js
│   ├── system-monitor.js
│   └── shell-control.js
├── tools.js                     # Unified tool definitions + dispatcher
├── tokens.json                  # Google OAuth tokens (gitignore)
├── tool-audit.log               # Audit log
└── .env                         # API keys, client IDs, secrets
```

---

## 9. Environment Variables

| Variable | Required | Source | Notes |
|---|---|---|---|
| `ASSEMBLYAI_API_KEY` | Yes | AssemblyAI Dashboard | Server-side only |
| `AGENT_ID` | Yes | Agents REST API | Stored agent with Gateway LLM + tools |
| `GEMINI_API_KEY` | BYOK | Google AI Studio | User-supplied; write-only on agent object |
| `GOOGLE_CLIENT_ID` | Yes | Google Cloud Console | OAuth 2.0 Desktop app |
| `GOOGLE_CLIENT_SECRET` | Yes | Google Cloud Console | OAuth 2.0 Desktop app |
| `GOOGLE_SEARCH_API_KEY` | Optional | Google Cloud Console | Custom Search API |
| `GOOGLE_SEARCH_CX` | Optional | Programmable Search Engine | Search Engine ID |
| `PICOVOICE_ACCESS_KEY` | Optional | Picovoice | For Porcupine wake word |

---

## 10. Key Improvements Summary

| Area | Original | With Gemini + Computer Use |
|---|---|---|
| **LLM default** | Unspecified | Gemini 3.8 Flash via LLM Gateway |
| **Fallback chain** | Manual retry | Claude → Gemini → GPT automatic |
| **Desktop control** | nut.js coordinates only | Vision-guided: screenshot → decide → act |
| **Browser control** | Playwright selectors | Playwright + Computer Use vision |
| **Safety** | Prompt-based confirmation | Gemini `safety_decision` + voice confirmation gates |
| **Prompt injection** | Not addressed | `enable_prompt_injection_detection: true` |
| **Environment awareness** | Single environment | Desktop + browser environments |
| **Task completion** | Explicit tool calls | Continuous loop until task done |
| **Reasoning transparency** | None | `intent` field explains each action |

---

## 11. Pricing

| Component | Cost |
|---|---|
| **AssemblyAI Voice Agent API** | $4.50/hr flat ($0.075/min) — all-inclusive |
| **Gemini 3.x Flash** | Input $1.25/M tokens; output $10.00/M tokens |
| **Gemini 2.5 Computer Use (legacy)** | Input $1.25/M tokens; output $10.00/M tokens |

With BYOK, the Gemini API cost is billed separately on top of the AssemblyAI flat rate.

---

## 12. Summary

This architecture delivers a **voice-first PC assistant** with:

- **Gemini as the default LLM**, routed through AssemblyAI's LLM Gateway with automatic fallback to Claude and GPT
- **Gemini Computer Use** for vision-guided desktop and browser automation — *"Open Google Chrome"* triggers a screenshot → click loop
- **Voice confirmation gates** for every consequential action, implementing the official Gemini `USER_CONFIRMATION` categories
- **Prompt injection detection** enabled via screenshot scanning
- **BYOK everywhere** — users bring their own Gemini, AssemblyAI, and Google OAuth credentials
- **AssemblyAI skills and MCP docs** for AI-assisted development

The assistant transforms from a conversational agent into a **full PC control surface** — one that sees the screen, reasons about UI elements, and acts through the mouse and keyboard, all while keeping the user in the loop for anything consequential.

---

**References:** Gemini Computer Use documentation; Computer Use JavaScript examples; Safety best practices; AssemblyAI Voice Agent API; LLM Gateway with fallback; AssemblyAI skill installation.
