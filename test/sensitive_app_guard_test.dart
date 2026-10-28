import 'package:flutter_test/flutter_test.dart';
import 'package:device_assistant/core/security/sensitive_app_guard.dart';

void main() {
  group('SensitiveAppGuard Protection Tests', () {
    late SensitiveAppGuard guard;

    setUp(() {
      guard = SensitiveAppGuard();
    });

    test('SIM Toolkit packages are strictly blocked', () {
      final stk1 = guard.evaluate(packageName: 'com.android.stk');
      expect(stk1.isBlocked, isTrue);
      expect(stk1.reason, contains('SIM Toolkit'));

      final stk2 = guard.evaluate(packageName: 'com.android.stk2');
      expect(stk2.isBlocked, isTrue);

      final mtkStk = guard.evaluate(packageName: 'com.mediatek.stk');
      expect(mtkStk.isBlocked, isTrue);

      final qcomUim = guard.evaluate(packageName: 'com.qualcomm.qti.uim');
      expect(qcomUim.isBlocked, isTrue);

      final samsungStk = guard.evaluate(
          packageName: 'com.samsung.android.app.telephonyui.stk');
      expect(samsungStk.isBlocked, isTrue);
    });

    test('Banking and FinTech apps are strictly blocked', () {
      final chase = guard.evaluate(packageName: 'com.chase.sig.android');
      expect(chase.isBlocked, isTrue);

      final revolut = guard.evaluate(packageName: 'com.revolut.revolut');
      expect(revolut.isBlocked, isTrue);

      final paypal =
          guard.evaluate(packageName: 'com.paypal.android.p2pmobile');
      expect(paypal.isBlocked, isTrue);

      final metamask = guard.evaluate(packageName: 'io.metamask');
      expect(metamask.isBlocked, isTrue);
    });

    test('2FA and Password Managers are strictly blocked', () {
      final bitwarden = guard.evaluate(packageName: 'com.x8bit.bitwarden');
      expect(bitwarden.isBlocked, isTrue);

      final googleAuth =
          guard.evaluate(packageName: 'com.google.android.apps.authenticator2');
      expect(googleAuth.isBlocked, isTrue);
    });

    test('Android Category Finance triggers automatic block', () {
      final genericFinanceApp = guard.evaluate(
        packageName: 'com.unknown.bank.client',
        applicationCategory: SensitiveAppGuard.categoryFinance,
      );
      expect(genericFinanceApp.isBlocked, isTrue);
      expect(genericFinanceApp.reason, contains('Finance'));
    });

    test('FLAG_SECURE window always triggers block', () {
      final secureWindow = guard.evaluate(
        packageName: 'com.example.normalapp',
        isFlagSecure: true,
      );
      expect(secureWindow.isBlocked, isTrue);
      expect(secureWindow.reason, contains('FLAG_SECURE'));
    });

    test('Non-sensitive apps are allowed', () {
      final chrome = guard.evaluate(packageName: 'com.android.chrome');
      expect(chrome.isBlocked, isFalse);

      final camera =
          guard.evaluate(packageName: 'com.google.android.GoogleCamera');
      expect(camera.isBlocked, isFalse);

      final calc = guard.evaluate(packageName: 'com.google.android.calculator');
      expect(calc.isBlocked, isFalse);
    });

    test('Custom protected packages can be added and removed dynamically', () {
      const customPkg = 'com.mycustom.privateapp';
      expect(guard.evaluate(packageName: customPkg).isBlocked, isFalse);

      guard.addProtectedPackage(customPkg);
      expect(guard.evaluate(packageName: customPkg).isBlocked, isTrue);

      guard.removeProtectedPackage(customPkg);
      expect(guard.evaluate(packageName: customPkg).isBlocked, isFalse);
    });
  });
}
