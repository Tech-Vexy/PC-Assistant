import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:device_assistant/core/database/local_database.dart';
import 'package:device_assistant/core/security/sensitive_app_guard.dart';
import 'package:device_assistant/core/workflow/device_app_operator.dart';
import 'package:device_assistant/core/workflow/workflow_manager.dart';
import 'package:device_assistant/features/tools/tool_dispatcher.dart';
import 'package:device_assistant/platform/android/android_bridge.dart';

/// Mock AndroidBridge for testing layout inspection and UI automation
class MockAndroidBridge extends AndroidBridge {
  bool launchAppCalled = false;
  String? lastLaunchedApp;
  bool takeScreenshotCalled = false;
  bool dumpHierarchyCalled = false;
  List<Map<String, dynamic>> mockHierarchy = [];

  MockAndroidBridge() : super(isAndroid: true);

  @override
  Future<bool> launchApp(String appName) async {
    launchAppCalled = true;
    lastLaunchedApp = appName;
    return true;
  }

  @override
  Future<Uint8List?> takeScreenCapture() async {
    takeScreenshotCalled = true;
    // 1x1 dummy JPEG bytes
    return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]);
  }

  @override
  Future<List<Map<String, dynamic>>> dumpWindowHierarchy() async {
    dumpHierarchyCalled = true;
    return mockHierarchy;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LocalDatabase db;
  late SensitiveAppGuard guard;
  late MockAndroidBridge mockBridge;
  late HermesWorkflowManager hermes;
  late DeviceAppOperator operator;
  late ToolDispatcher dispatcher;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('device_app_op_test_');
    db = LocalDatabase();
    await db.initialize(baseDirectory: tempDir);
    guard = SensitiveAppGuard();
    mockBridge = MockAndroidBridge();
    hermes = HermesWorkflowManager(db);

    dispatcher = ToolDispatcher(
      db: db,
      guard: guard,
      androidBridge: mockBridge,
    );

    operator = DeviceAppOperator(
      androidBridge: mockBridge,
      db: db,
      hermesManager: hermes,
      dispatchStep: (tool, args) =>
          dispatcher.dispatch(toolName: tool, args: args),
    );
  });

  tearDown(() async {
    db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('DeviceAppOperator & Operate Dialer / Device Tests', () {
    test(
        'First run: captures screenshot & hierarchy to determine layout, executes, and saves workflow',
        () async {
      // Setup mock dialer layout in hierarchy
      mockBridge.mockHierarchy = [
        {
          'id': 'com.google.android.dialer:id/search_box',
          'text': 'Search contacts',
          'className': 'android.widget.EditText',
          'clickable': true,
        },
        {
          'id': 'com.google.android.dialer:id/dialpad_floating_action_button',
          'contentDescription': 'keypad',
          'className': 'android.widget.ImageButton',
          'clickable': true,
        },
        {
          'id': 'com.google.android.dialer:id/call_button',
          'contentDescription': 'Call',
          'className': 'android.widget.Button',
          'clickable': true,
        },
      ];

      final executedTools = <String>[];
      final testOperator = DeviceAppOperator(
        androidBridge: mockBridge,
        db: db,
        hermesManager: hermes,
        dispatchStep: (tool, args) async {
          executedTools.add(tool);
          return {'status': 'done', 'tool': tool};
        },
      );

      final res = await testOperator.operateApp(
        appName: 'Phone',
        goal: 'call contact',
        parameters: {'contact_name': 'Dad', 'sim_slot': 1},
      );

      expect(res['status'], equals('success'));
      expect(res['mode'], equals('learned_and_saved_workflow'));
      expect(mockBridge.launchAppCalled, isTrue);
      expect(mockBridge.takeScreenshotCalled, isTrue);
      expect(mockBridge.dumpHierarchyCalled, isTrue);

      // Verify the workflow was saved to the database
      final savedWorkflow = db.getWorkflow('workflow_phone_call_contact');
      expect(savedWorkflow, isNotNull);
      final steps = (savedWorkflow!['steps'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(steps.isNotEmpty, isTrue);

      // Verify tools executed
      expect(executedTools.contains('open_application'), isTrue);
      expect(executedTools.contains('input_text'), isTrue);
      expect(executedTools.contains('click_element'), isTrue);
    });

    test(
        'Second run: references and replays learned workflow with new parameters',
        () async {
      // Pre-save a learned workflow
      db.saveWorkflow('workflow_phone_call_contact', steps: [
        {
          'tool': 'remember',
          'args': {'key': 'called_contact', 'value': '{{contact_name}}'},
        },
        {
          'tool': 'remember',
          'args': {'key': 'called_sim', 'value': 'SIM {{sim_slot}}'},
        },
      ]);

      final res = await operator.operateApp(
        appName: 'Phone',
        goal: 'call contact',
        parameters: {'contact_name': 'Alice', 'sim_slot': 2},
      );

      expect(res['status'], equals('success'));
      expect(res['mode'], equals('replayed_workflow'));
      expect(res['workflow_name'], equals('workflow_phone_call_contact'));

      // Check substituted parameter values in database
      expect(db.recall('called_contact'), equals('Alice'));
      expect(db.recall('called_sim'), equals('SIM 2'));

      // Screenshot should NOT have been captured on replay
      expect(mockBridge.takeScreenshotCalled, isFalse);
    });

    test(
        'Operate dialer with phone number synthesizes dialpad actions and replays subsequently',
        () async {
      mockBridge.mockHierarchy = [
        {
          'id': 'com.google.android.dialer:id/dialpad_floating_action_button',
          'contentDescription': 'keypad',
          'className': 'android.widget.ImageButton',
        },
        {
          'id': 'com.google.android.dialer:id/digits',
          'className': 'android.widget.EditText',
        },
        {
          'id': 'com.google.android.dialer:id/call_button',
          'contentDescription': 'Call',
          'className': 'android.widget.Button',
        },
      ];

      final executedTools = <String>[];
      final testOperator = DeviceAppOperator(
        androidBridge: mockBridge,
        db: db,
        hermesManager: hermes,
        dispatchStep: (tool, args) async {
          executedTools.add(tool);
          return {'status': 'done', 'tool': tool};
        },
      );

      // First run with phone number
      final res = await testOperator.operateApp(
        appName: 'Phone',
        goal: 'call number',
        parameters: {'phone_number': '+123456789', 'sim_slot': 1},
      );

      expect(res['status'], equals('success'));
      expect(res['mode'], equals('learned_and_saved_workflow'));
      expect(executedTools.contains('open_application'), isTrue);
      expect(executedTools.contains('input_text'), isTrue);

      // Verify learned workflow exists
      final savedWorkflow = db.getWorkflow('workflow_phone_call_number');
      expect(savedWorkflow, isNotNull);

      // Next run should replay
      final replayRes = await testOperator.operateApp(
        appName: 'Phone',
        goal: 'call number',
        parameters: {'phone_number': '+987654321', 'sim_slot': 1},
      );

      expect(replayRes['status'], equals('success'));
      expect(replayRes['mode'], equals('replayed_workflow'));
    });

    test('ToolDispatcher dispatches operate_dialer as operate_device',
        () async {
      db.saveWorkflow('workflow_phone_call_contact', steps: [
        {
          'tool': 'remember',
          'args': {'key': 'dialer_called', 'value': '{{contact_name}}'},
        },
      ]);

      final res = await dispatcher.dispatch(
        toolName: 'operate_dialer',
        args: {
          'contact_name': 'Bob',
          'sim_slot': 1,
        },
      );

      expect(res['status'], equals('success'));
      expect(res['mode'], equals('replayed_workflow'));
      expect(db.recall('dialer_called'), equals('Bob'));
    });
  });
}
