# PC Personal Voice Assistant

**Repository:** [github.com/Tech-Vexy/PC-Assistant](https://github.com/Tech-Vexy/PC-Assistant)

A local-first, voice-driven assistant for your PC that is both a **knowledge source** and a **hands-free computer controller**. Ask it to explain something ("Tell me about Transformer model architecture"), to look something up ("What's the latest on X?"), or to actually *do* things on your machine ("Open Control Panel", "organize my Downloads folder", "check my email in the browser") — it talks back through your speakers.

Everything runs on your PC: the auth/token server binds to `127.0.0.1` only, API keys stay in your local store, and there is no deployment step — no Docker, no hosting. The only cloud services are the APIs themselves (AssemblyAI voice, your chosen LLM, Gemini for vision/search).

---

## What you can say

| You say | What happens |
|---|---|
| "Tell me about Transformer model architecture" | Answered directly from model knowledge — structured explanation, no tools fired |
| "What's the current price of the Framework 16?" | `web_search` first (time-sensitive → live results with sources), then a spoken summary |
| "Open Control Panel" | Launched by real name from the agent's knowledge of your installed apps |
| "Open my Tafiti project and start the dev server" | `plan_task` decomposes → `execute_plan` runs each step with verification + checkpoints |
| "Organize my Downloads folder" | `file_organize` sorts files into category folders (reversible via `undo_last`) |
| "Remember my editor is VS Code" | `remember` — later "open the project in my editor" just works |
| "Every morning prepare my workspace" | `save_workflow` once, then `run_workflow` on demand |
| "Mute, next track, read my clipboard" | Media + volume + clipboard in one sentence |
| "Read the error on my screen and fix it" | Looks first (`screen_context`), acts with Gemini Computer Use starting from what it saw, then re-checks the screen and reports |

## Features

- **Voice-first interaction** over AssemblyAI's single WebSocket (STT → LLM → TTS → tool calling)
- **Knowledge + search**: answers conceptual questions from its own knowledge; goes to `web_search` (Google Search Grounding) when information could be time-sensitive
- **Knows your machine**: at publish time the agent is told your OS and your **installed applications**, so it launches real apps instead of guessing
- **Vision-guided UI automation** via Gemini Computer Use: screenshot → decide → act → verify loops on the real desktop or in a Chromium browser, with confirmation gates on consequential actions
- **Screen awareness**: a recorder-grade ffmpeg feed keeps a few seconds of frames in memory, and `screen_context` reads them with Gemini multimodal vision — the agent looks before it acts on anything visible and chains what it saw into `computer_use` tasks
- **Planner & executor**: multi-step goals become verified, checkpointed, resumable plans; recurring routines become saved workflows
- **Memory**: preferences, project locations, and facts persist in a local DuckDB store
- **Undo layer**: file moves/renames, memories, workflows — automatically reversible; shell/computer-use actions journaled for human review
- **Sub-agents**: spawn scoped specialists (deny-by-default tool allowlists, budgets, isolation)
- **Real-time barge-in**: start talking and it stops listening to itself; synthesized earcons for listening/success/attention states
- **On-device wake word** with openWakeWord → Sherpa-ONNX → energy-VAD fallback chain
- **Layered security**: confirmation queues, allowlists, veto lists, prompt-injection detection, audit trails, signed tool manifest

## Quick start

**Prerequisites**

- Node.js 18+
- [pnpm](https://pnpm.io/) (or npm — the scripts are identical)
- [FFmpeg](https://ffmpeg.org/download.html) on PATH (audio capture + playback)
  - Windows: download a build and add it to PATH; check with `ffmpeg -version`
  - macOS: `brew install ffmpeg` · Linux: `sudo apt install ffmpeg`

**API keys you'll need**

| Key | For | Where |
|---|---|---|
| `ASSEMBLYAI_API_KEY` | Voice pipeline (STT/TTS/tool calls) — required | [assemblyai.com](https://www.assemblyai.com/dashboard/api-key) |
| `LLM_API_KEY` | Voice LLM via OpenRouter (free model by default) — required | [openrouter.ai/keys](https://openrouter.ai/keys) |
| `GEMINI_API_KEY` | Computer Use vision loop + Google Search Grounding — recommended | [aistudio.google.com/apikey](https://aistudio.google.com/apikey) |

**Run it**

```bash
pnpm install
pnpm run up
```

The launcher does everything: creates `.env` from the template, warns about missing FFmpeg, signs the tool manifest, starts the local server, opens `http://localhost:3000/setup` in your browser if keys are missing, gathers your installed apps, publishes the AssemblyAI agent on first run, then starts listening. **Ctrl+C stops everything.**

Ideas for the first conversation: *"Tell me about how LLM attention works"* · *"What did the latest Chromium release change?"* · *"Open Calculator"*.

<details>
<summary>Running the pieces manually (separate terminals)</summary>

```bash
pnpm start        # local server: tokens, approvals UI, store API  → :3000
pnpm run agent    # voice agent (talk now)
pnpm run wakeword # idle on wake word, spawns the agent on detection
```
</details>

## Configuration

Keys can be set in `.env` or in the browser UI at `http://localhost:3000/setup` (recommended — validation, secrets never echoed back). Precedence: **environment variables > database > defaults**.

```env
# .env — minimal config
ASSEMBLYAI_API_KEY=...   # voice pipeline
LLM_API_KEY=...          # OpenRouter key (base URL + free model are defaults)
GEMINI_API_KEY=...       # Computer Use + Search Grounding
PORT=3000
```

Common tuning knobs (all optional, validated at startup):

| Variable | Default | Purpose |
|---|---|---|
| `FAST_MODEL` / `STRONG_MODEL` | `openrouter/free` | Voice LLM models (any OpenAI-compatible endpoint works via `LLM_BASE_URL`, incl. Ollama/LM Studio) |
| `COMPUTER_USE_MAX_STEPS` / `COMPUTER_USE_STEP_TIMEOUT_MS` | 20 / 30000 | Vision-loop budgets |
| `COMPUTER_USE_ENVIRONMENT` | `desktop` | Default surface: `desktop` or `browser` |
| `COMPUTER_USE_ENABLE_PROMPT_INJECTION_DETECTION` | `true` | Screenshot scanning for adversarial instructions |
| `GEMINI_VISION_MODEL` / `GEMINI_MODEL` | `gemini-3.8-flash` / `gemini-2.5-flash` | Vision loop model / search-grounding model |
| `AUTO_APPROVE` | `false` | Dev-only: skip the approval queue for dangerous tools |
| `BARGE_IN_THRESHOLD` | `8000` | Mic energy threshold for interrupting playback (0 disables) |
| `WAKEWORD_ENGINE` / `WAKEWORD_THRESHOLD` | `auto` / `0.5` | Wake word engine and sensitivity |
| `SCREEN_VERIFY` | `false` | Screenshot-verify device-control actions before execution |
| `SCREEN_WATCHER_FPS` / `SCREEN_WATCHER_BUFFER_S` | `2` / `8` | Screen-awareness feed rate and history window (frames stay in RAM only) |
| `STORE_PATH` | `data/assistant.db` | DuckDB store location |

## The published agent & device context

Your voice sessions bind to a **stored agent** on AssemblyAI (`AGENT_ID` in `.env`). Publishing (`pnpm run publish`) bakes in:

1. **Tool definitions** — the full local tool registry, semantically vetted and covered by a signed integrity manifest.
2. **System prompt** — knowledge-first guidance, the planning workflow, and security rules.
3. **Device context** — your OS facts and **installed application names** (Windows uninstall registry, macOS `/Applications`, Linux `.desktop` files), so app launches use real names. If discovery is unavailable it falls back to the common built-in app list and says so honestly.
4. **LLM routes** — your BYOK provider(s), with optional cross-provider fallbacks via `LLM_FALLBACK_MODELS`.

> **Re-publish whenever** tools, the system prompt, or your installed apps change materially — the prompt is a snapshot, not re-read per session. `pnpm run up` publishes automatically only when `AGENT_ID` is missing; to adopt an updated agent, put its printed `AGENT_ID` into `.env` (or set it at `/setup`).

## Approvals, audit, and control surfaces

- **Dangerous tools** (shell, device control, app launches, sending communications, computer use, plan execution, undo) pause until you approve them at `http://localhost:3000/api/confirm` or on the **dashboard's Pending Approvals panel** — a live queue shared by every process. `AUTO_APPROVE=true` skips it, for development only.
- **Every tool call and security event** is written to the DuckDB audit tables:

  ```bash
  node -e "import('./lib/store.js').then(async (s) => { await s.initStore(); console.table(await s.recentToolAudits(10)); await s.closeStore(); process.exit(0); })"
  ```

- **`http://localhost:3000/tasks`** shows plans and sub-agents with per-step results.
- **`http://localhost:3000/api/metrics`** exposes tool timings and success rates.
- **`POST /test-tool`** dispatches a single tool by hand (dangerous ones still queue for approval).

### Live monitoring

The agent process streams events (state, transcripts, tool calls/results, audio levels, approval requests/resolutions) to the server over a batched relay, and any subscriber watches them in real time:

- **`http://localhost:3000/dashboard`** — web dashboard: live conversation, tool calls with status, audio visualizer, and one-click Approve/Deny for pending confirmations.
- **`GET /api/events`** — the raw SSE stream for anything else you want to build on top.

Approval events carry the real pending-approval id, so a decision made in one surface (dashboard, `/api/confirm`, terminal) resolves everywhere at once.

## Tools reference

| Tool | Description | Safety |
|---|---|---|
| `web_search` | Live Google Search Grounding (Gemini key) or Custom Search if configured | Read-only |
| `list_installed_apps` | Inventory installed applications | Read-only |
| `open_application` | Launch an installed app by name (with aliases) | Confirmation gate |
| `manage_windows` | Minimize/restore all, focus or close a window | Confirmation gate |
| `media_control` | Volume, mute (absolute state, not blind toggle), play/pause, skip | Safe |
| `clipboard` | Read or write clipboard | Safe |
| `move_mouse` / `click_mouse` | Cursor movement and clicks | Screenshot verify |
| `type_text` / `press_keys` | Typing and shortcuts | Screenshot verify |
| `system_status` | CPU/memory/disk/network | Read-only |
| `list_processes` / `kill_process` | Process listing / termination | Read-only / protected-PID guard |
| `run_command` | Allowlisted shell command (no chaining) | Confirmation gate |
| `terminal_execute` / `terminal_start` / `terminal_read` / `terminal_input` / `terminal_kill` | One-shot + interactive background terminal sessions | Confirmation gate / session-scoped |
| `file_organize` / `file_rename` / `file_find` / `file_convert` | Folder organization, templated renames, search, document conversion (LibreOffice) | Confirmation gate; first two auto-reversible |
| `screen_context` | Look at the screen right now: active window, apps, on-screen text (Gemini multimodal) | Read-only |
| `computer_use` | Vision-guided desktop/browser automation loop; accepts a context hint from `screen_context` | Per-action gates + veto list + injection detection |
| `remember` / `recall` / `forget` / `resolve_location` | Semantic memory for preferences, locations, projects | Validated, audited |
| `save_workflow` / `list_workflows` / `run_workflow` / `delete_workflow` | Reusable multi-step routines | Validated; run gated |
| `plan_task` / `execute_plan` / `plan_status` / `list_plans` / `cancel_plan` | Goal → verified, checkpointed, resumable plan execution | Gated; planning is side-effect free |
| `spawn_agent` / `list_agents` / `agent_status` / `cancel_agent` / `send_to_agent` | Scoped sub-agents with budgets and isolation | Gated |
| `undo_last` / `undo_session` / `list_undo` | Reverse journaled actions (auto-reversible ones applied; manual ones surfaced) | Gated |

## Planning, workflows, memory, undo

- **Plans** — *"Open the Tafiti project and start the dev server"* → `plan_task` decomposes the goal (grounded in remembered context), `execute_plan` runs it with per-step verification, a checkpoint after every step, one retry for transient failures (timeouts, 429/503), and resume-on-rerun. Watch it at `/tasks`.
- **Workflows** — recurring routines saved once, replayed through the same per-step gates.
- **Memory** — *"Remember that my Tafiti project lives at C:\Projects\tafiti"*; later *"Open Tafiti"* resolves through memory instead of asking again.
- **Undo** — *"Undo that"* reverses the last auto-reversible action (file moves/renames, memory/workflow edits, created files). Shell commands and computer-use actions are journaled but only a human reverses those — `list_undo` shows exactly what changed.

## Google services (Gmail, Calendar)

Direct Google OAuth is **disabled** in this build; Gmail/Calendar tools return guidance instead. The agent handles email and calendar through the **browser**: it uses `computer_use` (environment `browser`) to open Gmail or Google Calendar, compose, and click through — with the standard confirmation gates before anything is sent. No Google Cloud project, OAuth client, or token files are needed.

## Architecture

```
[Microphone] → [Wake Word Engine] → [Audio Capture PCM16 24kHz]
    → [WebSocket: wss://agents.assemblyai.com/v1/ws?token=...]
    → [AssemblyAI: STT → LLM (your BYOK routes) → tool call? → TTS]
    → [tool.call] → [Local dispatcher: validation → approval gate → audit → undo journal]
         → handler (native tool, or Gemini Computer Use loop for UI tasks)
    → [tool.result] → [AssemblyAI TTS] → [Speaker, barge-in aware]
```

The voice agent process and the local server are separate: **the server is the sole writer** of the DuckDB store (`data/assistant.db` — config, tokens, sessions, memories, workflows, plans, agents, undo journal, audit trails); the agent reaches it over localhost HTTP. Config precedence is env > DB > defaults, and legacy files (`tokens.json`, `.session-state.json`, audit logs) are migrated once and never written again.

For the full design — Computer Use loops, safety policies, LLM routing — see [ARCHITECTURE.md](ARCHITECTURE.md).

## Security

- **Human in the loop**: confirmation queue for every consequential action; the voice agent describes what it's about to do and relays outcomes.
- **Computer Use safety**: official RULE 1/2 (USER_CONFIRMATION / ACTUATE) system instruction; model `safety_decision` honored (`require_confirmation` → approval queue, blocked → halt); an independent local veto list (credential stores, destructive commands, injection phrasing); `enable_prompt_injection_detection: true`; hard caps on steps, per-step timeout, wall clock, and concurrency.
- **Shell safety**: strict allowlist, no chaining/pipes/redirection, protected process guards on kill/close.
- **Auth hardening**: 5-minute temporary voice tokens, header-gated internal store API, unpredictable approval IDs, CSRF-checked callbacks, cross-origin approval POSTs rejected.
- **Integrity**: tool descriptors are semantically vetted and covered by a signed manifest verified at server startup.
- **Screen privacy**: awareness frames live only in a short in-memory ring buffer (~8 s) that idles down when unused — nothing is written to disk, and frames go only to your configured Gemini key for description.
- **At rest**: the store is plaintext on disk — OS disk encryption (BitLocker/FileVault) is the at-rest story; `.env` and tokens are gitignored with restrictive permissions.

## Troubleshooting

**"FFmpeg not on PATH" at startup** — install FFmpeg (see Quick start) or install the audio features later; the server still boots for setup.

**The agent launches the wrong app / can't find one** — say "list my installed apps"; if the app is missing from the list, re-publish (`pnpm run publish` + update `AGENT_ID`) so device context refreshes. `open_application` knows common aliases ("control panel" → `control`).

**Computer Use errors with a 400 about `enable_prompt_injection_detection`** — you're on an old `@google/genai` interaction shape; update dependencies (`pnpm install`) so the snake_case interactions API is used.

**Voice doesn't capture** — test your mic: `ffmpeg -f dshow -list_devices true -i dummy` (Windows; macOS uses avfoundation, Linux ALSA), or set `AUDIO_DEVICE`.

**Dangerous tool seems stuck** — approve it at `http://localhost:3000/api/confirm` (or set `AUTO_APPROVE=true` for dev). Check the audit trail if unsure what ran.

**AssemblyAI connection issues** — verify `ASSEMBLYAI_API_KEY`, that `AGENT_ID` matches a published agent, and that `http://localhost:3000/api/voice-token` returns a token while the server runs.

**Store locked / config not saving** — DuckDB allows one writer: make sure only one server process runs; the agent intentionally never opens the DB file.

## Billing notes

- **AssemblyAI Voice Agent API**: $4.50/hr flat (STT, LLM turn-taking, TTS, tool calling included). Sessions get a 30-second reconnect grace window; explicit `session.end` is sent on shutdown to avoid idle charges.
- **LLM + Gemini vision** are billed by your providers (BYOK). The default OpenRouter route can be a free model; Computer Use and Search Grounding use your Gemini key.

## Development

```
pc_assistant/
├── server.js               # Local server: tokens, approvals, store API, setup UI
├── agent.js                # Voice agent: WebSocket, audio, VAD/barge-in, dispatch
├── wakeword.js             # Wake word supervisor (openWakeWord → sherpa → energy)
├── setup-agent.js          # Publishes the stored agent (tools + prompt + device context)
├── tools.js                # Unified tool definitions + security-checked dispatcher
├── security.js             # Dangerous-tool gates, argument validation, rate limits
├── lib/
│   ├── store.js            # DuckDB store (config, sessions, memory, plans, audit, undo)
│   ├── device-context.js   # OS + installed-apps inventory for the agent prompt
│   ├── event-emitter.js    # Event bus + cross-process relay feeding the SSE stream
│   ├── model-router.js     # BYOK LLM routes, fast/strong routing, fallback chain
│   ├── security-extras.js  # Manifest signing, semantic vetting, approval plumbing
│   ├── screen-watcher.js   # ffmpeg gdigrab frame feed + Gemini multimodal describeScreen
│   ├── undo.js / fs-safety.js / vad.js / sound-effects.js / monitor.js / …
├── tools/                  # Handlers: desktop suite, files, system, shell, terminal,
│                           #   memory, plan, agents, search, screen context
├── computer-use/           # Gemini Computer Use: client, loop, executors, safety
├── public/dashboard.html   # Web monitoring dashboard (live SSE client)
├── scripts/                # launch.js (`up`), setup, tray, Windows service scripts
└── tests/                  # 20 suites, 170+ tests (node --test)
```

**Everyday commands**

```bash
pnpm test              # full suite
pnpm run sign-manifest # re-sign after tool definition changes
pnpm run vet-tools     # semantic vetting of tool descriptors
pnpm run publish       # (re)publish the stored agent
pnpm run check-ffmpeg  # list audio devices, test 2s capture
```

**Run as a background app (Windows)**

```powershell
powershell -ExecutionPolicy Bypass -File scripts\install-service.ps1   # logon task + startup shortcut
pnpm run tray                                                          # console status monitor
powershell -ExecutionPolicy Bypass -File scripts\uninstall-service.ps1 # remove
```

(A logon task is used rather than a Windows service because services run in Session 0, where mouse/keyboard control doesn't work.)

**Adding a tool** — create the handler in `tools/`, register the definition + handler in `tools.js`, add validation in `security.js` if needed, then `pnpm run sign-manifest` and `pnpm run publish`. The device context, vetting, and manifest all flow from `tools.js`.

## License

MIT

## References

- [AssemblyAI Voice Agent API](https://www.assemblyai.com/docs/voice-agent/api) · [BYOM/BYOK guide](https://www.assemblyai.com/docs/voice-agent/guides/connect-your-own-llm)
- [Gemini Computer Use documentation](https://ai.google.dev/gemini-api/docs/computer-use)
- [OpenRouter](https://openrouter.ai/docs) (default LLM router) · [Google Custom Search API](https://developers.google.com/custom-search/v1/overview)
- [nut.js desktop automation](https://nutjs.dev/) · [Playwright](https://playwright.dev/) · [DuckDB Node API](https://duckdb.org/docs/stable/api/nodejs/reference)
- [openWakeWord](https://github.com/dscripka/openWakeWord) · [Sherpa-ONNX](https://github.com/k2-fsa/sherpa-onnx)
