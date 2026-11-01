import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:device_assistant/core/database/local_database.dart';
import 'package:device_assistant/core/memory/memory_vector.dart';
import 'package:device_assistant/core/memory/memory_recall.dart';
import 'package:device_assistant/core/skills/skill_generator.dart';
import 'package:device_assistant/core/workflow/workflow_guard.dart';
import 'package:device_assistant/core/workflow/workflow_manager.dart';
import 'package:device_assistant/core/network/dartantic_firebase_agent.dart';
import 'package:device_assistant/core/security/sensitive_app_guard.dart';
import 'package:device_assistant/features/tools/tool_dispatcher.dart';

void main() {
  group('Memory Vector Engine Tests', () {
    test('generateEmbedding creates 128-D normalized vectors', () {
      final vec = MemoryVectorEngine.generateEmbedding(
          'User loves Flutter and mobile development');
      expect(vec.length, equals(128));

      // Check unit-norm: dot with self ~ 1.0
      final selfSim = MemoryVectorEngine.cosineSimilarity(vec, vec);
      expect((selfSim - 1.0).abs(), lessThan(0.01));
    });

    test('semantically similar texts score higher than dissimilar', () {
      final v1 = MemoryVectorEngine.generateEmbedding(
          'user prefers dark mode theme in ide');
      final v2 = MemoryVectorEngine.generateEmbedding(
          'user likes dark ui themes and night mode');
      final v3 = MemoryVectorEngine.generateEmbedding(
          'recipe for homemade chocolate chip cookies');

      final simClose = MemoryVectorEngine.cosineSimilarity(v1, v2);
      final simFar = MemoryVectorEngine.cosineSimilarity(v1, v3);

      expect(simClose, greaterThan(simFar));
    });

    test('serialization and deserialization roundtrip preserves values', () {
      final vec =
          MemoryVectorEngine.generateEmbedding('test memory serialization');
      final serialized = MemoryVectorEngine.serializeEmbedding(vec);
      final deserialized = MemoryVectorEngine.deserializeEmbedding(serialized);

      final sim = MemoryVectorEngine.cosineSimilarity(vec, deserialized);
      expect(sim, greaterThan(0.999));
    });
  });

  group('Rich Memory & Hybrid Recall Tests', () {
    late LocalDatabase db;
    late Directory tempDir;
    late MemoryRecallEngine recallEngine;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('assistant_memory_test_');
      db = LocalDatabase();
      await db.initialize(baseDirectory: tempDir);
      recallEngine = MemoryRecallEngine(db);
    });

    tearDown(() async {
      db.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
        'saveMemory deduplicates exact duplicates and performs FTS/vector indexing',
        () {
      final id1 = db.saveMemory(
        content: 'User is building an AI assistant for Android in Flutter',
        category: 'project',
        importance: 0.8,
        embedding: MemoryVectorEngine.serializeEmbedding(
          MemoryVectorEngine.generateEmbedding(
              'User is building an AI assistant for Android in Flutter'),
        ),
      );
      expect(id1, greaterThan(0));

      // Attempt exact duplicate
      final id2 = db.saveMemory(
        content: 'User is building an AI assistant for Android in Flutter',
        category: 'project',
      );
      expect(id2, equals(-1)); // Duplicate rejected

      // Recall via hybrid search
      final results =
          recallEngine.hybridRecall('What project is the user working on?');
      expect(results, isNotEmpty);
      expect(results.first.content, contains('AI assistant'));
    });

    test('forgetMemoriesMatching erases by natural language topic', () {
      db.saveMemory(
        content: 'User runs 5 kilometers every Tuesday morning in Nairobi',
        category: 'routine',
      );
      db.saveMemory(
        content: 'User drinks black coffee with oat milk',
        category: 'preference',
      );

      final count = recallEngine.forgetMemoriesMatching('running routine');
      expect(count, greaterThan(0));

      final remaining = db.listRichMemories();
      expect(remaining.any((m) => m['content'].toString().contains('Nairobi')),
          isFalse);
      expect(remaining.any((m) => m['content'].toString().contains('coffee')),
          isTrue);
    });

    test('repetition guard flags previous user queries across sessions', () {
      final sessionId = db.createConversationSession(title: 'Previous Session');
      db.addConversationMessage(
        sessionId: sessionId,
        role: 'user',
        content: 'Can you generate a summary of today sales report',
      );
      db.addConversationMessage(
        sessionId: sessionId,
        role: 'assistant',
        content:
            'Here is your sales report summary: Total revenue was \$5,400 with 42 units sold.',
      );

      final candidates = recallEngine.findPriorDeliverables(
        'generate a summary of today sales report',
        excludeSessionId: 9999,
      );

      expect(candidates, isNotEmpty);
      expect(candidates.first.assistantSummary, contains('revenue'));
    });
  });

  group('Dynamic Skill Parameterization Tests', () {
    test('applyParameters replaces dynamic template placeholders', () {
      final steps = [
        {
          'tool': 'web_search',
          'args': {'query': 'weather forecast for {{city}} today'},
        },
        {
          'tool': 'open_application',
          'args': {'app_name': '{{app}}'},
        }
      ];

      final parameterized = DynamicSkillGenerator.applyParameters(steps, {
        'city': 'Nairobi',
        'app': 'Google Calendar',
      });

      expect(parameterized[0]['args']['query'],
          equals('weather forecast for Nairobi today'));
      expect(parameterized[1]['args']['app_name'], equals('Google Calendar'));
    });
  });

  group('Hermes-Style Workflow Skill & Security Tests', () {
    late LocalDatabase db;
    late Directory tempDir;
    late HermesWorkflowManager workflowMgr;

    setUp(() async {
      tempDir =
          await Directory.systemTemp.createTemp('assistant_workflow_test_');
      db = LocalDatabase();
      await db.initialize(baseDirectory: tempDir);
      workflowMgr = HermesWorkflowManager(db);
    });

    tearDown(() async {
      db.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('WorkflowGuard blocks dangerous destructive commands', () {
      final safeScan = WorkflowGuard.scan(
        name: 'clean_cache',
        markdownContent: '# Clean Cache\nDeletes temporary app logs safely.',
        steps: [
          {'tool': 'system_status', 'args': <String, dynamic>{}}
        ],
      );
      expect(safeScan.isSafe, isTrue);

      final dangerousScan = WorkflowGuard.scan(
        name: 'wipe_system',
        markdownContent: 'rm -rf / --no-preserve-root',
      );
      expect(dangerousScan.isSafe, isFalse);
      expect(dangerousScan.violationReason, contains('failed security guard'));
    });

    test(
        'HermesWorkflowManager creates skills with frontmatter & progressive disclosure',
        () {
      final res = workflowMgr.saveSkill(
        name: 'morning_routine',
        description: 'Checks morning weather and agenda',
        markdownContent: '## Steps\n1. Search weather\n2. Open Calendar',
        version: '1.0.0',
        tags: ['routine', 'daily'],
      );
      expect(res['status'], equals('saved'));

      // Progressive disclosure L1 (summary list)
      final summaries = workflowMgr.listSkillsSummary();
      expect(summaries.length, equals(1));
      expect(summaries.first['name'], equals('morning_routine'));
      expect(summaries.first['description'],
          equals('Checks morning weather and agenda'));

      // Progressive disclosure L2 (full view)
      final view = workflowMgr.viewSkill('morning_routine');
      expect(view, isNotNull);
      expect(view!['content_markdown'], contains('name: morning_routine'));
    });

    test('patchSkill surgically modifies workflows and tracks version ledger',
        () {
      workflowMgr.saveSkill(
        name: 'audio_brief',
        description: 'Speaks notifications',
        markdownContent: '## Action\nPlay sound at volume 50%',
        version: '1.0.0',
      );

      final patchRes = workflowMgr.patchSkill(
        name: 'audio_brief',
        searchTarget: 'volume 50%',
        replacement: 'volume 80%',
        changeSummary: 'Increased audio alert volume',
      );
      expect(patchRes['status'], equals('patched'));
      expect(patchRes['new_version'], equals('1.0.1'));

      final view = workflowMgr.viewSkill('audio_brief');
      expect(view!['content_markdown'], contains('volume 80%'));

      // Check version ledger
      final history = db.getWorkflowVersions('audio_brief');
      expect(history.length, equals(2));
      expect(history.first['change_summary'],
          contains('Increased audio alert volume'));
    });

    test('rollbackSkill reverts workflow to previous ledger state', () {
      workflowMgr.saveSkill(
        name: 'data_sync',
        description: 'Synchronizes files',
        markdownContent: 'Version 1 Content',
        version: '1.0.0',
      );

      workflowMgr.patchSkill(
        name: 'data_sync',
        searchTarget: 'Version 1 Content',
        replacement: 'Broken Version 2 Content',
      );

      final history = db.getWorkflowVersions('data_sync');
      final originalVersionId = history.last['id'] as int;

      final rollbackRes =
          workflowMgr.rollbackSkill('data_sync', originalVersionId);
      expect(rollbackRes['status'], equals('rolled_back'));

      final current = workflowMgr.viewSkill('data_sync');
      expect(current!['content_markdown'], contains('Version 1 Content'));
    });
  });

  group('Dartantic Firebase Agent Adapter Tests', () {
    late LocalDatabase db;
    late Directory tempDir;
    late ToolDispatcher dispatcher;

    setUp(() async {
      tempDir =
          await Directory.systemTemp.createTemp('assistant_dartantic_test_');
      db = LocalDatabase();
      await db.initialize(baseDirectory: tempDir);
      dispatcher = ToolDispatcher(
        db: db,
        guard: SensitiveAppGuard(),
      );
    });

    tearDown(() async {
      db.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('DartanticFirebaseAgent initializes and executes tool-aware prompts',
        () async {
      final agent = DartanticFirebaseAgent(
        dispatcher: dispatcher,
        database: db,
        modelName: 'gemini-2.5-flash',
      );

      await agent.initialize();
      expect(agent.isReady, isTrue);

      final result = await agent.sendPrompt(
        prompt:
            'Remember: User prefers Dartantic for Flutter agent orchestration',
      );
      expect(result, contains('Memory stored via Dartantic'));

      final memories = db.listRichMemories();
      expect(memories.any((m) => m['content'].toString().contains('Dartantic')),
          isTrue);
    });
  });

  group('Telephony, Device Admin, and Contact Tools Tests', () {
    late LocalDatabase db;
    late Directory tempDir;
    late ToolDispatcher dispatcher;

    setUp(() async {
      tempDir =
          await Directory.systemTemp.createTemp('assistant_telephony_test_');
      db = LocalDatabase();
      await db.initialize(baseDirectory: tempDir);
      dispatcher = ToolDispatcher(
        db: db,
        guard: SensitiveAppGuard(),
      );
    });

    tearDown(() async {
      db.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
        'Telephony and contact tool dispatches gracefully handle missing bridge',
        () async {
      final contactsRes = await dispatcher.dispatch(
        toolName: 'get_contacts',
        args: {'query': 'Alice'},
      );
      expect(contactsRes.containsKey('error'), isTrue);

      final lockRes = await dispatcher.dispatch(
        toolName: 'lock_device',
        args: {},
      );
      expect(lockRes.containsKey('error'), isTrue);
    });
  });
}
