import '../database/local_database.dart';
import 'memory_vector.dart';

/// A distilled memory surfaced by the recall engine.
class RecalledMemory {
  final int id;
  final String content;
  final String category;
  final String source; // 'auto' | 'manual' | 'onboarding'
  final double importance;
  final String date; // ISO date string e.g. '2024-11-01'
  final double rank; // Lower = better for BM25; Higher = better for cosine

  const RecalledMemory({
    required this.id,
    required this.content,
    required this.category,
    required this.source,
    required this.importance,
    required this.date,
    required this.rank,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'content': content,
        'category': category,
        'source': source,
        'importance': importance,
        'date': date,
        'rank': rank,
      };
}

/// A prior deliverable record found by the repetition guard.
class PriorDeliverable {
  final int sessionId;
  final String date;
  final String userRequest;
  final String assistantSummary;

  const PriorDeliverable({
    required this.sessionId,
    required this.date,
    required this.userRequest,
    required this.assistantSummary,
  });

  Map<String, dynamic> toJson() => {
        'session_id': sessionId,
        'date': date,
        'user_request': userRequest,
        'assistant_summary': assistantSummary,
      };
}

/// Hybrid memory recall engine.
///
/// Combines SQLite FTS5 BM25 lexical search with 128-D dense vector
/// similarity search using Reciprocal Rank Fusion (RRF) to surface the
/// most relevant memories for any user query.
class MemoryRecallEngine {
  static const double bm25Floor = -0.6; // BM25 relevance threshold
  static const double cosineFloor = 0.15; // Minimum cosine similarity
  static const int rrfK = 60; // RRF smoothing constant
  static const int topK = 6; // Max memories returned by hybrid recall
  static const int coreLimit = 6; // Ambient core memories injected always

  final LocalDatabase db;

  const MemoryRecallEngine(this.db);

  // ── Keyword extraction ─────────────────────────────────────────────────────

  static const Set<String> _stopwords = {
    'the', 'a', 'an', 'and', 'or', 'but', 'if', 'then', 'so', 'because',
    'as', 'of', 'at', 'by', 'for', 'with', 'about', 'into', 'to', 'from',
    'in', 'on', 'is', 'are', 'was', 'were', 'be', 'been', 'being', 'do',
    'does', 'did', 'have', 'has', 'had', 'i', 'you', 'he', 'she', 'it',
    'we', 'they', 'me', 'him', 'her', 'us', 'them', 'my', 'your', 'his',
    'its', 'our', 'their', 'this', 'that', 'these', 'those', 'what',
    'which', 'who', 'whom', 'how', 'when', 'where', 'why', 'not', 'no',
    'yes', 'can', 'could', 'should', 'would', 'will', 'shall', 'may',
    'might', 'must', 'just', 'also', 'very', 'really', 'some', 'any',
    'all', 'get', 'got', 'make', 'made', 'like', 'want', 'need', 'know',
    'think', 'thought', 'there', 'here', 'than', 'tell', 'give', 'show',
    'help', 'please', 'thanks', 'thank', 'okay',
  };

  /// Extracts distinctive keywords from [text] for use as BM25 query terms.
  List<String> keywordsFrom(String text) {
    final words = text
        .toLowerCase()
        .replaceAll(RegExp(r"[^a-z0-9\s'\-]"), ' ')
        .split(RegExp(r'\s+'))
        .map((w) => w.replaceAll(RegExp(r"^['\-]+|['\-]+$"), ''))
        .where((w) => w.length >= 3 && !_stopwords.contains(w))
        .toSet()
        .toList();
    return words.length > 12 ? words.sublist(0, 12) : words;
  }

  /// Reduces a word to its common stem for wider prefix matching.
  static String stemWord(String word) {
    if (word.endsWith('ies') && word.length > 4) return '${word.substring(0, word.length - 3)}y';
    if (word.endsWith('ing') && word.length > 5) {
      var base = word.substring(0, word.length - 3);
      if (base.length >= 3 && base[base.length - 1] == base[base.length - 2]) {
        base = base.substring(0, base.length - 1);
      }
      return base;
    }
    if (word.endsWith('es') && word.length > 4) return word.substring(0, word.length - 2);
    if (word.endsWith('s') && !word.endsWith('ss') && word.length > 3) return word.substring(0, word.length - 1);
    if (word.endsWith('ed') && word.length > 4) return word.substring(0, word.length - 2);
    return word;
  }

  // ── Meta-memory / directive detection ──────────────────────────────────────

  /// Returns true if the user is asking what the assistant knows about them.
  bool isMetaMemoryQuery(String text) {
    final norm = text.toLowerCase().trim().replaceAll(RegExp(r'''[.,!?;:'"]'''), ' ');
    final patterns = [
      RegExp(r'what\s+(do\s+you\s+)?know\s+(about\s+)?(me|myself)'),
      RegExp(r'what\s+(do\s+you\s+)?remember(\s+about\s+(me|us))?'),
      RegExp(r'who\s+am\s+i'),
      RegExp(r'what\s+is\s+my\s+name'),
      RegExp(r"whats\s+my\s+name"),
      RegExp(r'tell\s+me\s+about\s+(myself|me)'),
      RegExp(r'what\s+have\s+we\s+(talked|discussed|worked|done)'),
      RegExp(r'what\s+are\s+my\s+(projects|interests|goals)'),
      RegExp(r'do\s+you\s+(know|remember)\s+me'),
      RegExp(r'what\s+is\s+in\s+(your|my)\s+memory'),
      RegExp(r'summarize\s+what\s+you\s+know'),
    ];
    return patterns.any((p) => p.hasMatch(norm));
  }

  /// Detects an explicit "forget about X" directive. Returns the topic or null.
  String? detectForgetDirective(String text) {
    final patterns = [
      RegExp(r'^(?:please\s+)?forget\s+(?:about\s+)?(?:all\s+(?:about\s+)?)?(.+)', caseSensitive: false),
      RegExp(r'^(?:please\s+)?(?:delete|remove)\s+(.+?)\s+(?:from\s+(?:your\s+|my\s+)?memory|from\s+vault)', caseSensitive: false),
      RegExp(r"^(?:please\s+)?don'?t\s+remember\s+(?:about\s+)?(.+)", caseSensitive: false),
      RegExp(r'^(?:please\s+)?erase\s+(.+?)\s+from\s+memory', caseSensitive: false),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(text.trim());
      if (m != null && m.groupCount >= 1) {
        final topic = (m.group(1) ?? '').trim().replaceAll(RegExp(r'[.,!?;:]+$'), '');
        if (topic.length >= 2) return topic;
      }
    }
    return null;
  }

  // ── BM25 FTS5 Search ───────────────────────────────────────────────────────

  /// Lexical BM25 recall via SQLite FTS5. Returns memories above relevance floor.
  List<RecalledMemory> bm25Recall(String query, {int? excludeSessionId}) {
    final words = keywordsFrom(query);
    if (words.isEmpty) return [];

    final terms = <String>{...words, ...words.map(stemWord)};
    final matchExpr = terms.map((w) => '"$w"*').join(' OR ');

    try {
      final result = db.rawSelect('''
        SELECT m.id, m.content, m.category, m.source, m.importance, m.created_at,
               bm25(memories_fts) AS rank
        FROM memories_fts
        JOIN memories_v2 m ON m.id = memories_fts.rowid
        WHERE memories_fts MATCH ?
        ORDER BY rank
        LIMIT 8
      ''', [matchExpr]);

      return result.map(_rowToMemory).toList();
    } catch (_) {
      return [];
    }
  }

  // ── Dense Vector Search ────────────────────────────────────────────────────

  /// Dense semantic vector similarity search. Returns memories above cosine floor.
  List<RecalledMemory> vectorRecall(String query, {int? excludeSessionId}) {
    final queryVec = MemoryVectorEngine.generateEmbedding(query);

    final rows = db.rawSelect('''
      SELECT m.id, m.content, m.category, m.source, m.importance, m.created_at, m.embedding
      FROM memories_v2 m
      WHERE m.embedding IS NOT NULL
    ''', []);

    final scored = <({RecalledMemory memory, double score})>[];
    for (final row in rows) {
      try {
        final embJson = row['embedding'] as String?;
        if (embJson == null || embJson.isEmpty) continue;
        final memVec = MemoryVectorEngine.deserializeEmbedding(embJson);
        final score = MemoryVectorEngine.cosineSimilarity(queryVec, memVec);
        if (score > 0.0) {
          scored.add((memory: _rowToMemory(row, rank: score), score: score));
        }
      } catch (_) {
        continue;
      }
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(8).map((e) => e.memory).toList();
  }

  // ── Reciprocal Rank Fusion ─────────────────────────────────────────────────

  /// Hybrid recall: fuses BM25 and vector results using Reciprocal Rank Fusion.
  ///
  /// RRF score = 1/(k + rank_bm25) + 1/(k + rank_vector)
  /// Returns top [topK] most relevant memories.
  List<RecalledMemory> hybridRecall(String query, {int? excludeSessionId}) {
    if (isMetaMemoryQuery(query)) {
      return _allMemories(limit: 20);
    }

    final bm25 = bm25Recall(query, excludeSessionId: excludeSessionId);
    final vector = vectorRecall(query, excludeSessionId: excludeSessionId);

    final fusedMap = <int, ({RecalledMemory memory, double rrfScore})>{};

    for (int i = 0; i < bm25.length; i++) {
      final m = bm25[i];
      final score = 1.0 / (rrfK + i + 1);
      fusedMap[m.id] = (memory: m, rrfScore: score);
    }

    for (int i = 0; i < vector.length; i++) {
      final m = vector[i];
      final score = 1.0 / (rrfK + i + 1);
      if (fusedMap.containsKey(m.id)) {
        final existing = fusedMap[m.id]!;
        fusedMap[m.id] = (memory: existing.memory, rrfScore: existing.rrfScore + score);
      } else {
        fusedMap[m.id] = (memory: m, rrfScore: score);
      }
    }

    final merged = fusedMap.values.toList()
      ..sort((a, b) => b.rrfScore.compareTo(a.rrfScore));

    return merged.take(topK).map((e) => e.memory).toList();
  }

  // ── Core / Ambient Memories ────────────────────────────────────────────────

  /// Returns the most recent [limit] memories — always injected as ambient context.
  /// These are the "core facts" the model should always know about the user.
  List<RecalledMemory> coreMemories({int limit = coreLimit}) {
    return _allMemories(limit: limit);
  }

  List<RecalledMemory> _allMemories({int limit = 20}) {
    final rows = db.rawSelect('''
      SELECT id, content, category, source, importance, created_at,
             -1.0 AS rank
      FROM memories_v2
      ORDER BY importance DESC, id DESC
      LIMIT ?
    ''', [limit]);
    return rows.map(_rowToMemory).toList();
  }

  // ── Repetition Guard ───────────────────────────────────────────────────────

  /// Scans recent conversation messages to detect repeated deliverable requests.
  List<PriorDeliverable> findPriorDeliverables(String userMessage,
      {int? excludeSessionId}) {
    final words = keywordsFrom(userMessage);
    if (words.isEmpty) return [];

    final candidates = <PriorDeliverable>[];
    final seenSessionIds = <int>{};

    for (final word in words.take(4)) {
      final rows = db.rawSelect('''
        SELECT cm.id AS msgId,
               cm.session_id AS sessionId,
               cm.content AS content,
               cm.created_at AS createdAt
        FROM conversation_messages cm
        WHERE cm.session_id != ?
          AND cm.role = 'user'
          AND lower(cm.content) LIKE ?
        ORDER BY cm.id DESC
        LIMIT 3
      ''', [excludeSessionId ?? 0, '%${word.toLowerCase()}%']);

      for (final row in rows) {
        final sessionId = row['sessionId'] as int;
        if (seenSessionIds.contains(sessionId)) continue;

        final assistantRows = db.rawSelect('''
          SELECT content FROM conversation_messages
          WHERE session_id = ? AND role = 'assistant' AND id > ?
          ORDER BY id ASC LIMIT 1
        ''', [sessionId, row['msgId'] as int]);

        if (assistantRows.isNotEmpty) {
          final summary = (assistantRows.first['content'] as String).substring(
              0,
              (assistantRows.first['content'] as String).length > 280
                  ? 280
                  : (assistantRows.first['content'] as String).length);
          final date = DateTime.fromMillisecondsSinceEpoch(
                  row['createdAt'] as int)
              .toIso8601String()
              .substring(0, 10);
          candidates.add(PriorDeliverable(
            sessionId: sessionId,
            date: date,
            userRequest: row['content'] as String,
            assistantSummary: summary,
          ));
          seenSessionIds.add(sessionId);
        }
      }
    }

    return candidates.take(2).toList();
  }

  // ── Forget by topic ────────────────────────────────────────────────────────

  /// Deletes all memories matching the specified topic from both the
  /// relational table and FTS index.
  int forgetMemoriesMatching(String topic) {
    final words = keywordsFrom(topic);
    if (words.isEmpty) return 0;

    final terms = <String>{...words, ...words.map(stemWord)};
    final matchExpr = terms.map((w) => '"$w"*').join(' OR ');
    int count = 0;

    try {
      final rows = db.rawSelect('''
        SELECT m.id
        FROM memories_v2 m
        WHERE m.id IN (
          SELECT rowid FROM memories_fts WHERE memories_fts MATCH ?
        )
        OR lower(m.category) LIKE ?
        OR lower(m.content) LIKE ?
      ''', [matchExpr, '%${topic.toLowerCase()}%', '%${topic.toLowerCase()}%']);

      for (final row in rows) {
        final id = row['id'] as int;
        db.rawExecute('DELETE FROM memories_v2 WHERE id = ?', [id]);
        count++;
      }
    } catch (_) {}

    return count;
  }

  // ── Helper ─────────────────────────────────────────────────────────────────

  RecalledMemory _rowToMemory(Map<String, dynamic> row, {double? rank}) {
    final ts = row['created_at'] as int? ?? DateTime.now().millisecondsSinceEpoch;
    final date = DateTime.fromMillisecondsSinceEpoch(ts).toIso8601String().substring(0, 10);
    return RecalledMemory(
      id: row['id'] as int,
      content: row['content'] as String,
      category: (row['category'] as String?) ?? 'general',
      source: (row['source'] as String?) ?? 'manual',
      importance: (row['importance'] as num?)?.toDouble() ?? 0.5,
      date: date,
      rank: rank ?? (row['rank'] as num?)?.toDouble() ?? 0.0,
    );
  }
}
