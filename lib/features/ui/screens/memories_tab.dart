import 'package:flutter/material.dart';
import '../../../core/database/local_database.dart';
import '../../../core/network/pc_bridge_client.dart';
import '../../../core/security/key_vault.dart';

class MemoriesTab extends StatefulWidget {
  final LocalDatabase database;
  final KeyVault? keyVault;

  const MemoriesTab({
    super.key,
    required this.database,
    this.keyVault,
  });

  @override
  State<MemoriesTab> createState() => _MemoriesTabState();
}

class _MemoriesTabState extends State<MemoriesTab> {
  String? _selectedCategory;
  List<Map<String, dynamic>> _memories = [];
  final _searchController = TextEditingController();
  bool _isSyncing = false;

  final List<String> _categories = [
    'all',
    'preference',
    'location',
    'workflow',
    'general',
  ];

  @override
  void initState() {
    super.initState();
    _loadMemories();
  }

  void _loadMemories() {
    setState(() {
      final cat = _selectedCategory == 'all' ? null : _selectedCategory;
      _memories = widget.database.listMemories(category: cat);
    });
  }

  void _showAddMemoryDialog([Map<String, dynamic>? existing]) {
    final keyCtrl = TextEditingController(text: existing?['key'] ?? '');
    final valCtrl = TextEditingController(text: existing?['value'] ?? '');
    String category = existing?['category'] ?? 'general';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(existing == null ? 'Add Memory' : 'Edit Memory'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: keyCtrl,
                enabled: existing == null,
                decoration: const InputDecoration(
                  labelText: 'Key (identifier)',
                  hintText: 'e.g. favorite_coffee, home_address',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: valCtrl,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Value',
                  hintText: 'e.g. Oat milk cappuccino with extra shot',
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: category,
                decoration: const InputDecoration(labelText: 'Category'),
                items: ['general', 'preference', 'location', 'workflow']
                    .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                    .toList(),
                onChanged: (val) {
                  if (val != null) setDialogState(() => category = val);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                if (keyCtrl.text.trim().isNotEmpty &&
                    valCtrl.text.trim().isNotEmpty) {
                  widget.database.remember(
                    keyCtrl.text.trim(),
                    valCtrl.text.trim(),
                    category: category,
                  );
                  Navigator.pop(ctx);
                  _loadMemories();
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _deleteMemory(String key) {
    widget.database.forget(key);
    _loadMemories();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Memory "$key" forgotten.')),
    );
  }

  Future<void> _syncFromPc() async {
    if (widget.keyVault == null) return;
    setState(() => _isSyncing = true);
    try {
      final pcUrl = await widget.keyVault!.getPcServerUrl();
      final bridge = PcBridgeClient(serverUrl: pcUrl);
      final result = await bridge.syncMemories(widget.database);
      _loadMemories();
      if (mounted) {
        final synced = result['synced_count'] ?? 0;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor:
                result['status'] == 'success' ? Colors.green : Colors.red,
            content: Text(
              result['status'] == 'success'
                  ? 'Synced $synced memories from PC Assistant.'
                  : 'Sync failed: ${result['error']}',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              backgroundColor: Colors.red, content: Text('Sync error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _memories.where((m) {
      final query = _searchController.text.toLowerCase();
      if (query.isEmpty) return true;
      final k = (m['key'] as String).toLowerCase();
      final v = (m['value'] as String).toLowerCase();
      return k.contains(query) || v.contains(query);
    }).toList();

    return Scaffold(
      body: Column(
        children: [
          // Filter & Search bar
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: 'Search memories...',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      isDense: true,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                DropdownButton<String>(
                  value: _selectedCategory ?? 'all',
                  underline: const SizedBox(),
                  items: _categories
                      .map((c) => DropdownMenuItem(
                          value: c,
                          child: Text(c.toUpperCase(),
                              style: const TextStyle(fontSize: 12))))
                      .toList(),
                  onChanged: (val) {
                    setState(() {
                      _selectedCategory = val;
                      _loadMemories();
                    });
                  },
                ),
              ],
            ),
          ),

          // Memory items list
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.psychology_outlined,
                            size: 48, color: Colors.grey.shade600),
                        const SizedBox(height: 8),
                        Text('No memories saved in this category.',
                            style: TextStyle(color: Colors.grey.shade500)),
                      ],
                    ),
                  )
                : ListView.separated(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (ctx, idx) {
                      final item = filtered[idx];
                      final cat = item['category'] as String? ?? 'general';
                      final key = item['key'] as String;
                      final val = item['value'] as String;
                      final updated = DateTime.fromMillisecondsSinceEpoch(
                          item['updated_at'] as int);

                      return Card(
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor:
                                Colors.indigo.withValues(alpha: 0.2),
                            child: Icon(
                              cat == 'location'
                                  ? Icons.location_on_outlined
                                  : cat == 'preference'
                                      ? Icons.favorite_border
                                      : cat == 'workflow'
                                          ? Icons.account_tree_outlined
                                          : Icons.bookmark_outline,
                              color: Colors.indigoAccent,
                              size: 20,
                            ),
                          ),
                          title: Row(
                            children: [
                              Text(key,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold)),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.white10,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(cat,
                                    style: const TextStyle(
                                        fontSize: 10, color: Colors.grey)),
                              ),
                            ],
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 4),
                              Text(val),
                              const SizedBox(height: 2),
                              Text(
                                'Updated ${updated.toLocal().toString().split('.').first}',
                                style: const TextStyle(
                                    fontSize: 10, color: Colors.grey),
                              ),
                            ],
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit_outlined, size: 18),
                                onPressed: () => _showAddMemoryDialog(item),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline,
                                    size: 18, color: Colors.redAccent),
                                onPressed: () => _deleteMemory(key),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.keyVault != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FloatingActionButton(
                heroTag: 'sync_memories',
                onPressed: _isSyncing ? null : _syncFromPc,
                tooltip: 'Sync from PC',
                child: _isSyncing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.sync),
              ),
            ),
          FloatingActionButton.extended(
            heroTag: 'add_memory',
            onPressed: () => _showAddMemoryDialog(),
            icon: const Icon(Icons.add),
            label: const Text('Add Memory'),
          ),
        ],
      ),
    );
  }
}
