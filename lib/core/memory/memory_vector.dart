import 'dart:math' as math;
import 'dart:typed_data';

/// Pure-Dart 128-dimensional L2-normalized semantic vector engine.
///
/// Uses deterministic feature hashing (unigrams, char 3-grams, bigrams)
/// with stopword damping. No external dependencies or network calls required.
/// Produces embeddings suitable for cosine-similarity retrieval of memories.
class MemoryVectorEngine {
  static const int dim = 128;

  static const Set<String> _stopwords = {
    'the',
    'a',
    'an',
    'and',
    'or',
    'but',
    'if',
    'then',
    'so',
    'because',
    'as',
    'of',
    'at',
    'by',
    'for',
    'with',
    'about',
    'into',
    'to',
    'from',
    'in',
    'on',
    'is',
    'are',
    'was',
    'were',
    'be',
    'been',
    'being',
    'do',
    'does',
    'did',
    'have',
    'has',
    'had',
    'i',
    'you',
    'he',
    'she',
    'it',
    'we',
    'they',
    'me',
    'him',
    'her',
    'us',
    'them',
    'my',
    'your',
    'his',
    'its',
    'our',
    'their',
    'this',
    'that',
    'these',
    'those',
    'what',
    'which',
    'who',
    'whom',
    'how',
    'when',
    'where',
    'why',
    'not',
    'no',
    'yes',
    'can',
    'could',
    'should',
    'would',
    'will',
    'shall',
    'may',
    'might',
    'must',
    'just',
    'also',
    'very',
    'really',
    'some',
    'any',
    'all',
    'get',
    'got',
    'make',
    'made',
    'like',
    'want',
    'need',
    'know',
    'think',
    'thought',
    'there',
    'here',
    'than',
    'tell',
    'give',
    'show',
    'help',
    'please',
    'thanks',
    'thank',
    'okay',
  };

  /// Murmur-inspired 32-bit string hash for deterministic feature hashing.
  static int _hashString(String str, int seed) {
    int h = seed ^ str.length;
    for (int i = 0; i < str.length; i++) {
      h = h ^ str.codeUnitAt(i);
      // Simulate 32-bit multiply with overflow wrapping
      h = _imul(h, 0x5bd1e995);
      h ^= h >>> 15;
    }
    return h >>> 0; // Unsigned 32-bit
  }

  /// Simulate JavaScript Math.imul (32-bit integer multiply).
  static int _imul(int a, int b) {
    final al = a & 0xFFFF;
    final ah = (a >> 16) & 0xFFFF;
    final bl = b & 0xFFFF;
    final bh = (b >> 16) & 0xFFFF;
    return ((al * b) + ((ah * bl + al * bh) << 16)) & 0xFFFFFFFF;
  }

  /// Generates a deterministic, L2-normalized dense 128-D vector for [text].
  ///
  /// Pipeline:
  ///   1. Unigram feature hashing with stopword damping (weight 0.2 vs 1.0)
  ///   2. Character 3-gram hashing for morphological similarity
  ///   3. Word bigram hashing for phrase-level similarity
  ///   4. L2 normalization (makes dot product == cosine similarity)
  static Float32List generateEmbedding(String text) {
    final vec = Float32List(dim);
    final normalized = text.toLowerCase().trim();
    if (normalized.isEmpty) return vec;

    final words = normalized
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();

    // 1. Unigram feature hashing
    for (final word in words) {
      final weight = _stopwords.contains(word) ? 0.2 : 1.0;
      final bucket = _hashString(word, 42) % dim;
      final sign = (_hashString(word, 137) % 2 == 0) ? 1.0 : -1.0;
      vec[bucket] += sign * weight;

      // 2. Character 3-grams for morphological/inflectional similarity
      if (word.length >= 3) {
        for (int i = 0; i <= word.length - 3; i++) {
          final tri = word.substring(i, i + 3);
          final bTri = _hashString(tri, 99) % dim;
          final sTri = (_hashString(tri, 211) % 2 == 0) ? 1.0 : -1.0;
          vec[bTri] += sTri * 0.4;
        }
      }
    }

    // 3. Word bigram hashing (phrase similarity)
    for (int i = 0; i < words.length - 1; i++) {
      final bi = '${words[i]}_${words[i + 1]}';
      final bBi = _hashString(bi, 777) % dim;
      final sBi = (_hashString(bi, 888) % 2 == 0) ? 1.0 : -1.0;
      vec[bBi] += sBi * 0.8;
    }

    // 4. L2 normalization
    double norm = 0.0;
    for (int i = 0; i < dim; i++) {
      norm += vec[i] * vec[i];
    }
    norm = math.sqrt(norm);
    if (norm > 0) {
      for (int i = 0; i < dim; i++) {
        vec[i] /= norm;
      }
    }

    return vec;
  }

  /// Cosine similarity between two unit-normalized vectors (dot product).
  /// Returns value in [-1.0, 1.0]; higher is more similar.
  static double cosineSimilarity(Float32List a, Float32List b) {
    double dot = 0.0;
    final len = math.min(a.length, b.length);
    for (int i = 0; i < len; i++) {
      dot += a[i] * b[i];
    }
    return dot;
  }

  /// Serializes a Float32List to a compact JSON float array string.
  static String serializeEmbedding(Float32List vec) {
    final buffer = StringBuffer('[');
    for (int i = 0; i < vec.length; i++) {
      // 6 decimal places — enough precision, compact output
      buffer.write(vec[i].toStringAsFixed(6));
      if (i < vec.length - 1) buffer.write(',');
    }
    buffer.write(']');
    return buffer.toString();
  }

  /// Deserializes a JSON float array string back to Float32List.
  static Float32List deserializeEmbedding(String json) {
    final clean = json.trim();
    if (clean.isEmpty || clean == '[]') return Float32List(dim);
    // Remove brackets and split on commas
    final inner = clean.substring(1, clean.length - 1);
    final parts = inner.split(',');
    final vec = Float32List(dim);
    for (int i = 0; i < parts.length && i < dim; i++) {
      vec[i] = double.tryParse(parts[i].trim()) ?? 0.0;
    }
    return vec;
  }
}
