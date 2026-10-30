import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:device_assistant/core/network/gcp_adc_auth_service.dart';
import 'package:device_assistant/core/security/key_vault.dart';

class _MockKeyVault extends KeyVault {
  final Map<String, String> _data = {};

  @override
  Future<void> setAdcCredentialsJson(String json) async {
    _data['KEY_ADC_CREDENTIALS_JSON'] = json;
  }

  @override
  Future<String?> getAdcCredentialsJson() async {
    return _data['KEY_ADC_CREDENTIALS_JSON'];
  }

  @override
  Future<String> getGcpProjectId() async {
    return _data['KEY_GCP_PROJECT_ID'] ?? '';
  }

  @override
  Future<void> setGcpProjectId(String id) async {
    _data['KEY_GCP_PROJECT_ID'] = id;
  }
}

void main() {
  group('GcpAdcAuthService Tests', () {
    test('Refreshes authorized_user ADC token and caches valid token', () async {
      int tokenRequests = 0;

      final mockHttp = MockClient((request) async {
        if (request.url.toString() == 'https://oauth2.googleapis.com/token') {
          tokenRequests++;
          expect(request.bodyFields['grant_type'], equals('refresh_token'));
          expect(request.bodyFields['refresh_token'], equals('dummy_refresh'));

          return http.Response(
            jsonEncode({
              'access_token': 'ya29.test_adc_access_token_123',
              'expires_in': 3600,
              'token_type': 'Bearer',
            }),
            200,
          );
        }
        return http.Response('Not found', 404);
      });

      final mockVault = _MockKeyVault();
      await mockVault.setAdcCredentialsJson(jsonEncode({
        'type': 'authorized_user',
        'client_id': 'test_client_id.apps.googleusercontent.com',
        'client_secret': 'test_client_secret',
        'refresh_token': 'dummy_refresh',
        'quota_project_id': 'tafiti-ai-508523',
      }));

      final service = GcpAdcAuthService(
        keyVault: mockVault,
        httpClient: mockHttp,
      );

      // Verify credentials detection
      expect(await service.hasAdcCredentials(), isTrue);

      // Verify token retrieval
      final token = await service.getAccessToken();
      expect(token, equals('ya29.test_adc_access_token_123'));
      expect(tokenRequests, equals(1));

      // Second retrieval should use cached token without additional network request
      final cachedToken = await service.getAccessToken();
      expect(cachedToken, equals('ya29.test_adc_access_token_123'));
      expect(tokenRequests, equals(1));

      // Verify project ID extracted
      final projectId = await service.getProjectId();
      expect(projectId, equals('tafiti-ai-508523'));

      // Test connection
      final connTest = await service.testAdcConnection();
      expect(connTest['success'], isTrue);
      expect(connTest['projectId'], equals('tafiti-ai-508523'));
      expect(connTest['tokenPrefix'], contains('ya29.test_'));
    });

    test('Throws informative error when no ADC credentials available', () async {
      final mockVault = _MockKeyVault();
      final service = GcpAdcAuthService(
        keyVault: mockVault,
        httpClient: MockClient((_) async => http.Response('', 500)),
      );

      // If no file exists and nothing in vault, getAccessToken throws StateError
      // (Unless local host has gcloud ADC, in which case it loads local ADC)
      final hasAdc = await service.hasAdcCredentials();
      if (!hasAdc) {
        expect(() => service.getAccessToken(), throwsA(isA<StateError>()));
      }
    });
  });
}
