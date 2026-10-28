import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secure hardware-backed vault for sensitive credentials and keys.
/// Uses Android Keystore on Android, Windows DPAPI on Windows,
/// and SecretService/Keyring on Linux.
class KeyVault {
  static const _geminiKey = 'KEY_GEMINI_API';
  static const _nebiusKey = 'KEY_NEBIUS_API';
  static const _nebiusEndpointKey = 'KEY_NEBIUS_ENDPOINT';
  static const _nebiusSuperModelKey = 'KEY_NEBIUS_SUPER_MODEL';
  static const _nebiusNanoModelKey = 'KEY_NEBIUS_NANO_MODEL';
  static const _dbPassphraseKey = 'KEY_DB_PASSPHRASE';
  static const _pcServerUrlKey = 'KEY_PC_SERVER_URL';
  static const _hotwordEnabledKey = 'KEY_HOTWORD_ENABLED';
  static const _hotwordPhraseKey = 'KEY_HOTWORD_PHRASE';

  final FlutterSecureStorage _storage;

  KeyVault({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  /// Saves the PC Assistant Server URL (e.g. http://localhost:3000 or LAN IP)
  Future<void> setPcServerUrl(String url) async {
    await _storage.write(key: _pcServerUrlKey, value: url.trim());
  }

  /// Retrieves the PC Assistant Server URL (default http://127.0.0.1:3000)
  Future<String> getPcServerUrl() async {
    final custom = await _storage.read(key: _pcServerUrlKey);
    if (custom != null && custom.isNotEmpty) {
      return custom;
    }
    return 'http://127.0.0.1:3000';
  }

  /// Saves the Google Gemini API Key
  Future<void> setGeminiApiKey(String key) async {
    await _storage.write(key: _geminiKey, value: key.trim());
  }

  /// Retrieves the Google Gemini API Key
  Future<String?> getGeminiApiKey() async {
    return await _storage.read(key: _geminiKey);
  }

  /// Saves the Nebius Token Factory API Key
  Future<void> setNebiusApiKey(String key) async {
    await _storage.write(key: _nebiusKey, value: key.trim());
  }

  /// Retrieves the Nebius Token Factory API Key
  Future<String?> getNebiusApiKey() async {
    return await _storage.read(key: _nebiusKey);
  }

  /// Saves the Nebius Token Factory API Base Endpoint
  Future<void> setNebiusEndpoint(String endpoint) async {
    await _storage.write(key: _nebiusEndpointKey, value: endpoint.trim());
  }

  /// Retrieves the Nebius endpoint (defaults to official studio endpoint)
  Future<String> getNebiusEndpoint() async {
    final custom = await _storage.read(key: _nebiusEndpointKey);
    if (custom != null && custom.isNotEmpty) {
      return custom;
    }
    return 'https://api.studio.nebius.ai/v1';
  }

  /// Saves the model identifier used for complex reasoning tasks (default: nvidia/nemotron-3-super-vl)
  Future<void> setNebiusSuperModel(String model) async {
    await _storage.write(key: _nebiusSuperModelKey, value: model.trim());
  }

  /// Retrieves the model identifier for complex reasoning tasks
  Future<String> getNebiusSuperModel() async {
    final custom = await _storage.read(key: _nebiusSuperModelKey);
    if (custom != null && custom.isNotEmpty) {
      return custom;
    }
    return 'nvidia/nemotron-3-super-vl';
  }

  /// Saves the model identifier used for simple/fast tasks (default: nvidia/nemotron-3-nano)
  Future<void> setNebiusNanoModel(String model) async {
    await _storage.write(key: _nebiusNanoModelKey, value: model.trim());
  }

  /// Retrieves the model identifier for simple/fast tasks
  Future<String> getNebiusNanoModel() async {
    final custom = await _storage.read(key: _nebiusNanoModelKey);
    if (custom != null && custom.isNotEmpty) {
      return custom;
    }
    return 'nvidia/nemotron-3-nano';
  }

  /// Retrieves or generates a persistent 256-bit passphrase for local DB encryption
  Future<String> getOrCreateDatabasePassphrase() async {
    var pass = await _storage.read(key: _dbPassphraseKey);
    if (pass == null || pass.isEmpty) {
      final random = Random.secure();
      final bytes = List<int>.generate(32, (_) => random.nextInt(256));
      pass = sha256.convert(bytes).toString();
      await _storage.write(key: _dbPassphraseKey, value: pass);
    }
    return pass;
  }

  /// Checks if all necessary keys have been configured
  Future<bool> hasRequiredKeys() async {
    final gemini = await getGeminiApiKey();
    return gemini != null && gemini.isNotEmpty;
  }

  /// Saves whether continuous background hotword detection is enabled
  Future<void> setHotwordEnabled(bool enabled) async {
    await _storage.write(key: _hotwordEnabledKey, value: enabled ? 'true' : 'false');
  }

  /// Retrieves whether continuous background hotword detection is enabled (default true)
  Future<bool> isHotwordEnabled() async {
    final val = await _storage.read(key: _hotwordEnabledKey);
    return val != 'false';
  }

  /// Saves the custom primary hotword wake phrase (e.g. "hey assistant")
  Future<void> setCustomHotword(String phrase) async {
    await _storage.write(key: _hotwordPhraseKey, value: phrase.trim());
  }

  /// Retrieves the custom primary hotword wake phrase (default: "hey assistant")
  Future<String> getCustomHotword() async {
    final val = await _storage.read(key: _hotwordPhraseKey);
    if (val != null && val.isNotEmpty) return val;
    return 'hey assistant';
  }

  /// Clears all stored credentials
  Future<void> clearAll() async {
    await _storage.deleteAll();
  }
}
