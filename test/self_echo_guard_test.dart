import 'package:flutter_test/flutter_test.dart';
import 'package:device_assistant/core/audio/self_echo_guard.dart';

void main() {
  group('SelfEchoGuard', () {
    late DateTime clock;
    SelfEchoGuard guardWithClock() => SelfEchoGuard(
          lookback: const Duration(seconds: 8),
          now: () => clock,
        );

    setUp(() {
      clock = DateTime(2026, 10, 30, 12);
    });

    test('flags a transcript that repeats recent assistant speech', () {
      final guard = guardWithClock();
      guard.noteSpoken('Opening the computer settings for you.');

      expect(guard.isLikelyEcho('computer settings'), isTrue);
      expect(guard.isLikelyEcho('Computer  SETTINGS!'), isTrue);
    });

    test('keeps genuine user commands', () {
      final guard = guardWithClock();
      guard.noteSpoken('Opening the computer settings for you.');

      expect(guard.isLikelyEcho('hey assistant play music'), isFalse);
      expect(guard.isLikelyEcho('turn off wifi'), isFalse);
    });

    test('forgets speech older than the lookback window', () {
      final guard = guardWithClock();
      guard.noteSpoken('device assistant ready');

      clock = clock.add(const Duration(seconds: 9));

      expect(guard.isLikelyEcho('device assistant'), isFalse);
    });

    test('reset clears remembered speech', () {
      final guard = guardWithClock();
      guard.noteSpoken('jarvis is online');
      guard.reset();

      expect(guard.isLikelyEcho('jarvis'), isFalse);
    });

    test('ignores empty candidates and has no memory before first speech', () {
      final guard = guardWithClock();

      expect(guard.isLikelyEcho(''), isFalse);
      expect(guard.isLikelyEcho('hey assistant'), isFalse);
    });
  });
}
