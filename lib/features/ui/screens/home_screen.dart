import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../../../core/agent/dartantic_agent.dart';
import '../../../core/audio/audio_playback_service.dart';
import '../../../core/audio/audio_recording_service.dart';
import '../../../core/database/local_database.dart';
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

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
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
  String? _activePackage;
  bool _isAccessibilityEnabled = false;
  bool _isBatteryOptimizationIgnored = true;
  final List<String> _transcripts = [];
  final List<Map<String, dynamic>> _toolHistory = [];

  StreamSubscription? _transcriptSub;
  StreamSubscription? _toolCallSub;
  StreamSubscription? _connSub;
  StreamSubscription? _activePackageSub;
  StreamSubscription? _shieldAlertSub;
  StreamSubscription? _trayActionSub;
  StreamSubscription? _audioOutputSub;
  StreamSubscription? _interruptionSub;
  StreamSubscription? _hotwordSub;

  List<Map<String, dynamic>> _pendingPcApprovals = [];
  Timer? _approvalPollTimer;
  StreamSubscription? _pcEventsSub;

  late final CameraStreamingService _cameraStreaming;
  WorkflowSchedulerService? _workflowScheduler;
  bool _isCameraStreaming = false;
  StreamSubscription? _cameraStreamSub;

  bool _isHotwordActive = false;
  String _activeHotwordPhrase = 'hey assistant';

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
    if (state == AppLifecycleState.resumed && Platform.isAndroid && _androidBridge != null) {
      _checkAndroidPermissions();
    }
  }

  Future<void> _checkAndroidPermissions() async {
    if (_androidBridge == null) return;
    final access = await _androidBridge!.isAccessibilityEnabled();
    final battery = await _androidBridge!.isBatteryOptimizationIgnored();
    if (mounted) {
      setState(() {
        _isAccessibilityEnabled = access;
        _isBatteryOptimizationIgnored = battery;
      });
    }
  }

  Future<void> _initClients() async {
    final geminiKey = await widget.keyVault.getGeminiApiKey();
    final nebiusKey = await widget.keyVault.getNebiusApiKey();

    if (nebiusKey != null && nebiusKey.isNotEmpty) {
      final endpoint = await widget.keyVault.getNebiusEndpoint();
      final superModel = await widget.keyVault.getNebiusSuperModel();
      final nanoModel = await widget.keyVault.getNebiusNanoModel();
      _nebiusClient = NebiusClient(
        apiKey: nebiusKey,
        endpoint: endpoint,
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
      _isBatteryOptimizationIgnored = await _androidBridge!.isBatteryOptimizationIgnored();
      await _androidBridge!.startForegroundService();
      await _androidBridge!.updateProtectedPackages(widget.guard.customProtectedPackages.toList());

      final notifGranted = await _androidBridge!.isNotificationPermissionGranted();
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
          _toggleConnection();
        } else if (action == 'exit') {
          _liveClient?.disconnect();
          _audioRecorder.stopStreaming();
        }
      });

      // Always-On On-Device Hotword Detection ("Hey Assistant", "OK Google")
      final hotwordEnabled = await widget.keyVault.isHotwordEnabled();
      _activeHotwordPhrase = await widget.keyVault.getCustomHotword();
      if (hotwordEnabled) {
        _isHotwordActive = true;
        await _androidBridge!.startHotwordListening(
          hotwords: [_activeHotwordPhrase, 'hey assistant', 'ok google', 'device assistant', 'computer'],
        );
      }
      _hotwordSub?.cancel();
      _hotwordSub = _androidBridge!.hotwordStream.listen(_handleHotwordDetected);
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

    if (geminiKey != null && geminiKey.isNotEmpty) {
      _setupGeminiClient(geminiKey);
    }
  }

  void _setupGeminiClient(String apiKey) {
    _liveClient?.dispose();
    _liveClient = GeminiLiveClient(
      apiKey: apiKey,
      toolDeclarations: ToolDefinitions.getAllDeclarations(isAndroid: Theme.of(context).platform == TargetPlatform.android),
      systemInstruction: '''
You are Device Assistant, an intelligent cross-platform agent running natively on the device.
You have tool access to device controls, memory, task planning, and sub-agents.
When the user asks to plan a complex multi-step task, use the plan_task tool.
When the user gives a preference or location, remember it using remember.
When asked to observe or inspect what is currently on the screen, use capture_screen or inspect_screen.
For autonomous sub-tasks, you can spawn specialized sub-agents with scoped tools using spawn_agent.
Sensitive apps (banking, SIM toolkit, 2FA) are strictly guarded.
''',
    );

    _transcriptSub = _liveClient!.transcriptStream.listen((text) {
      setState(() {
        _transcripts.add(text);
      });
    });

    _audioOutputSub = _liveClient!.audioOutputStream.listen((chunk) {
      _audioPlayback?.playChunk(chunk);
    });

    _interruptionSub = _liveClient!.interruptionStream.listen((_) {
      _audioPlayback?.flush();
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
          _toolHistory[0]['status'] = result.containsKey('blocked') ? 'blocked' : 'done';
          _toolHistory[0]['result'] = result;
        }
      });

      _liveClient!.sendToolResponse(
        callId: event.callId,
        result: result,
      );
    });

    _connSub = _liveClient!.connectionStateStream.listen((connected) {
      setState(() {
        _isConnected = connected;
        _isConnecting = false;
      });
      _androidBridge?.updateTrayStatus(isActive: connected);
    });
  }

  void _handleHotwordDetected(Map<String, String?> event) async {
    final hotword = event['hotword'] ?? 'hey assistant';
    final command = event['command'];

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.indigo.shade800,
          duration: const Duration(seconds: 3),
          content: Row(
            children: [
              const Icon(Icons.bolt, color: Colors.amberAccent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  command != null && command.isNotEmpty
                      ? 'Heard: "$hotword, $command"'
                      : 'Hotword: "$hotword" detected! Listening...',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (!_isConnected) {
      await _toggleConnection();
    }

    if (command != null && command.isNotEmpty) {
      final cleanCommand = command.trim();
      final lower = cleanCommand.toLowerCase();

      // Check if command is a direct local device shortcut
      if (lower.startsWith('open ')) {
        final app = cleanCommand.substring(5).trim();
        _dispatcher?.dispatch(toolName: 'open_application', args: {'app_name': app});
      } else if (lower == 'take a screenshot' || lower == 'take screenshot' || lower == 'screenshot' || lower == 'capture screen') {
        _dispatcher?.dispatch(toolName: 'capture_screen', args: {});
      } else if (lower == 'scroll down') {
        _dispatcher?.dispatch(toolName: 'scroll', args: {'forward': true});
      } else if (lower == 'scroll up') {
        _dispatcher?.dispatch(toolName: 'scroll', args: {'forward': false});
      } else if (lower == 'go back' || lower == 'press back' || lower == 'back') {
        _dispatcher?.dispatch(toolName: 'perform_navigation', args: {'action': 1});
      } else if (lower == 'go home' || lower == 'press home' || lower == 'home') {
        _dispatcher?.dispatch(toolName: 'perform_navigation', args: {'action': 2});
      } else if (lower == 'show recents' || lower == 'recent apps' || lower == 'recents') {
        _dispatcher?.dispatch(toolName: 'perform_navigation', args: {'action': 3});
      } else {
        // Compound natural language request - forward directly as user turn to Gemini Live
        setState(() {
          _transcripts.add('User: $cleanCommand');
        });
        Future.delayed(const Duration(milliseconds: 700), () {
          _liveClient?.sendTextMessage(cleanCommand);
        });
      }
    }
  }

  Future<void> _toggleConnection() async {
    if (_isConnected) {
      await _audioRecorder.stopStreaming();
      await _liveClient?.disconnect();
      // Resume idle hotword detection if active
      if (Platform.isAndroid && _androidBridge != null && _isHotwordActive) {
        await _androidBridge!.startHotwordListening(
          hotwords: [_activeHotwordPhrase, 'hey assistant', 'ok google', 'device assistant', 'computer'],
        );
      }
    } else {
      // Pause idle hotword detector before capturing audio stream for Gemini Live
      if (Platform.isAndroid && _androidBridge != null) {
        await _androidBridge!.stopHotwordListening();
      }
      final geminiKey = await widget.keyVault.getGeminiApiKey();
      if (geminiKey == null || geminiKey.isEmpty) {
        _showKeyDialog();
        return;
      }
      setState(() => _isConnecting = true);
      _setupGeminiClient(geminiKey);
      await _liveClient?.connect();
      await _audioRecorder.startStreaming(
        onAudioChunk: (chunk) {
          _liveClient?.sendAudioChunk(chunk);
        },
      );
    }
  }

  void _showKeyDialog() {
    final geminiCtrl = TextEditingController();
    final nebiusCtrl = TextEditingController();

    widget.keyVault.getGeminiApiKey().then((val) => geminiCtrl.text = val ?? '');
    widget.keyVault.getNebiusApiKey().then((val) => nebiusCtrl.text = val ?? '');

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
                  const SnackBar(content: Text('Keys securely saved to hardware keystore.')),
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
            content: Text('Sensitive app active (${_activePackage ?? "Protected"}). Screen capture shielded.'),
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
            _transcripts.add('[Visual screen frame captured and streamed to Gemini Live]');
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
              content: Text('Screen capture unavailable or blocked by Android FLAG_SECURE.'),
            ),
          );
        }
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Screen capture frame available on Android (API 30+).'),
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
          backgroundColor: approved ? Colors.green.shade800 : Colors.red.shade800,
          content: Text(
            approved
                ? (ok ? 'Approved PC dangerous action' : 'Failed to approve action')
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
          const SnackBar(content: Text('Connect to Gemini Live before streaming camera vision.')),
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
        bodyContent = MemoriesTab(database: widget.database, keyVault: widget.keyVault);
        break;
      case 2:
        bodyContent = _dispatcher != null
            ? PlansWorkflowsTab(database: widget.database, dispatcher: _dispatcher!)
            : const Center(child: CircularProgressIndicator());
        break;
      case 3:
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
            const Text('Device Assistant', style: TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _isConnected ? Colors.green.withValues(alpha: 0.15) : Colors.grey.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _isConnected ? Colors.green : Colors.grey),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: 4,
                    backgroundColor: _isConnected ? Colors.green : Colors.grey,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _isConnected ? 'Gemini Live Active' : 'Disconnected',
                    style: TextStyle(
                      fontSize: 12,
                      color: _isConnected ? Colors.green : Colors.grey,
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
        onDestinationSelected: (idx) => setState(() => _activeTabIndex = idx),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.mic_outlined),
            selectedIcon: Icon(Icons.mic),
            label: 'Voice',
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
                  const Icon(Icons.battery_alert, color: Colors.amberAccent, size: 20),
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
                      final ignored = await _androidBridge?.isBatteryOptimizationIgnored() ?? false;
                      setState(() => _isBatteryOptimizationIgnored = ignored);
                    },
                    child: const Text('Disable', style: TextStyle(color: Colors.amberAccent)),
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
                  const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Accessibility Service disabled. Enable to allow mobile app automation.',
                      style: TextStyle(fontSize: 12, color: Colors.white),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _androidBridge?.openAccessibilitySettings(),
                    child: const Text('Enable', style: TextStyle(color: Colors.redAccent)),
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
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
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
          if (_pendingPcApprovals.isNotEmpty)
            _buildPcApprovalsSection(),

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
                      final scale = _isConnected ? 1.0 + (_orbController.value * 0.12) : 1.0;
                      return Transform.scale(
                        scale: scale,
                        child: Container(
                          width: 140,
                          height: 140,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: _isConnected
                                  ? [Colors.cyanAccent, Colors.indigo, Colors.blueAccent]
                                  : [Colors.grey.shade400, Colors.grey.shade700],
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: _isConnected
                                    ? Colors.cyanAccent.withValues(alpha: 0.4)
                                    : Colors.black12,
                                blurRadius: _isConnected ? 30 : 10,
                                spreadRadius: _isConnected ? 8 : 2,
                              ),
                            ],
                          ),
                          child: IconButton(
                            iconSize: 48,
                            icon: _isConnecting
                                ? const CircularProgressIndicator(color: Colors.white)
                                : Icon(
                                    _isConnected ? Icons.mic : Icons.mic_none,
                                    color: Colors.white,
                                  ),
                            onPressed: _toggleConnection,
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 20),
                  Text(
                    _isConnected ? 'Listening & Conversing with Gemini Live' : 'Tap Orb to Start Assistant',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Smart Routing: Nemotron 3 super vl & nano | Encrypted Local DB',
                    style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
                  ),
                  if (Platform.isAndroid && _isHotwordActive && !_isConnected)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                        decoration: BoxDecoration(
                          color: Colors.indigo.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.cyanAccent.withValues(alpha: 0.3)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.hearing, size: 14, color: Colors.cyanAccent),
                            const SizedBox(width: 6),
                            Text(
                              'Hotword Active: Say "$_activeHotwordPhrase"',
                              style: const TextStyle(fontSize: 11, color: Colors.cyanAccent, fontWeight: FontWeight.w500),
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
                        icon: Icon(_isCameraStreaming ? Icons.videocam : Icons.videocam_outlined,
                            size: 16, color: _isCameraStreaming ? Colors.tealAccent : null),
                        label: Text(_isCameraStreaming ? 'Stop Camera' : 'Live Camera Vision',
                            style: TextStyle(fontSize: 12, color: _isCameraStreaming ? Colors.tealAccent : null)),
                        style: _isCameraStreaming
                            ? OutlinedButton.styleFrom(side: const BorderSide(color: Colors.tealAccent))
                            : null,
                        onPressed: _toggleCameraStreaming,
                      ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.screenshot_monitor_outlined, size: 16),
                        label: const Text('Stream Screen Frame', style: TextStyle(fontSize: 12)),
                        onPressed: _manualCaptureScreen,
                      ),
                      if (_transcripts.isNotEmpty)
                        OutlinedButton.icon(
                          icon: const Icon(Icons.clear_all, size: 16),
                          label: const Text('Clear Log', style: TextStyle(fontSize: 12)),
                          onPressed: () => setState(() => _transcripts.clear()),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const Divider(height: 1),

          // Live Transcript & Action Stream
          Expanded(
            flex: 5,
            child: Row(
              children: [
                // Transcript column
                Expanded(
                  flex: 3,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Live Transcript', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        const SizedBox(height: 8),
                        Expanded(
                          child: _transcripts.isEmpty
                              ? const Center(
                                  child: Text('Spoken responses will appear here.', style: TextStyle(color: Colors.grey)),
                                )
                              : ListView.builder(
                                  itemCount: _transcripts.length,
                                  itemBuilder: (ctx, idx) => Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 4),
                                    child: Text(_transcripts[idx]),
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
                ),

                const VerticalDivider(width: 1),

                // Tool Execution Feed
                Expanded(
                  flex: 2,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Tool Execution & Audit', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        const SizedBox(height: 8),
                        Expanded(
                          child: _toolHistory.isEmpty
                              ? const Center(
                                  child: Text('Tool calls will appear here.', style: TextStyle(color: Colors.grey)),
                                )
                              : ListView.builder(
                                  itemCount: _toolHistory.length,
                                  itemBuilder: (ctx, idx) {
                                    final item = _toolHistory[idx];
                                    final isBlocked = item['status'] == 'blocked';
                                    return Card(
                                      color: isBlocked ? Colors.red.withValues(alpha: 0.1) : null,
                                      child: ListTile(
                                        dense: true,
                                        leading: Icon(
                                          isBlocked ? Icons.block : Icons.build_outlined,
                                          color: isBlocked ? Colors.red : Colors.indigo,
                                          size: 18,
                                        ),
                                        title: Text(item['tool'] as String, style: const TextStyle(fontWeight: FontWeight.bold)),
                                        subtitle: Text(
                                          isBlocked ? 'Blocked by sensitive app guard' : 'Executed successfully',
                                          style: TextStyle(
                                            color: isBlocked ? Colors.red : Colors.green,
                                            fontSize: 11,
                                          ),
                                        ),
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
                  style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14),
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
                  style: const TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.bold),
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
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.amberAccent.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          tool,
                          style: const TextStyle(color: Colors.amberAccent, fontFamily: 'monospace', fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ),
                      const Spacer(),
                      Text(
                        id,
                        style: const TextStyle(color: Colors.grey, fontSize: 10, fontFamily: 'monospace'),
                      ),
                    ],
                  ),
                  if (args.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      args.entries.map((e) => '${e.key}: ${e.value}').join(', '),
                      style: const TextStyle(color: Colors.white70, fontSize: 11, fontFamily: 'monospace'),
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
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          minimumSize: const Size(60, 32),
                        ),
                        onPressed: () => _resolvePcApproval(id, false),
                        icon: const Icon(Icons.close, size: 14),
                        label: const Text('Deny', style: TextStyle(fontSize: 12)),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green.shade700,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          minimumSize: const Size(80, 32),
                        ),
                        onPressed: () => _resolvePcApproval(id, true),
                        icon: const Icon(Icons.check, size: 14),
                        label: const Text('Approve', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
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
