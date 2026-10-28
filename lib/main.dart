import 'dart:io';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'core/database/local_database.dart';
import 'core/security/key_vault.dart';
import 'core/security/sensitive_app_guard.dart';
import 'features/ui/screens/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Desktop Window Configuration
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    const windowOptions = WindowOptions(
      size: Size(950, 680),
      minimumSize: Size(700, 500),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      title: 'Device Assistant',
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  // Security Vault & Local Database Initialization
  final keyVault = KeyVault();
  final passphrase = await keyVault.getOrCreateDatabasePassphrase();

  final database = LocalDatabase();
  await database.initialize(passphrase: passphrase);

  // Initialize Sensitive App Guard with saved custom packages
  final customBlacklist = database.loadCustomProtectedPackages();
  final guard = SensitiveAppGuard(customBlacklist: customBlacklist);

  runApp(DeviceAssistantApp(
    keyVault: keyVault,
    database: database,
    guard: guard,
  ));
}

class DeviceAssistantApp extends StatelessWidget {
  final KeyVault keyVault;
  final LocalDatabase database;
  final SensitiveAppGuard guard;

  const DeviceAssistantApp({
    super.key,
    required this.keyVault,
    required this.database,
    required this.guard,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Device Assistant',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.indigo,
        scaffoldBackgroundColor: const Color(0xFF12141A),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF181B22),
          elevation: 0,
        ),
        cardTheme: const CardThemeData(
          color: Color(0xFF1E222B),
          elevation: 1,
        ),
      ),
      home: HomeScreen(
        keyVault: keyVault,
        database: database,
        guard: guard,
      ),
    );
  }
}
