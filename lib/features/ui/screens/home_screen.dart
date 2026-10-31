import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import '../../../core/agent/dartantic_agent.dart';
import '../../../core/audio/audio_playback_service.dart';
import '../../../core/audio/audio_recording_service.dart';
import '../../../core/audio/self_echo_guard.dart';
import '../../../core/database/local_database.dart';
import '../../../core/memory/memory_extractor.dart';
import '../../../core/memory/memory_recall.dart';
import '../../../core/memory/memory_vector.dart';
import '../../../core/network/gcp_adc_auth_service.dart';
import '../../../core/network/gemini_live_client.dart';
import '../../../core/network/dartantic_firebase_agent.dart';
import '../../../core/network/nebius_client.dart';
import '../../../core/network/pc_bridge_client.dart';
import '../../../core/security/key_vault.dart';
import '../../../core/security/sensitive_app_guard.dart';
import '../../../platform/android/android_bridge.dart';
import '../../../platform/desktop/desktop_driver.dart';
import '../../tools/tool_definition.dart';
import '../../tools/tool_dispatcher.dart';
import '../../../core/video/camera_streaming_service.dart';
import '../../../core/workflow/workflow_scheduler_service.dart';
import 'security_shield_tab.dart';
import 'settings_screen.dart';
import 'chat_tab.dart';

class HomeScreen extends StatefulWidget {
  final KeyVault keyVault;
  final LocalDatabase database;
  final SensitiveAppGuard guard;

  const HomeScreen({
    super.key,
    required this.keyVault,
    required this.database,
    required this.guard,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final AudioRecordingService _audioRecorder = AudioRecordingService();
  final SelfEchoGuard _selfEchoGuard = SelfEchoGuard();
  DateTime? _lastAudioChunkAt;
  AudioPlaybackService? _audioPlayback;

  GeminiLiveClient? _liveClient;
  DartanticFirebaseAgent? _dartanticAgent;
  NebiusClient? _nebiusClient;
  ToolDispatcher? _dispatcher;
  AndroidBridge? _androidBridge;
  DesktopDriver? _desktopDriver;
  PcBridgeClient? _pcBridgeClient;

  bool _isConnecting = false;
  bool _isConnected = false;
  bool _isLocalSttActive = false;
  String? _activePackage;
  bool _isAccessibilityEnabled = false;
  bool _isBatteryOptimizationIgnored = true;
  bool _isUsageAccessGranted = true;
  final List<ChatMessage> _chatMessages = [];

  StreamSubscription? _transcriptSub;
  StreamSubscription? _toolCallSub;
  StreamSubscription? _connSub;
  StreamSubscription? _activePackageSub;
  StreamSubscription? _shieldAlertSub;
  StreamSubscription? _trayActionSub;
  StreamSubscription? _audioOutputSub;
  StreamSubscription? _interruptionSub;
  StreamSubscription? _hotwordSub;
  StreamSubscription? _micPermSub;

  List<Map<String, dynamic>> _pendingPcApprovals = [];
  Timer? _approvalPollTimer;
  StreamSubscription? _pcEventsSub;

  late final CameraStreamingService _cameraStreaming;
  WorkflowSchedulerService? _workflowScheduler;
  bool _isCameraStreaming = false;
  StreamSubscription? _cameraStreamSub;

  String _currentVoiceTranscript = '';
  bool _isTtsSpeaking = false;
  final TextEditingController _textController = TextEditingController();

  StreamSubscription? _partialTranscriptSub;
  StreamSubscription? _ttsSub;

  late AnimationController _orbController;

  late final MemoryRecallEngine _memoryRecall;
  int? _currentSessionId;
  String _lastLiveUserUtterance = '';

  @override
  void initState() {
    super.initState();
    _memoryRecall = MemoryRecallEngine(widget.database);
    _ensureSession();
    WidgetsBinding.instance.addObserver(this);
    _cameraStreaming = CameraStreamingService(guard: widget.guard);
    _cameraStreamSub = _cameraStreaming.streamingStateStream.listen((active) {
      if (mounted) setState(() => _isCameraStreaming = active);
    });
    _orbController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _initClients();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        Platform.isAndroid &&
        _androidBridge != null) {
      _checkAndroidPermissions();
    }
  }

  Future<void> _checkAndroidPermissions() async {
    if (_androidBridge == null) return;
    final access = await _androidBridge!.isAccessibilityEnabled();
    final battery = await _androidBridge!.isBatteryOptimizationIgnored();
    final usageAccess = await _androidBridge!.isUsageAccessGranted();
    if (mounted) {
      setState(() {
        _isAccessibilityEnabled = access;
        _isBatteryOptimizationIgnored = battery;
        _isUsageAccessGranted = usageAccess;
      });
    }
  }

  Future<void> _initClients() async {
    final nebiusKey = await widget.keyVault.getNebiusApiKey();

    if (nebiusKey != null && nebiusKey.isNotEmpty) {
      final superEndpoint = await widget.keyVault.getNebiusSuperEndpoint();
      final nanoEndpoint = await widget.keyVault.getNebiusNanoEndpoint();
      final superModel = await widget.keyVault.getNebiusSuperModel();
      final nanoModel = await widget.keyVault.getNebiusNanoModel();
      _nebiusClient = NebiusClient(
        apiKey: nebiusKey,
        superVlEndpoint: superEndpoint,
        nanoEndpoint: nanoEndpoint,
        superVlModel: superModel,
        nanoModel: nanoModel,
      );
    }

    final pcUrl = await widget.keyVault.getPcServerUrl();
    _pcBridgeClient = PcBridgeClient(serverUrl: pcUrl);
    _startPcApprovalMonitoring();

    // Platform Driver setup
    if (Platform.isAndroid) {
      _androidBridge = AndroidBridge();
      _isAccessibilityEnabled = await _androidBridge!.isAccessibilityEnabled();
      _isBatteryOptimizationIgnored =
          await _androidBridge!.isBatteryOptimizationIgnored();
      _isUsageAccessGranted = await _androidBridge!.isUsageAccessGranted();
      await _androidBridge!.startForegroundService();
      await _androidBridge!.updateProtectedPackages(
          widget.guard.customProtectedPackages.toList());

      final notifGranted =
          await _androidBridge!.isNotificationPermissionGranted();
      if (!notifGranted) {
        await _androidBridge!.requestNotificationPermission();
      }

      _activePackageSub = _androidBridge!.activePackageStream.listen((pkg) {
        setState(() => _activePackage = pkg);
        _dispatcher?.updateActivePackage(pkg);
      });
      _shieldAlertSub = _androidBridge!.shieldAlertStream.listen((pkg) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: Colors.red.shade900,
              content: Text('Sensitive App Active ($pkg). Shield engaged.'),
            ),
          );
        }
      });
      // Listen to Android top bar tray & QS tile actions
      _trayActionSub = _androidBridge!.trayActionStream.listen((action) {
        if (action == 'toggle_voice') {
          // Defer until after _initClients completes so _dispatcher is ready
          if (_dispatcher != null) {
            _toggleConnection();
          } else {
            // Post to next frame to let _initClients finish
            WidgetsBinding.instance
                .addPostFrameCallback((_) => _toggleConnection());
          }
        } else if (action == 'exit') {
          _liveClient?.disconnect();
          _audioRecorder.stopStreaming();
          if (_isLocalSttActive &&
              Platform.isAndroid &&
              _androidBridge != null) {
            _androidBridge!.stopHotwordListening();
            if (mounted) setState(() => _isLocalSttActive = false);
          }
        }
      });

      // On-Device Hotword Detection — configured but NOT auto-started.
      // The mic only activates when the user explicitly taps the orb,
      // the notification "Start Listening" button, or the accessibility button.
      final hotwordEnabled = await widget.keyVault.isHotwordEnabled();
      if (hotwordEnabled) {
        // Pre-flight: ensure permission is present so the first tap is instant.
        final hasMic = await _androidBridge!.isMicrophonePermissionGranted();
        if (!hasMic) {
          await _androidBridge!.requestMicrophonePermission();
        }
        // Do NOT call startHotwordListening here — mic stays off until user touch.
      }

      // Initialize telephony service
      await _androidBridge!.initializeTelephony();
      _hotwordSub?.cancel();
      _hotwordSub =
          _androidBridge!.hotwordStream.listen(_handleHotwordDetected);

      _micPermSub?.cancel();
      _micPermSub =
          _androidBridge!.microphonePermissionStream.listen((granted) {
        if (granted && mounted) {
          // Only resume if user is already in an active STT session
          // (e.g. they started listening before permission was granted).
          // Do NOT auto-arm on init — mic only activates on explicit touch.
          if (_isLocalSttActive) {
            _androidBridge!.startHotwordListening(hotwords: ['*']);
          }
        }
      });
      _partialTranscriptSub?.cancel();
      _partialTranscriptSub =
          _androidBridge!.partialTranscriptStream.listen((partial) {
        if (mounted && _isLocalSttActive) {
          setState(() {
            _currentVoiceTranscript = partial;
          });
        }
      });

      _ttsSub?.cancel();
      _ttsSub = _androidBridge!.isSpeakingStream.listen((speaking) {
        if (mounted) {
          setState(() {
            _isTtsSpeaking = speaking;
          });
        }
      });
    } else if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      _desktopDriver = DesktopDriver(onToggleVoice: _toggleConnection);
      await _desktopDriver!.initialize();
    }

    _audioPlayback = AudioPlaybackService(androidBridge: _androidBridge);

    _dispatcher = ToolDispatcher(
      db: widget.database,
      guard: widget.guard,
      nebiusClient: _nebiusClient,
      geminiClient: _liveClient,
      androidBridge: _androidBridge,
      pcBridgeClient: _pcBridgeClient,
      desktopDriver: _desktopDriver,
      activePackageName: _activePackage,
      onImageCaptured: (bytes) {
        _liveClient?.sendImageFrame(bytes);
      },
    );

    final subAgentManager = SubAgentManager(
      db: widget.database,
      rootDispatcher: _dispatcher!,
      nebiusClient: _nebiusClient,
    );
    _dispatcher!.setSubAgentManager(subAgentManager);

    _dartanticAgent = DartanticFirebaseAgent(
      dispatcher: _dispatcher!,
      database: widget.database,
      modelName: 'gemini-2.5-flash',
    );
    await _dartanticAgent!.initialize();

    _workflowScheduler?.dispose();
    _workflowScheduler = WorkflowSchedulerService(
      database: widget.database,
      dispatcher: _dispatcher!,
    );
    _workflowScheduler!.start();
  }

  /// True briefly after the last Live audio chunk while the speaker is audible.
  bool get _isAssistantAudioAudible =>
      _lastAudioChunkAt != null &&
      DateTime.now().difference(_lastAudioChunkAt!) <
          const Duration(milliseconds: 900);

  Color get _statusColor {
    if (_isConnected) return Colors.green;
    if (_isLocalSttActive) return Colors.teal;
    if (_isTtsSpeaking) return Colors.amberAccent;
    return Colors.grey;
  }

  String get _statusLabel {
    if (_isConnected) return 'Live';
    if (_isLocalSttActive) return 'Listening';
    if (_isTtsSpeaking) return 'Speaking';
    return 'Ready';
  }

  void _handleHotwordDetected(Map<String, String?> data) {
    final hotword = data['hotword'] ?? 'hey assistant';
    final command = data['command'] ?? '';

    final heard = hotword == 'stt' ? command : '$hotword $command'.trim();
    if (_selfEchoGuard.isLikelyEcho(heard) || _isAssistantAudioAudible) {
      return;
    }

    if (mounted) {
      setState(() {
        _currentVoiceTranscript = command.isNotEmpty ? command : 'Listening...';
      });
    }

    if (command.isNotEmpty) {
      _processAssistantQuery(command);
      return;
    }

    if (Platform.isAndroid && _androidBridge != null) {
      _androidBridge!.startHotwordListening(hotwords: ['*']);
      if (mounted) setState(() => _isLocalSttActive = true);
    }
  }

  void _toggleConnection() async {
    if (_isConnecting) return;

    setState(() => _isConnecting = true);

    try {
      final geminiKey = await widget.keyVault.getGeminiApiKey();
      final nebiusKey = await widget.keyVault.getNebiusApiKey();
      final authMode = await widget.keyVault.getAuthMode();

      if (_isConnected || _isLocalSttActive) {
        await _liveClient?.disconnect();
        await _audioRecorder.stopStreaming();
        if (Platform.isAndroid && _androidBridge != null) {
          await _androidBridge!.stopHotwordListening();
          await _androidBridge!.updateTrayStatus(isActive: false);
        }
        if (mounted) {
          setState(() {
            _isConnected = false;
            _isLocalSttActive = false;
            _currentVoiceTranscript = '';
          });
        }
        return;
      }

      final adcService = GcpAdcAuthService(keyVault: widget.keyVault);
      final hasAdc = authMode == 'adc' && await adcService.hasAdcCredentials();
      final hasGemini = hasAdc || (geminiKey != null && geminiKey.isNotEmpty);

      if (hasGemini) {
        final projectId = await widget.keyVault.getGcpProjectId();
        final location = await widget.keyVault.getGcpLocation();
        final geminiModel = await widget.keyVault.getGeminiModel();
        final geminiEndpoint = await widget.keyVault.getGeminiEndpoint();

        await _liveClient?.disconnect();
        final coreMemories = _memoryRecall.coreMemories(limit: 6);
        final liveInstruction = _buildLiveSystemInstruction(coreMemories);

        _liveClient = GeminiLiveClient(
          apiKey: authMode == 'api_key' ? geminiKey : null,
          accessTokenProvider:
              authMode == 'adc' ? () => adcService.getAccessToken() : null,
          projectId: projectId,
          location: location,
          host: geminiEndpoint,
          model: geminiModel,
          toolDeclarations:
              ToolDefinitions.getAllDeclarations(isAndroid: Platform.isAndroid),
          systemInstruction: liveInstruction,
        );
        _attachLiveClientStreams(_liveClient!);

        await _liveClient!.connect();

        final micReady = await _audioRecorder.startStreaming(
          onAudioChunk: (chunk) => _liveClient?.sendAudioChunk(chunk),
          onBargeIn: () {
            _audioPlayback?.flush();
            _audioRecorder.notifyPlaybackEnded();
          },
        );
        if (!micReady && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content:
                  Text('Microphone permission denied. Use text input instead.'),
            ),
          );
        }
        _androidBridge?.updateTrayStatus(isActive: true);
      } else if (Platform.isAndroid && _androidBridge != null) {
        final ok = await _androidBridge!.startHotwordListening(hotwords: ['*']);
        if (mounted) {
          setState(() => _isLocalSttActive = ok);
          _androidBridge?.updateTrayStatus(isActive: ok);
        }
      } else {
        final hasNebius = nebiusKey != null && nebiusKey.isNotEmpty;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                hasNebius
                    ? 'Live voice needs a Gemini key. Type below to chat with Nemotron.'
                    : 'No API key configured. Add a Gemini or Nebius key in settings.',
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connection error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  void _ensureSession() {
    if (_currentSessionId == null) {
      _currentSessionId = widget.database.createConversationSession(
        title: 'Session ${DateTime.now().toIso8601String().substring(0, 16)}',
      );
    }
  }

  String _buildLiveSystemInstruction(List<RecalledMemory> coreMemories) {
    final memoryBlock = coreMemories.isEmpty
        ? ''
        : '''
--- WHAT YOU KNOW ABOUT THIS USER (AMBIENT MEMORY) ---
${coreMemories.map((m) => '• ${m.content}').join('\n')}
--- END AMBIENT MEMORY ---
''';

    return '''
You are Device Assistant, an intelligent on-device agent.
$memoryBlock
Memory, task plans, and recurring workflows are managed by you through tools:
- save_memory: Save durable user facts/preferences (auto-deduplicated, semantic indexing).
- search_memories: Hybrid semantic + keyword search across long-term memories.
- forget_topic: Erase memories related to a topic ("forget about my workout routine").
- memory_summary: Return all known user facts ("what do you know about me?").
- remember / recall / list_memories / forget: Key-value memory primitives.
- generate_skill: Turn natural language task requests into reusable workflow skills.
- learn_skill: Convert recent tool calls into a named workflow.
- save_workflow_skill: Save Hermes-format procedural skills (markdown, parameters, safety-guarded, version ledger).
- patch_workflow_skill: Surgical search-and-replace edit of a workflow skill without rewrite.
- view_workflow_skill: Progressive disclosure L2 - retrieve full markdown instructions and rules.
- list_workflow_skills: Progressive disclosure L1 - compact skill list to minimize tokens.
- rollback_workflow_skill: Revert a workflow skill to a previous version from the ledger.
- plan_task / execute_plan / list_plans: Multi-step task planning.
- save_workflow / run_workflow / list_workflows / delete_workflow: Procedural routines.
- schedule_workflow / list_scheduled_workflows / cancel_scheduled_workflow: Recurring runs.
Use capture_screen or inspect_screen to observe the screen, and device tools to act.
Sensitive apps (banking, SIM toolkit, 2FA) are strictly guarded.
''';
  }

  static const String _liveSystemInstruction = '''
You are Device Assistant, an intelligent on-device agent.
Memory, task plans, and recurring workflows are managed by you through tools —
there is no UI for them, so call the appropriate tool whenever the user asks:
- remember / recall / list_memories / forget for durable user memory.
- plan_task / execute_plan / list_plans for multi-step task planning.
- save_workflow / run_workflow / list_workflows / delete_workflow for routines.
- schedule_workflow / list_scheduled_workflows / cancel_scheduled_workflow for recurring runs.
Use capture_screen or inspect_screen to observe the screen, and device tools to act.
Sensitive apps (banking, SIM toolkit, 2FA) are strictly guarded.
''';

  void _attachLiveClientStreams(GeminiLiveClient client) {
    _connSub?.cancel();
    _connSub = client.connectionStateStream.listen((connected) {
      if (mounted) {
        setState(() {
          _isConnected = connected;
          _isConnecting = false;
          if (connected) _isLocalSttActive = false;
        });
      }
      _androidBridge?.updateTrayStatus(isActive: connected);
      if (!connected && _audioRecorder.isRecording) {
        _audioRecorder.stopStreaming();
      }
      if (!connected) _selfEchoGuard.reset();
    });

    _transcriptSub?.cancel();
    _transcriptSub = client.transcriptStream.listen((text) {
      if (text.isEmpty) return;
      if (_isAssistantAudioAudible) _selfEchoGuard.noteSpoken(text);
      if (!mounted) return;
      setState(() {
        if (_chatMessages.isNotEmpty &&
            !_chatMessages.last.isUser &&
            !_chatMessages.last.isError &&
            _chatMessages.last.toolData == null) {
          _chatMessages.last.text += text;
        } else {
          _chatMessages.add(ChatMessage(
            id: 'assistant_${DateTime.now().millisecondsSinceEpoch}',
            isUser: false,
            text: text,
            timestamp: DateTime.now(),
          ));
        }
      });
    });

    _audioOutputSub?.cancel();
    _audioOutputSub = client.audioOutputStream.listen((chunk) {
      _lastAudioChunkAt = DateTime.now();
      _audioRecorder.notifyPlaybackStarted();
      _audioPlayback?.playChunk(chunk);
    });

    _interruptionSub?.cancel();
    _interruptionSub = client.interruptionStream.listen((_) {
      _audioPlayback?.flush();
      _audioRecorder.notifyPlaybackEnded();
    });

    _toolCallSub?.cancel();
    _toolCallSub = client.toolCallStream.listen((event) async {
      final dispatcher = _dispatcher;
      if (dispatcher == null) return;
      final result = await dispatcher.dispatch(
        toolName: event.name,
        args: event.arguments,
      );
      client.sendToolResponse(
        callId: event.callId,
        name: event.name,
        result: result,
      );
      if (!mounted) return;
      setState(() {
        _chatMessages.add(ChatMessage(
          id: 'tool_${DateTime.now().millisecondsSinceEpoch}',
          isUser: false,
          text: 'Executed tool: ${event.name}',
          timestamp: DateTime.now(),
          toolData: {
            'tool': event.name,
            'args': event.arguments,
            'status': _toolStatus(result),
            'result': result,
          },
        ));
      });
    });
  }

  String _toolStatus(Map<String, dynamic> result) {
    if (result['status'] == 'blocked' || result.containsKey('blocked')) {
      return 'blocked';
    }
    if (result['status'] == 'error' ||
        result.containsKey('error') ||
        result['success'] == false) {
      return 'error';
    }
    return 'done';
  }

  Future<void> _processAssistantQuery(String userQuery) async {
    if (_dispatcher == null) return;

    final clean = userQuery.trim();
    if (clean.isEmpty) return;

    // Add user message to chat
    final userMsgId = DateTime.now().millisecondsSinceEpoch.toString();
    setState(() {
      _chatMessages.add(ChatMessage(
        id: userMsgId,
        isUser: true,
        text: clean,
        timestamp: DateTime.now(),
      ));
    });

    _ensureSession();
    if (_currentSessionId != null) {
      widget.database.addConversationMessage(
        sessionId: _currentSessionId!,
        role: 'user',
        content: clean,
      );
    }

    final geminiKey = await widget.keyVault.getGeminiApiKey();
    final nebiusKey = await widget.keyVault.getNebiusApiKey();
    final authMode = await widget.keyVault.getAuthMode();

    // While the Live session is running, keep text turns inside that session so
    // memory/plan/workflow tool calls flow through the same agent loop.
    if (_isConnected && _liveClient != null) {
      _lastLiveUserUtterance = clean;
      _liveClient!.sendTextMessage(clean);
      return;
    }

    final isScreenVision = ToolDispatcher.isScreenVisionRequest(clean);
    final isComputerUse = ToolDispatcher.isComputerUseRequest(clean);
    final useNebius = nebiusKey != null &&
        nebiusKey.isNotEmpty &&
        (isScreenVision || geminiKey == null || geminiKey.isEmpty);

    // Add thinking message
    final modelLabel = useNebius ? 'Nemotron' : 'Gemini 3.8 Flash';
    final pendingMsgId = 'pending_${DateTime.now().millisecondsSinceEpoch}';
    setState(() {
      _chatMessages.add(
        ChatMessage(
          id: pendingMsgId,
          isUser: false,
          text: 'Thinking with $modelLabel...',
          timestamp: DateTime.now(),
        ),
      );
    });

    try {
      final relevantMemories = _memoryRecall.hybridRecall(clean);
      final memoryContext = relevantMemories.isEmpty
          ? ''
          : '\n--- RECALLED MEMORIES ABOUT THE USER ---\n' +
              relevantMemories.map((m) => '• ${m.content}').join('\n') +
              '\n--- END RECALLED MEMORIES ---\n';

      final String systemPrompt;
      if (!useNebius && isComputerUse) {
        systemPrompt = '''
You are Device Assistant's Computer Use agent powered by Google Gemini 3.8 Flash.
$memoryContext
Your role is to execute GUI computer use actions, screen navigation, clicks, typing, gestures, and desktop OS commands.
Reply ONLY with a single JSON object in this format:
{"action": "tool_call", "tool": "<tool_name>", "args": {<arguments>}}

Available Computer Use tools:
- computer_use: {"action": "click"|"mouse_move"|"type"|"scroll"|"screenshot"|"shell", "coordinate": [x,y], "text": "string", "command": "string"}
- click_element: {"text": "visible label on screen"}
- touch_gesture: {"type": "tap"|"swipe", "x": number, "y": number, "startX": number, "startY": number, "endX": number, "endY": number}
- input_text: {"text": "string to type", "view_id": "optional string"}
- scroll_screen: {"direction": "down"|"up"}
- navigate: {"action": "back"|"home"|"recents"|"notifications"}
- capture_screen: {}
- inspect_screen: {"query": "string"}
- run_shell_command: {"command": "string"}
- delegate_to_pc: {"tool": "string", "args": {}}
''';
      } else {
        systemPrompt = '''
You are Device Assistant powered by NVIDIA Nemotron on Nebius Token Factory.
$memoryContext
You handle all general conversational intelligence, multi-step task planning, sub-agents, memory retention, workflows, and knowledge queries.
When a user asks to perform an action on their device or inspect device state, reply ONLY with a single JSON object in this format:
{"action": "tool_call", "tool": "<tool_name>", "args": {<arguments>}}

Available tools:
- system_status: {}
- open_application: {"package_name": "string (e.g. com.chrome.dev)", "app_name": "string"}
- list_installed_apps: {"filter": "optional string"}
- save_memory: {"content": "third-person fact about user", "category": "identity|preference|project|general"}
- search_memories: {"query": "natural language query"}
- forget_topic: {"topic": "subject to erase"}
- memory_summary: {}
- remember: {"key": "string", "value": "string", "category": "preference"|"location"|"general"}
- recall: {"key": "string"}
- list_memories: {"category": "optional string"}
- forget: {"key": "string"}
- generate_skill: {"description": "natural language task description", "platform": "android"|"desktop"}
- learn_skill: {"name": "snake_case_skill_name"}
- save_workflow_skill: {"name": "string", "description": "string", "markdown_content": "string"}
- patch_workflow_skill: {"name": "string", "search_target": "string", "replacement": "string"}
- view_workflow_skill: {"name": "string"}
- list_workflow_skills: {}
- rollback_workflow_skill: {"name": "string", "version_id": number}
- plan_task: {"goal": "string"}
- execute_plan: {"plan_id": "string"}
- list_plans: {}
- save_workflow: {"name": "string", "steps": [...]}
- run_workflow: {"name": "string"}
- list_workflows: {}
- delete_workflow: {"name": "string"}
- web_search: {"query": "string"}
- computer_use: {"action": "string", "coordinate": [x,y], "text": "string", "command": "string"}

If the user query is a general knowledge question, conversational request, or explanation, reply directly in natural language without any JSON wrapper.
''';
      }

      String response;
      if (useNebius) {
        final baseEndpoint = await widget.keyVault.getNebiusBaseEndpoint();
        final superVlEndpoint =
            await widget.keyVault.getNebiusSuperVlEndpoint();
        final nanoEndpoint = await widget.keyVault.getNebiusNanoEndpoint();
        final superVlModel = await widget.keyVault.getNebiusSuperModel();
        final nanoModel = await widget.keyVault.getNebiusNanoModel();

        _nebiusClient ??= NebiusClient(
          apiKey: nebiusKey,
          endpoint: baseEndpoint,
          superVlEndpoint: superVlEndpoint,
          nanoEndpoint: nanoEndpoint,
          superVlModel: superVlModel,
          nanoModel: nanoModel,
        );

        final complexity = NebiusClient.classifyTask(taskDescription: clean);
        response = await _nebiusClient!.chatCompletion(
          messages: [
            {'role': 'system', 'content': systemPrompt},
            {'role': 'user', 'content': clean},
          ],
          complexity: complexity,
        );
      } else if (_dartanticAgent != null && _dartanticAgent!.isReady) {
        // Use Dartantic + Firebase AI Logic Agent
        response = await _dartanticAgent!.sendPrompt(
          prompt: clean,
          systemPrompt: systemPrompt,
        );
      } else {
        final geminiModel = await widget.keyVault.getGeminiModel();
        final geminiEndpoint = await widget.keyVault.getGeminiEndpoint();
        final projectId = await widget.keyVault.getGcpProjectId();
        final location = await widget.keyVault.getGcpLocation();
        final adcService = GcpAdcAuthService(keyVault: widget.keyVault);

        _liveClient ??= GeminiLiveClient(
          apiKey: authMode == 'api_key' ? geminiKey : null,
          accessTokenProvider:
              authMode == 'adc' ? () => adcService.getAccessToken() : null,
          projectId: projectId,
          location: location,
          host: geminiEndpoint,
          model: geminiModel,
        );

        response = await _liveClient!.generateContent(
          prompt: clean,
          systemInstruction: systemPrompt,
        );
      }

      // Remove thinking message
      setState(() {
        _chatMessages.removeWhere((msg) => msg.id == pendingMsgId);
      });

      // Check if response is a tool call
      if (response.trim().startsWith('{') && response.trim().endsWith('}')) {
        try {
          final parsed = jsonDecode(response) as Map<String, dynamic>;
          if (parsed['action'] == 'tool_call') {
            final tool = parsed['tool'] as String?;
            final args = parsed['args'] as Map<String, dynamic>?;
            if (tool != null && args != null) {
              final result =
                  await _dispatcher!.dispatch(toolName: tool, args: args);
              setState(() {
                _chatMessages.add(ChatMessage(
                  id: DateTime.now().millisecondsSinceEpoch.toString(),
                  isUser: false,
                  text: 'Executed $tool: ${result['status'] ?? 'done'}',
                  timestamp: DateTime.now(),
                ));
              });
              return;
            }
          }
        } catch (e) {
          // Not a valid JSON, treat as text response
        }
      }

      // Add assistant response to chat
      setState(() {
        _chatMessages.add(ChatMessage(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          isUser: false,
          text: response,
          timestamp: DateTime.now(),
        ));
      });

      if (_currentSessionId != null) {
        widget.database.addConversationMessage(
          sessionId: _currentSessionId!,
          role: 'assistant',
          content: response,
        );
      }

      // Background auto-extraction of long-term user memories from this turn
      unawaited(_triggerBackgroundMemoryExtraction(clean, response));
    } catch (e) {
      setState(() {
        _chatMessages.removeWhere((msg) => msg.id == pendingMsgId);
        _chatMessages.add(ChatMessage(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          isUser: false,
          text: 'Error: $e',
          timestamp: DateTime.now(),
        ));
      });
    }
  }

  Future<void> _triggerBackgroundMemoryExtraction(
      String userMessage, String assistantReply) async {
    try {
      final extractor = MemoryExtractor(
        geminiClient: _liveClient,
        nebiusClient: _nebiusClient,
      );

      final extracted = await extractor.extractMemories(
        userMessage: userMessage,
        assistantReply: assistantReply,
      );

      for (final memory in extracted) {
        final embedding = MemoryVectorEngine.serializeEmbedding(
          MemoryVectorEngine.generateEmbedding(memory),
        );
        widget.database.saveMemory(
          content: memory,
          category: 'general',
          source: 'auto',
          importance: 0.6,
          embedding: embedding,
        );
      }
    } catch (_) {
      // Background extraction errors should not crash the foreground turn
    }
  }

  void _handleUserTextInput(String text) {
    _processAssistantQuery(text);
  }

  void _startPcApprovalMonitoring() {
    _approvalPollTimer?.cancel();
    _approvalPollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _pollPcApprovals();
    });
  }

  Future<void> _pollPcApprovals() async {
    if (_pcBridgeClient == null) return;
    try {
      final approvals = await _pcBridgeClient!.getPendingApprovals();
      if (approvals.isNotEmpty) {
        setState(() => _pendingPcApprovals = approvals);
      }
    } catch (e) {
      // Ignore polling errors
    }
  }

  Future<void> _resolvePcApproval(String id, bool approved) async {
    try {
      await _pcBridgeClient?.resolveApproval(
        approvalId: id,
        approved: approved,
      );
      setState(() {
        _pendingPcApprovals.removeWhere((a) => a['id'] == id);
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to resolve approval: $e')),
        );
      }
    }
  }

  void _toggleCameraStreaming() async {
    if (_isCameraStreaming) {
      await _cameraStreaming.stopStreaming();
      if (mounted) {
        setState(() => _isCameraStreaming = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Live camera vision stream stopped.')),
        );
      }
    } else {
      if (!_isConnected) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'Connect to Gemini Live before streaming camera vision.')),
        );
        return;
      }
      _cameraStreaming.updateActivePackage(_activePackage);
      await _cameraStreaming.startStreaming(
        onFrame: (frame) => _liveClient?.sendImageFrame(frame),
        fps: 1,
      );
      if (mounted) {
        setState(() => _isCameraStreaming = true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.teal,
            content: Text('Live camera vision stream active (1 FPS).'),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _orbController.dispose();
    _transcriptSub?.cancel();
    _toolCallSub?.cancel();
    _connSub?.cancel();
    _activePackageSub?.cancel();
    _shieldAlertSub?.cancel();
    _trayActionSub?.cancel();
    _audioOutputSub?.cancel();
    _interruptionSub?.cancel();
    _hotwordSub?.cancel();
    _approvalPollTimer?.cancel();
    _pcEventsSub?.cancel();
    _cameraStreamSub?.cancel();
    _cameraStreaming.dispose();
    _workflowScheduler?.dispose();
    _audioRecorder.dispose();
    _micPermSub?.cancel();
    _partialTranscriptSub?.cancel();
    _ttsSub?.cancel();
    _audioPlayback?.dispose();
    _liveClient?.dispose();
    _desktopDriver?.dispose();
    _textController.dispose();
    super.dispose();
  }

  void _openShield() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: const Color(0xFF12141A),
          appBar: AppBar(
            backgroundColor: const Color(0xFF181B22),
            elevation: 0,
            title: const Text('Privacy Shield'),
          ),
          body: SecurityShieldTab(
            database: widget.database,
            guard: widget.guard,
            androidBridge: _androidBridge,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      canPop: !Platform.isAndroid,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (Platform.isAndroid && _androidBridge != null) {
          _androidBridge!.minimizeApp();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF12141A),
        appBar: AppBar(
          backgroundColor: const Color(0xFF181B22),
          elevation: 0,
          title: Row(
            children: [
              const Icon(Icons.hub_outlined, color: Colors.indigoAccent),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Device Assistant',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _statusColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _statusColor),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(radius: 4, backgroundColor: _statusColor),
                    const SizedBox(width: 6),
                    Text(
                      _statusLabel,
                      style: TextStyle(fontSize: 12, color: _statusColor),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.shield_outlined),
              tooltip: 'Privacy Shield',
              onPressed: _openShield,
            ),
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Settings & Keys',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SettingsScreen(
                      keyVault: widget.keyVault,
                      database: widget.database,
                    ),
                  ),
                ).then((_) => _initClients());
              },
            ),
          ],
        ),
        body: _buildGeminiLiveView(theme),
      ),
    );
  }

  Widget _buildGeminiLiveView(ThemeData theme) {
    return Column(
      children: [
        // Status Banners
        if (Platform.isAndroid && !_isBatteryOptimizationIgnored)
          _buildStatusBanner(
            Colors.orange.shade900,
            Icons.battery_alert,
            Colors.amberAccent,
            'Battery optimization active. Disable to allow always-on background voice.',
            'Disable',
            () async {
              await _androidBridge?.requestIgnoreBatteryOptimization();
              final ignored =
                  await _androidBridge?.isBatteryOptimizationIgnored() ?? false;
              setState(() => _isBatteryOptimizationIgnored = ignored);
            },
          ),
        if (Platform.isAndroid && !_isAccessibilityEnabled)
          _buildStatusBanner(
            Colors.red.shade900,
            Icons.warning_amber_rounded,
            Colors.redAccent,
            'Accessibility Service disabled. Enable to allow mobile app automation.',
            'Enable',
            () => _androidBridge?.openAccessibilitySettings(),
          ),
        if (Platform.isAndroid && !_isUsageAccessGranted)
          _buildStatusBanner(
            Colors.blue.shade900,
            Icons.apps_outlined,
            Colors.lightBlueAccent,
            'Usage Access needed for precise app targeting.',
            'Grant',
            () async {
              await _androidBridge?.requestUsageAccess();
              await Future.delayed(const Duration(milliseconds: 500));
              final granted =
                  await _androidBridge?.isUsageAccessGranted() ?? false;
              if (mounted) setState(() => _isUsageAccessGranted = granted);
            },
          ),

        if (_pendingPcApprovals.isNotEmpty) _buildPcApprovalCard(),

        // Main Content Area
        Expanded(
          child: _chatMessages.isEmpty
              ? _buildEmptyState()
              : _buildConversationList(),
        ),

        // Bottom Input Area
        _buildBottomInputArea(),
      ],
    );
  }

  Widget _buildPcApprovalCard() {
    final request = _pendingPcApprovals.first;
    final id = request['id']?.toString() ?? '';
    final tool = request['tool'] ??
        request['tool_name'] ??
        request['action'] ??
        'PC action';
    final args = request['args'];
    final extra = _pendingPcApprovals.length - 1;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.amberAccent.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.devices, color: Colors.amberAccent, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  extra > 0
                      ? 'PC approval required (+$extra more)'
                      : 'PC approval required',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.amberAccent,
                  ),
                ),
                Text(
                  args == null ? '$tool' : '$tool: $args',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Colors.white70),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => _resolvePcApproval(id, false),
            child: const Text('Deny', style: TextStyle(color: Colors.white54)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.amber,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            onPressed: () => _resolvePcApproval(id, true),
            child: const Text('Approve'),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBanner(Color bgColor, IconData icon, Color iconColor,
      String message, String buttonText, VoidCallback onButtonPressed) {
    return Container(
      color: bgColor.withValues(alpha: 0.3),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: iconColor, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 12, color: Colors.white),
            ),
          ),
          TextButton(
            onPressed: onButtonPressed,
            child: Text(buttonText, style: TextStyle(color: iconColor)),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedBuilder(
            animation: _orbController,
            builder: (context, child) {
              final isActive = _isConnected || _isLocalSttActive;
              final scale =
                  isActive ? 1.0 + (_orbController.value * 0.12) : 1.0;
              return Transform.scale(
                scale: scale,
                child: Container(
                  width: 160,
                  height: 160,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: _isConnected
                          ? [
                              Colors.cyanAccent,
                              Colors.indigo,
                              Colors.blueAccent
                            ]
                          : _isLocalSttActive
                              ? [
                                  Colors.tealAccent,
                                  Colors.teal.shade800,
                                  Colors.indigo.shade900
                                ]
                              : [Colors.grey.shade400, Colors.grey.shade700],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: _isConnected
                            ? Colors.cyanAccent.withValues(alpha: 0.4)
                            : _isLocalSttActive
                                ? Colors.tealAccent.withValues(alpha: 0.4)
                                : Colors.black12,
                        blurRadius: _isConnected || _isLocalSttActive ? 30 : 10,
                        spreadRadius: _isConnected || _isLocalSttActive ? 8 : 2,
                      ),
                    ],
                  ),
                  child: IconButton(
                    iconSize: 64,
                    icon: _isConnecting
                        ? const CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 3)
                        : Icon(
                            _isConnected || _isLocalSttActive
                                ? Icons.mic
                                : Icons.mic_none,
                            color: Colors.white,
                          ),
                    onPressed: _toggleConnection,
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 24),
          Text(
            _isConnected
                ? 'Listening...'
                : _isLocalSttActive
                    ? 'Listening on device'
                    : _isTtsSpeaking
                        ? 'Speaking...'
                        : 'Tap the orb to talk',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w500,
              color: Colors.white70,
            ),
          ),
          const SizedBox(height: 8),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              'Ask me to remember something, plan a task, or run a routine.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.white38),
            ),
          ),
          if (_currentVoiceTranscript.isNotEmpty) ...[
            const SizedBox(height: 16),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 32),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _currentVoiceTranscript,
                style: const TextStyle(color: Colors.white70, fontSize: 16),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildConversationList() {
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.all(16),
      itemCount: _chatMessages.length,
      itemBuilder: (context, index) {
        final message = _chatMessages[_chatMessages.length - 1 - index];
        return _buildMessageBubble(message);
      },
    );
  }

  Widget _buildToolBubble(ChatMessage message) {
    final data = message.toolData!;
    final tool = data['tool']?.toString() ?? 'tool';
    final status = data['status']?.toString() ?? 'done';
    final result = (data['result'] as Map?)?.cast<String, dynamic>() ?? {};
    final isBlocked = status == 'blocked';
    final isError = status == 'error';

    final color = isBlocked
        ? Colors.orangeAccent
        : isError
            ? Colors.redAccent
            : Colors.cyanAccent;
    final icon = isBlocked
        ? Icons.block
        : isError
            ? Icons.error_outline
            : Icons.check_circle_outline;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 8),
                Text(
                  tool,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _summarizeToolResult(result),
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }

  String _summarizeToolResult(Map<String, dynamic> result) {
    if (result.isEmpty) return 'Completed.';
    if (result.containsKey('error')) return '${result['error']}';
    if (result['status'] == 'blocked' || result.containsKey('blocked')) {
      return '${result['security_alert'] ?? result['reason'] ?? 'Blocked by Privacy Shield.'}';
    }

    final memories = result['memories'];
    if (memories is List) {
      if (memories.isEmpty) return 'No memories stored.';
      return memories.take(6).map((m) {
        final map = m is Map ? m : {'key': 'item', 'value': m.toString()};
        return '${map['key']}: ${map['value']}';
      }).join('\n');
    }

    final plans = result['plans'];
    if (plans is List) {
      if (plans.isEmpty) return 'No task plans yet.';
      return plans.take(6).map((p) {
        final map = p is Map ? p : {'goal': p.toString()};
        return '${map['goal'] ?? map['id'] ?? 'Plan'} (${map['status'] ?? 'planned'})';
      }).join('\n');
    }

    final workflows = result['workflows'];
    if (workflows is List) {
      if (workflows.isEmpty) return 'No saved workflows.';
      return workflows.take(6).map((w) {
        final map = w is Map ? w : {'name': w.toString()};
        return '${map['name'] ?? map['id'] ?? 'workflow'}';
      }).join('\n');
    }

    final scheduled = result['scheduled_workflows'];
    if (scheduled is List) {
      if (scheduled.isEmpty) return 'No scheduled routines.';
      return scheduled.take(6).map((s) {
        final map = s is Map ? s : {'name': s.toString()};
        return '${map['workflow_name'] ?? map['name'] ?? map['id'] ?? 'routine'}';
      }).join('\n');
    }

    final steps = result['steps'];
    if (steps is List) {
      return 'Plan created with ${steps.length} steps.';
    }

    final answer = result['answer'];
    if (answer != null) return '$answer';

    if (result['status'] != null && result.length <= 3) {
      return 'Status: ${result['status']}';
    }

    final text = result.toString();
    return text.length > 220 ? '${text.substring(0, 220)}…' : text;
  }

  Widget _buildMessageBubble(ChatMessage message) {
    if (message.toolData != null) return _buildToolBubble(message);

    final isUser = message.isUser;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isUser) ...[
            Container(
              width: 36,
              height: 36,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [Colors.cyanAccent, Colors.indigo],
                ),
              ),
              child: const Icon(Icons.smart_toy, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: isUser
                    ? Colors.indigo.withValues(alpha: 0.3)
                    : Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: isUser
                      ? Colors.indigo.withValues(alpha: 0.5)
                      : Colors.white.withValues(alpha: 0.1),
                ),
              ),
              child: Text(
                message.text,
                style: TextStyle(
                  color: isUser ? Colors.white : Colors.white70,
                  fontSize: 15,
                ),
              ),
            ),
          ),
          if (isUser) ...[
            const SizedBox(width: 8),
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.indigo.withValues(alpha: 0.3),
              ),
              child: const Icon(Icons.person, color: Colors.white70, size: 20),
            ),
          ],
        ],
      ),
    );
  }

  void _sendTypedMessage() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _handleUserTextInput(text);
    _textController.clear();
  }

  Widget _buildBottomInputArea() {
    final isActive = _isConnected || _isLocalSttActive;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF181B22),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            _buildInputAction(
              icon:
                  _isCameraStreaming ? Icons.videocam : Icons.videocam_outlined,
              tooltip: _isCameraStreaming
                  ? 'Stop camera vision'
                  : 'Start camera vision',
              active: _isCameraStreaming,
              onPressed: _toggleCameraStreaming,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _textController,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _sendTypedMessage(),
                decoration: InputDecoration(
                  hintText: 'Message Device Assistant',
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.06),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _buildInputAction(
              icon: Icons.arrow_upward_rounded,
              tooltip: 'Send',
              primary: true,
              onPressed: _sendTypedMessage,
            ),
            const SizedBox(width: 8),
            _buildInputAction(
              tooltip: isActive ? 'Stop listening' : 'Start listening',
              active: isActive,
              primary: !isActive,
              onPressed: _toggleConnection,
              child: _isConnecting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Icon(
                      isActive ? Icons.mic : Icons.mic_none,
                      color: isActive
                          ? (_isConnected
                              ? Colors.cyanAccent
                              : Colors.tealAccent)
                          : Colors.white,
                      size: 24,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputAction({
    IconData? icon,
    required String tooltip,
    required VoidCallback onPressed,
    bool active = false,
    bool primary = false,
    Widget? child,
  }) {
    final background = primary
        ? Colors.indigo
        : active
            ? Colors.cyanAccent.withValues(alpha: 0.18)
            : Colors.white.withValues(alpha: 0.06);
    final foreground =
        active ? Colors.cyanAccent : (primary ? Colors.white : Colors.white54);

    return Tooltip(
      message: tooltip,
      child: Material(
        color: background,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(
            width: 46,
            height: 46,
            child: Center(
              child: child ?? Icon(icon, size: 22, color: foreground),
            ),
          ),
        ),
      ),
    );
  }
}
