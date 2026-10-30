import 'dart:convert';
import 'dart:io';
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;
import '../security/key_vault.dart';

/// Service to resolve, exchange, and auto-refresh Google Cloud
/// Application Default Credentials (ADC) for Serverless Gemini 3.8 Flash inference.
class GcpAdcAuthService {
  static const List<String> cloudPlatformScopes = [
    'https://www.googleapis.com/auth/cloud-platform',
  ];

  static const String oauthTokenEndpoint =
      'https://oauth2.googleapis.com/token';

  final KeyVault? keyVault;
  final http.Client _httpClient;

  String? _cachedAccessToken;
  DateTime? _tokenExpiry;
  String? _cachedProjectId;

  GcpAdcAuthService({
    this.keyVault,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  /// Retrieves a valid, fresh Google Cloud OAuth2 Access Token via ADC.
  /// Automatically refreshes before expiration.
  Future<String> getAccessToken({bool forceRefresh = false}) async {
    final now = DateTime.now();
    if (!forceRefresh &&
        _cachedAccessToken != null &&
        _tokenExpiry != null &&
        _tokenExpiry!.isAfter(now.add(const Duration(minutes: 5)))) {
      return _cachedAccessToken!;
    }

    final creds = await loadAdcCredentialsMap();
    if (creds == null) {
      throw StateError(
        'Google Cloud Application Default Credentials (ADC) not found.\n'
        'Run `gcloud auth application-default login` on desktop, set GOOGLE_APPLICATION_CREDENTIALS, '
        'or import your ADC credentials JSON in the assistant Settings.',
      );
    }

    final type = creds['type'] as String?;

    if (type == 'authorized_user') {
      // Standard gcloud user ADC with refresh token
      final clientId = creds['client_id'] as String?;
      final clientSecret = creds['client_secret'] as String?;
      final refreshToken = creds['refresh_token'] as String?;

      if (clientId == null || clientSecret == null || refreshToken == null) {
        throw StateError(
            'Malformed ADC credentials: missing client_id, client_secret, or refresh_token.');
      }

      final response = await _httpClient.post(
        Uri.parse(oauthTokenEndpoint),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'client_id': clientId,
          'client_secret': clientSecret,
          'refresh_token': refreshToken,
          'grant_type': 'refresh_token',
        },
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final token = data['access_token'] as String;
        final expiresIn = (data['expires_in'] as num?)?.toInt() ?? 3600;

        _cachedAccessToken = token;
        _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));
        _cachedProjectId =
            (creds['quota_project_id'] ?? creds['project_id']) as String?;

        return token;
      } else {
        throw StateError(
          'Failed to refresh ADC token (${response.statusCode}): ${response.body}',
        );
      }
    } else if (type == 'service_account') {
      // Standard Google Cloud Service Account JSON
      final saCredentials =
          ServiceAccountCredentials.fromJson(jsonEncode(creds));
      final authClient = await clientViaServiceAccount(
        saCredentials,
        cloudPlatformScopes,
        baseClient: _httpClient,
      );

      final token = authClient.credentials.accessToken.data;
      final expiry = authClient.credentials.accessToken.expiry;

      _cachedAccessToken = token;
      _tokenExpiry = expiry;
      _cachedProjectId =
          (creds['project_id'] ?? creds['quota_project_id']) as String?;

      return token;
    } else {
      throw StateError('Unsupported ADC credential type: "$type".');
    }
  }

  /// Resolves the active Google Cloud Project ID from ADC, KeyVault, or environment.
  Future<String?> getProjectId() async {
    if (_cachedProjectId != null && _cachedProjectId!.isNotEmpty) {
      return _cachedProjectId;
    }

    if (keyVault != null) {
      final kvProject = await keyVault!.getGcpProjectId();
      if (kvProject.isNotEmpty) {
        _cachedProjectId = kvProject;
        return kvProject;
      }
    }

    try {
      final envProject = Platform.environment['GOOGLE_CLOUD_PROJECT'] ??
          Platform.environment['GCLOUD_PROJECT'];
      if (envProject != null && envProject.isNotEmpty) {
        _cachedProjectId = envProject;
        return envProject;
      }
    } catch (_) {}

    final creds = await loadAdcCredentialsMap();
    if (creds != null) {
      final proj =
          (creds['quota_project_id'] ?? creds['project_id']) as String?;
      if (proj != null && proj.isNotEmpty) {
        _cachedProjectId = proj;
        return proj;
      }
    }

    return null;
  }

  /// Checks if ADC is available either locally on the file system or in secure storage.
  Future<bool> hasAdcCredentials() async {
    try {
      final creds = await loadAdcCredentialsMap();
      return creds != null && creds.containsKey('type');
    } catch (_) {
      return false;
    }
  }

  /// Loads the ADC credentials Map from KeyVault, environment, or default file locations.
  Future<Map<String, dynamic>?> loadAdcCredentialsMap() async {
    // 1. Check KeyVault (Android hardware storage / custom imported JSON)
    if (keyVault != null) {
      final storedJson = await keyVault!.getAdcCredentialsJson();
      if (storedJson != null && storedJson.trim().isNotEmpty) {
        try {
          return jsonDecode(storedJson) as Map<String, dynamic>;
        } catch (_) {}
      }
    }

    // 2. Check GCP_ADC_JSON or GCP_ADC_CREDENTIALS environment variable
    try {
      final directJson = Platform.environment['GCP_ADC_JSON'] ??
          Platform.environment['GCP_ADC_CREDENTIALS'];
      if (directJson != null && directJson.trim().startsWith('{')) {
        return jsonDecode(directJson) as Map<String, dynamic>;
      }
    } catch (_) {}

    // 3. Check GOOGLE_APPLICATION_CREDENTIALS environment variable
    try {
      final envPath = Platform.environment['GOOGLE_APPLICATION_CREDENTIALS'];
      if (envPath != null && envPath.isNotEmpty) {
        if (envPath.trim().startsWith('{')) {
          return jsonDecode(envPath) as Map<String, dynamic>;
        }
        final file = File(envPath);
        if (await file.exists()) {
          final content = await file.readAsString();
          return jsonDecode(content) as Map<String, dynamic>;
        }
      }
    } catch (_) {}

    // 3. Check default gcloud ADC path on Linux / macOS / Windows
    try {
      final defaultFile = getDefaultAdcFile();
      if (defaultFile != null && await defaultFile.exists()) {
        final content = await defaultFile.readAsString();
        return jsonDecode(content) as Map<String, dynamic>;
      }
    } catch (_) {}

    return null;
  }

  /// Returns standard default File location for gcloud ADC, or null on unsupported platform.
  static File? getDefaultAdcFile() {
    try {
      if (Platform.isLinux || Platform.isMacOS) {
        final home = Platform.environment['HOME'];
        if (home != null && home.isNotEmpty) {
          return File(
              '$home/.config/gcloud/application_default_credentials.json');
        }
      } else if (Platform.isWindows) {
        final appData = Platform.environment['APPDATA'];
        if (appData != null && appData.isNotEmpty) {
          return File('$appData\\gcloud\\application_default_credentials.json');
        }
      }
    } catch (_) {}
    return null;
  }

  /// Tests ADC authentication and verifies token generation
  Future<Map<String, dynamic>> testAdcConnection() async {
    final stopwatch = Stopwatch()..start();
    try {
      final token = await getAccessToken(forceRefresh: true);
      final projectId = await getProjectId();
      stopwatch.stop();

      return {
        'success': true,
        'tokenPrefix':
            token.length > 10 ? '${token.substring(0, 10)}...' : token,
        'projectId': projectId ?? 'Unknown',
        'latencyMs': stopwatch.elapsedMilliseconds,
      };
    } catch (e) {
      stopwatch.stop();
      return {
        'success': false,
        'error': e.toString(),
        'latencyMs': stopwatch.elapsedMilliseconds,
      };
    }
  }

  void dispose() {
    _httpClient.close();
  }
}
