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
import '../widgets/floating_assistant_overlay.dart';
import '../widgets/glass_container.dart';
import '../widgets/animated_glass_orb.dart';

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
  bool _isThinking = false;
  bool _isWaitingForMicPermission = false;
  bool _isUserSpeaking = false;
  Timer? _playbackEndTimer;
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

      // Microphone stays dormant on app launch. Voice only activates on explicit user touch (orb tap).
      // Initialize telephony service
      await _androidBridge!.initializeTelephony();
      _hotwordSub?.cancel();
      _hotwordSub =
          _androidBridge!.hotwordStream.listen(_handleHotwordDetected);

      _micPermSub?.cancel();
      _micPermSub =
          _androidBridge!.microphonePermissionStream.listen((granted) {
        if (granted && mounted) {
          // If the user tapped the orb and was waiting for mic permission, proceed to connect now.
          if (_isWaitingForMicPermission) {
            _isWaitingForMicPermission = false;
            _toggleConnection();
          } else if (_isLocalSttActive) {
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

  bool get _isSpeaking => _isTtsSpeaking || _isAssistantAudioAudible;

  Color get _statusColor {
    if (_isConnecting) return const Color(0xFF4895EF);
    if (_isThinking) return Colors.purpleAccent;
    if (_isSpeaking) return Colors.amberAccent;
    if (_isUserSpeaking) return Colors.tealAccent;
    if (_isConnected) return Colors.cyanAccent;
    if (_isLocalSttActive) return Colors.teal;
    return Colors.grey;
  }

  String get _statusLabel {
    if (_isConnecting) return 'Connecting';
    if (_isThinking) return 'Thinking';
    if (_isSpeaking) return 'Speaking';
    if (_isUserSpeaking) return 'Listening';
    if (_isConnected) return 'Live';
    if (_isLocalSttActive) return 'Listening';
    return 'Ready';
  }

  String get _heroStatusText {
    if (_isConnecting) return 'Connecting...';
    if (_isThinking) return 'Thinking...';
    if (_isSpeaking) return 'Speaking...';
    if (_isUserSpeaking) return 'Listening to you...';
    if (_isConnected) return 'Live & listening';
    if (_isLocalSttActive) return 'Listening on device';
    return 'Tap the orb to speak';
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
      if (Platform.isAndroid && _androidBridge != null) {
        _androidBridge!.stopHotwordListening();
      }
      if (mounted) {
        setState(() => _isLocalSttActive = false);
      }
      _processAssistantQuery(command);
      return;
    }

    if (Platform.isAndroid && _androidBridge != null && _isLocalSttActive) {
      _androidBridge!.startHotwordListening(hotwords: ['*']);
    }
  }

  void _toggleConnection() async {
    if (_isConnecting) return;

    setState(() => _isConnecting = true);

    try {
      final geminiKey = await widget.keyVault.getGeminiApiKey();
      final nebiusKey = await widget.keyVault.getNebiusApiKey();
      final authMode = await widget.keyVault.getAuthMode();
      final isAdc = (authMode == 'adc');
      final adcService = GcpAdcAuthService(keyVault: widget.keyVault);
      final hasAdc = isAdc && await adcService.hasAdcCredentials();

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
            _isUserSpeaking = false;
            _isThinking = false;
            _currentVoiceTranscript = '';
          });
        }
        return;
      }

      if (Platform.isAndroid && _androidBridge != null) {
        final hasMic = await _androidBridge!.isMicrophonePermissionGranted();
        if (!hasMic) {
          _isWaitingForMicPermission = true;
          await _androidBridge!.requestMicrophonePermission();
          return;
        }
      }

      final hasGemini = (geminiKey != null && geminiKey.isNotEmpty) || hasAdc;

      if (hasGemini) {
        final projectId = await widget.keyVault.getGcpProjectId();
        final location = await widget.keyVault.getGcpLocation();
        final geminiModel = await widget.keyVault.getGeminiModel();
        final geminiEndpoint = await widget.keyVault.getGeminiEndpoint();

        await _liveClient?.disconnect();
        final coreMemories = _memoryRecall.coreMemories(limit: 6);
        final liveInstruction = _buildLiveSystemInstruction(coreMemories);

        _liveClient = GeminiLiveClient(
          apiKey: isAdc ? null : geminiKey,
          accessTokenProvider: isAdc ? () => adcService.getAccessToken() : null,
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

        // BiDi real-time 24kHz audio streaming with on-device VAD gating
        final micReady = await _audioRecorder.startStreaming(
          enableVad: true,
          onAudioChunk: (chunk) => _liveClient?.sendAudioChunk(chunk),
          onBargeIn: () {
            _audioPlayback?.flush();
            _audioRecorder.notifyPlaybackEnded();
            if (mounted) {
              setState(() {
                _isThinking = false;
                _lastAudioChunkAt = null;
              });
            }
          },
          onSpeechStatusChanged: (isSpeech, rms) {
            if (_isUserSpeaking != isSpeech && mounted) {
              setState(() {
                _isUserSpeaking = isSpeech;
                if (isSpeech) {
                  _isThinking = false;
                } else if (_isConnected && !_isSpeaking) {
                  _isThinking = true;
                }
              });
            }
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
    _currentSessionId ??= widget.database.createConversationSession(
      title: 'Session ${DateTime.now().toIso8601String().substring(0, 16)}',
    );
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
You are Zen, a calm, mindful, and intuitive cross-platform companion.
Personality:
- Composed, attentive, concise, and effortlessly competent.
- You bring clarity, warmth, and peace of mind to the user's day. Speak naturally and concisely without robotic filler.
- You respect privacy and quiet focus above all else.
- When performing actions (dialing, device control, PC bridging, or scheduling), execute decisively and confirm clearly.

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
      final cleanText = _sanitizeTranscript(text);
      if (cleanText.isEmpty) return;
      if (_isAssistantAudioAudible) _selfEchoGuard.noteSpoken(cleanText);
      if (!mounted) return;
      setState(() {
        if (_chatMessages.isNotEmpty &&
            !_chatMessages.last.isUser &&
            !_chatMessages.last.isError &&
            _chatMessages.last.toolData == null) {
          _chatMessages.last.text += cleanText;
        } else {
          _chatMessages.add(ChatMessage(
            id: 'assistant_${DateTime.now().millisecondsSinceEpoch}',
            isUser: false,
            text: cleanText,
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
      if ((!_isSpeaking || _isThinking) && mounted) {
        setState(() {
          _isThinking = false;
        });
      }
      _playbackEndTimer?.cancel();
      _playbackEndTimer = Timer(const Duration(milliseconds: 950), () {
        if (mounted) setState(() {});
      });
    });

    _interruptionSub?.cancel();
    _interruptionSub = client.interruptionStream.listen((_) {
      _audioPlayback?.flush();
      _audioRecorder.notifyPlaybackEnded();
      _playbackEndTimer?.cancel();
      if (mounted) {
        setState(() {
          _isThinking = false;
          _lastAudioChunkAt = null;
        });
      }
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

  String _sanitizeTranscript(String text) {
    var cleaned = text;
    // Strip any thinking prefixes or model meta-announcements
    cleaned = cleaned.replaceAll(
      RegExp(r'Thinking with\s+[^\n.]+[.]?', caseSensitive: false),
      '',
    );
    cleaned = cleaned.replaceAll(
      RegExp(r'Thinking Process:?[^\n]*\n?', caseSensitive: false),
      '',
    );
    return cleaned.trim();
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
    final isAdc = (authMode == 'adc');
    final adcService = GcpAdcAuthService(keyVault: widget.keyVault);
    final hasAdc = isAdc && await adcService.hasAdcCredentials();

    // While the Live session is running, keep text turns inside that session so
    // memory/plan/workflow tool calls flow through the same agent loop.
    if (_isConnected && _liveClient != null) {
      _liveClient!.sendTextMessage(clean);
      return;
    }

    final isScreenVision = ToolDispatcher.isScreenVisionRequest(clean);
    final isComputerUse = ToolDispatcher.isComputerUseRequest(clean);
    final useNebius = nebiusKey != null &&
        nebiusKey.isNotEmpty &&
        (isScreenVision || (geminiKey == null || geminiKey.isEmpty) && !hasAdc);

    setState(() {
      _isThinking = true;
    });

    try {
      final relevantMemories = _memoryRecall.hybridRecall(clean);
      final memoryContext = relevantMemories.isEmpty
          ? ''
          : '\n--- RECALLED MEMORIES ABOUT THE USER ---\n${relevantMemories.map((m) => '• ${m.content}').join('\n')}\n--- END RECALLED MEMORIES ---\n';

      final String systemPrompt;
      if (!useNebius && isComputerUse) {
        systemPrompt = '''
You are Zen's Computer Use engine powered by Google Gemini.
Personality: Calm, composed, precise, and efficient.
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
You are Zen, an intelligent, calm, mindful on-device companion powered by NVIDIA Nemotron on Nebius Token Factory.
Personality: Composed, concise, attentive, and helpful. You speak naturally with clarity and warmth.
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
      } else if ((geminiKey != null && geminiKey.isNotEmpty) || hasAdc) {
        final geminiModel = await widget.keyVault.getGeminiModel();
        final geminiEndpoint = await widget.keyVault.getGeminiEndpoint();
        final projectId = await widget.keyVault.getGcpProjectId();
        final location = await widget.keyVault.getGcpLocation();

        _liveClient ??= GeminiLiveClient(
          apiKey: isAdc ? null : geminiKey,
          accessTokenProvider: isAdc ? () => adcService.getAccessToken() : null,
          projectId: projectId,
          location: location,
          host: geminiEndpoint,
          model: geminiModel,
        );

        response = await _liveClient!.generateContent(
          prompt: clean,
          systemInstruction: systemPrompt,
        );
      } else {
        response = isAdc
            ? 'Google Cloud ADC credentials not found. Run `gcloud auth application-default login` on desktop or import credentials in Settings.'
            : 'Please configure a Gemini API key or Nebius API key in Settings.';
      }

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

      // If response was triggered from background (e.g. quick tile, accessibility button, or wake word),
      // speak the reply via on-device TTS so the user hears it without looking at the screen.
      if (Platform.isAndroid && _androidBridge != null) {
        _androidBridge!.speakText(response);
      }

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
      if (mounted) {
        setState(() {
          _chatMessages.add(ChatMessage(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            isUser: false,
            text: 'Error: $e',
            timestamp: DateTime.now(),
          ));
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isThinking = false;
        });
      }
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
    _playbackEndTimer?.cancel();
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
        backgroundColor: Colors.transparent,
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(66),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
              child: GlassContainer(
                blur: 20,
                opacity: 0.12,
                borderRadius: BorderRadius.circular(22),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.18),
                  width: 1.2,
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: [Colors.cyanAccent, Colors.indigoAccent],
                        ),
                      ),
                      child: const Icon(Icons.hub_outlined,
                          color: Colors.white, size: 18),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Zen',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: _statusColor.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                            color: _statusColor.withValues(alpha: 0.5)),
                        boxShadow: [
                          BoxShadow(
                            color: _statusColor.withValues(alpha: 0.25),
                            blurRadius: 8,
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircleAvatar(
                              radius: 4, backgroundColor: _statusColor),
                          const SizedBox(width: 6),
                          Text(
                            _statusLabel,
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: _statusColor),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: const Icon(Icons.shield_outlined,
                          color: Colors.white70),
                      tooltip: 'Privacy Shield',
                      onPressed: _openShield,
                    ),
                    IconButton(
                      icon: const Icon(Icons.settings_outlined,
                          color: Colors.white70),
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
              ),
            ),
          ),
        ),
        body: AnimatedAuroraBackground(
          child: Stack(
            children: [
              _buildGeminiLiveView(theme),
              FloatingAssistantOverlay(
                isListening: _isLocalSttActive || _isConnected,
                isSpeaking: _isSpeaking,
                transcript: _currentVoiceTranscript,
                onDismiss: () => setState(() => _currentVoiceTranscript = ''),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGeminiLiveView(ThemeData theme) {
    final hasMessages = _chatMessages.isNotEmpty;
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

        // Animated Voice Orb Hero Section — always visible in Gemini Live UI
        Padding(
          padding: EdgeInsets.symmetric(
            vertical: hasMessages ? 2 : 10,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedGlassOrb(
                size: hasMessages ? 105 : 140,
                isConnected: _isConnected,
                isListening: _isLocalSttActive || _isUserSpeaking,
                isSpeaking: _isSpeaking,
                isConnecting: _isConnecting,
                isThinking: _isThinking,
                onTap: _toggleConnection,
              ),
              const SizedBox(height: 6),
              Text(
                _heroStatusText,
                style: TextStyle(
                  fontSize: hasMessages ? 14 : 17,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),

        // Main Content Area
        Expanded(
          child: hasMessages
              ? Column(
                  children: [
                    if (_currentVoiceTranscript.isNotEmpty)
                      _buildLiveTranscriptBox(),
                    Expanded(child: _buildConversationList()),
                  ],
                )
              : _buildEmptyStateContent(),
        ),

        // Bottom Input Area
        _buildBottomInputArea(),
      ],
    );
  }

  Widget _buildEmptyStateContent() {
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                'Ask me to remember something, plan a task, or run a workflow routine.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Colors.white54),
              ),
            ),
            if (_currentVoiceTranscript.isNotEmpty) ...[
              const SizedBox(height: 16),
              _buildLiveTranscriptBox(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLiveTranscriptBox() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      child: GlassContainer(
        blur: 16,
        opacity: 0.12,
        borderRadius: BorderRadius.circular(16),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        border: Border.all(
          color: Colors.tealAccent.withValues(alpha: 0.4),
          width: 1.2,
        ),
        child: Text(
          _currentVoiceTranscript,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14.5,
            fontWeight: FontWeight.w500,
          ),
          textAlign: TextAlign.center,
        ),
      ),
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
      margin: const EdgeInsets.fromLTRB(14, 6, 14, 0),
      child: GlassContainer(
        blur: 18,
        opacity: 0.15,
        color: Colors.amber,
        borderRadius: BorderRadius.circular(18),
        padding: const EdgeInsets.all(12),
        border: Border.all(
            color: Colors.amberAccent.withValues(alpha: 0.5), width: 1.2),
        shadows: [
          BoxShadow(
            color: Colors.amberAccent.withValues(alpha: 0.2),
            blurRadius: 14,
            spreadRadius: 1,
          ),
        ],
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.amber.withValues(alpha: 0.2),
              ),
              child: const Icon(Icons.devices,
                  color: Colors.amberAccent, size: 20),
            ),
            const SizedBox(width: 12),
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
                  const SizedBox(height: 2),
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
              child:
                  const Text('Deny', style: TextStyle(color: Colors.white54)),
            ),
            const SizedBox(width: 4),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.amber,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              onPressed: () => _resolvePcApproval(id, true),
              child: const Text('Approve',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBanner(Color bgColor, IconData icon, Color iconColor,
      String message, String buttonText, VoidCallback onButtonPressed) {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 6, 14, 0),
      child: GlassContainer(
        blur: 16,
        opacity: 0.14,
        color: bgColor,
        borderRadius: BorderRadius.circular(16),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        border:
            Border.all(color: iconColor.withValues(alpha: 0.45), width: 1.2),
        child: Row(
          children: [
            Icon(icon, color: iconColor, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(fontSize: 12, color: Colors.white),
              ),
            ),
            TextButton(
              onPressed: onButtonPressed,
              style: TextButton.styleFrom(
                foregroundColor: iconColor,
                textStyle:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
              ),
              child: Text(buttonText),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConversationList() {
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
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
      child: GlassContainer(
        blur: 14,
        opacity: 0.08,
        color: color,
        borderRadius: BorderRadius.circular(16),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 1.2),
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
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _summarizeToolResult(result),
              style: const TextStyle(
                  fontSize: 12, color: Colors.white70, height: 1.4),
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

    final filtered = Map<String, dynamic>.from(result)..remove('engine');
    if (filtered.isEmpty) return 'Completed.';

    final memories = filtered['memories'];
    if (memories is List) {
      if (memories.isEmpty) return 'No memories stored.';
      return memories.take(6).map((m) {
        final map = m is Map ? m : {'key': 'item', 'value': m.toString()};
        return '${map['key']}: ${map['value']}';
      }).join('\n');
    }

    final plans = filtered['plans'];
    if (plans is List) {
      if (plans.isEmpty) return 'No task plans yet.';
      return plans.take(6).map((p) {
        final map = p is Map ? p : {'goal': p.toString()};
        return '${map['goal'] ?? map['id'] ?? 'Plan'} (${map['status'] ?? 'planned'})';
      }).join('\n');
    }

    final workflows = filtered['workflows'];
    if (workflows is List) {
      if (workflows.isEmpty) return 'No saved workflows.';
      return workflows.take(6).map((w) {
        final map = w is Map ? w : {'name': w.toString()};
        return '${map['name'] ?? map['id'] ?? 'workflow'}';
      }).join('\n');
    }

    final scheduled = filtered['scheduled_workflows'];
    if (scheduled is List) {
      if (scheduled.isEmpty) return 'No scheduled routines.';
      return scheduled.take(6).map((s) {
        final map = s is Map ? s : {'name': s.toString()};
        return '${map['workflow_name'] ?? map['name'] ?? map['id'] ?? 'routine'}';
      }).join('\n');
    }

    final steps = filtered['steps'];
    if (steps is List) {
      return 'Plan created with ${steps.length} steps.';
    }

    final answer = filtered['answer'];
    if (answer != null) return '$answer';

    if (filtered['status'] != null && filtered.length <= 3) {
      return 'Status: ${filtered['status']}';
    }

    final text = filtered.toString();
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
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isUser) ...[
            Container(
              width: 34,
              height: 34,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [Colors.cyanAccent, Colors.indigoAccent],
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.cyanAccent,
                    blurRadius: 8,
                    spreadRadius: -2,
                  ),
                ],
              ),
              child: const Icon(Icons.smart_toy, color: Colors.white, size: 18),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: GlassContainer(
              blur: 16,
              opacity: isUser ? 0.16 : 0.09,
              color: isUser ? Colors.indigoAccent : Colors.white,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(18),
                topRight: const Radius.circular(18),
                bottomLeft: Radius.circular(isUser ? 18 : 4),
                bottomRight: Radius.circular(isUser ? 4 : 18),
              ),
              border: Border.all(
                color: isUser
                    ? Colors.indigoAccent.withValues(alpha: 0.5)
                    : Colors.white.withValues(alpha: 0.18),
                width: 1.2,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text(
                message.text,
                style: TextStyle(
                  color: isUser
                      ? Colors.white
                      : Colors.white.withValues(alpha: 0.9),
                  fontSize: 14.5,
                  height: 1.35,
                ),
              ),
            ),
          ),
          if (isUser) ...[
            const SizedBox(width: 8),
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.indigo.withValues(alpha: 0.4),
                border: Border.all(
                  color: Colors.indigoAccent.withValues(alpha: 0.5),
                  width: 1.2,
                ),
              ),
              child: const Icon(Icons.person, color: Colors.white, size: 18),
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

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
      child: SafeArea(
        top: false,
        child: GlassContainer(
          blur: 24,
          opacity: 0.12,
          borderRadius: BorderRadius.circular(30),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.2),
            width: 1.2,
          ),
          shadows: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
          child: Row(
            children: [
              GlassActionButton(
                icon: _isCameraStreaming
                    ? Icons.videocam
                    : Icons.videocam_outlined,
                tooltip: _isCameraStreaming
                    ? 'Stop camera vision'
                    : 'Start camera vision',
                active: _isCameraStreaming,
                onPressed: _toggleCameraStreaming,
                size: 42,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  controller: _textController,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _sendTypedMessage(),
                  decoration: const InputDecoration(
                    hintText: 'Ask or command Zen...',
                    hintStyle: TextStyle(color: Colors.white38, fontSize: 13),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              GlassActionButton(
                icon: Icons.arrow_upward_rounded,
                tooltip: 'Send message',
                primary: true,
                onPressed: _sendTypedMessage,
                size: 42,
              ),
              const SizedBox(width: 6),
              GlassActionButton(
                icon: isActive ? Icons.stop_rounded : Icons.mic_rounded,
                tooltip: isActive ? 'Stop listening' : 'Start listening',
                active: isActive,
                onPressed: _toggleConnection,
                size: 42,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
