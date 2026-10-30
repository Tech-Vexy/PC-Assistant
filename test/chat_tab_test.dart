import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:device_assistant/features/ui/screens/chat_tab.dart';

void main() {
  group('ChatTab Widget Tests', () {
    testWidgets('renders empty state with quick suggestion chips',
        (tester) async {
      String? sentText;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatTab(
              messages: const [],
              onSendMessage: (text) async {
                sentText = text;
              },
            ),
          ),
        ),
      );

      expect(find.text('NVIDIA Nemotron On-Device Agent'), findsOneWidget);
      expect(find.text('System status'), findsOneWidget);
      expect(find.text('Take a screenshot'), findsOneWidget);

      // Tap suggestion chip
      await tester.tap(find.text('System status'));
      await tester.pumpAndSettle();

      expect(sentText, equals('System status'));
    });

    testWidgets('submits typed message via send button', (tester) async {
      String? sentText;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatTab(
              messages: const [],
              onSendMessage: (text) async {
                sentText = text;
              },
            ),
          ),
        ),
      );

      final inputFinder = find.byType(TextField);
      expect(inputFinder, findsOneWidget);

      await tester.enterText(inputFinder, 'Open Chrome');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pumpAndSettle();

      expect(sentText, equals('Open Chrome'));
    });

    testWidgets('renders user messages, assistant responses, and tool calls',
        (tester) async {
      final messages = [
        ChatMessage(
          id: '1',
          isUser: true,
          text: 'What is my battery level?',
          timestamp: DateTime.now(),
        ),
        ChatMessage(
          id: '2',
          isUser: false,
          text: 'Your battery level is 85%.',
          timestamp: DateTime.now(),
        ),
        ChatMessage(
          id: '3',
          isUser: false,
          text: 'Executed tool: system_status',
          timestamp: DateTime.now(),
          toolData: {
            'tool': 'system_status',
            'args': {},
            'status': 'done',
          },
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatTab(
              messages: messages,
              onSendMessage: (_) async {},
            ),
          ),
        ),
      );

      expect(find.text('What is my battery level?'), findsOneWidget);
      expect(find.text('Your battery level is 85%.'), findsOneWidget);
      expect(find.text('Device Tool: system_status'), findsOneWidget);
    });
  });
}
