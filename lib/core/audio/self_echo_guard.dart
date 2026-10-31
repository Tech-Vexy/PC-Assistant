/// Drops microphone transcripts that are only the assistant's own speech
/// coming back off the speaker. Wake-word mode keeps listening during playback
/// so the user can interrupt, which means hotwords the assistant plausibly says
/// ("computer", "device assistant") can fire on its own output.
class SelfEchoGuard {
  final Duration lookback;
  final DateTime Function() _now;

  final List<_SpokenPhrase> _phrases = [];

  SelfEchoGuard({
    this.lookback = const Duration(seconds: 8),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Records text the assistant is expected to speak out loud.
  void noteSpoken(String text) {
    final normalized = _normalize(text);
    if (normalized.isEmpty) return;
    _phrases.add(_SpokenPhrase(normalized, _now()));
    _prune();
  }

  /// Forgets all remembered speech, e.g. when a Live session ends.
  void reset() => _phrases.clear();

  bool isLikelyEcho(String transcript) {
    final candidate = _normalize(transcript);
    if (candidate.isEmpty) return false;
    _prune();
    return _phrases.any((p) => p.text.contains(candidate));
  }

  void _prune() {
    final cutoff = _now().subtract(lookback);
    _phrases.removeWhere((p) => p.at.isBefore(cutoff));
  }

  static String _normalize(String value) => value
      .toLowerCase()
      .replaceAll(_nonWordPattern, ' ')
      .replaceAll(_whitespacePattern, ' ')
      .trim();
}

class _SpokenPhrase {
  final String text;
  final DateTime at;

  const _SpokenPhrase(this.text, this.at);
}

final _nonWordPattern = RegExp(r'[^\w\s]+');
final _whitespacePattern = RegExp(r'\s+');
