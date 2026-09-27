# PC Personal Voice Assistant

A production-grade PC-native personal voice assistant that enables hands-free interaction with Gmail, Google Calendar, web search, and direct device manipulation using AssemblyAI's Voice Agent API and MCP servers.

**Local-first: everything runs on your PC.** The Node.js auth/token server binds to `127.0.0.1` only, API keys stay in your local store, and there is no deployment step — no Docker, no hosting, no cloud services besides the APIs themselves (AssemblyAI, Google).

## Storage (DuckDB)

All runtime state lives in a single DuckDB file, `data/assistant.db` (gitignored, override with `STORE_PATH`):

| Table | Replaces | Contents |
|---|---|---|
| `config` | `.env` (runtime) | API keys, provider URLs, models, timeouts, safety flags |
| `oauth_tokens` | `tokens.json` | Google access + refresh tokens |
| `sessions` | `.session-state.json` | Voice session ID + last transcript |
| `tool_audit` / `security_audit` | `tool-audit.log` / `security-audit.log` | Every tool call + security event, queryable |

Config precedence: **environment variables > database > built-in defaults**, so shell-exported vars and tests keep working. First boot migrates legacy files once (seed-only, fingerprint-guarded so logs are never double-imported); afterwards the old files aren't written — `tokens.json`, `.session-state.json`, and the audit logs can be deleted. `.env` remains as first-run seed plus bootstrap mirror (`PORT`, audio/wake-word settings the processes need before the DB is reachable).

Architecture note: DuckDB allows only one read-write opener per file, so **the server is the sole writer**. The voice-agent process talks to it over localhost HTTP (`/api/store/*`, same header gate as approval delegation) and never opens the file. Still plaintext at rest — OS disk encryption (BitLocker/FileVault) is the at-rest story.

## Features

- **Voice-first interaction** via AssemblyAI's single WebSocket at $4.50/hr
- **Real-time barge-in interruption** that halts assistant TTS playback immediately when you speak
- **Zero-dependency audio earcons** (listening, success, attention, interrupted chimes) synthesized dynamically in pure PCM16
- **Desktop productivity suite** for app launching, window management, media/volume controls, and clipboard manipulation
- **Vision-guided UI automation** via the `computer_use` tool (Gemini Computer Use): the agent screenshots the screen, decides the next mouse/keyboard action, executes it, and verifies the result — for tasks like *"Open Google Chrome"* or filling web forms
- **BYOK flexibility** for custom LLM endpoints
- **Extensible tool layer** via MCP servers (Gmail, Calendar, Search, Device Control)
- **On-device wake word** with no audio leaving the machine until engaged
- **Layered security** addressing MCP tool poisoning, device control risks, and token hardening
- **Local auth service** keeping API keys server-side and minting one-time temporary tokens

## Architecture

```
[Microphone] → [Wake Word Engine] → (detected) → [Audio Capture PCM16 24kHz]
    → [WebSocket: wss://agents.assemblyai.com/v1/ws?token=...]
    → [AssemblyAI: STT → LLM → Tool Call? → TTS]
    → [Tool Call] → [Local Node.js Dispatcher] → [MCP Server] → [External API]
    → [Tool Result] → [WebSocket: tool.result] → [AssemblyAI] → [TTS Audio]
    → [Speaker]
```

> For the comprehensive Version 2.0 design covering Gemini Computer Use, vision-guided desktop/browser automation loops, AssemblyAI LLM Gateway routing, and HITL safety policies, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Prerequisites

- Node.js 18+ 
- FFmpeg (for audio capture and playback)
- AssemblyAI API key
- (Optional) Gemini API key (for Computer Use vision loop & Google Search grounding)

## Installation

1. **Clone the repository and install dependencies:**

```bash
cd pc_assistant
npm install
```

2. **Install FFmpeg:**

- **Windows:** Download from [ffmpeg.org](https://ffmpeg.org/download.html) and add to PATH
- **macOS:** `brew install ffmpeg`
- **Linux:** `sudo apt install ffmpeg` or `sudo yum install ffmpeg`

3. **Start everything with one command:**

```bash
npm run up
```

This bootstraps `.env`, checks prerequisites, signs the tool manifest, starts
the server, opens the browser setup UI if keys are missing, auto-publishes the
AssemblyAI agent when keys exist, then starts the voice agent. Ctrl+C stops
everything. Add `-- --wakeword` to idle on the wake word instead of talking
immediately. (Separate terminals still work: `npm start` + `npm run agent` +
`npm run wakeword`.)

4. **Manual configuration (optional — `npm run up` covers this):**

```bash
cp .env.example .env
```

Edit `.env` with your credentials — by hand, or start the server and open
`http://localhost:3000/setup` for a browser form (provider presets, validation,
secrets never displayed back):

```env
# AssemblyAI (voice pipeline)
ASSEMBLYAI_API_KEY=your_assemblyai_api_key_here

# Voice LLM: OpenRouter + free model by default — just add your key
# (https://openrouter.ai/keys). Base + openrouter/free model are baked in.
LLM_API_KEY=your_openrouter_api_key_here

# Google (Gmail/Calendar)
GOOGLE_CLIENT_ID=your_google_client_id_here
GOOGLE_CLIENT_SECRET=your_google_client_secret_here

# Computer Use vision loop (on by default) needs a Gemini key
# (https://aistudio.google.com/apikey)
# GEMINI_API_KEY=

# Server Configuration
PORT=3000
```

4. **Verify prerequisites and sign the tool manifest:**

```bash
npm run setup        # checks node, ffmpeg, .env, signs tool manifest
npm run check-ffmpeg # lists audio devices, tests 2s capture
npm run setup-gcp    # validates Google OAuth scopes, APIs, stored tokens
```

## Google Cloud Setup

1. **Create a Google Cloud project** and enable the following APIs:
   - Gmail API
   - Google Calendar API
   - (Optional) Custom Search API

2. **Configure OAuth consent screen:**
   - External for testing, Internal for Workspace
   - Add required scopes: `gmail.readonly`, `gmail.send`, `calendar.readonly`, `calendar.events`

3. **Create OAuth 2.0 credentials:**
   - Application type: Desktop application
   - Add `http://localhost:3000/callback` as authorized redirect URI

4. **(Optional) Set up Google Custom Search:**
   - Create a Programmable Search Engine
   - Enable Custom Search API
   - Get API key and Search Engine ID (cx)

## AssemblyAI Agent Setup

1. **Create a stored agent** with your tools and BYOK configuration
   (OpenRouter + free model by default — `npm run up` does this for you):

```bash
npm run publish   # alias of npm run setup-agent
```

Or manually create via REST API (swap in your provider's `base_url`/`model`/`api_key`):

```bash
curl -X POST https://agents.assemblyai.com/v1/agents \
  -H "Authorization: Bearer $ASSEMBLYAI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "PC Personal Assistant",
    "system_prompt": "You are a personal assistant on the user'\''s PC. You can search the web, read/send email, manage calendar, control the desktop (mouse, keyboard, windows), and monitor system health.",
    "voice": { "voice_id": "alba" },
    "llm": [{
      "base_url": "https://openrouter.ai/api/v1",
      "model": "openrouter/free",
      "api_key": "YOUR_OPENROUTER_API_KEY"
    }],
    "tools": [...] // Use the tool definitions from tools.js
  }'
```

2. **Copy the returned `agent_id` to your `.env` file** (or set it at
   `http://localhost:3000/setup`).

   Provider/model changes afterwards need **no re-publish**: the voice agent
   sends the local `LLM_BASE_URL` + `LLM_API_KEY` + `FAST_MODEL`/`STRONG_MODEL`
   as a session override on every connect. Re-publish only when tools, the
   system prompt, or the voice change.

## Usage

### Start the Auth Server

```bash
npm start
```

The server will run on `http://localhost:3000`.

### Authenticate with Google

1. Visit `http://localhost:3000/auth` in your browser
2. Complete the Google OAuth flow
3. Tokens will be saved to `tokens.json`

### Start the Voice Agent

```bash
npm run agent
```

The agent will:
1. Fetch a temporary AssemblyAI token from your local server
2. Connect to the AssemblyAI Voice Agent WebSocket
3. Start listening for voice input
4. Process tool calls through local handlers
5. Play audio responses

### Start Wake Word Detection

```bash
npm run wakeword
```

Engine is auto-selected (`WAKEWORD_ENGINE=auto`): openWakeWord if its Python
package is installed, else Sherpa-ONNX if configured, else an energy-based
voice-activity trigger that needs only FFmpeg. On wake, it spawns the voice
agent and resumes listening when the session ends.

### Approve dangerous tool calls

`send_email`, `create_event`, mouse/keyboard, `kill_process`, and
`run_command` pause until you approve them at
`http://localhost:3000/api/confirm` (auto-refreshing page). The voice agent
process delegates approvals to the server automatically, so calls from either
process show up in the same UI. For development only, set `AUTO_APPROVE=true`
to skip the queue. `POST /test-tool` dispatches a single tool (dangerous ones
still queue for approval).

### Inspect the store

```bash
# Recent tool calls, straight from DuckDB
node -e "import('./lib/store.js').then(async (s) => { await s.initStore(); console.table(await s.recentToolAudits(10)); await s.closeStore(); process.exit(0); })"
```

### Run in the background (Windows)

```powershell
powershell -ExecutionPolicy Bypass -File scripts\install-service.ps1
```

Installs a logon Scheduled Task in your user session (services run isolated in
Session 0, where mouse/keyboard control fails) plus a Startup shortcut.
`npm run tray` shows a console status monitor. Uninstall with
`scripts\uninstall-service.ps1`.

### Tests

```bash
npm test   # 111 tests: security, cache/router, MCP mock server, dispatcher, routes, desktop suite, remote approvals, Computer Use loop & safety gates, memory & workflows, terminal sessions, planner & executor, sub-agents
```

## Available Tools

| Tool | Description | Safety |
|---|---|---|
| `web_search` | Search the web with live Google Search Grounding | Read-only |
| `computer_use` | Vision-guided desktop/browser UI automation (screenshot → decide → act loop) | Per-action confirmation gates + local veto list |
| `open_application` | Launch desktop applications | Confirmation gate |
| `manage_windows` | Minimize, restore, or focus windows | Read-only / Safe |
| `media_control` | Control volume and media playback | Read-only / Safe |
| `clipboard` | Read or write clipboard contents | Read-only / Safe |
| `move_mouse` | Move cursor | Screenshot verify |
| `type_text` | Type at cursor | Screenshot verify |
| `press_keys` | Keyboard shortcut | Allowlist |
| `system_status` | CPU/memory/disk/net | Read-only |
| `list_processes` | List processes | Read-only |
| `kill_process` | Terminate process | Protected PIDs guard |
| `run_command` | Allowlisted command | Strict allowlist |
| `terminal_execute` | Run allowlisted command with cwd + timeout, wait for exit | Confirmation gate |
| `terminal_start` | Start a background session (dev servers, REPLs); approved once | Confirmation gate |
| `terminal_read` | Poll new session output | Session-scoped |
| `terminal_input` | Type into session stdin (covered by start approval) | Session-scoped |
| `terminal_kill` | Terminate a session | Session-scoped |
| `remember` | Store a preference, location, project path, or fact | Validated, audited |
| `recall` | Search stored memories (exact key + substring, category filter) | Read-only |
| `forget` | Delete a stored memory | Validated, audited |
| `resolve_location` | Resolve a project/place alias to its saved path | Read-only |
| `save_workflow` | Save a named multi-step tool sequence (steps validated on save) | Validated, audited |
| `list_workflows` | List workflows with use/success stats | Read-only |
| `run_workflow` | Execute a workflow step by step (per-step gates still apply) | Confirmation gate |
| `delete_workflow` | Delete a saved workflow | Validated, audited |
| `plan_task` | Decompose a goal into an executable plan (LLM or explicit steps) | Validated (side-effect free) |
| `execute_plan` | Run a plan with verification, checkpoints, retry, resume | Confirmation gate |
| `plan_status` | Plan detail with per-step results + checkpoint | Read-only |
| `list_plans` | Recent plans with progress | Read-only |
| `cancel_plan` | Cancel a plan (executor stops at next step) | Validated, audited |
| `spawn_agent` | Spawn a specialist sub-agent (deny-by-default tools, budgets) | Confirmation gate |
| `list_agents` | Sub-agents with status, depth, parent linkage | Read-only |
| `agent_status` | Full agent detail: role, budget, messages, result | Read-only |
| `cancel_agent` | Cancel a sub-agent (stops at next step boundary) | Validated, audited |
| `send_to_agent` | Queue a message for a live sub-agent | Validated, audited |

### Sub-agents

Fully dynamic specialists — no presets. *"Research the Gemini Live API and
summarize Flutter-relevant changes"* → `spawn_agent` with a researcher role
and a browser/search-only allowlist. High-risk toolsets (terminal, computer
use, email) run in an isolated worker process and report back through the
store; safe ones run in-process. Guardrails: max 10 active agents, max depth
3, max 4 parallel, per-agent step + timeout budgets. Watch everything in
`http://localhost:3000/tasks` next to plans.

### Planner & tasks

`plan_task` turns *"Open the Tafiti project and start the dev server"* into
ordered tool calls (grounded with memory context — known locations are used,
not re-asked). `execute_plan` runs them with per-step verification, a
checkpoint after every step, one retry for transient failures, and resume via
re-running `execute_plan`. Watch progress at `http://localhost:3000/tasks`
(auto-refreshing timeline with per-step results).

### Memory & workflows

Teach the assistant once, reuse forever:

- *"Remember that my Tafiti project lives at C:\Projects\tafiti"* → `remember`
  (`project:tafiti`), later *"Open Tafiti"* resolves via `resolve_location`.
- *"Remember my editor is VS Code"* → `recall` finds it before asking again.
- *"Save 'prepare-tafiti' as: open VS Code, then open Chrome"* →
  `save_workflow`, later `run_workflow` replays it with per-step approvals.
- Memories live in the DuckDB `memories` table, workflows in `workflows`
  (with use/success counters for future workflow learning).

## Security Features

### MCP Tool Poisoning Protection
- Tool description sanitization
- Argument validation
- Security event logging
- Rate limiting for dangerous operations

### Device Control Safety
- Confirmation gates for destructive actions
- Protected PID checks
- Strict command allowlist
- Audit logging for all tool calls

### Computer Use Safety (Gemini vision automation)
- Official RULE 1/2 (USER_CONFIRMATION / ACTUATE) system instruction on every request
- Model `safety_decision` honored: `require_confirmation` queues a human approval, `blocked` halts the task
- Independent local veto list (credential stores, destructive commands, prompt-injection phrasing in action intents) enforced even if the model allows the action
- Local always-confirm list (send/purchase/login/download/delete/accept-terms) mapped to the same `/api/confirm` queue
- `enable_prompt_injection_detection: true` — screenshot pixels scanned for hidden adversarial instructions
- Hard caps: max steps, per-step timeout, 5-minute wall-clock limit, one task at a time
- Every action audited to the `tool_audit` store; tasks can be denied at any gate and the voice agent relays the outcome

### Token & Auth Hardening
- Short-lived AssemblyAI temporary tokens (5 minutes)
- Local server keeps permanent API keys secure
- Restricted file permissions for tokens.json
- Session lifecycle management to prevent billing surprises
- OAuth `state` validation on the Google callback (CSRF protection)
- Cross-origin approval POSTs rejected (browsers can't forge custom headers on form posts)
- Unpredictable 128-bit approval IDs, so pending approvals can't be guessed
- Approval requests are only accepted from known internal clients (header-gated), and the decision API is separate from the browser form path
- Tool manifest integrity verified at server startup (`npm run sign-manifest` re-signs after tool changes)

## Security Monitoring

All tool calls are logged to `tool-audit.log` with:
- Timestamp
- Tool name
- Arguments
- Result/error

Security events are logged with severity levels:
- HIGH: Unauthorized access, dangerous operations
- MEDIUM: Tool execution, validation failures
- LOW: Normal operations

## Troubleshooting

### Audio Issues
- Ensure FFmpeg is installed and accessible
- Check microphone device name in `agent.js`
- Test audio capture: `ffmpeg -f dshow -list_devices true -i dummy` (Windows)

### OAuth Issues
- Verify redirect URI matches Google Cloud Console
- Check that tokens.json exists and is valid
- Re-authenticate if tokens expire

### AssemblyAI Issues
- Verify API key is valid
- Check agent_id matches your stored agent
- Ensure temporary token minting works via `/api/voice-token`

### Tool Execution Errors
- Check `tool-audit.log` for detailed error messages
- Verify MCP server credentials are configured
- Ensure required APIs are enabled in Google Cloud

## Billing Considerations

**AssemblyAI Voice Agent API:** $4.50/hr flat ($0.075/min)
- Includes STT, LLM reasoning, TTS, turn detection, tool calling
- Temporary tokens have 30-second grace window after disconnect
- Always send explicit `session.end` to avoid idle charges
- BYOK LLM providers billed separately

## Development

### Project Structure

```
voice-assistant/
├── server.js              # Auth + token minting
├── agent.js               # AssemblyAI WebSocket + tool dispatch + barge-in
├── wakeword.js            # Wake word listener
├── computer-use/          # Gemini Computer Use (vision-guided UI automation)
│   ├── gemini-client.js   # @google/genai Interactions API wrapper
│   ├── dispatch.js        # Screenshot → decide → act loop orchestration
│   ├── desktop-executor.js# nut.js action execution (real desktop)
│   ├── browser-executor.js# Playwright action execution (Chromium)
│   ├── safety.js          # RULE 1/2 instruction, veto/confirm policy, gates
│   ├── screenshot.js      # Desktop + browser screenshot capture
│   └── coordinates.js     # 0-1000 → pixel denormalization
├── lib/
│   ├── sound-effects.js   # Synthesized PCM16 audio earcons/chimes
│   ├── mcp-client.js      # Pool-based stdio MCP JSON-RPC client
│   ├── security-extras.js # Manifest signing & semantic vetting
│   ├── model-router.js    # Fast/strong LLM routing + provider resolution
│   └── store.js           # DuckDB store: config, tokens, sessions, audits
├── tools/
│   ├── desktop-suite.js   # Apps, window management, media, clipboard
│   ├── gmail-mcp.js       # Gmail tool handlers
│   ├── calendar-mcp.js    # Calendar tool handlers
│   ├── search-mcp.js      # Google Search tool handlers
│   ├── device-control.js  # Mouse/keyboard automation
│   ├── system-monitor.js  # CPU, memory, process management
│   └── shell-control.js   # Allowlisted shell commands
├── tools.js               # Unified tool definitions + dispatcher
├── security.js            # Security measures and validation
├── data/assistant.db      # DuckDB store (gitignore; override with STORE_PATH)
└── .env                   # First-run seed + bootstrap mirror (PORT, audio)
```

### Adding New Tools

1. Create handler function in `tools/` directory
2. Add tool definition to `tools.js`
3. Add handler to `allHandlers` mapping
4. Update security validation if needed
5. Re-sign the manifest: `npm run sign-manifest`
6. Recreate AssemblyAI agent with new tools (`npm run setup-agent`)

## License

MIT

## References

- [AssemblyAI Voice Agent WebSocket API](https://www.assemblyai.com/docs/voice-agent/api)
- [Connect Your Own LLM](https://www.assemblyai.com/docs/voice-agent/guides/connect-your-own-llm)
- [Gmail MCP Library](https://github.com/modelcontextprotocol/servers/tree/main/src/gmail)
- [Calendar MCP Server](https://github.com/modelcontextprotocol/servers/tree/main/src/google-calendar)
- [Google Custom Search API](https://developers.google.com/custom-search/v1/overview)
- [nut.js Desktop Automation](https://nutjs.dev/)
- [openWakeWord](https://github.com/dscripes/openWakeWord)
- [Sherpa-ONNX](https://github.com/k2-fsa/sherpa-onnx)