import 'dart:io';
import 'package:flutter/material.dart';
import '../../../core/database/local_database.dart';
import '../../../core/network/discovery_service.dart';
import '../../../core/network/nebius_client.dart';
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
  final _nebiusSuperEndpointCtrl = TextEditingController();
  final _nebiusSuperModelCtrl = TextEditingController();
  final _nebiusNanoEndpointCtrl = TextEditingController();
  final _nebiusNanoModelCtrl = TextEditingController();
  final _pcUrlCtrl = TextEditingController();
  final _hotwordPhraseCtrl = TextEditingController();

  final _discoveryService = DiscoveryService();
  bool _isScanningPc = false;
  List<DiscoveredPcServer> _discoveredServers = [];

  bool _isTestingPc = false;
  Map<String, dynamic>? _pcHealthResult;

  bool _isTestingSuperVl = false;
  Map<String, dynamic>? _superVlTestResult;

  bool _isTestingNano = false;
  Map<String, dynamic>? _nanoTestResult;

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
    _nebiusSuperEndpointCtrl.text =
        await widget.keyVault.getNebiusSuperEndpoint();
    _nebiusSuperModelCtrl.text = await widget.keyVault.getNebiusSuperModel();
    _nebiusNanoEndpointCtrl.text =
        await widget.keyVault.getNebiusNanoEndpoint();
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
      if (_nebiusSuperEndpointCtrl.text.trim().isNotEmpty) {
        await widget.keyVault
            .setNebiusSuperEndpoint(_nebiusSuperEndpointCtrl.text.trim());
      }
      if (_nebiusSuperModelCtrl.text.trim().isNotEmpty) {
        await widget.keyVault
            .setNebiusSuperModel(_nebiusSuperModelCtrl.text.trim());
      }
      if (_nebiusNanoEndpointCtrl.text.trim().isNotEmpty) {
        await widget.keyVault
            .setNebiusNanoEndpoint(_nebiusNanoEndpointCtrl.text.trim());
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

  Future<void> _testSuperVlEndpoint() async {
    setState(() {
      _isTestingSuperVl = true;
      _superVlTestResult = null;
    });

    try {
      final key = _nebiusCtrl.text.trim();
      final endpoint = _nebiusSuperEndpointCtrl.text.trim();
      final model = _nebiusSuperModelCtrl.text.trim();

      if (key.isEmpty) {
        setState(() {
          _superVlTestResult = {
            'success': false,
            'error': 'Nebius API Key required to test endpoint',
          };
        });
        return;
      }

      final client = NebiusClient(
        apiKey: key,
        superVlEndpoint: endpoint,
        superVlModel: model,
      );

      final res = await client.testConnection(
        endpoint: endpoint,
        model: model,
        complexity: TaskComplexity.complex,
      );
      if (mounted) setState(() => _superVlTestResult = res);
    } catch (e) {
      if (mounted) {
        setState(() => _superVlTestResult = {
              'success': false,
              'error': e.toString(),
            });
      }
    } finally {
      if (mounted) setState(() => _isTestingSuperVl = false);
    }
  }

  Future<void> _testNanoEndpoint() async {
    setState(() {
      _isTestingNano = true;
      _nanoTestResult = null;
    });

    try {
      final key = _nebiusCtrl.text.trim();
      final endpoint = _nebiusNanoEndpointCtrl.text.trim();
      final model = _nebiusNanoModelCtrl.text.trim();

      if (key.isEmpty) {
        setState(() {
          _nanoTestResult = {
            'success': false,
            'error': 'Nebius API Key required to test endpoint',
          };
        });
        return;
      }

      final client = NebiusClient(
        apiKey: key,
        nanoEndpoint: endpoint,
        nanoModel: model,
      );

      final res = await client.testConnection(
        endpoint: endpoint,
        model: model,
        complexity: TaskComplexity.simple,
      );
      if (mounted) setState(() => _nanoTestResult = res);
    } catch (e) {
      if (mounted) {
        setState(() => _nanoTestResult = {
              'success': false,
              'error': e.toString(),
            });
      }
    } finally {
      if (mounted) setState(() => _isTestingNano = false);
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
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Scan failed: $e')),
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Selected ${server.hostname} (${server.url})')),
    );
  }

  Future<void> _confirmClearKeys() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear All API Keys?'),
        content: const Text(
            'This will purge all API keys and custom server configurations from the secure storage.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear All Keys'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await widget.keyVault.clearAllKeys();
      _geminiCtrl.clear();
      _nebiusCtrl.clear();
      _nebiusSuperEndpointCtrl.text = 'https://api.tokenfactory.nebius.com/v1';
      _nebiusNanoEndpointCtrl.text = 'https://api.tokenfactory.nebius.com/v1';
      _nebiusSuperModelCtrl.text = 'nvidia/Nemotron-3.5-Super-VL';
      _nebiusNanoModelCtrl.text = 'nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B';
      _pcUrlCtrl.clear();
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.orange,
            content: Text('Keystore cleared.'),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _geminiCtrl.dispose();
    _nebiusCtrl.dispose();
    _nebiusSuperEndpointCtrl.dispose();
    _nebiusSuperModelCtrl.dispose();
    _nebiusNanoEndpointCtrl.dispose();
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
          // --- Nebius Token Factory Section ---
          _buildSectionHeader(
            Icons.psychology,
            'Nebius Token Factory & NVIDIA Nemotron',
            'Primary on-device reasoning engine & smart tool routing',
          ),
          const SizedBox(height: 12),
          _buildSecureField(
            controller: _nebiusCtrl,
            label: 'Nebius Token Factory API Key',
            hint: 'v1.CmQK...',
            icon: Icons.key,
          ),
          const SizedBox(height: 14),

          // Region-agnostic deployments info card
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
                    Icon(Icons.hub_outlined,
                        color: Colors.cyanAccent, size: 18),
                    SizedBox(width: 8),
                    Text(
                      'Region-Agnostic Deployments',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: Colors.cyanAccent),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Nebius deployments are region-agnostic (tokenfactory.nebius.com/endpoints). '
                  'Each model can point to its own dedicated endpoint URL or serverless base.',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // --- Complex Tasks: Nemotron 3.5 Super VL ---
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side:
                  BorderSide(color: Colors.indigoAccent.withValues(alpha: 0.3)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.psychology_alt,
                          color: Colors.indigoAccent, size: 20),
                      SizedBox(width: 8),
                      Text(
                        'Complex Tasks (Vision / Multimodal / Planning)',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _nebiusSuperModelCtrl,
                    decoration: InputDecoration(
                      labelText: 'Super VL Model ID',
                      hintText: 'nvidia/Nemotron-3.5-Super-VL',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10)),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    children: [
                      _buildChip(
                        label: 'Nemotron-3.5-Super-VL',
                        model: 'nvidia/Nemotron-3.5-Super-VL',
                        targetController: _nebiusSuperModelCtrl,
                      ),
                      _buildChip(
                        label: 'Super-120b',
                        model: 'nvidia/nemotron-3-super-120b-a12b',
                        targetController: _nebiusSuperModelCtrl,
                      ),
                      _buildChip(
                        label: 'Ultra-550b',
                        model: 'nvidia/Nemotron-3-Ultra-550b-a55b',
                        targetController: _nebiusSuperModelCtrl,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _nebiusSuperEndpointCtrl,
                    decoration: InputDecoration(
                      labelText: 'Super VL Dedicated Endpoint',
                      hintText: 'https://api.tokenfactory.nebius.com/v1',
                      prefixIcon: const Icon(Icons.link, size: 18),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10)),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      ElevatedButton.icon(
                        icon: _isTestingSuperVl
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.network_check, size: 16),
                        label: const Text('Test Super VL Endpoint'),
                        onPressed:
                            _isTestingSuperVl ? null : _testSuperVlEndpoint,
                      ),
                    ],
                  ),
                  if (_superVlTestResult != null) ...[
                    const SizedBox(height: 8),
                    _buildTestStatusCard(_superVlTestResult!),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),

          // --- Simple Tasks: Nemotron 3 Nano 30b ---
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: Colors.tealAccent.withValues(alpha: 0.3)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.flash_on, color: Colors.tealAccent, size: 20),
                      SizedBox(width: 8),
                      Text(
                        'Simple Tasks (Tools / Fast QA / Device Actions)',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _nebiusNanoModelCtrl,
                    decoration: InputDecoration(
                      labelText: 'Nano Model ID',
                      hintText: 'nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10)),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    children: [
                      _buildChip(
                        label: 'Nemotron-3-Nano-30b',
                        model: 'nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B',
                        targetController: _nebiusNanoModelCtrl,
                      ),
                      _buildChip(
                        label: 'Nemotron-3.5-Lightning',
                        model: 'nvidia/Nemotron-3_5-Lightning',
                        targetController: _nebiusNanoModelCtrl,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _nebiusNanoEndpointCtrl,
                    decoration: InputDecoration(
                      labelText: 'Nano Dedicated Endpoint',
                      hintText: 'https://api.tokenfactory.nebius.com/v1',
                      prefixIcon: const Icon(Icons.link, size: 18),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10)),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      ElevatedButton.icon(
                        icon: _isTestingNano
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.network_check, size: 16),
                        label: const Text('Test Nano Endpoint'),
                        onPressed: _isTestingNano ? null : _testNanoEndpoint,
                      ),
                    ],
                  ),
                  if (_nanoTestResult != null) ...[
                    const SizedBox(height: 8),
                    _buildTestStatusCard(_nanoTestResult!),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 28),

          // --- Voice Wake-up & Device STT Section ---
          _buildSectionHeader(
              Icons.record_voice_over,
              'Voice Wake-up & Device STT',
              'On-device speech recognition & wake word detection'),
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
                        'Listens on-device for wake words with zero battery overhead',
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
                            'Processed on-device. Spoken commands route directly to NVIDIA Nemotron.',
                        helperMaxLines: 2,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 28),

          // --- Optional Google Gemini Section ---
          _buildSectionHeader(
              Icons.key, 'Google Gemini Key (Optional)', 'Live API fallback'),
          const SizedBox(height: 12),
          _buildSecureField(
            controller: _geminiCtrl,
            label: 'Google Gemini API Key',
            hint: 'Optional fallback key',
            icon: Icons.mic,
          ),
          const SizedBox(height: 28),

          // --- PC Bridge Section ---
          _buildSectionHeader(Icons.computer, 'PC Assistant Bridge',
              'Bi-directional bridge to desktop computer'),
          const SizedBox(height: 12),
          TextField(
            controller: _pcUrlCtrl,
            decoration: InputDecoration(
              labelText: 'PC Server URL',
              hintText: 'http://192.168.1.50:3000',
              prefixIcon: const Icon(Icons.lan),
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              ElevatedButton.icon(
                icon: _isTestingPc
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.network_check, size: 16),
                label: const Text('Test PC Connection'),
                onPressed: _isTestingPc ? null : _testPcConnection,
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                icon: _isScanningPc
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.radar, size: 16),
                label: const Text('Scan LAN'),
                onPressed: _isScanningPc ? null : _scanForPcServers,
              ),
            ],
          ),

          if (_pcHealthResult != null) ...[
            const SizedBox(height: 8),
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
                        : Icons.error,
                    size: 16,
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

          if (_discoveredServers.isNotEmpty) ...[
            const SizedBox(height: 12),
            Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('Discovered PC Servers',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  ..._discoveredServers.map((s) => ListTile(
                        leading: const Icon(Icons.desktop_windows),
                        title: Text(s.hostname),
                        subtitle: Text(s.url),
                        trailing: ElevatedButton(
                          onPressed: () => _selectDiscoveredServer(s),
                          child: const Text('Select'),
                        ),
                      )),
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
                  _buildInfoRow('Primary AI Engine', 'NVIDIA Nemotron 3.5 / 3'),
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

  Widget _buildChip({
    required String label,
    required String model,
    required TextEditingController targetController,
  }) {
    final isSelected = targetController.text.trim() == model;
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 11)),
      selected: isSelected,
      onSelected: (_) {
        setState(() {
          targetController.text = model;
        });
      },
    );
  }

  Widget _buildTestStatusCard(Map<String, dynamic> res) {
    final success = res['success'] == true;
    final msg = res['message'] ?? res['error'] ?? 'Unknown response';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: success
            ? Colors.green.withValues(alpha: 0.12)
            : Colors.red.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: success ? Colors.green : Colors.red,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            success ? Icons.check_circle : Icons.error,
            size: 16,
            color: success ? Colors.green : Colors.red,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              msg,
              style: TextStyle(
                fontSize: 11,
                color: success ? Colors.greenAccent : Colors.redAccent,
              ),
            ),
          ),
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
