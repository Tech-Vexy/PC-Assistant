# Agent Development Notes

## Build Commands

### Initial Setup
```bash
npm install
```

### Server & Configuration Setup
```bash
# Start the server
npm start

# In a browser, visit http://localhost:3000/setup to configure keys and settings
# (AssemblyAI key, OpenRouter LLM key, Gemini API key for computer use)
```

### Agent Creation
```bash
# Create the AssemblyAI agent with your tools and BYOK configuration
# (OpenRouter + openrouter/free by default — just LLM_API_KEY;
#  OPENAI_API_KEY/OPENAI_BASE_URL still work as fallback;
#  local Ollama/LM Studio needs only LLM_BASE_URL, no key)
npm run publish  # alias of npm run setup-agent
```

### Computer Use (Gemini vision automation, on by default)

The `computer_use` tool drives the real UI through a Gemini Computer Use loop
(screenshot → function_call → execute → verify). Setup:

1. Set `GEMINI_API_KEY` at `/setup` — that is the only step. The tool is
   already enabled and the model defaults to `GEMINI_VISION_MODEL`.
2. `npm run sign-manifest && npm run publish` so the stored agent knows the tool.
3. Say things like "Open Google Chrome" — consequential actions pause in
   `http://localhost:3000/api/confirm` and the outcome is spoken back.

Tuning: `COMPUTER_USE_ENVIRONMENT` (desktop|browser), `COMPUTER_USE_MAX_STEPS`,
`COMPUTER_USE_STEP_TIMEOUT_MS`, `GEMINI_VISION_MODEL`. The loop is serialized
(one task at a time), step-capped, and every action is audited.
Safety policy lives in `computer-use/safety.js`; the browser executor lazily
launches Playwright Chromium per task and closes it afterwards.

### Memory (Phase 1: preferences, locations, workflows)

- Semantic memory (`remember`/`recall`/`forget`/`resolve_location`) and
  procedural workflows (`save`/`list`/`run`/`delete_workflow`) live in DuckDB
  (`memories`, `workflows` tables) — see `tools/memory.js`, `lib/store.js`.
- `run_workflow` is confirmation-gated and executes steps through the real
  dispatcher (pass `dispatchTool` in — never import `tools.js` from tool
  modules, to avoid an import cycle).
- The agent process reaches memory over `/api/store/memory` and
  `/api/store/workflows` (same header gate as other delegation endpoints).

### Planner (Phase 3: plan → execute → verify → recover)

- `plan_task` decomposes goals (LLM via `lib/llm.js`, or explicit `steps`
  for programmatic use/tests); steps are validated against the live registry
  at plan time. Memory hits are injected as planner context.
- `execute_plan` runs steps through the real dispatcher (pass `dispatchTool`
  in, same anti-cycle pattern as workflows), with per-step `verify`
  checks, checkpoints after every step (`plans` table), one retry for
  transient failures, and resume-on-rerun. Only `execute_plan` is
  confirmation-gated.
- Plans reach the agent process over `/api/store/plans`; progress is visible
  at `/tasks` (and `/api/tasks` JSON).

### Undo / Transaction Layer

Every mutating tool action gets a reversal record in the DuckDB `undo_journal`
(see `lib/undo.js`, wired centrally in `tools.js` dispatchTool):

- **Automatic reversibility**: `file_organize` (moves + created category dirs
  + overwritten destinations), `file_rename`, `file_convert` (created output),
  `remember`/`forget` (previous value + category), `save_workflow`/
  `delete_workflow` (previous steps). "Undo what you just did" works end to end.
- **Manual reversibility**: `run_command`, `terminal_*`, `computer_use`,
  `kill_process` — before-state is journaled, but a human decides how to
  reverse; the agents only surface what changed.
- Tools: `undo_last` (newest pending record; manual records are reported, never
  auto-applied), `undo_session` (rolls back everything automatically-reversible
  from one voice session, newest first — rows are tagged via
  `AGENT_SESSION_ID` set in agent.js), `list_undo` (read-only).
- `undo_last`/`undo_session` are confirmation-gated (DANGEROUS_TOOLS).
- The agent process journals through `/api/store/undo*` remote routes, same
  header gate as other store delegation.
- Tests: `tests/undo.test.js` (isolated store + temp workspace root).

### Sub-agents (Phase 4: hybrid, deny-by-default, fully dynamic)

- `spawn_agent` takes `{role, instructions, allowed_tools[], isolation,
  max_steps, timeoutMs, waitMs}`; no built-in presets. Unknown tools and
  `spawn_agent` itself are rejected at spawn time (no recursive front-door).
- `resolveIsolation()`: `auto` routes to `spawned` when the allowlist hits a
  high-risk tool, else `shared`. Shared runs `runAgentLoop` inline;
  spawned launches `scripts/agent-worker.js` (remote store, real dispatch)
  and the parent polls the `agents` table.
- Limits: 10 active, depth 3, 4 parallel (`Promise.allSettled` fan-out).
  `list_agents`/`agent_status`/`cancel_agent`/`send_to_agent` round out the
  lifecycle; `/tasks` shows agents next to plans. Tests: `tests/agents.test.js`
  (scripted llmFn, never network).

### Terminal (Phase 2: native execute + interactive sessions)

- One-shot `terminal_execute` shares the `run_command` allowlist (plus `cwd`,
  `timeoutMs`); both are confirmation-gated.
- `terminal_start` spawns a background session (max 10, 200KB output buffer,
  10-min idle expiry) approved once; `read`/`input`/`kill` are session-scoped.
- Same allowlist + no-shell execution as `run_command`; on Windows real
  binaries spawn directly and only builtins/batch files route through `cmd`
  (`resolveWindowsTarget` in `tools/shell-control.js`).
- Tests live in `tests/terminal.test.js` (uses `node` itself as the fixture
  binary; `__clearSessions()` in `after()` for hygiene).

### Running the Assistant
```bash
# One command: bootstraps .env, starts server, guides setup,
# auto-publishes the agent, starts voice (add `-- --wakeword` to idle)
npm run up

# Or separate terminals:
# Terminal 1: Start auth server
npm start

# Terminal 2: Start voice agent
npm run agent

# Terminal 3: Start wake word detection (optional)
npm run wakeword
```

## Verification Steps

### 1. Test Auth Server
```bash
curl http://localhost:3000/health
```

Expected response: `{"status":"ok","timestamp":"..."}`

### 2. Test Token Minting
```bash
curl http://localhost:3000/api/voice-token
```

Expected response: `{"token":"..."}`

### 3. Test Configuration & Health
Visit `http://localhost:3000/setup` to ensure keys are saved, and check `http://localhost:3000/health`.

### 4. Test Tool Handlers
```bash
# Test system status (safe, read-only)
curl -X POST http://localhost:3000/test-tool -d '{"tool":"system_status","args":{}}'
```

### Storage
- Runtime state (config, OAuth tokens, sessions, audits) lives in DuckDB at
  `data/assistant.db` — see `lib/store.js`. The server is the sole writer;
  the agent uses remote mode over `/api/store/*`.
- Tests must set `STORE_PATH` to a tmp file (see `tests/store.test.js`) so the
  real database is never touched. Legacy files (`.env` values, `tokens.json`,
  `.session-state.json`, `*-audit.log`) are migrated once on first boot.

## Known Issues

### Audio Capture & Voice Agent Protocol
- **Transport**: AssemblyAI Voice Agent operates over a full-duplex WebSocket (`wss://agents.assemblyai.com/v1/ws`).
- **Sample Rate**: Native 24 kHz 16-bit mono PCM (`s16le`) for both input capture (`input.audio`) and server reply streaming (`reply.audio`).
- **Streaming Playback**: Reply audio chunks are piped directly to an active `ffplay -f s16le -ar 24000 -ac 1 -nodisp -` stdin process, avoiding per-chunk process spawn overhead and audio stutter.
- **Protocol Events**:
  - `reply.started`: Initializes streaming audio playback for the turn.
  - `reply.audio`: Streams base64-encoded PCM16 audio chunks.
  - `transcript.agent.delta`: Streams assistant's live words to stdout.
  - `reply.done`: Flushes stdin on `completed` or halts playback immediately on `interrupted` (barge-in).
- FFmpeg device names vary by platform and microphone:
  - Windows: Use `ffmpeg -f dshow -list_devices true -i dummy` to find your device (resolved automatically by default).
  - macOS: `avfoundation` input device.

### Wake Word Detection
- Energy-VAD fallback triggers on any loud sound, not a specific keyword
- Real keyword spotting needs openWakeWord (`pip install openwakeword`) or Sherpa-ONNX setup
- Each engine has different setup requirements

### MCP Server Integration
- The MCP stdio client is implemented (lib/mcp-client.js) and tried first
- On any failure it falls back to the direct Google SDK handlers in tools/*
- MCP server commands are configurable via MCP_*_CMD / MCP_*_ARGS env vars

## Troubleshooting

### AssemblyAI Connection Issues
- Verify API key is valid
- Check that agent_id matches your stored agent
- Ensure temporary token minting works


### Tool Execution Failures
- Check `tool-audit.log` for detailed errors
- Verify argument validation rules
- Ensure rate limiting isn't blocking requests
- Dangerous tools need approval: open http://localhost:3000/api/confirm or set AUTO_APPROVE=true for dev
- `run_command` blocks shell chaining (`;`, `&&`, pipes, backticks, `$()`, redirects) — single commands only
- `open_application` is gated behind dangerous approval queue for safety

### Conversational Polish & Desktop Suite
- **VAD & Echo Ducking**: Audio frames pass through `VoiceActivityDetector` (`lib/vad.js`). Microphone frames are ducked during TTS playback to prevent the assistant from hearing its own voice or triggering false self-interruption.
- **Barge-In Interruption**: While playback is active, sustained loud user speech (>400ms after onset, multiple frames above `BARGE_IN_THRESHOLD`, default 8000; set to 0 to disable) terminates `ffplay` immediately.
- **Audio Earcons**: Zero-dependency sine-wave synthesized PCM16 chimes are emitted on listening (`session.ready`), action completion, confirmation prompts, and interruption.
- **Desktop Tools**: `open_application`, `manage_windows`, `media_control`, and `clipboard` are integrated directly into the AssemblyAI Voice Agent tool registry.

## Security Notes

- Never commit `tokens.json` or `.env` files
- Use restrictive file permissions for sensitive files
- Monitor `tool-audit.log` for suspicious activity
- Keep FFmpeg and dependencies updated
- Review and update allowlists regularly