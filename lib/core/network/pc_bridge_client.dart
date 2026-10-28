import 'dart:convert';
import 'package:http/http.dart' as http;
import '../database/local_database.dart';

/// Client bridge connecting Device Assistant to the desktop PC Voice Assistant
/// server (Node.js + DuckDB on port 3000) for cross-device delegation,
/// remote desktop tools, memory synchronization, and approval resolution.
class PcBridgeClient {
  final String serverUrl;
  final http.Client _httpClient;

  PcBridgeClient({
    required this.serverUrl,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'X-Requested-With': 'pc-assistant-agent',
      };

  /// Checks the health and resource metrics of the PC Assistant server
  Future<Map<String, dynamic>> checkHealth() async {
    try {
      final res = await _httpClient
          .get(
            Uri.parse('$serverUrl/health'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 4));

      if (res.statusCode == 200) {
        return {
          'connected': true,
          'status': 'ok',
          'data': jsonDecode(res.body),
        };
      }
      return {
        'connected': false,
        'status': 'http_${res.statusCode}',
        'error': res.body,
      };
    } catch (e) {
      return {
        'connected': false,
        'status': 'unreachable',
        'error': e.toString(),
      };
    }
  }

  /// Delegates execution of a desktop tool to the PC server (e.g. computer_use, terminal, media)
  Future<Map<String, dynamic>> delegateTool({
    required String tool,
    required Map<String, dynamic> args,
  }) async {
    try {
      final res = await _httpClient
          .post(
            Uri.parse('$serverUrl/test-tool'),
            headers: _headers,
            body: jsonEncode({
              'tool': tool,
              'args': args,
            }),
          )
          .timeout(const Duration(seconds: 30));

      if (res.statusCode == 200) {
        return jsonDecode(res.body) as Map<String, dynamic>;
      }
      return {
        'status': 'error',
        'error': 'PC Assistant server error [${res.statusCode}]: ${res.body}',
      };
    } catch (e) {
      return {
        'status': 'error',
        'error': 'Failed to reach PC server at $serverUrl: $e',
      };
    }
  }

  /// Fetches currently pending dangerous tool approvals from the PC Assistant server
  Future<List<Map<String, dynamic>>> fetchPendingApprovals() async {
    try {
      final res = await _httpClient
          .get(
            Uri.parse('$serverUrl/api/approvals'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 4));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final list = (data['pending'] as List<dynamic>?) ?? [];
        return list.whereType<Map<String, dynamic>>().toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  /// Streams real-time Server-Sent Events (SSE) from the PC Assistant server
  /// Emits maps representing parsed JSON events, such as 'approval_request',
  /// 'approval_resolved', 'transcript_delta', etc.
  Stream<Map<String, dynamic>> listenToEvents() async* {
    http.Client? client;
    try {
      client = http.Client();
      final request = http.Request('GET', Uri.parse('$serverUrl/api/events'));
      request.headers.addAll({
        'Accept': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'X-Requested-With': 'pc-assistant-mobile',
      });

      final response = await client.send(request);
      if (response.statusCode != 200) {
        client.close();
        return;
      }

      await for (final line
          in response.stream.toStringStream().transform(const LineSplitter())) {
        final trimmed = line.trim();
        if (trimmed.startsWith('data:')) {
          final jsonStr = trimmed.substring(5).trim();
          if (jsonStr.isNotEmpty) {
            try {
              final parsed = jsonDecode(jsonStr);
              if (parsed is Map<String, dynamic>) {
                yield parsed;
              }
            } catch (_) {
              // Ignore non-json lines
            }
          }
        }
      }
    } catch (_) {
      // Stream disconnected
    } finally {
      client?.close();
    }
  }

  /// Resolves a pending dangerous action approval on the PC Assistant server
  Future<bool> resolveApproval({
    required String approvalId,
    required bool approved,
    String note = 'via Device Assistant companion',
  }) async {
    try {
      final res = await _httpClient
          .post(
            Uri.parse('$serverUrl/api/approvals/$approvalId/decision'),
            headers: _headers,
            body: jsonEncode({
              'approved': approved,
              'note': note,
            }),
          )
          .timeout(const Duration(seconds: 5));

      if (res.statusCode == 200) return true;

      // Fallback: try POST /api/approvals/:id directly
      final fallbackRes = await _httpClient
          .post(
            Uri.parse('$serverUrl/api/approvals/$approvalId'),
            headers: _headers,
            body: jsonEncode({
              'approved': approved,
              'note': note,
            }),
          )
          .timeout(const Duration(seconds: 5));

      return fallbackRes.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Pulls memories from the PC Assistant DuckDB store and merges into local encrypted SQLite
  Future<Map<String, dynamic>> syncMemories(LocalDatabase localDb) async {
    try {
      final res = await _httpClient
          .get(
            Uri.parse('$serverUrl/api/store/memory'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 8));

      if (res.statusCode != 200) {
        return {
          'status': 'error',
          'error': 'Server responded ${res.statusCode}'
        };
      }

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final remoteList = (data['memories'] as List<dynamic>?) ?? [];

      int synced = 0;
      for (final item in remoteList) {
        if (item is Map<String, dynamic>) {
          final key = item['key'] as String?;
          final val = item['value'] as String?;
          final cat = (item['category'] as String?) ?? 'general';

          if (key != null && val != null) {
            localDb.remember(key, val, category: cat);
            synced++;
          }
        }
      }

      return {
        'status': 'success',
        'synced_count': synced,
        'remote_total': remoteList.length,
      };
    } catch (e) {
      return {'status': 'error', 'error': e.toString()};
    }
  }

  /// Pulls workflows from the PC Assistant DuckDB store and merges into local encrypted SQLite
  Future<Map<String, dynamic>> syncWorkflows(LocalDatabase localDb) async {
    try {
      final res = await _httpClient
          .get(
            Uri.parse('$serverUrl/api/store/workflows'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 8));

      if (res.statusCode != 200) {
        return {
          'status': 'error',
          'error': 'Server responded ${res.statusCode}'
        };
      }

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final remoteList = (data['workflows'] as List<dynamic>?) ?? [];

      int synced = 0;
      for (final item in remoteList) {
        if (item is Map<String, dynamic>) {
          final name = item['name'] as String?;
          final desc = item['description'] as String?;
          final stepsRaw = item['steps'];

          List<Map<String, dynamic>> steps = [];
          if (stepsRaw is List) {
            steps = stepsRaw.cast<Map<String, dynamic>>();
          } else if (stepsRaw is String) {
            try {
              steps =
                  (jsonDecode(stepsRaw) as List).cast<Map<String, dynamic>>();
            } catch (_) {}
          }

          if (name != null) {
            localDb.saveWorkflow(name, description: desc, steps: steps);
            synced++;
          }
        }
      }

      return {
        'status': 'success',
        'synced_count': synced,
        'remote_total': remoteList.length,
      };
    } catch (e) {
      return {'status': 'error', 'error': e.toString()};
    }
  }

  /// Connects to the PC Assistant Server-Sent Events (SSE) stream at /api/events.
  /// Yields decoded event maps: { type: 'state' | 'tool_call' | 'approval_request' | ..., data: {...} }
  Stream<Map<String, dynamic>> subscribeToEvents() async* {
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse('$serverUrl/api/events'));
      request.headers.addAll({
        'Accept': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'X-Requested-With': 'pc-assistant-agent',
      });

      final response = await client.send(request);
      if (response.statusCode != 200) {
        yield {
          'type': 'error',
          'error': 'Failed to connect: HTTP ${response.statusCode}'
        };
        return;
      }

      await for (final line
          in response.stream.toStringStream().transform(const LineSplitter())) {
        final trimmed = line.trim();
        if (trimmed.startsWith('data:')) {
          final payload = trimmed.substring(5).trim();
          if (payload.isNotEmpty) {
            try {
              final decoded = jsonDecode(payload);
              if (decoded is Map<String, dynamic>) {
                yield decoded;
              }
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      yield {'type': 'error', 'error': e.toString()};
    } finally {
      client.close();
    }
  }

  /// Lists pending dangerous tool approval requests from the PC server.
  Future<List<Map<String, dynamic>>> getPendingApprovals() async {
    try {
      final res = await _httpClient
          .get(
            Uri.parse('$serverUrl/api/approvals'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 4));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final list = data['pending'] as List<dynamic>? ?? [];
        return list.cast<Map<String, dynamic>>();
      }
    } catch (_) {}
    return [];
  }
}
