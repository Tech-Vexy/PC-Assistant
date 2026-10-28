/// Shield to safeguard sensitive applications from being accessed,
/// inspected, automated, or screenshotted by Device Assistant while
/// cloud inference is active.
class SensitiveAppGuard {
  static const int categoryFinance = 3; // Android ApplicationInfo.CATEGORY_FINANCE

  /// Default package blacklist covering Banking, FinTech, SIM Toolkit,
  /// 2FA, Crypto Wallets, and Password Managers.
  static final Set<String> defaultBlacklist = {
    // SIM Toolkit (STK) & Carrier Menus
    'com.android.stk',
    'com.android.stk2',
    'com.mediatek.stk',
    'com.qualcomm.qti.uim',
    'com.samsung.android.app.telephonyui.stk',
    'com.sec.android.app.servicemodeapp',

    // Mobile Money & Carrier STK Menus
    'ke.co.safaricom.mpesa',
    'com.safaricom.mpesa.lifestyle',
    'com.airtel.africa.airtelmoney',
    'com.mtn.mymtn',

    // Global Banking & FinTech Apps
    'com.chase.sig.android',
    'com.infonow.bofa',
    'com.wf.wellsfargomobile',
    'com.citi.citimobile',
    'com.capitalone.mobile.banking',
    'com.revolut.revolut',
    'co.monzo',
    'com.paypal.android.p2pmobile',
    'com.squareup.cash',
    'com.venmo',
    'com.transferwise.android',

    // Crypto & Web3 Wallets
    'io.metamask',
    'com.coinbase.android',
    'com.wallet.crypto.trustapp',
    'com.binance.dev',
    'com.ledger.live',

    // 2FA & Password Managers
    'com.onepassword.android',
    'com.x8bit.bitwarden',
    'com.lastpass.lpandroid',
    'org.keepassdroid',
    'keepass2android.keepass2android',
    'com.google.android.apps.authenticator2',
    'com.authy.authy',
    'com.yubico.yubioath',
    'com.duosecurity.duomobile',
    'com.microsoft.msa.authenticator',

    // Government & Identity
    'gov.id',
    'org.torproject.torbrowser',
  };

  final Set<String> _customBlacklist = {};

  SensitiveAppGuard({Set<String>? customBlacklist}) {
    if (customBlacklist != null) {
      _customBlacklist.addAll(customBlacklist);
    }
  }

  /// Returns an unmodifiable view of custom user-protected packages
  Set<String> get customProtectedPackages => Set.unmodifiable(_customBlacklist);
  Set<String> get customBlacklist => Set.unmodifiable(_customBlacklist);

  /// Adds a package to the user's custom protected list
  void addProtectedPackage(String packageName) {
    _customBlacklist.add(packageName.trim().toLowerCase());
  }

  /// Removes a package from the custom protected list
  void removeProtectedPackage(String packageName) {
    _customBlacklist.remove(packageName.trim().toLowerCase());
  }

  /// Convenience helper to check if a package is protected
  bool isPackageProtected(String packageName) {
    return evaluate(packageName: packageName).isBlocked;
  }

  /// Returns whether a given application package or category is protected.
  /// If protected, screen capture, UI inspection, and automated input must be rejected.
  SecurityDecision evaluate({
    required String? packageName,
    int? applicationCategory,
    bool isFlagSecure = false,
  }) {
    // 1. Android Window FLAG_SECURE check
    if (isFlagSecure) {
      return const SecurityDecision(
        isBlocked: true,
        reason: 'Window has FLAG_SECURE enabled. Screen capture and reading blocked.',
      );
    }

    if (packageName == null || packageName.isEmpty) {
      return const SecurityDecision(isBlocked: false);
    }

    final pkg = packageName.trim().toLowerCase();

    // 2. SIM Toolkit check (exact or substring heuristic)
    if (pkg.contains('.stk') || pkg.endsWith('.stk') || pkg.contains('simtoolkit')) {
      return SecurityDecision(
        isBlocked: true,
        reason: 'SIM Toolkit ($pkg) is protected. Device Assistant cannot view or automate SIM operations.',
      );
    }

    // 3. Explicit default blacklist
    if (defaultBlacklist.contains(pkg)) {
      return SecurityDecision(
        isBlocked: true,
        reason: 'Package $pkg is in the sensitive security blacklist (Banking/FinTech/2FA/Wallet).',
      );
    }

    // 4. Custom blacklist
    if (_customBlacklist.contains(pkg)) {
      return SecurityDecision(
        isBlocked: true,
        reason: 'Package $pkg was marked as protected by user policy.',
      );
    }

    // 5. Android CATEGORY_FINANCE check
    if (applicationCategory != null && applicationCategory == categoryFinance) {
      return SecurityDecision(
        isBlocked: true,
        reason: 'Application $pkg is categorized as Finance. Action blocked.',
      );
    }

    return const SecurityDecision(isBlocked: false);
  }
}

class SecurityDecision {
  final bool isBlocked;
  final String? reason;

  const SecurityDecision({
    required this.isBlocked,
    this.reason,
  });

  @override
  String toString() => isBlocked ? 'BLOCKED: $reason' : 'ALLOWED';
}
