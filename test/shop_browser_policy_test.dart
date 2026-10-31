import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/web/shop_browser_policy.dart';

void main() {
  test('site and admin use configured origin, never a cashier token URL', () {
    final policy = ShopBrowserPolicy(
      'https://demo.khoga.ci/caisse?token=private',
    );
    expect(policy.site.toString(), 'https://demo.khoga.ci/');
    expect(policy.admin.toString(), 'https://demo.khoga.ci/accueil');
    expect(
      policy.navigation(Uri.parse('https://demo.khoga.ci/login')),
      ShopNavigation.internal,
    );
  });
  test('external and unsafe navigation cannot receive internal privileges', () {
    final policy = ShopBrowserPolicy('https://demo.khoga.ci');
    for (final value in [
      'javascript:alert(1)',
      'file:///etc/passwd',
      'intent://anything',
      'https://user:secret@demo.khoga.ci/',
    ]) {
      expect(policy.navigation(Uri.parse(value)), ShopNavigation.blocked);
    }
    for (final value in [
      'https://demo.khoga.ci.attacker.test/',
      'https://demo.khoga.ci:8443/',
      'https://wa.me/2250000000000',
      'tel:+2250000000000',
    ]) {
      expect(policy.navigation(Uri.parse(value)), ShopNavigation.external);
    }
  });
  test('invalid origins are refused before creating a web view', () {
    for (final value in [
      '',
      'http://demo.khoga.ci',
      'https://user:password@demo.khoga.ci',
    ]) {
      expect(() => ShopBrowserPolicy(value), throwsFormatException);
    }
  });
}
