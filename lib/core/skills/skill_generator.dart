import 'dart:convert';
import '../network/gemini_live_client.dart';
import '../network/nebius_client.dart';

/// A dynamically generated, parameterized workflow skill.
class SkillDefinition {
  final String name;
  final String description;
  final List<String> parameters; // Named slots that can be filled at runtime
  final List<Map<String, dynamic>> steps; // Tool call steps
  final String generatedBy; // 'ai' | 'learned' | 'manual'
  final DateTime createdAt;

  const SkillDefinition({
    required this.name,
    required this.description,
    required this.parameters,
    required this.steps,
    required this.generatedBy,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'parameters': parameters,
        'steps': steps,
        'generated_by': generatedBy,
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  factory SkillDefinition.fromJson(Map<String, dynamic> json) {
    return SkillDefinition(
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
      parameters: (json['parameters'] as List<dynamic>? ?? []).cast<String>(),
      steps: (json['steps'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>(),
      generatedBy: json['generated_by'] as String? ?? 'ai',
      createdAt: DateTime.fromMillisecondsSinceEpoch(
          json['created_at'] as int? ?? DateTime.now().millisecondsSinceEpoch),
    );
  }
}

const _skillGenerationSystemPrompt = '''
You are a skill synthesis engine for a cross-platform device assistant.
Convert a natural language description of a task into an executable workflow.

Available tools (use only these):
- system_status: {}
- remember: {key, value, category?}
- recall: {key}
- list_memories: {category?}
- open_application: {app_name?, package_name?}
- run_shell_command: {command} [desktop only]
- inspect_screen: {query?}
- click_element: {text} [Android]
- touch_gesture: {type, x?, y?, startX?, startY?, endX?, endY?} [Android]
- input_text: {text} [Android]
- navigate: {action} [Android]
- scroll_screen: {direction?} [Android]
- web_search: {query}
- run_workflow: {name}
- save_workflow: {name, description?, steps}

Output a JSON object:
{
  "name": "snake_case_skill_name",
  "description": "One sentence describing what this skill does",
  "parameters": ["param_name_1", "param_name_2"],
  "steps": [
    {
      "tool": "tool_name",
      "args": {"arg": "value or {{param_name}} placeholder"},
      "purpose": "why this step exists"
    }
  ]
}

Rules:
- Use {{param_name}} placeholders for dynamic values (e.g., {{app_name}}, {{query}})
- Steps must be sequential and each must use a tool from the list above
- Keep steps minimal — prefer 2-5 steps
- Return ONLY the JSON object, no markdown or extra text
''';

const _skillLearnSystemPrompt = '''
You are a skill synthesis engine. Given a sequence of tool calls observed
during a user interaction, synthesize them into a named, reusable workflow skill.

Output a JSON object:
{
  "name": "snake_case_skill_name",
  "description": "One sentence describing what this skill does",
  "parameters": [],
  "steps": [
    {
      "tool": "tool_name",
      "args": {"arg": "value"},
      "purpose": "why this step exists"
    }
  ]
}

Return ONLY the JSON object, no markdown or extra text.
''';

/// AI-driven skill (workflow) generator.
///
/// Converts natural language task descriptions or observed tool-call sequences
/// into parameterized, reusable workflow skill definitions that can be saved
/// and run via the existing WorkflowSchedulerService.
class DynamicSkillGenerator {
  final GeminiLiveClient? geminiClient;
  final NebiusClient? nebiusClient;

  const DynamicSkillGenerator({this.geminiClient, this.nebiusClient});

  bool get _hasLlm => geminiClient != null || nebiusClient != null;

  /// Generates a skill from a natural language [description].
  ///
  /// Example: "Every morning, check the weather for Nairobi and open my calendar"
  /// Returns a [SkillDefinition] ready to save as a workflow.
  Future<SkillDefinition?> generateFromDescription({
    required String description,
    bool isAndroid = false,
  }) async {
    if (!_hasLlm) return null;

    final platformHint = isAndroid
        ? 'Target platform: Android mobile. Use Android-specific tools.'
        : 'Target platform: Desktop (Linux/Windows/macOS). Use shell commands.';

    final prompt = '$platformHint\n\nTask description: $description';

    try {
      final raw = await _callLlm(
        systemPrompt: _skillGenerationSystemPrompt,
        userMessage: prompt,
        temperature: 0.3,
      );
      final def = _parseSkillDefinition(raw, generatedBy: 'ai');
      return def;
    } catch (_) {
      return null;
    }
  }

  /// Learns a skill from a sequence of observed tool calls.
  ///
  /// [history] is a list of `{tool, args, result}` maps from recent interactions.
  /// [skillName] is the desired name for the generated skill.
  Future<SkillDefinition?> learnFromHistory({
    required List<Map<String, dynamic>> history,
    required String skillName,
  }) async {
    if (!_hasLlm || history.isEmpty) return null;

    final toolCallLog = history
        .map((h) => '- ${h['tool']}: ${jsonEncode(h['args'])}')
        .join('\n');

    final prompt = '''
Skill name hint: "$skillName"
Observed tool call sequence:
$toolCallLog

Synthesize these into a reusable workflow skill.
''';

    try {
      final raw = await _callLlm(
        systemPrompt: _skillLearnSystemPrompt,
        userMessage: prompt,
        temperature: 0.2,
      );      return _parseSkillDefinition(raw, generatedBy: 'learned');
    } catch (_) {
      return null;
    }
  }

  /// Applies parameter values to a skill's step args, replacing {{placeholder}} tokens.
  ///
  /// Example: args={'query': '{{city}} weather'} with params={'city': 'Nairobi'}
  ///          → args={'query': 'Nairobi weather'}
  static List<Map<String, dynamic>> applyParameters(
    List<Map<String, dynamic>> steps,
    Map<String, String> params,
  ) {
    return steps.map((step) {
      final args = Map<String, dynamic>.from(step['args'] as Map? ?? {});
      final resolved = args.map((k, v) {
        if (v is String) {
          String result = v;
          for (final entry in params.entries) {
            result = result.replaceAll('{{${entry.key}}}', entry.value);
          }
          return MapEntry(k, result);
        }
        return MapEntry(k, v);
      });
      return {
        ...step,
        'args': resolved,
      };
    }).toList();
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  Future<String> _callLlm({
    required String systemPrompt,
    required String userMessage,
    double temperature = 0.3,
  }) async {
    if (geminiClient != null) {
      return geminiClient!.generateContent(
        prompt: userMessage,
        systemInstruction: systemPrompt,
        temperature: temperature,
      );
    }
    return nebiusClient!.chatCompletion(
      messages: [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': userMessage},
      ],
      temperature: temperature,
      maxTokens: 1024,
    );
  }

  SkillDefinition? _parseSkillDefinition(String raw, {required String generatedBy}) {
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start == -1 || end <= start) return null;

    try {
      final obj = jsonDecode(raw.substring(start, end + 1)) as Map<String, dynamic>;
      final steps = (obj['steps'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      if (steps.isEmpty) return null;

      return SkillDefinition(
        name: (obj['name'] as String? ?? 'generated_skill')
            .replaceAll(RegExp(r'[^a-z0-9_]'), '_')
            .toLowerCase(),
        description: obj['description'] as String? ?? '',
        parameters: (obj['parameters'] as List<dynamic>? ?? []).cast<String>(),
        steps: steps,
        generatedBy: generatedBy,
        createdAt: DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }
}
