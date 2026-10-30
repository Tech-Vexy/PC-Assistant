import 'dart:convert';
import 'package:http/http.dart' as http;

/// Task complexity tier for dynamic model routing
enum TaskComplexity {
  /// Simple, fast, low-latency tasks routed to Nemotron-3-Nano-30B
  simple,

  /// Complex, multi-step, deep reasoning, or visual tasks routed to Nemotron-3.5-Super-VL
  complex,
}

/// Client for Nebius Token Factory with smart routing across NVIDIA Nemotron models:
/// - Complex tasks (multi-step planning, visual inspection, deep sub-agent loops) -> Nemotron 3.5 Super VL
/// - Simple tasks (quick fact QA, memory extraction, status queries) -> Nemotron 3 Nano 30B
///
/// Nebius deployments are region-agnostic (https://tokenfactory.nebius.com/endpoints),
/// and each model tier supports its own dedicated or serverless endpoint.
class NebiusClient {
  static const String defaultEndpoint =
      'https://api.tokenfactory.nebius.com/v1';
  static const String studioEndpoint = 'https://api.studio.nebius.ai/v1';

  static const String defaultSuperVlModel = 'nvidia/Nemotron-3.5-Super-VL';
  static const String defaultNanoModel =
      'nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B';

  /// Catalog of curated NVIDIA Nemotron models hosted on Nebius Token Factory
  static const List<String> availableNvidiaModels = [
    'nvidia/Nemotron-3.5-Super-VL',
    'nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B',
    'nvidia/nemotron-3-super-120b-a12b',
    'nvidia/Nemotron-3-Ultra-550b-a55b',
    'nvidia/Nemotron-3_5-Lightning',
  ];

  final String apiKey;
  final String superVlEndpoint;
  final String nanoEndpoint;
  final String superVlModel;
  final String nanoModel;
  final http.Client _httpClient;

  NebiusClient({
    required this.apiKey,
    String? endpoint,
    String? superVlEndpoint,
    String? nanoEndpoint,
    String? superVlModel,
    String? nanoModel,
    String? model,
    http.Client? httpClient,
  })  : superVlEndpoint =
            normalizeEndpoint(superVlEndpoint ?? endpoint ?? defaultEndpoint),
        nanoEndpoint =
            normalizeEndpoint(nanoEndpoint ?? endpoint ?? defaultEndpoint),
        superVlModel =
            normalizeModel(superVlModel ?? model ?? defaultSuperVlModel),
        nanoModel = normalizeModel(nanoModel ?? model ?? defaultNanoModel),
        _httpClient = httpClient ?? http.Client();

  /// Legacy general endpoint getter
  String get endpoint => superVlEndpoint;

  /// Strips trailing slashes from endpoint URLs
  static String normalizeEndpoint(String ep) {
    var clean = ep.trim();
    while (clean.endsWith('/')) {
      clean = clean.substring(0, clean.length - 1);
    }
    return clean;
  }

  /// Maps common user-friendly model aliases to official Nebius model identifiers
  static String normalizeModel(String rawModel) {
    final lower = rawModel.trim().toLowerCase();

    if (lower == 'nemotron-3-nano-30b' ||
        lower == 'nemotron 3 nano 30b' ||
        lower == 'nemotron-3-nano' ||
        lower == 'nvidia/nemotron-3-nano' ||
        lower == 'nvidia/nemotron-3-nano-30b' ||
        lower.contains('nano-30b') ||
        lower.contains('nano_30b')) {
      return 'nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B';
    }

    if (lower == 'nemotron 3.5 super vl' ||
        lower == 'nemotron-3.5-super-vl' ||
        lower == 'nemotron-3-super-vl' ||
        lower == 'nvidia/nemotron-3-super-vl' ||
        lower == 'nvidia/nemotron-3.5-super-vl' ||
        lower.contains('super-vl') ||
        lower.contains('super_vl')) {
      return 'nvidia/Nemotron-3.5-Super-VL';
    }

    if (lower.contains('lightning')) {
      return 'nvidia/Nemotron-3_5-Lightning';
    }

    if (lower.contains('120b')) {
      return 'nvidia/nemotron-3-super-120b-a12b';
    }

    if (lower.contains('550b') || lower.contains('ultra')) {
      return 'nvidia/Nemotron-3-Ultra-550b-a55b';
    }

    return rawModel.trim();
  }

  /// Resolves the endpoint based on task complexity or explicit override
  String resolveEndpoint({
    TaskComplexity complexity = TaskComplexity.simple,
    String? explicitEndpoint,
  }) {
    if (explicitEndpoint != null && explicitEndpoint.isNotEmpty) {
      return normalizeEndpoint(explicitEndpoint);
    }
    switch (complexity) {
      case TaskComplexity.complex:
        return superVlEndpoint;
      case TaskComplexity.simple:
        return nanoEndpoint;
    }
  }

  /// Resolves the model identifier based on task complexity or explicit override
  String resolveModel({
    TaskComplexity complexity = TaskComplexity.simple,
    String? explicitModel,
  }) {
    if (explicitModel != null && explicitModel.isNotEmpty) {
      return normalizeModel(explicitModel);
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

  /// Executes a chat completion request with smart routing to Nemotron 3.5 Super VL or Nano 30B
  Future<String> chatCompletion({
    required List<Map<String, dynamic>> messages,
    String? model,
    String? endpoint,
    TaskComplexity complexity = TaskComplexity.simple,
    double temperature = 0.2,
    int maxTokens = 2048,
    Map<String, dynamic>? responseFormat,
  }) async {
    final selectedModel =
        resolveModel(complexity: complexity, explicitModel: model);
    final targetEndpoint =
        resolveEndpoint(complexity: complexity, explicitEndpoint: endpoint);
    final url = Uri.parse('$targetEndpoint/chat/completions');

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
    final content = message['content'] as String?;
    if (content != null && content.trim().isNotEmpty) {
      return content.trim();
    }

    // Fallback to reasoning fields for thinking/reasoning models (Nemotron-3-Nano-30B)
    final reasoning =
        (message['reasoning_content'] ?? message['reasoning']) as String?;
    if (reasoning != null && reasoning.trim().isNotEmpty) {
      return reasoning.trim();
    }

    return '';
  }

  /// Fetches available models from the target Nebius Token Factory endpoint
  Future<List<String>> listModels({String? endpoint}) async {
    final target = normalizeEndpoint(endpoint ?? superVlEndpoint);
    final url = Uri.parse('$target/models');

    final response = await _httpClient.get(
      url,
      headers: {
        'Authorization': 'Bearer $apiKey',
      },
    );

    if (response.statusCode != 200) {
      throw Exception(
          'Nebius models error [${response.statusCode}]: ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final list = data['data'] as List<dynamic>? ?? [];
    return list.map((m) => m['id'] as String).toList();
  }

  /// Verifies connectivity and model availability for a specific endpoint and model
  Future<Map<String, dynamic>> testConnection({
    String? endpoint,
    String? model,
    TaskComplexity complexity = TaskComplexity.simple,
  }) async {
    final targetEndpoint =
        resolveEndpoint(complexity: complexity, explicitEndpoint: endpoint);
    final targetModel =
        resolveModel(complexity: complexity, explicitModel: model);

    try {
      final models = await listModels(endpoint: targetEndpoint);
      final nvidiaModels =
          models.where((m) => m.toLowerCase().contains('nvidia')).toList();
      final hasTargetModel = models.contains(targetModel);

      // Perform a minimal dry completion to verify token inference works
      final probeResult = await chatCompletion(
        messages: [
          {'role': 'user', 'content': 'Say OK'}
        ],
        model: targetModel,
        endpoint: targetEndpoint,
        maxTokens: 16,
      );

      return {
        'success': true,
        'endpoint': targetEndpoint,
        'model': targetModel,
        'hasTargetModel': hasTargetModel,
        'modelCount': models.length,
        'nvidiaModels': nvidiaModels,
        'probeResponse': probeResult,
        'message':
            'Verified $targetModel on $targetEndpoint (${models.length} models, ${nvidiaModels.length} NVIDIA)',
      };
    } catch (e) {
      return {
        'success': false,
        'endpoint': targetEndpoint,
        'model': targetModel,
        'error': e.toString(),
      };
    }
  }

  /// Multi-step task planner routed to Nemotron 3.5 Super VL.
  /// Decomposes complex user goals into structured JSON execution steps.
  Future<List<Map<String, dynamic>>> planTask({
    required String goal,
    required List<String> availableTools,
    String? platformContext,
  }) async {
    final systemPrompt = '''
You are the Planning Engine of Device Assistant powered by Nemotron-3.5-Super-VL.
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

    // Planning is complex: Smart route to Nemotron 3.5 Super VL
    final result = await chatCompletion(
      messages: [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': 'Plan this task: $goal'},
      ],
      complexity: TaskComplexity.complex,
      temperature: 0.1,
    );

    try {
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
  /// routed to lightweight, fast Nemotron 3 Nano 30B.
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

    // Memory extraction is simple classification: Smart route to Nemotron 3 Nano 30B
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
