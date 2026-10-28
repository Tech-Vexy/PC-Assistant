import 'dart:io';
import 'package:flutter/material.dart';
import '../../../core/database/local_database.dart';
import '../../../core/network/discovery_service.dart';
import '../../../core/network/pc_bridge_client.dart';
import '../../../core/security/key_vault.dart';

class SettingsScreen extends StatefulWidget {
  final KeyVault keyVault;
  final LocalDatabase database;

  const SettingsScreen({
    super.key,
    required this.keyVault,
    required this.database,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _geminiCtrl = TextEditingController();
  final _nebiusCtrl = TextEditingController();
  final _nebiusEndpointCtrl = TextEditingController();
  final _nebiusSuperModelCtrl = TextEditingController();
  final _nebiusNanoModelCtrl = TextEditingController();
  final _pcUrlCtrl = TextEditingController();
  final _hotwordPhraseCtrl = TextEditingController();

  final _discoveryService = DiscoveryService();
  bool _isScanningPc = false;
  List<DiscoveredPcServer> _discoveredServers = [];

  bool _isTestingPc = false;
  Map<String, dynamic>? _pcHealthResult;
  bool _isSaving = false;
  bool _hotwordEnabled = true;

  @override
  void initState() {
    super.initState();
    _loadCurrentValues();
  }

  Future<void> _loadCurrentValues() async {
    _geminiCtrl.text = (await widget.keyVault.getGeminiApiKey()) ?? '';
    _nebiusCtrl.text = (await widget.keyVault.getNebiusApiKey()) ?? '';
    _nebiusEndpointCtrl.text = await widget.keyVault.getNebiusEndpoint();
    _nebiusSuperModelCtrl.text = await widget.keyVault.getNebiusSuperModel();
    _nebiusNanoModelCtrl.text = await widget.keyVault.getNebiusNanoModel();
    _pcUrlCtrl.text = await widget.keyVault.getPcServerUrl();
    _hotwordEnabled = await widget.keyVault.isHotwordEnabled();
    _hotwordPhraseCtrl.text = await widget.keyVault.getCustomHotword();
    if (mounted) setState(() {});
  }

  Future<void> _saveAll() async {
    setState(() => _isSaving = true);
    try {
      if (_geminiCtrl.text.trim().isNotEmpty) {
        await widget.keyVault.setGeminiApiKey(_geminiCtrl.text.trim());
      }
      if (_nebiusCtrl.text.trim().isNotEmpty) {
        await widget.keyVault.setNebiusApiKey(_nebiusCtrl.text.trim());
      }
      if (_nebiusEndpointCtrl.text.trim().isNotEmpty) {
        await widget.keyVault
            .setNebiusEndpoint(_nebiusEndpointCtrl.text.trim());
      }
      if (_nebiusSuperModelCtrl.text.trim().isNotEmpty) {
        await widget.keyVault
            .setNebiusSuperModel(_nebiusSuperModelCtrl.text.trim());
      }
      if (_nebiusNanoModelCtrl.text.trim().isNotEmpty) {
        await widget.keyVault
            .setNebiusNanoModel(_nebiusNanoModelCtrl.text.trim());
      }
      await widget.keyVault.setPcServerUrl(_pcUrlCtrl.text.trim());
      await widget.keyVault.setHotwordEnabled(_hotwordEnabled);
      if (_hotwordPhraseCtrl.text.trim().isNotEmpty) {
        await widget.keyVault.setCustomHotword(_hotwordPhraseCtrl.text.trim());
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.green,
            content: Text('All settings saved securely to hardware keystore.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _testPcConnection() async {
    setState(() {
      _isTestingPc = true;
      _pcHealthResult = null;
    });

    try {
      final url = _pcUrlCtrl.text.trim();
      if (url.isEmpty) {
        setState(() {
          _pcHealthResult = {'connected': false, 'error': 'No URL configured'};
        });
        return;
      }

      final bridge = PcBridgeClient(serverUrl: url);
      final result = await bridge.checkHealth();
      if (mounted) {
        setState(() => _pcHealthResult = result);
      }
    } catch (e) {
      if (mounted) {
        setState(() =>
            _pcHealthResult = {'connected': false, 'error': e.toString()});
      }
    } finally {
      if (mounted) setState(() => _isTestingPc = false);
    }
  }

  Future<void> _scanForPcServers() async {
    setState(() {
      _isScanningPc = true;
      _discoveredServers = [];
    });
    try {
      final servers = await _discoveryService.discoverServers(
          timeout: const Duration(seconds: 2));
      if (mounted) {
        setState(() => _discoveredServers = servers);
        if (servers.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  'No PC Assistant servers found via UDP broadcast. Ensure PC server is running on the same network.'),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: Colors.green,
              content: Text(
                  'Discovered ${servers.length} PC Assistant server(s) on Wi-Fi.'),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              backgroundColor: Colors.red, content: Text('Scan error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isScanningPc = false);
    }
  }

  void _selectDiscoveredServer(DiscoveredPcServer server) {
    setState(() {
      _pcUrlCtrl.text = server.url;
    });
    _testPcConnection();
  }

  void _confirmClearKeys() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear All API Keys?'),
        content: const Text(
          'This will remove all stored API keys from the hardware keystore. '
          'You will need to reconfigure them to use voice and planning features.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              await widget.keyVault.clearAll();
              if (ctx.mounted) Navigator.pop(ctx);
              await _loadCurrentValues();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      backgroundColor: Colors.red,
                      content: Text('All API keys cleared.')),
                );
              }
            },
            child: const Text('Clear All Keys'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _geminiCtrl.dispose();
    _nebiusCtrl.dispose();
    _nebiusEndpointCtrl.dispose();
    _nebiusSuperModelCtrl.dispose();
    _nebiusNanoModelCtrl.dispose();
    _pcUrlCtrl.dispose();
    _hotwordPhraseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          _isSaving
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : IconButton(
                  icon: const Icon(Icons.save),
                  tooltip: 'Save All',
                  onPressed: _saveAll,
                ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // --- API Keys Section ---
          _buildSectionHeader(
              Icons.key, 'API Keys', 'Stored in hardware-backed keystore'),
          const SizedBox(height: 12),
          _buildSecureField(
            controller: _geminiCtrl,
            label: 'Google Gemini API Key',
            hint: 'Used for Gemini Live speech-to-speech and vision',
            icon: Icons.mic,
          ),
          const SizedBox(height: 12),
          _buildSecureField(
            controller: _nebiusCtrl,
            label: 'Nebius Token Factory API Key',
            hint: 'Used for Nemotron-3-super-vl task planning',
            icon: Icons.psychology,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _nebiusEndpointCtrl,
            decoration: InputDecoration(
              labelText: 'Nebius API Endpoint',
              hintText: 'https://api.studio.nebius.ai/v1',
              prefixIcon: const Icon(Icons.link),
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.indigo.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
              border:
                  Border.all(color: Colors.indigoAccent.withValues(alpha: 0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.alt_route, color: Colors.indigoAccent, size: 18),
                    SizedBox(width: 8),
                    Text(
                      'Smart Model Routing',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: Colors.indigoAccent),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Complex tasks (multi-step planning, visual inspection, deep sub-agents) route to Nemotron 3 super vl. '
                  'Simple tasks (memory extraction, fast QA, simple tool calls) route to Nemotron 3 nano.',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _nebiusSuperModelCtrl,
            decoration: InputDecoration(
              labelText: 'Complex Tasks Model (Super VL)',
              hintText: 'nvidia/nemotron-3-super-vl',
              prefixIcon: const Icon(Icons.psychology_alt),
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _nebiusNanoModelCtrl,
            decoration: InputDecoration(
              labelText: 'Simple Tasks Model (Nano)',
              hintText: 'nvidia/nemotron-3-nano',
              prefixIcon: const Icon(Icons.flash_on),
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),

          const SizedBox(height: 28),

          // --- Voice Wake-up & Hotword Section ---
          _buildSectionHeader(
              Icons.record_voice_over,
              'Voice Wake-up & Hotword',
              'Always-on on-device voice trigger (Google Hotword style)'),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Always-On Hotword Detection',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 14)),
                    subtitle: const Text(
                        'Listens continuously in background for wake words without draining battery',
                        style: TextStyle(fontSize: 12)),
                    value: _hotwordEnabled,
                    onChanged: (val) => setState(() => _hotwordEnabled = val),
                  ),
                  if (_hotwordEnabled) ...[
                    const Divider(),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _hotwordPhraseCtrl,
                      decoration: InputDecoration(
                        labelText: 'Primary Wake Phrase',
                        hintText:
                            'e.g. hey assistant, ok google, computer, jarvis',
                        prefixIcon: const Icon(Icons.mic_none),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12)),
                        helperText:
                            'Spotted locally on-device. You can also say commands directly: "Hey Assistant, open YouTube".',
                        helperMaxLines: 2,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        'hey assistant',
                        'ok google',
                        'device assistant',
                        'computer',
                        'jarvis',
                      ]
                          .map((preset) => ActionChip(
                                label: Text(preset,
                                    style: const TextStyle(fontSize: 11)),
                                onPressed: () => setState(
                                    () => _hotwordPhraseCtrl.text = preset),
                              ))
                          .toList(),
                    ),
                  ],
                ],
              ),
            ),
          ),

          const SizedBox(height: 28),

          // --- PC Bridge Section ---
          _buildSectionHeader(Icons.computer, 'PC Bridge (Cross-Device)',
              'Link to desktop PC Assistant for delegation'),
          const SizedBox(height: 12),
          TextField(
            controller: _pcUrlCtrl,
            decoration: InputDecoration(
              labelText: 'PC Assistant Server URL',
              hintText: 'http://192.168.x.x:3000 or http://localhost:3000',
              prefixIcon: const Icon(Icons.dns),
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                icon: _isScanningPc
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.radar, size: 18),
                label: const Text('Auto-Discover (Wi-Fi)'),
                onPressed: _isScanningPc ? null : _scanForPcServers,
              ),
              ElevatedButton.icon(
                icon: _isTestingPc
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.wifi_tethering, size: 18),
                label: const Text('Test Connection'),
                onPressed: _isTestingPc ? null : _testPcConnection,
              ),
            ],
          ),
          if (_discoveredServers.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.indigo.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: Colors.indigoAccent.withValues(alpha: 0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.devices, size: 18, color: Colors.indigoAccent),
                      SizedBox(width: 8),
                      Text('Discovered PC Servers',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 13)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ..._discoveredServers.map((s) => ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.laptop),
                        title: Text('${s.hostname} (${s.platform})'),
                        subtitle:
                            Text(s.url, style: const TextStyle(fontSize: 12)),
                        trailing: ElevatedButton(
                          onPressed: () => _selectDiscoveredServer(s),
                          child: const Text('Connect'),
                        ),
                      )),
                ],
              ),
            ),
          ],
          if (_pcHealthResult != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: _pcHealthResult!['connected'] == true
                    ? Colors.green.withValues(alpha: 0.1)
                    : Colors.red.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _pcHealthResult!['connected'] == true
                      ? Colors.green
                      : Colors.red,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _pcHealthResult!['connected'] == true
                        ? Icons.check_circle
                        : Icons.error_outline,
                    size: 18,
                    color: _pcHealthResult!['connected'] == true
                        ? Colors.green
                        : Colors.red,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _pcHealthResult!['connected'] == true
                          ? 'Connected — Server healthy'
                          : 'Failed: ${_pcHealthResult!['error'] ?? 'Unreachable'}',
                      style: TextStyle(
                        fontSize: 12,
                        color: _pcHealthResult!['connected'] == true
                            ? Colors.green
                            : Colors.red,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 28),

          // --- About Section ---
          _buildSectionHeader(
              Icons.info_outline, 'About', 'System and database information'),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _buildInfoRow('Platform',
                      '${Platform.operatingSystem} ${Platform.operatingSystemVersion}'),
                  _buildInfoRow(
                      'Dart Version', Platform.version.split(' ').first),
                  _buildInfoRow(
                      'Processors', '${Platform.numberOfProcessors} cores'),
                  _buildInfoRow(
                      'Database',
                      widget.database.isInitialized
                          ? 'Initialized (Encrypted)'
                          : 'Not initialized'),
                  _buildInfoRow('App Version', '1.0.0+1'),
                ],
              ),
            ),
          ),

          const SizedBox(height: 28),

          // --- Danger Zone ---
          _buildSectionHeader(
              Icons.warning_amber, 'Danger Zone', 'Irreversible actions',
              color: Colors.red),
          const SizedBox(height: 12),
          Card(
            color: Colors.red.withValues(alpha: 0.05),
            shape: RoundedRectangleBorder(
              side: BorderSide(color: Colors.red.withValues(alpha: 0.3)),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.key_off, color: Colors.redAccent),
                    title: const Text('Clear All API Keys'),
                    subtitle: const Text(
                        'Removes all credentials from the hardware keystore',
                        style: TextStyle(fontSize: 12)),
                    trailing: OutlinedButton(
                      style:
                          OutlinedButton.styleFrom(foregroundColor: Colors.red),
                      onPressed: _confirmClearKeys,
                      child: const Text('Clear'),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(IconData icon, String title, String subtitle,
      {Color? color}) {
    return Row(
      children: [
        Icon(icon, color: color ?? Colors.indigoAccent, size: 22),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 16, color: color)),
            Text(subtitle,
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
      ],
    );
  }

  Widget _buildSecureField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
  }) {
    return TextField(
      controller: controller,
      obscureText: true,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        suffixIcon: IconButton(
          icon: const Icon(Icons.visibility_off, size: 18),
          onPressed: () {},
          tooltip: 'Keys are always obscured',
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey, fontSize: 13)),
          Text(value,
              style:
                  const TextStyle(fontWeight: FontWeight.w500, fontSize: 13)),
        ],
      ),
    );
  }
}
