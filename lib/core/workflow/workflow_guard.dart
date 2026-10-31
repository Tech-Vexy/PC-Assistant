import 'dart:convert';

/// Static security scanner for workflows and procedural skills.
///
/// Inspired by Hermes `skills_guard.py` to prevent unsafe actions, command
/// injection, dangerous permission escalation, or exfiltration during workflow creation.
class WorkflowGuardResult {
  final bool isSafe;
  final String? violationReason;
  final List<String> flaggedPatterns;

  const WorkflowGuardResult({
    required this.isSafe,
    this.violationReason,
    this.flaggedPatterns = const [],
  });

  factory WorkflowGuardResult.safe() => const WorkflowGuardResult(isSafe: true);
  factory WorkflowGuardResult.blocked(String reason, List<String> patterns) =>
      WorkflowGuardResult(
        isSafe: false,
        violationReason: reason,
        flaggedPatterns: patterns,
      );
}

class WorkflowGuard {
  // Regex patterns targeting dangerous shell commands or destructive disk operations
  static final List<RegExp> _dangerousPatterns = [
    RegExp(r'\brm\s+-rf\s+[/~]', caseSensitive: false),
    RegExp(r'\bmkfs(\.[a-z0-9]+)?\b', caseSensitive: false),
    RegExp(r'\bdd\s+if=.*of=/dev/', caseSensitive: false),
    RegExp(r':\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:', caseSensitive: false), // Forkbomb
    RegExp(r'\b(curl|wget)\s+.*\|\s*(sh|bash|zsh)\b', caseSensitive: false),
    RegExp(r'\b(sudo\s+)?chmod\s+-R\s+777\s+/', caseSensitive: false),
    RegExp(r'>\s*/dev/sd[a-z]', caseSensitive: false),
    RegExp(r'\b(export|set)\s+AWS_SECRET|AZURE_SECRET|GOOGLE_CREDENTIALS\b', caseSensitive: false),
  ];

  // Disallowed sensitive Android packages or targets in workflow automations
  static final Set<String> _blacklistedPackages = {
    'com.android.settings.crypto',
    'com.google.android.apps.authenticator2',
    'com.authenticator',
    'com.onepassword',
    'com.lastpass',
    'org.keepass',
    'com.bitwarden',
  };

  /// Scans markdown content and step arguments for potential security risks.
  static WorkflowGuardResult scan({
    required String name,
    required String markdownContent,
    List<Map<String, dynamic>>? steps,
  }) {
    final flagged = <String>[];

    // 1. Scan markdown instructions & scripts
    for (final pattern in _dangerousPatterns) {
      if (pattern.hasMatch(markdownContent)) {
        flagged.add('Dangerous command pattern: "${pattern.pattern}"');
      }
    }

    // 2. Scan structured tool step arguments
    if (steps != null) {
      for (final step in steps) {
        final tool = step['tool']?.toString() ?? '';
        final args = step['args'];
        final argsStr = args != null ? jsonEncode(args) : '';

        for (final pattern in _dangerousPatterns) {
          if (pattern.hasMatch(argsStr)) {
            flagged.add('Dangerous argument in step ($tool): "${pattern.pattern}"');
          }
        }

        // Check if targeted at protected authenticators or password managers
        if (tool == 'open_application' || tool == 'click_element') {
          for (final pkg in _blacklistedPackages) {
            if (argsStr.toLowerCase().contains(pkg)) {
              flagged.add('Step ($tool) targets protected sensitive application: $pkg');
            }
          }
        }
      }
    }

    if (flagged.isNotEmpty) {
      return WorkflowGuardResult.blocked(
        'Workflow "$name" failed security guard audit.',
        flagged,
      );
    }

    return WorkflowGuardResult.safe();
  }
}
