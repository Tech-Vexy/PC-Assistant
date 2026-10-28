import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:device_assistant/platform/android/android_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.deviceassistant/bridge');
  final log = <MethodCall>[];

  setUp(() {
    log.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      log.add(methodCall);

      switch (methodCall.method) {
        case 'isAccessibilityEnabled':
          return true;
        case 'openAccessibilitySettings':
          return true;
        case 'clickByText':
          final text = methodCall.arguments['text'] as String?;
          return text == 'Submit';
        case 'injectTap':
          return true;
        case 'injectSwipe':
          return true;
        case 'performNavigation':
          return true;
        case 'dumpWindowHierarchy':
          return [
            {
              'className': 'android.widget.Button',
              'text': 'Login',
              'clickable': true,
              'bounds': {'left': 100, 'top': 200, 'right': 300, 'bottom': 250}
            }
          ];
        case 'getActivePackageName':
          return 'com.example.app';
        case 'startForegroundService':
          return true;
        case 'stopForegroundService':
          return true;
        case 'isBatteryOptimizationIgnored':
          return true;
        case 'requestIgnoreBatteryOptimization':
          return true;
        case 'launchApp':
          final pkg = methodCall.arguments['packageName'] as String?;
          return pkg == 'com.android.calculator';
        case 'updateTrayStatus':
          return true;
        case 'writeAudioChunk':
          return true;
        case 'flushAudio':
          return true;
        case 'takeScreenCapture':
          return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x00]);
        case 'inputText':
          return true;
        case 'scroll':
          return true;
        case 'updateProtectedPackages':
          return true;
        case 'minimizeApp':
          return true;
        case 'isNotificationPermissionGranted':
          return true;
        case 'requestNotificationPermission':
          return true;
        case 'isMicrophonePermissionGranted':
          return true;
        case 'requestMicrophonePermission':
          return true;
        case 'startHotwordListening':
          return true;
        case 'stopHotwordListening':
          return true;
        case 'isHotwordListening':
          return true;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('AndroidBridge Tests', () {
    test('Accessibility methods invoke correct platform calls', () async {
      final bridge = AndroidBridge(isAndroid: true);

      final enabled = await bridge.isAccessibilityEnabled();
      expect(enabled, isTrue);

      await bridge.openAccessibilitySettings();
      expect(log.any((call) => call.method == 'openAccessibilitySettings'),
          isTrue);

      final clickSuccess =
          await bridge.clickByText('Submit', viewId: 'btn_submit');
      expect(clickSuccess, isTrue);
      expect(
          log.any((call) =>
              call.method == 'clickByText' &&
              call.arguments['text'] == 'Submit' &&
              call.arguments['viewId'] == 'btn_submit'),
          isTrue);

      final clickFail = await bridge.clickByText('Cancel');
      expect(clickFail, isFalse);
    });

    test('Gesture and navigation methods invoke correct platform calls',
        () async {
      final bridge = AndroidBridge(isAndroid: true);

      final tapSuccess = await bridge.injectTap(150.0, 300.0);
      expect(tapSuccess, isTrue);
      expect(
          log.any((call) =>
              call.method == 'injectTap' &&
              call.arguments['x'] == 150.0 &&
              call.arguments['y'] == 300.0),
          isTrue);

      final swipeSuccess =
          await bridge.injectSwipe(100.0, 500.0, 100.0, 200.0, durationMs: 250);
      expect(swipeSuccess, isTrue);
      expect(
          log.any((call) =>
              call.method == 'injectSwipe' &&
              call.arguments['durationMs'] == 250),
          isTrue);

      final navSuccess = await bridge.performNavigation(2); // HOME
      expect(navSuccess, isTrue);
      expect(
          log.any((call) =>
              call.method == 'performNavigation' &&
              call.arguments['action'] == 2),
          isTrue);
    });

    test('Window hierarchy and active package inspection work properly',
        () async {
      final bridge = AndroidBridge(isAndroid: true);

      final hierarchy = await bridge.dumpWindowHierarchy();
      expect(hierarchy, isNotEmpty);
      expect(hierarchy.first['text'], 'Login');
      expect(hierarchy.first['clickable'], isTrue);

      final activePkg = await bridge.getActivePackageName();
      expect(activePkg, 'com.example.app');
    });

    test('Foreground service, tray, and battery optimization methods',
        () async {
      final bridge = AndroidBridge(isAndroid: true);

      await bridge.startForegroundService();
      expect(
          log.any((call) => call.method == 'startForegroundService'), isTrue);

      await bridge.updateTrayStatus(isActive: true, statusText: 'Listening...');
      expect(
          log.any((call) =>
              call.method == 'updateTrayStatus' &&
              call.arguments['isActive'] == true &&
              call.arguments['statusText'] == 'Listening...'),
          isTrue);

      final batteryIgnored = await bridge.isBatteryOptimizationIgnored();
      expect(batteryIgnored, isTrue);

      await bridge.requestIgnoreBatteryOptimization();
      expect(
          log.any((call) => call.method == 'requestIgnoreBatteryOptimization'),
          isTrue);

      final launched = await bridge.launchApp('com.android.calculator');
      expect(launched, isTrue);

      final launchFailed = await bridge.launchApp('com.nonexistent.app');
      expect(launchFailed, isFalse);

      await bridge.stopForegroundService();
      expect(log.any((call) => call.method == 'stopForegroundService'), isTrue);
    });

    test('Audio and screen capture methods work properly', () async {
      final bridge = AndroidBridge(isAndroid: true);

      final audioBytes = Uint8List.fromList([1, 2, 3, 4]);
      await bridge.writeAudioChunk(audioBytes);
      expect(log.any((call) => call.method == 'writeAudioChunk'), isTrue);

      await bridge.flushAudio();
      expect(log.any((call) => call.method == 'flushAudio'), isTrue);

      final screenBytes = await bridge.takeScreenCapture();
      expect(screenBytes, isNotNull);
      expect(screenBytes!.length, 5);
      expect(screenBytes[0], 0xFF);
    });

    test('Input text, scroll, and updateProtectedPackages methods', () async {
      final bridge = AndroidBridge(isAndroid: true);

      final inputSuccess =
          await bridge.inputText('Hello World', viewId: 'input_field');
      expect(inputSuccess, isTrue);
      expect(
          log.any((call) =>
              call.method == 'inputText' &&
              call.arguments['text'] == 'Hello World' &&
              call.arguments['viewId'] == 'input_field'),
          isTrue);

      final scrollSuccess = await bridge.scroll(forward: true);
      expect(scrollSuccess, isTrue);

      await bridge
          .updateProtectedPackages(['com.custom.secret', 'com.banking.app']);
      expect(
          log.any((call) =>
              call.method == 'updateProtectedPackages' &&
              (call.arguments['packages'] as List)
                  .contains('com.custom.secret')),
          isTrue);

      await bridge.minimizeApp();
      expect(log.any((call) => call.method == 'minimizeApp'), isTrue);

      final notifGranted = await bridge.isNotificationPermissionGranted();
      expect(notifGranted, isTrue);

      await bridge.requestNotificationPermission();
      expect(log.any((call) => call.method == 'requestNotificationPermission'),
          isTrue);

      final micGranted = await bridge.isMicrophonePermissionGranted();
      expect(micGranted, isTrue);

      await bridge.requestMicrophonePermission();
      expect(log.any((call) => call.method == 'requestMicrophonePermission'),
          isTrue);

      final hotwordStarted = await bridge
          .startHotwordListening(hotwords: ['hey assistant', 'ok google']);
      expect(hotwordStarted, isTrue);
      expect(
          log.any((call) =>
              call.method == 'startHotwordListening' &&
              (call.arguments['hotwords'] as List).contains('hey assistant')),
          isTrue);

      final isListening = await bridge.isHotwordListening();
      expect(isListening, isTrue);

      await bridge.stopHotwordListening();
      expect(log.any((call) => call.method == 'stopHotwordListening'), isTrue);
    });

    test(
        'Streams receive native callbacks for active package, shield alert, and tray actions',
        () async {
      final bridge = AndroidBridge(isAndroid: true);

      final activePackageFuture = bridge.activePackageStream.first;
      final shieldAlertFuture = bridge.shieldAlertStream.first;
      final trayActionFuture = bridge.trayActionStream.first;
      final hotwordFuture = bridge.hotwordStream.first;

      // Simulate native method call invocation from Kotlin to Dart
      final packageMessage = channel.codec.encodeMethodCall(
        const MethodCall('onActivePackageChanged', {
          'packageName': 'com.android.stk',
          'isProtected': true,
        }),
      );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
              channel.name, packageMessage, (ByteData? reply) {});

      final trayMessage = channel.codec.encodeMethodCall(
        const MethodCall('onTrayAction', {
          'action': 'toggle_voice',
        }),
      );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
              channel.name, trayMessage, (ByteData? reply) {});

      final hotwordMessage = channel.codec.encodeMethodCall(
        const MethodCall('onHotwordDetected', {
          'hotword': 'hey assistant',
          'command': 'open chrome',
        }),
      );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
              channel.name, hotwordMessage, (ByteData? reply) {});

      expect(await activePackageFuture, 'com.android.stk');
      expect(await shieldAlertFuture, 'com.android.stk');
      expect(await trayActionFuture, 'toggle_voice');
      final hotwordEvent = await hotwordFuture;
      expect(hotwordEvent['hotword'], 'hey assistant');
      expect(hotwordEvent['command'], 'open chrome');
    });
  });
}
