import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:device_assistant/core/network/discovery_service.dart';
import 'package:device_assistant/core/network/pc_bridge_client.dart';

void main() {
  group('DiscoveryService Tests', () {
    test('DiscoveredPcServer serializes and deserializes properly', () {
      final json = {
        'service': 'pc-assistant',
        'version': '1.0.0',
        'hostname': 'Dev-Workstation',
        'platform': 'linux',
        'port': 3000,
        'ip': '192.168.1.42',
        'url': 'http://192.168.1.42:3000',
      };

      final server = DiscoveredPcServer.fromJson(json);
      expect(server.service, equals('pc-assistant'));
      expect(server.version, equals('1.0.0'));
      expect(server.hostname, equals('Dev-Workstation'));
      expect(server.platform, equals('linux'));
      expect(server.port, equals(3000));
      expect(server.ip, equals('192.168.1.42'));
      expect(server.url, equals('http://192.168.1.42:3000'));

      final encoded = server.toJson();
      expect(encoded['hostname'], equals('Dev-Workstation'));
      expect(encoded['url'], equals('http://192.168.1.42:3000'));
    });

    test(
        'probeServer returns server details when /api/discovery responds with valid JSON',
        () async {
      final mockClient = MockClient((req) async {
        if (req.url.path == '/api/discovery') {
          return http.Response(
            jsonEncode({
              'service': 'pc-assistant',
              'version': '1.0.0',
              'hostname': 'LinuxBox',
              'platform': 'linux',
              'port': 3000,
              'ip': '192.168.1.99',
              'url': 'http://192.168.1.99:3000',
            }),
            200,
          );
        }
        return http.Response('Not Found', 404);
      });

      final discovery = DiscoveryService(httpClient: mockClient);
      final server = await discovery.probeServer('http://192.168.1.99:3000');

      expect(server, isNotNull);
      expect(server!.hostname, equals('LinuxBox'));
      expect(server.platform, equals('linux'));
      expect(server.url, equals('http://192.168.1.99:3000'));
    });

    test('probeServer falls back to /health if /api/discovery is unavailable',
        () async {
      final mockClient = MockClient((req) async {
        if (req.url.path == '/api/discovery') {
          return http.Response('Not Found', 404);
        }
        if (req.url.path == '/health') {
          return http.Response(jsonEncode({'status': 'ok'}), 200);
        }
        return http.Response('Not Found', 404);
      });

      final discovery = DiscoveryService(httpClient: mockClient);
      final server = await discovery.probeServer('http://192.168.1.88:3000');

      expect(server, isNotNull);
      expect(server!.url, equals('http://192.168.1.88:3000'));
    });

    test('probeServer returns null when host is completely unreachable',
        () async {
      final mockClient = MockClient((req) async {
        throw Exception('Connection refused');
      });

      final discovery = DiscoveryService(httpClient: mockClient);
      final server = await discovery.probeServer('http://192.168.1.10:3000');

      expect(server, isNull);
    });
  });

  group('PcBridgeClient Event Streaming & Remote Approvals Tests', () {
    test('getPendingApprovals parses pending queue correctly', () async {
      final mockClient = MockClient((req) async {
        if (req.url.path == '/api/approvals') {
          return http.Response(
            jsonEncode({
              'pending': [
                {
                  'id': 'appr-abc-123',
                  'tool': 'run_command',
                  'args': {'command': 'git status'},
                  'createdAt': DateTime.now().toIso8601String(),
                }
              ]
            }),
            200,
          );
        }
        return http.Response('Not Found', 404);
      });

      final bridge = PcBridgeClient(
          serverUrl: 'http://localhost:3000', httpClient: mockClient);
      final list = await bridge.getPendingApprovals();

      expect(list.length, equals(1));
      expect(list.first['id'], equals('appr-abc-123'));
      expect(list.first['tool'], equals('run_command'));
    });

    test('resolveApproval sends approval decision with correct payload',
        () async {
      String? recordedId;
      Map<String, dynamic>? recordedBody;

      final mockClient = MockClient((req) async {
        if (req.url.path.startsWith('/api/approvals/') &&
            req.url.path.endsWith('/decision')) {
          recordedId = req.url.pathSegments[2];
          recordedBody = jsonDecode(req.body) as Map<String, dynamic>;
          return http.Response(jsonEncode({'ok': true}), 200);
        }
        return http.Response('Not Found', 404);
      });

      final bridge = PcBridgeClient(
          serverUrl: 'http://localhost:3000', httpClient: mockClient);
      final res = await bridge.resolveApproval(
        approvalId: 'appr-xyz-789',
        approved: true,
        note: 'Approved via fingerprint on phone',
      );

      expect(res, isTrue);
      expect(recordedId, equals('appr-xyz-789'));
      expect(recordedBody?['approved'], isTrue);
      expect(
          recordedBody?['note'], equals('Approved via fingerprint on phone'));
    });
  });
}
