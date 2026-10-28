import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

/// Information about a discovered PC Assistant server on the local network.
class DiscoveredPcServer {
  final String service;
  final String version;
  final String hostname;
  final String platform;
  final int port;
  final String ip;
  final String url;
  final DateTime discoveredAt;

  DiscoveredPcServer({
    required this.service,
    required this.version,
    required this.hostname,
    required this.platform,
    required this.port,
    required this.ip,
    required this.url,
    DateTime? discoveredAt,
  }) : discoveredAt = discoveredAt ?? DateTime.now();

  factory DiscoveredPcServer.fromJson(Map<String, dynamic> json) {
    return DiscoveredPcServer(
      service: json['service'] as String? ?? 'pc-assistant',
      version: json['version'] as String? ?? '1.0.0',
      hostname: json['hostname'] as String? ?? 'PC Assistant',
      platform: json['platform'] as String? ?? 'unknown',
      port: (json['port'] as num?)?.toInt() ?? 3000,
      ip: json['ip'] as String? ?? '127.0.0.1',
      url: json['url'] as String? ??
          'http://${json['ip'] ?? '127.0.0.1'}:${json['port'] ?? 3000}',
    );
  }

  Map<String, dynamic> toJson() => {
        'service': service,
        'version': version,
        'hostname': hostname,
        'platform': platform,
        'port': port,
        'ip': ip,
        'url': url,
        'discoveredAt': discoveredAt.toIso8601String(),
      };
}

/// Discovers running PC Assistant desktop servers across the local Wi-Fi / LAN subnet
/// using zero-configuration UDP broadcast probes and HTTP capability verification.
class DiscoveryService {
  static const int defaultDiscoveryPort = 35500;
  static const String discoveryMagic = 'PC_ASSISTANT_DISCOVERY';

  final http.Client _httpClient;

  DiscoveryService({http.Client? httpClient})
      : _httpClient = httpClient ?? http.Client();

  /// Scans the local network via UDP broadcast on port 35500.
  /// Returns a deduplicated list of discovered PC Assistant instances.
  Future<List<DiscoveredPcServer>> discoverServers({
    Duration timeout = const Duration(seconds: 2),
    int port = defaultDiscoveryPort,
  }) async {
    final discoveredMap = <String, DiscoveredPcServer>{};
    RawDatagramSocket? socket;

    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;

      final completer = Completer<void>();
      final timer = Timer(timeout, () {
        if (!completer.isCompleted) completer.complete();
      });

      socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = socket?.receive();
          if (datagram != null) {
            try {
              final text = utf8.decode(datagram.data);
              final json = jsonDecode(text) as Map<String, dynamic>;
              if (json['service'] == 'pc-assistant') {
                final server = DiscoveredPcServer.fromJson(json);
                discoveredMap[server.url] = server;
              }
            } catch (_) {
              // Ignore invalid or unrelated datagrams
            }
          }
        }
      });

      // Broadcast discovery probe
      final messageBytes = utf8.encode(discoveryMagic);
      socket.send(messageBytes, InternetAddress('255.255.255.255'), port);

      await completer.future;
      timer.cancel();
    } catch (_) {
      // Best-effort network discovery: if UDP broadcast fails on this interface, return empty list
    } finally {
      socket?.close();
    }

    return discoveredMap.values.toList();
  }

  /// Verifies if a given HTTP URL is an active PC Assistant server by querying /api/discovery or /health.
  Future<DiscoveredPcServer?> probeServer(String baseUrl) async {
    final cleanUrl = baseUrl.replaceAll(RegExp(r'/+$'), '');
    try {
      // Try /api/discovery first
      final discRes = await _httpClient
          .get(
            Uri.parse('$cleanUrl/api/discovery'),
          )
          .timeout(const Duration(seconds: 3));

      if (discRes.statusCode == 200) {
        final json = jsonDecode(discRes.body) as Map<String, dynamic>;
        if (json['service'] == 'pc-assistant') {
          return DiscoveredPcServer.fromJson(json);
        }
      }
    } catch (_) {}

    // Fallback: try /health
    try {
      final healthRes = await _httpClient
          .get(
            Uri.parse('$cleanUrl/health'),
          )
          .timeout(const Duration(seconds: 3));

      if (healthRes.statusCode == 200) {
        final parsedUri = Uri.parse(cleanUrl);
        return DiscoveredPcServer(
          service: 'pc-assistant',
          version: '1.0.0',
          hostname: parsedUri.host,
          platform: 'desktop',
          port: parsedUri.port > 0 ? parsedUri.port : 3000,
          ip: parsedUri.host,
          url: cleanUrl,
        );
      }
    } catch (_) {}

    return null;
  }
}
