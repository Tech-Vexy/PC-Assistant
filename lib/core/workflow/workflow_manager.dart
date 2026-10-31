import '../database/local_database.dart';
import 'workflow_guard.dart';

/// Parsed Hermes-format SKILL.md representation.
class HermesSkillDocument {
  final Map<String, dynamic> frontmatter;
  final String markdownBody;

  const HermesSkillDocument({
    required this.frontmatter,
    required this.markdownBody,
  });

  String get name => frontmatter['name']?.toString() ?? 'unnamed_workflow';
  String get description => frontmatter['description']?.toString() ?? '';
  String get version => frontmatter['version']?.toString() ?? '1.0.0';
  List<String> get platforms =>
      (frontmatter['platforms'] as List<dynamic>? ?? ['android', 'linux', 'windows', 'macos'])
          .cast<String>();
  Map<String, dynamic> get parameters =>
      (frontmatter['parameters'] as Map<String, dynamic>? ?? {});
  List<String> get tags =>
      (frontmatter['tags'] as List<dynamic>? ?? []).cast<String>();

  /// Assembles the complete SKILL.md file format.
  String toMarkdown() {
    final buffer = StringBuffer('---\n');
    buffer.writeln('name: $name');
    buffer.writeln('description: "$description"');
    buffer.writeln('version: $version');
    buffer.writeln('platforms: [${platforms.join(', ')}]');
    if (parameters.isNotEmpty) {
      buffer.writeln('parameters:');
      for (final entry in parameters.entries) {
        buffer.writeln('  ${entry.key}:');
        if (entry.value is Map) {
          for (final prop in (entry.value as Map).entries) {
            buffer.writeln('    ${prop.key}: ${prop.value}');
          }
        } else {
          buffer.writeln('    default: ${entry.value}');
        }
      }
    }
    if (tags.isNotEmpty) {
      buffer.writeln('tags: [${tags.join(', ')}]');
    }
    buffer.writeln('---\n');
    buffer.write(markdownBody.trim());
    return buffer.toString();
  }

  /// Parses a SKILL.md file containing YAML frontmatter and Markdown body.
  static HermesSkillDocument parse(String text) {
    final trimmed = text.trim();
    if (!trimmed.startsWith('---')) {
      return HermesSkillDocument(
        frontmatter: {},
        markdownBody: text,
      );
    }

    final secondFence = trimmed.indexOf('---', 3);
    if (secondFence == -1) {
      return HermesSkillDocument(
        frontmatter: {},
        markdownBody: text,
      );
    }

    final yamlBlock = trimmed.substring(3, secondFence).trim();
    final body = trimmed.substring(secondFence + 3).trim();

    final frontmatter = <String, dynamic>{};
    for (final line in yamlBlock.split('\n')) {
      final parts = line.split(':');
      if (parts.length >= 2) {
        final key = parts[0].trim();
        var val = parts.sublist(1).join(':').trim();
        if (val.startsWith('"') && val.endsWith('"') && val.length >= 2) {
          val = val.substring(1, val.length - 1);
        }
        if (val.startsWith('[') && val.endsWith(']')) {
          final items = val
              .substring(1, val.length - 1)
              .split(',')
              .map((s) => s.trim().replaceAll('"', '').replaceAll("'", ''))
              .where((s) => s.isNotEmpty)
              .toList();
          frontmatter[key] = items;
        } else {
          frontmatter[key] = val;
        }
      }
    }

    return HermesSkillDocument(
      frontmatter: frontmatter,
      markdownBody: body,
    );
  }
}

/// Hermes-style Workflow Manager implementing progressive disclosure,
/// patch-based editing, safety auditing, and ledger versioning.
class HermesWorkflowManager {
  final LocalDatabase db;

  const HermesWorkflowManager(this.db);

  /// Creates or updates a workflow skill using the Hermes format.
  /// Validated through WorkflowGuard before persistence.
  Map<String, dynamic> saveSkill({
    required String name,
    required String description,
    required String markdownContent,
    String version = '1.0.0',
    List<String> platforms = const ['android', 'linux', 'windows', 'macos'],
    Map<String, dynamic> parameters = const {},
    List<Map<String, dynamic>> steps = const [],
    List<String> tags = const [],
    String changeSummary = 'Created workflow skill',
  }) {
    final cleanName = name.replaceAll(RegExp(r'[^a-z0-9_]'), '_').toLowerCase();

    // 1. Static security audit scan
    final scan = WorkflowGuard.scan(
      name: cleanName,
      markdownContent: markdownContent,
      steps: steps,
    );
    if (!scan.isSafe) {
      return {
        'status': 'blocked',
        'error': scan.violationReason,
        'flags': scan.flaggedPatterns,
      };
    }

    // 2. Format as SKILL.md
    final doc = HermesSkillDocument(
      frontmatter: {
        'name': cleanName,
        'description': description,
        'version': version,
        'platforms': platforms,
        'parameters': parameters,
        'tags': tags,
      },
      markdownBody: markdownContent,
    );

    // 3. Save to database & version ledger
    db.saveWorkflowSkill(
      name: cleanName,
      description: description,
      contentMarkdown: doc.toMarkdown(),
      version: version,
      platforms: platforms,
      parameters: parameters,
      steps: steps,
      tags: tags,
      changeSummary: changeSummary,
    );

    return {
      'status': 'saved',
      'name': cleanName,
      'version': version,
      'message': 'Workflow skill "$cleanName" saved successfully in Hermes format.',
    };
  }

  /// Patch-based modification: searches for a block of text in the workflow
  /// and substitutes it with replacement, avoiding full file rewrites.
  Map<String, dynamic> patchSkill({
    required String name,
    required String searchTarget,
    required String replacement,
    String? changeSummary,
  }) {
    final existing = db.getWorkflowSkill(name);
    if (existing == null) {
      return {'status': 'not_found', 'error': 'Workflow "$name" not found.'};
    }

    final currentMd = existing['content_markdown'] as String? ?? '';
    if (!currentMd.contains(searchTarget)) {
      return {
        'status': 'error',
        'error': 'Target block was not found in the workflow markdown content.',
      };
    }

    final patchedMd = currentMd.replaceAll(searchTarget, replacement);

    // Increment minor version (e.g. 1.0.0 -> 1.0.1)
    final curVer = existing['version']?.toString() ?? '1.0.0';
    final verParts = curVer.split('.');
    String newVer = '1.0.1';
    if (verParts.length == 3) {
      final patchNum = (int.tryParse(verParts[2]) ?? 0) + 1;
      newVer = '${verParts[0]}.${verParts[1]}.$patchNum';
    }

    final steps = (existing['steps'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();

    // Scan patched content
    final scan = WorkflowGuard.scan(
      name: name,
      markdownContent: patchedMd,
      steps: steps,
    );
    if (!scan.isSafe) {
      return {
        'status': 'blocked',
        'error': scan.violationReason,
        'flags': scan.flaggedPatterns,
      };
    }

    db.saveWorkflowSkill(
      name: name,
      description: existing['description']?.toString() ?? '',
      contentMarkdown: patchedMd,
      version: newVer,
      platforms: (existing['platforms'] as List<dynamic>? ?? []).cast<String>(),
      parameters: (existing['parameters'] as Map<String, dynamic>? ?? {}),
      steps: steps,
      tags: (existing['tags'] as List<dynamic>? ?? []).cast<String>(),
      changeSummary: changeSummary ?? 'Patched block in workflow content',
    );

    return {
      'status': 'patched',
      'name': name,
      'previous_version': curVer,
      'new_version': newVer,
      'message': 'Workflow "$name" successfully patched to version $newVer.',
    };
  }

  /// Progressive disclosure Level 1: returns lightweight list of skills with names and descriptions.
  List<Map<String, dynamic>> listSkillsSummary() {
    return db.listWorkflowSkillsSummary();
  }

  /// Progressive disclosure Level 2: returns full instructions and execution steps on demand.
  Map<String, dynamic>? viewSkill(String name) {
    return db.getWorkflowSkill(name);
  }

  /// Rolls back a workflow skill to a previous historical version from the ledger.
  Map<String, dynamic> rollbackSkill(String name, int versionId) {
    final ok = db.rollbackWorkflowSkill(name, versionId);
    if (!ok) {
      return {
        'status': 'error',
        'error': 'Failed to rollback "$name" to ledger ID #$versionId. Version not found.',
      };
    }
    return {
      'status': 'rolled_back',
      'name': name,
      'version_id': versionId,
      'message': 'Workflow "$name" reverted to version #$versionId.',
    };
  }
}
