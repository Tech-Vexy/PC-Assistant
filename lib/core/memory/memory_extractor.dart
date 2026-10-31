import 'dart:convert';
import '../network/gemini_live_client.dart';
import '../network/nebius_client.dart';

/// Smart distillation gate: determines whether the user's message is
/// substantive enough to warrant an LLM extraction call.
bool _shouldExtract(String userMessage) {
  final norm = userMessage.toLowerCase().trim();

  // Skip meta-memory questions
  final metaPatterns = [
    RegExp(r'what\s+(do\s+you\s+)?know\s+(about\s+)?(me|myself)'),
    RegExp(r'what\s+(do\s+you\s+)?remember'),
    RegExp(r'who\s+am\s+i'),
    RegExp(r'what\s+is\s+my\s+name'),
  ];
  if (metaPatterns.any((p) => p.hasMatch(norm))) return false;

  // Skip forget directives
  if (norm.startsWith('forget') ||
      norm.startsWith('delete') ||
      norm.startsWith("don't remember")) {
    return false;
  }

  final trimmed = norm.replaceAll(RegExp(r'[.,!?;:]'), '');
  const trivial = {
    'hi', 'hello', 'hey', 'thanks', 'thank you', 'ok', 'okay',
    'cool', 'yes', 'no', 'yep', 'nope', 'sure', 'bye', 'goodbye',
    "let's continue", 'lets continue', 'continue', 'whats up', "what's up",
    'good morning', 'good evening', 'how are you', 'who are you',
  };
  if (trivial.contains(trimmed)) return false;

  // Need at least 2 distinctive keywords (3+ chars)
  final words = trimmed
      .split(RegExp(r'\s+'))
      .where((w) => w.length >= 3)
      .toSet();
  return words.length >= 2;
}

/// The LLM extraction system prompt — instructs the model to distill
/// durable third-person facts about the user from a completed exchange.
const _extractionSystemPrompt = '''
You are the memory distillation kernel for a personal on-device AI assistant.
Your sole job: extract durable, long-term facts about the USER from the exchange below.

WHAT TO REMEMBER (durable facts about the USER only):
- Name, profession, location, expertise, affiliations
- Projects and systems they are building (tech stack, decisions, goals)
- Durable preferences and working style (tone, structure, technical biases)
- Life facts: milestones, commitments, plans, constraints, deadlines
- Explicit directives ("Remember that...", "Note that...", "Always...")

STRICT RULES — NEVER REMEMBER:
- Facts about the AI assistant itself
- Conversational actions ("User greeted...", "User asked a question...")
- Transient session states ("User is currently testing...")
- Non-facts or undetermined preferences
- Small talk, trivia, or general code syntax

FORMAT (JSON only, no markdown fences, no extra text):
{"memories": ["Third-person statement about the user, max 180 chars", ...]}

Return at most 2 facts. Return {"memories": []} if nothing qualifies.
''';

/// Auto-extraction pipeline: after every completed assistant turn, calls the
/// LLM to distill durable facts about the user and writes them to the DB.
class MemoryExtractor {
  final GeminiLiveClient? geminiClient;
  final NebiusClient? nebiusClient;

  const MemoryExtractor({this.geminiClient, this.nebiusClient});

  bool get _hasLlm => geminiClient != null || nebiusClient != null;

  /// Distills memories from a completed user/assistant exchange.
  ///
  /// Returns the list of distilled memory strings that were newly written.
  /// Returns empty list if extraction was skipped (trivial turn, no LLM, error).
  Future<List<String>> extractMemories({
    required String userMessage,
    required String assistantReply,
  }) async {
    if (!_hasLlm) return [];
    if (!_shouldExtract(userMessage)) return [];
    if (assistantReply.trim().isEmpty) return [];

    try {
      final prompt =
          'User said: $userMessage\n\nYou (assistant) replied: $assistantReply';

      String raw;
      if (geminiClient != null) {
        raw = await geminiClient!.generateContent(
          prompt: prompt,
          systemInstruction: _extractionSystemPrompt,
          temperature: 0.2,
        );
      } else {
        raw = await nebiusClient!.chatCompletion(
          messages: [
            {'role': 'system', 'content': _extractionSystemPrompt},
            {'role': 'user', 'content': prompt},
          ],
          complexity: TaskComplexity.simple,
          temperature: 0.2,
          maxTokens: 256,
        );
      }

      return _parseMemories(raw);
    } catch (_) {
      return [];
    }
  }

  List<String> _parseMemories(String raw) {
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start == -1 || end <= start) return [];

    try {
      final obj = jsonDecode(raw.substring(start, end + 1)) as Map<String, dynamic>;
      final list = obj['memories'];
      if (list is! List) return [];
      return list
          .whereType<String>()
          .map((m) => m.trim())
          .where((m) => m.isNotEmpty)
          .take(3)
          .toList();
    } catch (_) {
      return [];
    }
  }
}
