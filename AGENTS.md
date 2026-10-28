# Agent Development Notes

## Project Overview
**Device Assistant** is a cross-platform on-device intelligent assistant for **Android** and **Desktop** (Linux / Windows / macOS) built with **Flutter / Dart**. It integrates low-latency multimodal speech-to-speech (Gemini Live), local encrypted SQLite persistence, scheduled routines, privacy-shielded automation, and bidirectional PC bridging.

---

## Build & Test Commands

### Dependencies
```bash
flutter pub get
```

### Static Analysis
```bash
dart analyze
```

### Unit & Integration Tests
```bash
# Run all unit tests
flutter test

# Run a specific test suite
flutter test test/voice_activity_detector_test.dart
flutter test test/camera_streaming_service_test.dart
flutter test test/workflow_scheduler_service_test.dart
flutter test test/pc_bridge_client_test.dart
```

> [!CAUTION]
> Do NOT execute full compilation/assembly builds (`flutter build apk`, `flutter build linux`, etc.) unless explicitly requested by the user. Rely on `dart analyze` and `flutter test` for verification.

---

## Architecture & Subsystems

### 1. Multimodal Real-Time Streaming (`lib/core/`)
- **Gemini Live Client (`lib/core/network/gemini_live_client.dart`)**: Bidirectional 24 kHz 16-bit PCM streaming over WebSocket with immediate barge-in audio flushing.
- **Voice Activity Detector (`lib/core/audio/voice_activity_detector.dart`)**: Zero-Crossing Rate (ZCR) and RMS-based speech detection with dynamic ambient noise floor estimation, pre-roll buffering, and acoustic echo ducking during speaker playback.
- **Audio Recording Pipeline (`lib/core/audio/audio_recording_service.dart`)**: Captures mic frames and routes them through VAD gating.
- **Camera Streaming Service (`lib/core/video/camera_streaming_service.dart`)**: Periodic 1–2 FPS JPEG grabber for vision grounding into Gemini Live, gated by privacy shields.

### 2. Privacy & Security Shield (`lib/core/security/`)
- **Sensitive App Guard (`lib/core/security/sensitive_app_guard.dart`)**: Blocks screenshot capture, accessibility inspection, and camera streaming whenever banking apps, password managers, 2FA authenticators, SIM toolkits, or `FLAG_SECURE` windows are foregrounded.

### 3. Local Persistence & Scheduling (`lib/core/database/`, `lib/core/workflow/`)
- **Local Database (`lib/core/database/local_database.dart`)**: SQLite persistence managing memories, plans, execution audit logs, workflows, and scheduled workflows.
- **Workflow Scheduler (`lib/core/workflow/workflow_scheduler_service.dart`)**: Evaluates scheduled tasks, updates execution intervals, and dispatches routine steps.

### 4. Tool Execution & PC Bridge (`lib/features/tools/`, `lib/core/network/`)
- **Tool Dispatcher (`lib/features/tools/tool_dispatcher.dart`)**: Central execution dispatcher with argument validation, undo journaling, rate limiting, and dangerous tool confirmation gating.
- **PC Bridge Client (`lib/core/network/pc_bridge_client.dart`)**: Connects to the PC Assistant host for remote delegation, shared memories/workflows, and 1-tap mobile confirmation of dangerous PC actions.

### 5. UI Architecture (`lib/features/ui/`)
- **`HomeScreen` (`lib/features/ui/screens/home_screen.dart`)**: Voice interaction visualizer, approval queue cards, active session states, and floating camera vision indicators.
- **`PlansWorkflowsTab` (`lib/features/ui/screens/plans_workflows_tab.dart`)**: Task plans, workflow routines, and interactive recurring schedule configuration modal.
- **`MemoryTab` (`lib/features/ui/screens/memory_tab.dart`)**: Semantic memory search, categorization, and editing.
