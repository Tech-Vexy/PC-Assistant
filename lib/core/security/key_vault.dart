import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secure hardware-backed vault for sensitive credentials and keys.
/// Uses Android Keystore on Android, Windows DPAPI on Windows,
/// and SecretService/Keyring on Linux.
class KeyVault {
  static const _geminiKey = 'KEY_GEMINI_API';
  static const _geminiModelKey = 'KEY_GEMINI_MODEL';
  static const _geminiEndpointKey = 'KEY_GEMINI_ENDPOINT';
  static const _nebiusKey = 'KEY_NEBIUS_API';
  static const _nebiusEndpointKey = 'KEY_NEBIUS_ENDPOINT';
  static const _nebiusSuperEndpointKey = 'KEY_NEBIUS_SUPER_ENDPOINT';
  static const _nebiusNanoEndpointKey = 'KEY_NEBIUS_NANO_ENDPOINT';
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
    final stored = await _storage.read(key: _geminiKey);
    if (stored != null && stored.isNotEmpty) {
      return stored;
    }
    try {
      final env = Platform.environment['GEMINI_API_KEY'];
      if (env != null && env.isNotEmpty) {
        return env;
      }
    } catch (_) {}
    const defineVal = String.fromEnvironment('GEMINI_API_KEY');
    if (defineVal.isNotEmpty) {
      return defineVal;
    }
    return null;
  }

  /// Saves the Gemini Model identifier (default: gemini-3.8-flash)
  Future<void> setGeminiModel(String model) async {
    await _storage.write(key: _geminiModelKey, value: model.trim());
  }

  /// Retrieves the Gemini Model identifier (default: gemini-3.8-flash)
  Future<String> getGeminiModel() async {
    final custom = await _storage.read(key: _geminiModelKey);
    if (custom != null && custom.isNotEmpty) {
      return custom;
    }
    return 'gemini-3.8-flash';
  }

  /// Saves the Google Cloud Serverless inference endpoint / host
  Future<void> setGeminiEndpoint(String endpoint) async {
    await _storage.write(key: _geminiEndpointKey, value: endpoint.trim());
  }

  /// Retrieves the Google Cloud Serverless inference endpoint / host (default: generativelanguage.googleapis.com)
  Future<String> getGeminiEndpoint() async {
    final custom = await _storage.read(key: _geminiEndpointKey);
    if (custom != null && custom.isNotEmpty) {
      return custom;
    }
    return 'generativelanguage.googleapis.com';
  }

  /// Saves the Nebius Token Factory API Key
  Future<void> setNebiusApiKey(String key) async {
    await _storage.write(key: _nebiusKey, value: key.trim());
  }

  /// Retrieves the Nebius Token Factory API Key
  Future<String?> getNebiusApiKey() async {
    final stored = await _storage.read(key: _nebiusKey);
    if (stored != null && stored.isNotEmpty) {
      return stored;
    }
    try {
      final env = Platform.environment['NEBIUS_API_KEY'];
      if (env != null && env.isNotEmpty) {
        return env;
      }
    } catch (_) {}
    const defineVal = String.fromEnvironment('NEBIUS_API_KEY');
    if (defineVal.isNotEmpty) {
      return defineVal;
    }
    return null;
  }

  /// Saves the Nebius Token Factory API Base Endpoint
  Future<void> setNebiusEndpoint(String endpoint) async {
    await _storage.write(key: _nebiusEndpointKey, value: endpoint.trim());
  }

  /// Retrieves the Nebius endpoint (defaults to region-agnostic Token Factory endpoint)
  Future<String> getNebiusEndpoint() async {
    final custom = await _storage.read(key: _nebiusEndpointKey);
    if (custom != null && custom.isNotEmpty) {
      return custom;
    }
    return 'https://api.tokenfactory.nebius.com/v1';
  }

  /// Alias for getNebiusEndpoint()
  Future<String> getNebiusBaseEndpoint() => getNebiusEndpoint();

  /// Saves the dedicated endpoint for Complex Tasks (Nemotron 3.5 Super VL)
  Future<void> setNebiusSuperEndpoint(String endpoint) async {
    await _storage.write(key: _nebiusSuperEndpointKey, value: endpoint.trim());
  }

  /// Retrieves the dedicated endpoint for Complex Tasks (Nemotron 3.5 Super VL)
  Future<String> getNebiusSuperEndpoint() async {
    final custom = await _storage.read(key: _nebiusSuperEndpointKey);
    if (custom != null && custom.isNotEmpty) {
      return custom;
    }
    return getNebiusEndpoint();
  }

  /// Alias for getNebiusSuperEndpoint()
  Future<String> getNebiusSuperVlEndpoint() => getNebiusSuperEndpoint();

  /// Saves the dedicated endpoint for Simple Tasks (Nemotron 3 Nano 30B)
  Future<void> setNebiusNanoEndpoint(String endpoint) async {
    await _storage.write(key: _nebiusNanoEndpointKey, value: endpoint.trim());
  }

  /// Retrieves the dedicated endpoint for Simple Tasks (Nemotron 3 Nano 30B)
  Future<String> getNebiusNanoEndpoint() async {
    final custom = await _storage.read(key: _nebiusNanoEndpointKey);
    if (custom != null && custom.isNotEmpty) {
      return custom;
    }
    return getNebiusEndpoint();
  }

  /// Saves the model identifier used for complex reasoning tasks (default: nvidia/Nemotron-3.5-Super-VL)
  Future<void> setNebiusSuperModel(String model) async {
    await _storage.write(key: _nebiusSuperModelKey, value: model.trim());
  }

  /// Retrieves the model identifier for complex reasoning tasks
  Future<String> getNebiusSuperModel() async {
    final custom = await _storage.read(key: _nebiusSuperModelKey);
    if (custom != null &&
        custom.isNotEmpty &&
        custom != 'nvidia/nemotron-3-super-vl') {
      return custom;
    }
    return 'nvidia/Nemotron-3.5-Super-VL';
  }

  /// Alias for getNebiusSuperModel()
  Future<String> getNebiusSuperVlModel() => getNebiusSuperModel();

  /// Saves the model identifier used for simple/fast tasks (default: nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B)
  Future<void> setNebiusNanoModel(String model) async {
    await _storage.write(key: _nebiusNanoModelKey, value: model.trim());
  }

  /// Retrieves the model identifier for simple/fast tasks
  Future<String> getNebiusNanoModel() async {
    final custom = await _storage.read(key: _nebiusNanoModelKey);
    if (custom != null &&
        custom.isNotEmpty &&
        custom != 'nvidia/nemotron-3-nano') {
      return custom;
    }
    return 'nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B';
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
    await _storage.write(
        key: _hotwordEnabledKey, value: enabled ? 'true' : 'false');
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

  /// Alias for clearAll()
  Future<void> clearAllKeys() => clearAll();
}
