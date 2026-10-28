import 'package:flutter/material.dart';
import '../../../core/database/local_database.dart';
import '../../../core/security/sensitive_app_guard.dart';
import '../../../platform/android/android_bridge.dart';

class SecurityShieldTab extends StatefulWidget {
  final LocalDatabase database;
  final SensitiveAppGuard guard;
  final AndroidBridge? androidBridge;

  const SecurityShieldTab({
    super.key,
    required this.database,
    required this.guard,
    this.androidBridge,
  });

  @override
  State<SecurityShieldTab> createState() => _SecurityShieldTabState();
}

class _SecurityShieldTabState extends State<SecurityShieldTab> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  Set<String> _customPackages = {};
  List<Map<String, dynamic>> _auditLogs = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadData();
  }

  void _loadData() {
    setState(() {
      _customPackages = widget.database.loadCustomProtectedPackages();
      _auditLogs = widget.database.getRecentAudits(limit: 100);
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _showAddCustomPackageDialog() {
    final pkgCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Protect App Package'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Add an application package ID to prevent Device Assistant from inspecting, screenshotting, or interacting with it.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: pkgCtrl,
              decoration: const InputDecoration(
                labelText: 'Package Name',
                hintText: 'e.g. com.example.privateapp',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              final pkg = pkgCtrl.text.trim();
              if (pkg.isNotEmpty) {
                widget.database.saveProtectedPackage(pkg);
                widget.guard.addProtectedPackage(pkg);
                widget.androidBridge?.updateProtectedPackages(widget.guard.customProtectedPackages.toList());
                Navigator.pop(ctx);
                _loadData();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Package "$pkg" added to shield.')),
                );
              }
            },
            child: const Text('Protect'),
          ),
        ],
      ),
    );
  }

  void _removeCustomPackage(String pkg) {
    widget.database.removeProtectedPackage(pkg);
    widget.guard.removeProtectedPackage(pkg);
    widget.androidBridge?.updateProtectedPackages(widget.guard.customProtectedPackages.toList());
    _loadData();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Package "$pkg" removed from shield.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(48),
        child: Material(
          color: const Color(0xFF181B22),
          child: TabBar(
            controller: _tabController,
            indicatorColor: Colors.amberAccent,
            tabs: const [
              Tab(icon: Icon(Icons.shield_outlined, size: 18), text: 'Shield Rules'),
              Tab(icon: Icon(Icons.security_update_good, size: 18), text: 'Custom Protected Apps'),
              Tab(icon: Icon(Icons.history, size: 18), text: 'Audit Logs'),
            ],
          ),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          // 1. Built-in Shield Rules Overview
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                color: Colors.amber.withValues(alpha: 0.08),
                shape: RoundedRectangleBorder(
                  side: const BorderSide(color: Colors.amber, width: 0.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Padding(
                  padding: EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(Icons.verified_user, color: Colors.amber, size: 36),
                      SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Sensitive App Shield Active', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                            SizedBox(height: 4),
                            Text(
                              'Prevents screen inspection, OCR, automation, and touch gestures on confidential and financial apps.',
                              style: TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text('Enforced Protection Policies', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              const SizedBox(height: 8),
              _buildPolicyTile(
                icon: Icons.sim_card_outlined,
                title: 'SIM Toolkit & Carrier Menus',
                subtitle: 'com.android.stk, stk2, MediaTek STK, Qualcomm UIM, Samsung STK. Blocks SIM-based credential theft.',
              ),
              _buildPolicyTile(
                icon: Icons.payments_outlined,
                title: 'Mobile Money & Carrier Wallets',
                subtitle: 'M-Pesa, Airtel Money, MTN MobileMoney, MyMTN. Prevents unintended mobile money transfers.',
              ),
              _buildPolicyTile(
                icon: Icons.account_balance_outlined,
                title: 'Banking & FinTech Applications',
                subtitle: 'Chase, BofA, Wells Fargo, Revolut, Monzo, PayPal, Cash App, Venmo, Wise.',
              ),
              _buildPolicyTile(
                icon: Icons.currency_bitcoin_outlined,
                title: 'Crypto & Web3 Wallets',
                subtitle: 'MetaMask, Coinbase, Trust Wallet, Binance, Ledger Live.',
              ),
              _buildPolicyTile(
                icon: Icons.password_outlined,
                title: '2FA & Password Managers',
                subtitle: 'Bitwarden, 1Password, LastPass, KeePass, Google Authenticator, Authy, Duo.',
              ),
              _buildPolicyTile(
                icon: Icons.visibility_off_outlined,
                title: 'Android FLAG_SECURE & CATEGORY_FINANCE',
                subtitle: 'Hardware-enforced secure windows and system-categorized finance packages are strictly halted.',
              ),
            ],
          ),

          // 2. Custom Protected Apps
          _customPackages.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add_moderator_outlined, size: 48, color: Colors.grey.shade600),
                      const SizedBox(height: 8),
                      Text('No custom apps protected yet.', style: TextStyle(color: Colors.grey.shade500)),
                      const SizedBox(height: 12),
                      ElevatedButton.icon(
                        onPressed: _showAddCustomPackageDialog,
                        icon: const Icon(Icons.add),
                        label: const Text('Add Protected App'),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _customPackages.length,
                  itemBuilder: (ctx, idx) {
                    final pkg = _customPackages.elementAt(idx);
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: const Icon(Icons.lock_outline, color: Colors.amber),
                        title: Text(pkg, style: const TextStyle(fontWeight: FontWeight.bold, fontFamily: 'monospace')),
                        subtitle: const Text('User-defined policy rule', style: TextStyle(fontSize: 11, color: Colors.grey)),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                          onPressed: () => _removeCustomPackage(pkg),
                        ),
                      ),
                    );
                  },
                ),

          // 3. Audit Logs
          _auditLogs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.history_edu_outlined, size: 48, color: Colors.grey.shade600),
                      const SizedBox(height: 8),
                      Text('No tool audit records yet.', style: TextStyle(color: Colors.grey.shade500)),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _auditLogs.length,
                  itemBuilder: (ctx, idx) {
                    final log = _auditLogs[idx];
                    final toolName = log['tool_name'] as String;
                    final isBlocked = (log['is_blocked'] as int? ?? 0) == 1;
                    final blockReason = log['block_reason'] as String?;
                    final time = DateTime.fromMillisecondsSinceEpoch(log['timestamp'] as int);

                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      color: isBlocked ? Colors.red.withValues(alpha: 0.08) : null,
                      child: ListTile(
                        leading: Icon(
                          isBlocked ? Icons.block : Icons.check_circle_outline,
                          color: isBlocked ? Colors.redAccent : Colors.greenAccent,
                        ),
                        title: Row(
                          children: [
                            Text(toolName, style: const TextStyle(fontWeight: FontWeight.bold)),
                            const Spacer(),
                            Text(
                              '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}',
                              style: const TextStyle(fontSize: 10, color: Colors.grey),
                            ),
                          ],
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (isBlocked && blockReason != null)
                              Text('BLOCKED: $blockReason', style: const TextStyle(color: Colors.redAccent, fontSize: 11))
                            else if (log['args_json'] != null)
                              Text('Args: ${log['args_json']}', style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: Colors.grey)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ],
      ),
      floatingActionButton: _tabController.index == 1
          ? FloatingActionButton(
              onPressed: _showAddCustomPackageDialog,
              child: const Icon(Icons.add),
            )
          : null,
    );
  }

  Widget _buildPolicyTile({required IconData icon, required String title, required String subtitle}) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon, color: Colors.indigoAccent),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ),
    );
  }
}
