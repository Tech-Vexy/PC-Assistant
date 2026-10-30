import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import '../../../core/agent/dartantic_agent.dart';
import '../../../core/audio/audio_playback_service.dart';
import '../../../core/audio/audio_recording_service.dart';
import '../../../core/database/local_database.dart';
import '../../../core/network/gcp_adc_auth_service.dart';
import '../../../core/network/gemini_live_client.dart';
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
import 'memories_tab.dart';
import 'plans_workflows_tab.dart';
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
  AudioPlaybackService? _audioPlayback;
  int _activeTabIndex = 0;

  GeminiLiveClient? _liveClient;
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
  final List<String> _transcripts = [];
  final List<Map<String, dynamic>> _toolHistory = [];
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

  bool _isHotwordActive = false;
  String _activeHotwordPhrase = 'hey assistant';
  String _currentVoiceTranscript = '';
  String _lastAssistantVoiceResponse = '';
  bool _isTtsSpeaking = false;

  StreamSubscription? _partialTranscriptSub;
  StreamSubscription? _ttsSub;

  late AnimationController _orbController;

  @override
  void initState() {
    super.initState();
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
    final geminiKey = await widget.keyVault.getGeminiApiKey();
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

      // Always-On On-Device Hotword Detection ("Hey Assistant", "OK Google")
      final hotwordEnabled = await widget.keyVault.isHotwordEnabled();
      _activeHotwordPhrase = await widget.keyVault.getCustomHotword();
      if (hotwordEnabled) {
        _isHotwordActive = true;
        final hasMic = await _androidBridge!.isMicrophonePermissionGranted();
        if (!hasMic) {
          await _androidBridge!.requestMicrophonePermission();
        }
        await _androidBridge!.startHotwordListening(
          hotwords: [
            _activeHotwordPhrase,
            'hey assistant',
            'ok google',
            'device assistant',
            'computer'
          ],
        );
      }
      _hotwordSub?.cancel();
      _hotwordSub =
          _androidBridge!.hotwordStream.listen(_handleHotwordDetected);

      _micPermSub?.cancel();
      _micPermSub =
          _androidBridge!.microphonePermissionStream.listen((granted) {
        if (granted && mounted) {
          if (_isLocalSttActive) {
            _androidBridge!.startHotwordListening(hotwords: ['*']);
          } else if (_isHotwordActive) {
            _androidBridge!.startHotwordListening(
              hotwords: [
                _activeHotwordPhrase,
                'hey assistant',
                'ok google',
                'device assistant',
                'computer'
              ],
            );
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
      androidBridge: _androidBridge,
      pcBridgeClient: _pcBridgeClient,
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

    _workflowScheduler?.dispose();
    _workflowScheduler = WorkflowSchedulerService(
      database: widget.database,
      dispatcher: _dispatcher!,
    );
    _workflowScheduler!.start();

    final adcService = GcpAdcAuthService(keyVault: widget.keyVault);
    final hasAdc = await adcService.hasAdcCredentials();
    final authMode = await widget.keyVault.getAuthMode();

    if ((authMode == 'adc' && hasAdc) ||
        (geminiKey != null && geminiKey.isNotEmpty)) {
      final geminiModel = await widget.keyVault.getGeminiModel();
      final geminiEndpoint = await widget.keyVault.getGeminiEndpoint();
      final projectId = await widget.keyVault.getGcpProjectId();
      final location = await widget.keyVault.getGcpLocation();

      _setupGeminiClient(
        apiKey: authMode == 'api_key' ? geminiKey : null,
        accessTokenProvider:
            authMode == 'adc' ? () => adcService.getAccessToken() : null,
        projectId: projectId,
        location: location,
        model: geminiModel,
        endpoint: geminiEndpoint,
      );
    }
  }

  void _setupGeminiClient({
    String? apiKey,
    Future<String> Function()? accessTokenProvider,
    String? projectId,
    String? location,
    String? model,
    String? endpoint,
  }) {
    _liveClient?.dispose();
    _liveClient = GeminiLiveClient(
      apiKey: apiKey,
      accessTokenProvider: accessTokenProvider,
      projectId: projectId,
      location: location ?? 'us-central1',
      host: endpoint,
      model: model ?? GeminiLiveClient.defaultModel,
      toolDeclarations:
          ToolDefinitions.getAllDeclarations(isAndroid: Platform.isAndroid),
      systemInstruction: '''
You are Device Assistant, an intelligent on-device agent running natively on Android.
You have tool access to device controls, memory, task planning, and sub-agents.
When the user asks to plan a complex multi-step task, use the plan_task tool.
When the user gives a preference or location, remember it using remember.
When asked to observe or inspect what is currently on the screen, use capture_screen or inspect_screen.
When opening apps, use list_installed_apps to find exact package_name when needed, or pass package_name to open_application.
For autonomous sub-tasks, you can spawn specialized sub-agents with scoped tools using spawn_agent.
Sensitive apps (banking, SIM toolkit, 2FA) are strictly guarded.
''',
    );

    _transcriptSub = _liveClient!.transcriptStream.listen((text) {
      if (text.isEmpty) return;
      if (mounted) {
        setState(() {
          if (_chatMessages.isNotEmpty &&
              !_chatMessages.last.isUser &&
              !_chatMessages.last.isError &&
              _chatMessages.last.toolData == null) {
            _chatMessages.last.text += text;
          } else {
            _chatMessages.add(
              ChatMessage(
                id: 'assistant_${DateTime.now().millisecondsSinceEpoch}',
                isUser: false,
                text: text,
                timestamp: DateTime.now(),
              ),
            );
          }
        });
      }
    });

    _audioOutputSub = _liveClient!.audioOutputStream.listen((chunk) {
      _audioRecorder.notifyPlaybackStarted();
      _audioPlayback?.playChunk(chunk);
    });

    _interruptionSub = _liveClient!.interruptionStream.listen((_) {
      _audioPlayback?.flush();
      _audioRecorder.notifyPlaybackEnded();
    });

    _toolCallSub = _liveClient!.toolCallStream.listen((event) async {
      setState(() {
        _toolHistory.insert(0, {
          'tool': event.name,
          'args': event.arguments,
          'status': 'executing',
          'time': DateTime.now(),
        });
      });

      final result = await _dispatcher!.dispatch(
        toolName: event.name,
        args: event.arguments,
      );

      setState(() {
        if (_toolHistory.isNotEmpty) {
          final status =
              result['status'] == 'blocked' || result.containsKey('blocked')
                  ? 'blocked'
                  : result['status'] == 'error' ||
                          result.containsKey('error') ||
                          result['success'] == false
                      ? 'error'
                      : 'done';
          _toolHistory[0]['status'] = status;
          _toolHistory[0]['result'] = result;
        }
        final toolStatus =
            result['status'] == 'blocked' || result.containsKey('blocked')
                ? 'blocked'
                : result['status'] == 'error' ||
                        result.containsKey('error') ||
                        result['success'] == false
                    ? 'error'
                    : 'done';
        _chatMessages.add(
          ChatMessage(
            id: 'tool_${DateTime.now().millisecondsSinceEpoch}',
            isUser: false,
            text: 'Executed tool: ${event.name}',
            timestamp: DateTime.now(),
            toolData: {
              'tool': event.name,
              'args': event.arguments,
              'status': toolStatus,
              'result': result,
            },
          ),
        );
      });

      _liveClient!.sendToolResponse(
        callId: event.callId,
        name: event.name,
        result: result,
      );
    });

    _connSub = _liveClient!.connectionStateStream.listen((connected) {
      if (mounted) {
        setState(() {
          _isConnected = connected;
          _isConnecting = false;
          if (connected) {
            _isLocalSttActive = false;
          }
        });
        _androidBridge?.updateTrayStatus(isActive: connected);
      }
      if (!connected && _audioRecorder.isRecording) {
        _audioRecorder.stopStreaming();
      }
    });
  }

  void _handleHotwordDetected(Map<String, String?> event) async {
    final hotword = event['hotword'] ?? 'hey assistant';
    final command = event['command'];

    if (command == null || command.isEmpty) {
      if (mounted) {
        setState(() {
          _currentVoiceTranscript = 'Listening...';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.indigo.shade800,
            duration: const Duration(seconds: 2),
            content: Row(
              children: [
                const Icon(Icons.bolt, color: Colors.amberAccent),
                const SizedBox(width: 8),
                Text('Hotword: "$hotword" detected! Listening for command...'),
              ],
            ),
          ),
        );
      }
      if (Platform.isAndroid && _androidBridge != null) {
        await _androidBridge!.startHotwordListening(hotwords: ['*']);
        if (mounted) {
          setState(() => _isLocalSttActive = true);
          _androidBridge?.updateTrayStatus(isActive: true);
        }
      }
      return;
    }

    final cleanCommand = command.trim();
    if (mounted) {
      setState(() {
        _currentVoiceTranscript = cleanCommand;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.teal.shade800,
          duration: const Duration(seconds: 3),
          content: Row(
            children: [
              const Icon(Icons.mic, color: Colors.tealAccent),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Heard: "$cleanCommand"'),
              ),
            ],
          ),
        ),
      );
    }

    await _handleUserTextInput(cleanCommand);
  }

  Future<void> _handleUserTextInput(String input) async {
    final cleanCommand = input.trim();
    if (cleanCommand.isEmpty) return;

    if (mounted) {
      setState(() {
        _chatMessages.add(
          ChatMessage(
            id: 'user_${DateTime.now().millisecondsSinceEpoch}',
            isUser: true,
            text: cleanCommand,
            timestamp: DateTime.now(),
          ),
        );
      });
    }

    // Process through Gemini 3.8 Flash (Serverless) or fallback to Nemotron
    await _processCommand(cleanCommand);
  }

  Future<void> _processCommand(String command) async {
    final clean = command.trim();
    if (clean.isEmpty) return;

    final adcService = GcpAdcAuthService(keyVault: widget.keyVault);
    final hasAdc = await adcService.hasAdcCredentials();
    final authMode = await widget.keyVault.getAuthMode();
    final geminiKey = await widget.keyVault.getGeminiApiKey();
    final nebiusKey = await widget.keyVault.getNebiusApiKey();

    final canUseGemini = (authMode == 'adc' && hasAdc) ||
        (geminiKey != null && geminiKey.isNotEmpty);

    if (!canUseGemini && (nebiusKey == null || nebiusKey.isEmpty)) {
      if (mounted) {
        setState(() {
          _chatMessages.add(
            ChatMessage(
              id: 'err_${DateTime.now().millisecondsSinceEpoch}',
              isUser: false,
              text:
                  'Please configure Google Cloud Application Default Credentials (ADC) or Nebius API key in Settings.',
              timestamp: DateTime.now(),
              isError: true,
            ),
          );
        });
      }
      _showKeyDialog();
      return;
    }

    final geminiModel = await widget.keyVault.getGeminiModel();
    final geminiEndpoint = await widget.keyVault.getGeminiEndpoint();
    final projectId = await widget.keyVault.getGcpProjectId();
    final location = await widget.keyVault.getGcpLocation();

    final pendingMsgId = 'assistant_${DateTime.now().millisecondsSinceEpoch}';
    final modelLabel = canUseGemini
        ? (authMode == 'adc'
            ? 'Gemini 3.8 Flash (ADC Serverless)'
            : 'Gemini 3.8 Flash')
        : 'Nemotron';

    if (mounted) {
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
    }

    try {
      const systemPrompt = '''
You are Device Assistant running as an on-device intelligent agent for Android.
When a user asks to perform an action on their device or inspect device state, reply ONLY with a single JSON object in this format:
{"action": "tool_call", "tool": "<tool_name>", "args": {<arguments>}}

Available tools:
- system_status: {}
- open_application: {"package_name": "string (e.g. com.chrome.dev)", "app_name": "string"}
- list_installed_apps: {"filter": "optional string"}
- click_element: {"text": "visible label on screen"}
- touch_gesture: {"type": "tap"|"swipe", "x": number, "y": number, "startX": number, "startY": number, "endX": number, "endY": number}
- input_text: {"text": "string to type", "view_id": "optional string"}
- scroll_screen: {"direction": "down"|"up"}
- navigate: {"action": "back"|"home"|"recents"|"notifications"}
- capture_screen: {}
- inspect_screen: {"query": "string"}
- remember: {"key": "string", "value": "string", "category": "preference"|"location"|"general"}
- recall: {"key": "string"}
- list_memories: {"category": "optional string"}
- forget: {"key": "string"}
- plan_task: {"goal": "string"}
- execute_plan: {"plan_id": "string"}
- list_plans: {}
- save_workflow: {"name": "string", "steps": [...]}
- run_workflow: {"name": "string"}
- list_workflows: {}
- delete_workflow: {"name": "string"}
- web_search: {"query": "string"}

If the user query is a general knowledge question, conversational request, or explanation, reply directly in natural language without any JSON wrapper.
''';

      String response;
      if (canUseGemini) {
        _liveClient ??= GeminiLiveClient(
          apiKey: authMode == 'api_key' ? geminiKey : null,
          accessTokenProvider:
              authMode == 'adc' ? () => adcService.getAccessToken() : null,
          projectId: projectId,
          location: location,
          host: geminiEndpoint,
          model: geminiModel,
          toolDeclarations:
              ToolDefinitions.getAllDeclarations(isAndroid: Platform.isAndroid),
        );

        response = await _liveClient!.generateContent(
          prompt: clean,
          systemInstruction: systemPrompt,
        );
      } else {
        final baseEndpoint = await widget.keyVault.getNebiusBaseEndpoint();
        final superVlEndpoint =
            await widget.keyVault.getNebiusSuperVlEndpoint();
        final nanoEndpoint = await widget.keyVault.getNebiusNanoEndpoint();
        final superVlModel = await widget.keyVault.getNebiusSuperVlModel();
        final nanoModel = await widget.keyVault.getNebiusNanoModel();

        _nebiusClient ??= NebiusClient(
          apiKey: nebiusKey!,
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
      }

      final trimmed = response.trim();
      Map<String, dynamic>? toolCall;

      try {
        if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
          final parsed = jsonDecode(trimmed) as Map<String, dynamic>;
          if (parsed['action'] == 'tool_call' && parsed['tool'] != null) {
            toolCall = parsed;
          }
        } else {
          final s = trimmed.indexOf('{');
          final e = trimmed.lastIndexOf('}');
          if (s != -1 && e != -1 && e > s) {
            final candidate = trimmed.substring(s, e + 1);
            final parsed = jsonDecode(candidate) as Map<String, dynamic>;
            if (parsed['action'] == 'tool_call' && parsed['tool'] != null) {
              toolCall = parsed;
            }
          }
        }
      } catch (_) {}

      if (toolCall != null) {
        final toolName = toolCall['tool'] as String;
        final toolArgs = (toolCall['args'] as Map<String, dynamic>?) ?? {};

        final result = await _dispatcher?.dispatch(
              toolName: toolName,
              args: toolArgs,
            ) ??
            {};

        final summary = _formatToolResultSummary(toolName, toolArgs, result);

        if (mounted) {
          setState(() {
            _lastAssistantVoiceResponse = summary;
            final idx = _chatMessages.indexWhere((m) => m.id == pendingMsgId);
            if (idx != -1) {
              _chatMessages[idx] = ChatMessage(
                id: pendingMsgId,
                isUser: false,
                text: summary,
                timestamp: DateTime.now(),
                toolData: {
                  'tool': toolName,
                  'args': toolArgs,
                  'status': result.containsKey('blocked')
                      ? 'blocked'
                      : (result['status'] == 'app_not_found' ||
                              result['success'] == false ||
                              result.containsKey('error')
                          ? 'error'
                          : 'done'),
                  'result': result,
                },
              );
            }
            _toolHistory.insert(0, {
              'tool': toolName,
              'args': toolArgs,
              'status': result.containsKey('blocked')
                  ? 'blocked'
                  : (result['status'] == 'app_not_found' ||
                          result['success'] == false ||
                          result.containsKey('error')
                      ? 'error'
                      : 'done'),
              'result': result,
              'time': DateTime.now(),
            });
          });
        }
        _androidBridge?.speakText(summary);
        return;
      }

      // Natural language conversational response
      if (mounted) {
        setState(() {
          _lastAssistantVoiceResponse = trimmed;
          final idx = _chatMessages.indexWhere((m) => m.id == pendingMsgId);
          if (idx != -1) {
            _chatMessages[idx].text = trimmed;
          }
        });
      }
      _androidBridge?.speakText(trimmed);
    } catch (e) {
      if (mounted) {
        setState(() {
          _lastAssistantVoiceResponse = 'Nemotron Error: $e';
          final idx = _chatMessages.indexWhere((m) => m.id == pendingMsgId);
          if (idx != -1) {
            _chatMessages[idx] = ChatMessage(
              id: pendingMsgId,
              isUser: false,
              text: 'Nemotron Error: $e',
              timestamp: DateTime.now(),
              isError: true,
            );
          }
        });
      }
    }
  }

  String _formatToolResultSummary(
      String tool, Map<String, dynamic> args, Map<String, dynamic> result) {
    if (result.containsKey('blocked') || result['status'] == 'blocked') {
      final reason = result['security_alert'] ??
          result['reason'] ??
          'Sensitive application active';
      return 'Blocked by Security Shield: $reason';
    }
    if (result.containsKey('error')) {
      return 'Tool error ($tool): ${result['error']}';
    }

    switch (tool) {
      case 'system_status':
        final os = result['os'] ?? 'Unknown';
        final ver = result['os_version'] ?? '';
        final cores = result['cores'] ?? 1;
        final dev = result['device'] ?? 'Device';
        return 'System Status: $os $ver on $dev ($cores CPU cores).';

      case 'open_application':
        final app = args['app_name'] ?? args['package_name'] ?? 'app';
        if (result['status'] == 'app_not_found' || result['success'] == false) {
          return 'Could not open "$app": ${result['error'] ?? 'Application not found on this device.'}';
        }
        return 'Opened $app.';

      case 'list_installed_apps':
        final count = result['count'] ?? 0;
        final appsList = result['apps'] as List<dynamic>? ?? [];
        if (appsList.isEmpty) {
          final filter = args['filter'];
          return filter != null
              ? 'No apps found matching "$filter".'
              : 'No installed launcher apps found.';
        }
        final preview = appsList
            .take(5)
            .map((a) => a is Map
                ? '${a['appName']} (${a['packageName']})'
                : a.toString())
            .join(', ');
        return 'Found $count installed apps: $preview${appsList.length > 5 ? '...' : ''}.';

      case 'capture_screen':
        if (result['status'] == 'unavailable') {
          return 'Screen capture unavailable: ${result['message'] ?? 'FLAG_SECURE active'}';
        }
        final bytes = result['bytes_length'] ?? result['size_bytes'] ?? 0;
        return 'Captured screen screenshot ($bytes bytes).';

      case 'scroll':
      case 'scroll_screen':
        if (result['success'] == false) {
          return 'Failed to scroll screen: ${result['error'] ?? 'accessibility service unavailable'}';
        }
        final fwd = args['forward'] == true;
        return fwd ? 'Scrolled down.' : 'Scrolled up.';

      case 'perform_navigation':
      case 'navigate':
        if (result['success'] == false) {
          return 'Failed navigation: ${result['error'] ?? 'accessibility service unavailable'}';
        }
        final action = args['action'];
        final actionStr = action == 1 || action == 'back'
            ? 'back'
            : action == 2 || action == 'home'
                ? 'home'
                : action == 3 || action == 'recents'
                    ? 'recents'
                    : 'navigation';
        return 'Executed $actionStr navigation.';

      case 'remember':
        final key = args['key'] ?? '';
        final val = args['value'] ?? '';
        return 'Remembered "$key": $val';

      case 'recall':
        if (result['found'] == true) {
          return 'Recalled "${args['key']}": ${result['value']}';
        }
        return 'No saved memory found for "${args['key']}".';

      case 'forget':
        if (result['status'] == 'forgotten') {
          return 'Forgot memory "${args['key']}".';
        }
        return 'Memory "${args['key']}" was not found.';

      case 'list_memories':
        final count = result['count'] ?? 0;
        final memories = result['memories'] as List<dynamic>? ?? [];
        if (memories.isEmpty) {
          return 'No memories found in local database.';
        }
        final preview = memories
            .take(3)
            .map((m) => m is Map ? '${m['key']}: ${m['value']}' : m.toString())
            .join('; ');
        return 'Found $count memories ($preview${memories.length > 3 ? '...' : ''}).';

      case 'plan_task':
        final goal = result['goal'] ?? args['goal'] ?? '';
        final steps = (result['steps'] as List<dynamic>?) ?? [];
        final planId = result['plan_id'] ?? '';
        return 'Generated plan for "$goal" with ${steps.length} steps (ID: $planId).';

      case 'execute_plan':
        final status = result['status'] ?? 'completed';
        final count = result['steps_executed'] ?? 0;
        return 'Plan execution $status: completed $count steps.';

      case 'save_workflow':
        final name = result['name'] ?? args['name'] ?? '';
        final stepsCount = result['steps_count'] ?? 0;
        return 'Saved workflow "$name" ($stepsCount steps).';

      case 'run_workflow':
        final name = args['name'] ?? '';
        final status = result['status'] ?? 'done';
        return 'Workflow "$name" executed ($status).';

      case 'web_search':
        final ans = result['answer'] ?? result['result'] ?? '';
        if (ans.toString().isNotEmpty) {
          return ans.toString();
        }
        return 'Web search completed for "${args['query']}".';

      case 'undo_last':
        final toolName = result['tool'] ?? '';
        return 'Undid last action ($toolName).';

      default:
        return 'Executed tool $tool successfully.';
    }
  }

  Future<void> _toggleConnection() async {
    // If currently listening via local device STT, stop it
    if (_isLocalSttActive) {
      if (Platform.isAndroid && _androidBridge != null) {
        await _androidBridge!.stopHotwordListening();
        if (_isHotwordActive) {
          await _androidBridge!.startHotwordListening(
            hotwords: [
              _activeHotwordPhrase,
              'hey assistant',
              'ok google',
              'device assistant',
              'computer'
            ],
          );
        }
      }
      if (mounted) {
        setState(() => _isLocalSttActive = false);
        _androidBridge?.updateTrayStatus(isActive: false);
      }
      return;
    }

    // Start Device STT listening
    if (Platform.isAndroid && _androidBridge != null) {
      final hasMic = await _androidBridge!.isMicrophonePermissionGranted();
      if (!hasMic) {
        await _androidBridge!.requestMicrophonePermission();
      }

      final ok = await _androidBridge!.startHotwordListening(hotwords: ['*']);
      if (mounted) {
        setState(() => _isLocalSttActive = ok);
        _androidBridge?.updateTrayStatus(isActive: ok);
        if (ok) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Device STT active. Speak a command or request...'),
              backgroundColor: Colors.teal,
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
      return;
    }

    // Non-Android desktop
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Continuous Device STT is currently supported on Android. On desktop, please use the Chat tab.'),
          backgroundColor: Colors.indigo,
        ),
      );
    }
  }

  void _showKeyDialog() {
    final geminiCtrl = TextEditingController();
    final nebiusCtrl = TextEditingController();

    widget.keyVault
        .getGeminiApiKey()
        .then((val) => geminiCtrl.text = val ?? '');
    widget.keyVault
        .getNebiusApiKey()
        .then((val) => nebiusCtrl.text = val ?? '');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Configure API Keys (BYOK)'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: geminiCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Google Gemini API Key',
                  hintText: 'Used for Gemini Live Voice & Computer Use',
                  prefixIcon: Icon(Icons.mic),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nebiusCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Nebius Token Factory Key',
                  hintText: 'Used for Nemotron-3-super-vl Task Planning',
                  prefixIcon: Icon(Icons.psychology),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (geminiCtrl.text.isNotEmpty) {
                await widget.keyVault.setGeminiApiKey(geminiCtrl.text);
              }
              if (nebiusCtrl.text.isNotEmpty) {
                await widget.keyVault.setNebiusApiKey(nebiusCtrl.text);
              }
              if (ctx.mounted) {
                Navigator.of(ctx).pop();
              }
              if (mounted) {
                _initClients();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content:
                          Text('Keys securely saved to hardware keystore.')),
                );
              }
            },
            child: const Text('Save Keys'),
          ),
        ],
      ),
    );
  }

  Future<void> _manualCaptureScreen() async {
    final decision = widget.guard.evaluate(packageName: _activePackage);
    if (decision.isBlocked) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red.shade900,
            content: Text(
                'Sensitive app active (${_activePackage ?? "Protected"}). Screen capture shielded.'),
          ),
        );
      }
      return;
    }

    if (Platform.isAndroid && _androidBridge != null) {
      final bytes = await _androidBridge!.takeScreenCapture();
      if (bytes != null) {
        _liveClient?.sendImageFrame(bytes);
        if (mounted) {
          setState(() {
            _transcripts.add(
                '[Visual screen frame captured and streamed to Gemini Live]');
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              backgroundColor: Colors.indigo,
              content: Text('Screen frame streamed to Assistant vision model.'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              backgroundColor: Colors.amber,
              content: Text(
                  'Screen capture unavailable or blocked by Android FLAG_SECURE.'),
            ),
          );
        }
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text('Screen capture frame available on Android (API 30+).'),
          ),
        );
      }
    }
  }

  void _startPcApprovalMonitoring() {
    _approvalPollTimer?.cancel();
    _pcEventsSub?.cancel();

    if (_pcBridgeClient == null) return;

    // 1. Initial check & periodic polling fallback
    _checkPendingPcApprovals();
    _approvalPollTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      _checkPendingPcApprovals();
    });

    // 2. Real-time SSE stream for instant 0ms notification
    try {
      _pcEventsSub = _pcBridgeClient!.listenToEvents().listen((event) {
        final type = event['type'];
        if (type == 'approval_request' || type == 'approval_resolved') {
          _checkPendingPcApprovals();
        }
      });
    } catch (_) {}
  }

  Future<void> _checkPendingPcApprovals() async {
    if (_pcBridgeClient == null) return;
    try {
      final list = await _pcBridgeClient!.fetchPendingApprovals();
      if (mounted) {
        setState(() {
          _pendingPcApprovals = list;
        });
      }
    } catch (_) {}
  }

  Future<void> _resolvePcApproval(String id, bool approved) async {
    if (_pcBridgeClient == null) return;
    final ok = await _pcBridgeClient!.resolveApproval(
      approvalId: id,
      approved: approved,
      note: 'via mobile 1-tap confirmation',
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor:
              approved ? Colors.green.shade800 : Colors.red.shade800,
          content: Text(
            approved
                ? (ok
                    ? 'Approved PC dangerous action'
                    : 'Failed to approve action')
                : (ok ? 'Denied PC dangerous action' : 'Failed to deny action'),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
      _checkPendingPcApprovals();
    }
  }

  Future<void> _toggleCameraStreaming() async {
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget bodyContent;
    switch (_activeTabIndex) {
      case 1:
        bodyContent = ChatTab(
          messages: _chatMessages,
          onSendMessage: _handleUserTextInput,
          isLiveConnected: _isConnected || _isLocalSttActive,
          onToggleLive: _toggleConnection,
          onClearChat: () => setState(() => _chatMessages.clear()),
          onDispatchTool: (tool, args) async {
            await _dispatcher?.dispatch(toolName: tool, args: args);
          },
        );
        break;
      case 2:
        bodyContent =
            MemoriesTab(database: widget.database, keyVault: widget.keyVault);
        break;
      case 3:
        bodyContent = _dispatcher != null
            ? PlansWorkflowsTab(
                database: widget.database, dispatcher: _dispatcher!)
            : const Center(child: CircularProgressIndicator());
        break;
      case 4:
        bodyContent = SecurityShieldTab(
          database: widget.database,
          guard: widget.guard,
          androidBridge: _androidBridge,
        );
        break;
      default:
        bodyContent = _buildAssistantVoiceView(theme);
    }

    return PopScope(
        canPop: !Platform.isAndroid,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          if (Platform.isAndroid && _androidBridge != null) {
            _androidBridge!.minimizeApp();
          }
        },
        child: Scaffold(
          appBar: AppBar(
            title: Row(
              children: [
                const Icon(Icons.hub_outlined, color: Colors.indigoAccent),
                const SizedBox(width: 8),
                const Text('Device Assistant',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _isConnected
                        ? Colors.green.withValues(alpha: 0.15)
                        : _isLocalSttActive
                            ? Colors.teal.withValues(alpha: 0.15)
                            : Colors.grey.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: _isConnected
                            ? Colors.green
                            : _isLocalSttActive
                                ? Colors.teal
                                : Colors.grey),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircleAvatar(
                        radius: 4,
                        backgroundColor: _isConnected
                            ? Colors.green
                            : _isLocalSttActive
                                ? Colors.teal
                                : Colors.grey,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _isConnected
                            ? 'Gemini Live Active'
                            : _isLocalSttActive
                                ? 'Local STT (Nemotron)'
                                : 'Disconnected',
                        style: TextStyle(
                          fontSize: 12,
                          color: _isConnected
                              ? Colors.green
                              : _isLocalSttActive
                                  ? Colors.teal
                                  : Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
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
          body: bodyContent,
          bottomNavigationBar: NavigationBar(
            selectedIndex: _activeTabIndex,
            onDestinationSelected: (idx) =>
                setState(() => _activeTabIndex = idx),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.mic_outlined),
                selectedIcon: Icon(Icons.mic),
                label: 'Voice',
              ),
              NavigationDestination(
                icon: Icon(Icons.chat_bubble_outline),
                selectedIcon: Icon(Icons.chat_bubble),
                label: 'Chat',
              ),
              NavigationDestination(
                icon: Icon(Icons.psychology_outlined),
                selectedIcon: Icon(Icons.psychology),
                label: 'Memory',
              ),
              NavigationDestination(
                icon: Icon(Icons.alt_route),
                selectedIcon: Icon(Icons.alt_route),
                label: 'Plans & Workflows',
              ),
              NavigationDestination(
                icon: Icon(Icons.shield_outlined),
                selectedIcon: Icon(Icons.shield),
                label: 'Shield',
              ),
            ],
          ),
        ));
  }

  Widget _buildAssistantVoiceView(ThemeData theme) {
    return Column(
      children: [
        // Android Battery Optimization Exemption Banner
        if (Platform.isAndroid && !_isBatteryOptimizationIgnored)
          Container(
            color: Colors.orange.shade900.withValues(alpha: 0.3),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.battery_alert,
                    color: Colors.amberAccent, size: 20),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Battery optimization active. Disable to allow always-on background voice and automations.',
                    style: TextStyle(fontSize: 12, color: Colors.white),
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    await _androidBridge?.requestIgnoreBatteryOptimization();
                    final ignored =
                        await _androidBridge?.isBatteryOptimizationIgnored() ??
                            false;
                    setState(() => _isBatteryOptimizationIgnored = ignored);
                  },
                  child: const Text('Disable',
                      style: TextStyle(color: Colors.amberAccent)),
                ),
              ],
            ),
          ),

        // Android Accessibility Required Banner
        if (Platform.isAndroid && !_isAccessibilityEnabled)
          Container(
            color: Colors.red.shade900.withValues(alpha: 0.3),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.warning_amber_rounded,
                    color: Colors.redAccent, size: 20),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Accessibility Service disabled. Enable to allow mobile app automation.',
                    style: TextStyle(fontSize: 12, color: Colors.white),
                  ),
                ),
                TextButton(
                  onPressed: () => _androidBridge?.openAccessibilitySettings(),
                  child: const Text('Enable',
                      style: TextStyle(color: Colors.redAccent)),
                ),
              ],
            ),
          ),

        // Usage Access (Package Usage Stats) Required Banner
        if (Platform.isAndroid && !_isUsageAccessGranted)
          Container(
            color: Colors.blue.shade900.withValues(alpha: 0.3),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.apps_outlined,
                    color: Colors.lightBlueAccent, size: 20),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Usage Access needed for precise app targeting (Chrome Dev vs Stable, etc.).',
                    style: TextStyle(fontSize: 12, color: Colors.white),
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    await _androidBridge?.requestUsageAccess();
                    // Re-check after returning from settings
                    await Future.delayed(const Duration(milliseconds: 500));
                    final granted =
                        await _androidBridge?.isUsageAccessGranted() ?? false;
                    if (mounted) {
                      setState(() => _isUsageAccessGranted = granted);
                    }
                  },
                  child: const Text('Grant',
                      style: TextStyle(color: Colors.lightBlueAccent)),
                ),
              ],
            ),
          ),

        // Security Shield Status Banner
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: Colors.amber.withValues(alpha: 0.08),
          child: Row(
            children: [
              const Icon(Icons.shield_outlined, color: Colors.amber, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _activePackage != null
                      ? 'Shield Active (Foreground: $_activePackage)'
                      : 'Sensitive App Shield Active (SIM Toolkit, Banking, 2FA, FinTech Protected)',
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w500),
                ),
              ),
              Text(
                '${SensitiveAppGuard.defaultBlacklist.length} Apps Blocked',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
        ),

        // PC Dangerous Action Remote Approvals
        if (_pendingPcApprovals.isNotEmpty) _buildPcApprovalsSection(),

        // Central Live Voice Orb Area
        Expanded(
          flex: 4,
          child: Center(
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
                        width: 140,
                        height: 140,
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
                                    : [
                                        Colors.grey.shade400,
                                        Colors.grey.shade700
                                      ],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: _isConnected
                                  ? Colors.cyanAccent.withValues(alpha: 0.4)
                                  : _isLocalSttActive
                                      ? Colors.tealAccent.withValues(alpha: 0.4)
                                      : Colors.black12,
                              blurRadius: isActive ? 30 : 10,
                              spreadRadius: isActive ? 8 : 2,
                            ),
                          ],
                        ),
                        child: IconButton(
                          iconSize: 48,
                          icon: _isConnecting
                              ? const CircularProgressIndicator(
                                  color: Colors.white)
                              : Icon(
                                  isActive ? Icons.mic : Icons.mic_none,
                                  color: Colors.white,
                                ),
                          onPressed: _toggleConnection,
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 16),
                // Voice Speech Transcription & TTS Response Card
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 20),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: _isTtsSpeaking
                        ? Colors.indigo.withValues(alpha: 0.25)
                        : _isLocalSttActive
                            ? Colors.teal.withValues(alpha: 0.2)
                            : Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _isTtsSpeaking
                          ? Colors.cyanAccent.withValues(alpha: 0.5)
                          : _isLocalSttActive
                              ? Colors.tealAccent.withValues(alpha: 0.5)
                              : Colors.white12,
                    ),
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            _isTtsSpeaking
                                ? Icons.volume_up
                                : _isLocalSttActive
                                    ? Icons.mic
                                    : Icons.mic_none,
                            size: 18,
                            color: _isTtsSpeaking
                                ? Colors.cyanAccent
                                : _isLocalSttActive
                                    ? Colors.tealAccent
                                    : Colors.grey,
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              _isTtsSpeaking
                                  ? 'TTS Playing Voice Response...'
                                  : _isLocalSttActive
                                      ? (_currentVoiceTranscript.isNotEmpty
                                          ? 'Heard: "$_currentVoiceTranscript"'
                                          : 'Listening... Speak your request')
                                      : 'Tap Orb to Speak with Nemotron',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: _isTtsSpeaking
                                    ? Colors.cyanAccent
                                    : _isLocalSttActive
                                        ? Colors.white
                                        : Colors.grey.shade400,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (_lastAssistantVoiceResponse.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          _lastAssistantVoiceResponse,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            color: _isTtsSpeaking
                                ? Colors.white
                                : Colors.grey.shade400,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  _isLocalSttActive
                      ? 'Listening via Device STT (NVIDIA Nemotron)'
                      : (_isConnected
                          ? 'Listening & Conversing with Gemini Live'
                          : 'Tap Orb to Speak with Nemotron'),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _isLocalSttActive
                      ? 'Continuous On-Device STT | Active Tool Calling'
                      : 'Smart Routing: Nemotron-3.5-Super-VL & Nano-30B | Local DB',
                  style:
                      theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
                ),
                if (Platform.isAndroid &&
                    _isHotwordActive &&
                    !_isConnected &&
                    !_isLocalSttActive)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.indigo.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                            color: Colors.cyanAccent.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.hearing,
                              size: 14, color: Colors.cyanAccent),
                          const SizedBox(width: 6),
                          Text(
                            'Hotword Active: Say "$_activeHotwordPhrase"',
                            style: const TextStyle(
                                fontSize: 11,
                                color: Colors.cyanAccent,
                                fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      icon: Icon(
                          _isCameraStreaming
                              ? Icons.videocam
                              : Icons.videocam_outlined,
                          size: 16,
                          color: _isCameraStreaming ? Colors.tealAccent : null),
                      label: Text(
                          _isCameraStreaming
                              ? 'Stop Camera'
                              : 'Live Camera Vision',
                          style: TextStyle(
                              fontSize: 12,
                              color: _isCameraStreaming
                                  ? Colors.tealAccent
                                  : null)),
                      style: _isCameraStreaming
                          ? OutlinedButton.styleFrom(
                              side: const BorderSide(color: Colors.tealAccent))
                          : null,
                      onPressed: _toggleCameraStreaming,
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.screenshot_monitor_outlined,
                          size: 16),
                      label: const Text('Stream Screen Frame',
                          style: TextStyle(fontSize: 12)),
                      onPressed: _manualCaptureScreen,
                    ),
                    if (_toolHistory.isNotEmpty)
                      OutlinedButton.icon(
                        icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                        label: const Text('Clear Log',
                            style: TextStyle(fontSize: 12)),
                        onPressed: () => setState(() => _toolHistory.clear()),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),

        const Divider(height: 1),

        // Device Actions & Automation Feed
        Expanded(
          flex: 5,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.touch_app_outlined,
                            size: 18, color: Colors.cyanAccent),
                        const SizedBox(width: 8),
                        Text(
                          'Device Actions & Execution Log',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      '${_toolHistory.length} executed',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: _toolHistory.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.flash_on_outlined,
                                  size: 44, color: Colors.grey.shade600),
                              const SizedBox(height: 10),
                              const Text(
                                'No device actions recorded yet.',
                                style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color: Colors.grey),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Commands spoken via Device STT or sent to NVIDIA Nemotron automate app navigation, screen inspection, and device controls.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontSize: 12, color: Colors.grey.shade500),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          itemCount: _toolHistory.length,
                          itemBuilder: (ctx, idx) {
                            final item = _toolHistory[idx];
                            final isBlocked = item['status'] == 'blocked';
                            final isExecuting = item['status'] == 'executing';
                            final isError = item['status'] == 'error';
                            return Card(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              color: isBlocked
                                  ? Colors.red.withValues(alpha: 0.12)
                                  : isError
                                      ? Colors.orange.withValues(alpha: 0.12)
                                      : null,
                              child: ListTile(
                                dense: true,
                                leading: Icon(
                                  isBlocked
                                      ? Icons.block
                                      : isError
                                          ? Icons.error_outline
                                          : isExecuting
                                              ? Icons.sync
                                              : Icons.check_circle_outline,
                                  color: isBlocked
                                      ? Colors.redAccent
                                      : isError
                                          ? Colors.orangeAccent
                                          : isExecuting
                                              ? Colors.cyanAccent
                                              : Colors.greenAccent,
                                  size: 20,
                                ),
                                title: Text(
                                  item['tool'] as String,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold),
                                ),
                                subtitle: Text(
                                  () {
                                    if (isBlocked) {
                                      return 'Args: ${item['args']}\nBLOCKED by security guard';
                                    }
                                    if (isError) {
                                      final result = item['result'] as Map?;
                                      final errMsg =
                                          result?['error']?.toString() ??
                                              'Tool call failed';
                                      return 'Args: ${item['args']}\nERROR: $errMsg';
                                    }
                                    if (isExecuting) {
                                      return 'Args: ${item['args']}\nExecuting on device...';
                                    }
                                    return 'Args: ${item['args']}\nCompleted successfully';
                                  }(),
                                  style: const TextStyle(fontSize: 11),
                                ),
                                trailing:
                                    item['tool'] == 'remember' && !isBlocked
                                        ? TextButton(
                                            child: const Text('Undo',
                                                style: TextStyle(
                                                    fontSize: 11,
                                                    color: Colors.amberAccent)),
                                            onPressed: () {
                                              _dispatcher?.dispatch(
                                                  toolName: 'undo_last',
                                                  args: {});
                                            },
                                          )
                                        : null,
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPcApprovalsSection() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF2B1515),
        border: Border.all(color: Colors.redAccent, width: 1.5),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.redAccent.withValues(alpha: 0.2),
            blurRadius: 8,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.security, color: Colors.redAccent, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'PC Action Confirmation Needed',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      fontSize: 14),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.redAccent.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${_pendingPcApprovals.length} pending',
                  style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 11,
                      fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ..._pendingPcApprovals.map((appr) {
            final id = appr['id'] as String? ?? '';
            final tool = appr['tool'] as String? ?? 'dangerous_tool';
            final args = appr['args'] is Map ? appr['args'] as Map : {};
            return Container(
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.amberAccent.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          tool,
                          style: const TextStyle(
                              color: Colors.amberAccent,
                              fontFamily: 'monospace',
                              fontSize: 12,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                      const Spacer(),
                      Text(
                        id,
                        style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 10,
                            fontFamily: 'monospace'),
                      ),
                    ],
                  ),
                  if (args.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      args.entries
                          .map((e) => '${e.key}: ${e.value}')
                          .join(', '),
                      style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          fontFamily: 'monospace'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.redAccent,
                          side: const BorderSide(color: Colors.redAccent),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          minimumSize: const Size(60, 32),
                        ),
                        onPressed: () => _resolvePcApproval(id, false),
                        icon: const Icon(Icons.close, size: 14),
                        label:
                            const Text('Deny', style: TextStyle(fontSize: 12)),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green.shade700,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 4),
                          minimumSize: const Size(80, 32),
                        ),
                        onPressed: () => _resolvePcApproval(id, true),
                        icon: const Icon(Icons.check, size: 14),
                        label: const Text('Approve',
                            style: TextStyle(
                                fontSize: 12, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}
