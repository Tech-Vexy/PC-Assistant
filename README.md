# Device Assistant (Flutter Client)

Cross-platform on-device intelligent assistant for **Android** and **Desktop** (Linux / Windows / macOS). Integrates low-latency multimodal speech-to-speech, local encrypted persistence, deep task reasoning, always-on process management, and privacy-shielded automation.

---

## Architecture Overview

```
                                +-----------------------------+
                                |      HomeScreen (UI)        |
                                |  Voice | Memory | Plans |   |
                                +--------------+--------------+
                                               |
             +---------------------------------+---------------------------------+
             |                                 |                                 |
+------------v------------+      +-------------v-------------+      +------------v------------+
|    GeminiLiveClient     |      |       ToolDispatcher      |      |      NebiusClient       |
|  24kHz PCM Full-Duplex  |      |   Tool Execution, Safety  |      |   Smart Model Routing   |
|  Bidi WebSocket         |      |   Gating, & Undo Journal  |      | Super VL & Nano Routing |
+------------+------------+      +-------------+-------------+      +-------------------------+
             |                                 |
+------------v------------+      +-------------v-------------+
|  Audio Stream Services  |      |       LocalDatabase       |
|  Rec: package:record    |      |   SQLite/SQLCipher        |
|  Play: Native/ffplay    |      |   Memories, Plans, Audits |
+-------------------------+      +---------------------------+
             |
             +------------------------+------------------------+
                                      |
                      +---------------v---------------+
                      |        Platform Drivers       |
                      | Android: Accessibility/Tile   |
                      | Desktop: Hotkeys/Window/Tray  |
                      +-------------------------------+
```

---

## Core Capabilities

### 1. Real-Time Speech-to-Speech (Gemini Live)
- Bidirectional WebSocket communication over `wss://generativelanguage.googleapis.com/...` with `gemini-2.0-flash-exp`.
- **Microphone Streaming**: `AudioRecordingService` captures raw 24 kHz 16-bit mono PCM chunks.
- **Hardware Speaker Playback**: `AudioPlaybackService` streams 24 kHz audio chunks directly to hardware `AudioTrack` (`MODE_STREAM`) on Android and `ffplay` stdin on Desktop.
- **Instant Barge-In**: Flushes audio buffers with 0ms delay when user interruption is detected.

### 2. Android Always-On Process & Battery Optimization
- **Battery Optimization Bypass**: Implements `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` and provides an in-app prompt to whitelist the app from Android Doze mode.
- **Single-Process Hygiene**:
  - No OS child processes are spawned on Android to avoid high OOM adjustments (`oom_adj`) and Low Memory Killer (LMK) termination.
  - Native Intent launching (`packageManager.getLaunchIntentForPackage`) is used for application switches.
  - Shell execution (`run_shell_command`) is strictly blocked on mobile.
- **Sticky Foreground Service**: `AssistantForegroundService` runs with `android:stopWithTask="false"`, `START_STICKY`, and persistent `PARTIAL_WAKE_LOCK`.

### 3. Android Top Bar & System Tray Behavior
- **Top Pull-Down Notification Tray**: Mirrors the Windows/Linux system tray with live status ("Listening" vs. "Idle") and interactive buttons:
  - **Toggle Voice**: Starts or pauses Gemini Live speech-to-speech.
  - **Open**: Brings the assistant UI to the foreground.
  - **Exit**: Gracefully stops the background listener.
- **Android Quick Settings Top Bar Tile**: `AssistantTileService` allows users to add a **Device Assistant** tile directly to Android's top swipe-down Quick Settings panel.

### 4. Sensitive App Guard (Privacy Shield)
- Prevents screenshotting, UI inspection, touch automation, and cloud inference while sensitive applications are in the foreground.
- **Protected Packages**:
  - **SIM Toolkit & Carrier Menus**: `com.android.stk`, `stk2`, MediaTek STK, Qualcomm UIM, Samsung STK.
  - **Mobile Money**: M-Pesa, Airtel Money, MTN MobileMoney, MyMTN.
  - **Banking & FinTech**: Chase, Bank of America, Wells Fargo, Revolut, Monzo, PayPal, Cash App, Venmo, Wise.
  - **Crypto & Web3 Wallets**: MetaMask, Coinbase, Trust Wallet, Binance, Ledger Live.
  - **2FA & Password Managers**: Bitwarden, 1Password, LastPass, KeePass, Google Authenticator, Authy, Duo.
  - **Android System Flags**: Windows with `FLAG_SECURE` and packages with `CATEGORY_FINANCE`.
- Custom user-defined protected packages can be added/removed dynamically.

### 5. Task Planner & Procedural Workflows
- **Nemotron-3 Smart Model Routing**:
  - Complex tasks (multi-step decomposition, tool chaining >4, visual context, hierarchical routines) automatically route to `nvidia/nemotron-3-super-vl`.
  - Simple tasks (memory extraction, single-step execution, concise factual queries) route to `nvidia/nemotron-3-nano` for rapid execution and low token overhead.
  - Heuristic classification via `classifyTask({taskDescription, toolCount, requiresMultiStep, hasVisualContext})` or explicit `TaskComplexity` enum.
- **Persistent Plans & Workflows**: Saved in encrypted SQLite (`LocalDatabase`) with execution logs, pause/resume, and rollback capabilities.
- **Undo Journal**: Automatically records reversal data for mutating actions (`remember`, `forget`, `save_workflow`, `delete_workflow`).

### 6. Sub-Agent Orchestration (`dartantic_ai` Style Engine)
- **Deny-by-Default Tool Scoping**: Sub-agents spawned via `spawn_agent` only have access to their explicit `allowed_tools` allowlist. Unknown tools are rejected at spawn time.
- **Strict Guardrails & Limits**:
  - Maximum 10 active sub-agents concurrently.
  - Maximum recursion depth of 3 (`spawn_agent` cannot be passed recursively beyond depth 3).
  - Maximum 4 parallel executions.
  - Per-agent step cap (`max_steps`, default 10) and timeout enforcement (`timeout_ms`).
- **Autonomous Reasoning Loop**: Leverages NVIDIA Nemotron-3 Smart Routing (`super-vl` for multi-step reasoning & tool dispatch, `nano` for simple actions) and step checkpointing in encrypted local storage.
- **Sub-Agent Lifecycle**: `list_agents`, `agent_status`, `send_to_agent`, `cancel_agent` with full UI management in the Plans & Workflows tab.

### 7. Real-Time Screen Perception & Visual Context Streaming
- **Live Frame Forwarding**: Screen frames captured via Android API 30+ `takeScreenCapture()` or Desktop drivers are piped directly into `GeminiLiveClient.sendImageFrame(bytes)` over the bidirectional WebSocket.
- **Voice Tab Quick Action**: Users can tap "Stream Screen Frame" directly on the Voice tab during conversation to stream visual context to Gemini.
- **Privacy Gating**: `SensitiveAppGuard` intercepts every screen capture request; capture is immediately halted if banking, SIM toolkit, 2FA, or `FLAG_SECURE` windows are detected.

### 8. Cross-Device PC Assistant Bridge
- **Remote Tool Delegation**: Offloads desktop-only actions (`computer_use`, `terminal_execute`, `media_control`) to the companion Node.js PC Assistant server over HTTP (`/test-tool`).
- **Bi-Directional Sync**:
  - `sync_memories`: Pulls semantic memories from DuckDB into on-device encrypted SQLite with zero data collisions.
  - `sync_workflows`: Pulls procedural routines from the PC store to run natively on mobile/desktop.
- **One-Tap Status & Diagnostics**: `pc_status` verifies server health, latency, and uptime directly from the assistant or UI.

### 9. Real-Time Web & Knowledge Synthesis
- **Smart Knowledge Synthesis**: `web_search` dynamically classifies query complexity—routing complex deep synthesis to `nvidia/nemotron-3-super-vl` and concise factual QA to `nvidia/nemotron-3-nano`.
- Fully integrated into `ToolDefinitions` and handled natively by `ToolDispatcher`.

### 10. Hardware-Backed Settings & Key Vault
- **Encrypted BYOK Management**: Accessible via the Settings gear icon in the top AppBar.
- Configures Google Gemini API Key, Nebius Token Factory Key, Nebius Endpoint URL, Complex Tasks Model ID (`nvidia/nemotron-3-super-vl`), Simple Tasks Model ID (`nvidia/nemotron-3-nano`), and PC Server URL.
- One-click connection test for the PC Bridge with live status indicators.
- Emergency "Danger Zone" to securely flush hardware keystore credentials.

---

## Project Structure

```
device_assistant/
|-- android/app/src/main/
|   |-- AndroidManifest.xml                    # Permissions, Services, and QS Tile declaration
|   |-- kotlin/com/deviceassistant/device_assistant/
|   |   |-- MainActivity.kt                    # MethodChannel bridge for battery, intents, and audio
|   |   |-- AssistantAccessibilityService.kt   # Gestures, screenshots (API 30+), input, and shield
|   |   |-- AssistantForegroundService.kt      # Always-on process, AudioTrack streaming, tray notification
|   |   `-- AssistantTileService.kt            # Android Quick Settings top bar tile
|   `-- res/xml/accessibility_service_config.xml # Accessibility flags and screenshot permission
|-- lib/
|   |-- core/
|   |   |-- agent/
|   |   |   `-- dartantic_agent.dart           # Type-safe sub-agent orchestrator & execution loop
|   |   |-- audio/
|   |   |   |-- audio_recording_service.dart   # 24kHz PCM microphone streaming
|   |   |   `-- audio_playback_service.dart    # Low-latency playback with instant barge-in flush
|   |   |-- database/
|   |   |   `-- local_database.dart            # SQLite/SQLCipher memories, workflows, plans, agents, audits
|   |   |-- network/
|   |   |   |-- gemini_live_client.dart        # Full-duplex WebSocket Live API client with image streaming
|   |   |   |-- nebius_client.dart             # Smart model routing: Nemotron-3-super-vl (complex) & nano (simple)
|   |   |   `-- pc_bridge_client.dart          # PC Assistant cross-device delegation & sync bridge
|   |   `-- security/
|   |       |-- key_vault.dart                 # Hardware-backed keystore (DPAPI / Keystore / Keyring)
|   |       `-- sensitive_app_guard.dart       # Banking, SIM toolkit, 2FA, and FLAG_SECURE guard
|   |-- features/
|   |   |-- tools/
|   |   |   |-- tool_definition.dart           # Declarations for Gemini Live, PC Bridge, & Sub-Agent tools
|   |   |   `-- tool_dispatcher.dart           # Execution router, PC delegation, audit logging, & undo journal
|   |   `-- ui/screens/
|   |       |-- home_screen.dart               # Voice orb, live transcript, visual stream button, tabs
|   |       |-- memories_tab.dart              # Memory search, filter, add, edit, delete, & PC sync UI
|   |       |-- plans_workflows_tab.dart       # 3-tab manager: Plans, Workflows, Sub-Agents, & PC sync
|   |       |-- security_shield_tab.dart       # Protected app policy viewer and audit log UI
|   |       `-- settings_screen.dart           # BYOK keys, PC Bridge URL & connection test, diagnostics
|   |-- platform/
|   |   |-- android/android_bridge.dart        # Dart interface to native Android services
|   |   `-- desktop/desktop_driver.dart        # Window manager, tray, and global hotkeys
|   `-- main.dart                              # Application initialization entrypoint
`-- test/
    |-- sensitive_app_guard_test.dart
    |-- local_database_test.dart
    |-- tool_dispatcher_test.dart
    |-- nebius_client_test.dart
    |-- gemini_live_client_test.dart
    |-- audio_recording_service_test.dart
    |-- audio_playback_service_test.dart
    |-- sub_agent_test.dart
    |-- screen_capture_streaming_test.dart
    `-- pc_bridge_client_test.dart
```

---

## Testing

Run the full automated test suite (48 unit & integration tests):
```bash
flutter test
```

Run static analysis:
```bash
flutter analyze
```
