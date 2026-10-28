import 'dart:convert';
import 'package:http/http.dart' as http;

/// Task complexity tier for dynamic model routing
enum TaskComplexity {
  /// Simple, fast, low-latency tasks routed to Nemotron-3-nano
  simple,

  /// Complex, multi-step, deep reasoning, or visual tasks routed to Nemotron-3-super-vl
  complex,
}

/// Client for Nebius Token Factory with smart routing across NVIDIA Nemotron models:
/// - Complex tasks (multi-step planning, visual inspection, deep sub-agent loops) -> Nemotron-3-super-vl
/// - Simple tasks (quick fact QA, memory extraction, status queries) -> Nemotron-3-nano
class NebiusClient {
  static const String defaultEndpoint = 'https://api.studio.nebius.ai/v1';
  static const String defaultSuperVlModel = 'nvidia/nemotron-3-super-vl';
  static const String defaultNanoModel = 'nvidia/nemotron-3-nano';

  final String apiKey;
  final String endpoint;
  final String superVlModel;
  final String nanoModel;
  final http.Client _httpClient;

  NebiusClient({
    required this.apiKey,
    this.endpoint = defaultEndpoint,
    this.superVlModel = defaultSuperVlModel,
    this.nanoModel = defaultNanoModel,
    String? model,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  /// Resolves the model identifier based on task complexity or explicit override
  String resolveModel({
    TaskComplexity complexity = TaskComplexity.simple,
    String? explicitModel,
  }) {
    if (explicitModel != null && explicitModel.isNotEmpty) {
      return explicitModel;
    }
    switch (complexity) {
      case TaskComplexity.complex:
        return superVlModel;
      case TaskComplexity.simple:
        return nanoModel;
    }
  }

  /// Evaluates prompt and context to determine whether a task is simple or complex
  static TaskComplexity classifyTask({
    required String taskDescription,
    int toolCount = 0,
    bool requiresMultiStep = false,
    bool hasVisualContext = false,
  }) {
    if (requiresMultiStep || hasVisualContext || toolCount > 4) {
      return TaskComplexity.complex;
    }

    final lower = taskDescription.toLowerCase();
    final complexKeywords = [
      'plan',
      'decompose',
      'step by step',
      'workflow',
      'orchestrat',
      'strategy',
      'deep analysis',
      'coordinate',
      'multi-step',
      'sub-agent',
      'hierarchy',
      'inspect screen',
    ];

    if (complexKeywords.any((kw) => lower.contains(kw))) {
      return TaskComplexity.complex;
    }

    return TaskComplexity.simple;
  }

  /// Executes a chat completion request with smart routing to Nemotron 3 super vl or nano
  Future<String> chatCompletion({
    required List<Map<String, dynamic>> messages,
    String? model,
    TaskComplexity complexity = TaskComplexity.simple,
    double temperature = 0.2,
    int maxTokens = 2048,
    Map<String, dynamic>? responseFormat,
  }) async {
    final selectedModel =
        resolveModel(complexity: complexity, explicitModel: model);
    final url = Uri.parse('$endpoint/chat/completions');

    final payload = {
      'model': selectedModel,
      'messages': messages,
      'temperature': temperature,
      'max_tokens': maxTokens,
      if (responseFormat != null) 'response_format': responseFormat,
    };

    final response = await _httpClient.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode(payload),
    );

    if (response.statusCode != 200) {
      throw Exception(
          'Nebius API error [${response.statusCode}]: ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final choices = data['choices'] as List<dynamic>?;
    if (choices == null || choices.isEmpty) {
      throw Exception('Empty completion response from Nebius');
    }

    final message = choices.first['message'] as Map<String, dynamic>;
    return (message['content'] as String?)?.trim() ?? '';
  }

  /// Multi-step task planner routed to Nemotron-3-super-vl.
  /// Decomposes complex user goals into structured JSON execution steps.
  Future<List<Map<String, dynamic>>> planTask({
    required String goal,
    required List<String> availableTools,
    String? platformContext,
  }) async {
    final systemPrompt = '''
You are the Planning Engine of Device Assistant powered by Nemotron-3-super-vl.
Decompose the user's goal into a structured JSON execution plan.
Return ONLY valid JSON matching this schema:
{
  "goal": "$goal",
  "steps": [
    {
      "step_id": 1,
      "tool": "tool_name",
      "args": { ... },
      "purpose": "Brief description of what this step accomplishes",
      "verify": "Verification condition to check success"
    }
  ]
}
Available tools: ${availableTools.join(', ')}
${platformContext != null ? 'Platform Context: $platformContext' : ''}
''';

    // Planning is complex: Smart route to Nemotron-3-super-vl
    final result = await chatCompletion(
      messages: [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': 'Plan this task: $goal'},
      ],
      complexity: TaskComplexity.complex,
      temperature: 0.1,
    );

    try {
      // Clean possible markdown code fences
      String cleanJson = result.trim();
      if (cleanJson.startsWith('```json')) {
        cleanJson = cleanJson.substring(7);
      }
      if (cleanJson.startsWith('```')) {
        cleanJson = cleanJson.substring(3);
      }
      if (cleanJson.endsWith('```')) {
        cleanJson = cleanJson.substring(0, cleanJson.length - 3);
      }
      cleanJson = cleanJson.trim();

      final parsed = jsonDecode(cleanJson) as Map<String, dynamic>;
      final steps =
          (parsed['steps'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ??
              [];
      return steps;
    } catch (_) {
      // Fallback single-step task
      return [
        {
          'step_id': 1,
          'tool': 'direct_execution',
          'args': {'raw_goal': goal},
          'purpose': goal,
        }
      ];
    }
  }

  /// Extracts durable user preferences, facts, or workflow routines
  /// routed to lightweight, fast Nemotron-3-nano.
  Future<Map<String, dynamic>?> extractMemory(String conversation) async {
    final prompt = '''
Analyze the following conversation turn. Did the user state an explicit preference,
home/work location, or automated routine that should be remembered?
If yes, return JSON:
{
  "should_remember": true,
  "key": "short_snake_case_key",
  "value": "clear description of preference or fact",
  "category": "preference|location|workflow"
}
If nothing durable to remember, return:
{
  "should_remember": false
}
Return ONLY valid JSON.
Conversation:
"$conversation"
''';

    // Memory extraction is simple classification: Smart route to Nemotron-3-nano
    final result = await chatCompletion(
      messages: [
        {'role': 'user', 'content': prompt},
      ],
      complexity: TaskComplexity.simple,
      temperature: 0.0,
    );

    try {
      String clean =
          result.replaceAll('```json', '').replaceAll('```', '').trim();
      final parsed = jsonDecode(clean) as Map<String, dynamic>;
      if (parsed['should_remember'] == true) {
        return parsed;
      }
    } catch (_) {}
    return null;
  }
}
