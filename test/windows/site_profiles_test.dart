import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shopikaiss_terminal/src/windows/platform/site_profiles.dart';

void main() {
  test('switch keeps original database and every profile across restart', () async {
    final root = await Directory.systemTemp.createTemp('site-profiles-');
    addTearDown(() => root.delete(recursive: true));
    final profiles = SiteProfiles(root.path);
    await profiles.load();
    final original = profiles.dataDirectory;
    final saved = File(p.join(original, 'data.db'));
    await saved.parent.create(recursive: true);
    await saved.writeAsString('old database untouched');
    await profiles.labelOrigin('https://demo.example.test/caisse?token=do-not-store');
    await profiles.select(null);
    final second = profiles.active;
    expect(profiles.dataDirectory, isNot(original));
    await profiles.labelOrigin('https://shop.example.test');
    final restarted = SiteProfiles(root.path);
    await restarted.load();
    expect(restarted.active, second);
    expect(restarted.names['default'], 'https://demo.example.test');
    expect(await restarted.file.readAsString(), isNot(contains('do-not-store')));
    await restarted.select('default');
    expect(restarted.dataDirectory, original);
    expect(await saved.readAsString(), 'old database untouched');
    await expectLater(restarted.select('../escape'), throwsFormatException);
    expect(() => restarted.directory('../escape'), throwsFormatException);
  });
  test('corrupt registry fails closed instead of silently pairing another database', () async {
    final root = await Directory.systemTemp.createTemp('site-corrupt-');
    addTearDown(() => root.delete(recursive: true));
    final profiles = SiteProfiles(root.path);
    await profiles.file.writeAsString('{"schema":1,"active":"missing","names":{"default":"Demo"}}');
    await expectLater(profiles.load(), throwsFormatException);
  });
  test('all unresolved financial intent files prevent a switch', () async {
    final root = await Directory.systemTemp.createTemp('site-intents-');
    addTearDown(() => root.delete(recursive: true));
    expect(await hasUnresolvedSiteIntent(root.path), false);
    for (final name in ['pending-sale.json', 'pending-sale-v2.json', 'pending-return-v2.json', 'pending-close-v2.json']) {
      final file = File(p.join(root.path, name));
      await file.writeAsString('even unreadable evidence must block');
      expect(await hasUnresolvedSiteIntent(root.path), true);
      await file.delete();
    }
  });
  test('switch requires complete state, empty basket and no pending or arbitration', () {
    const clear = {'pending': 0, 'arbitration': 0};
    const empty = {'lines': []};
    expect(siteSwitchRefusal(clear, empty, uncertain: false), isNull);
    expect(siteSwitchRefusal(clear, empty, uncertain: true), isNotNull);
    expect(siteSwitchRefusal({}, empty, uncertain: false), isNotNull);
    expect(siteSwitchRefusal(clear, {}, uncertain: false), isNotNull);
    expect(siteSwitchRefusal({'pending': 1, 'arbitration': 0}, empty, uncertain: false), isNotNull);
    expect(siteSwitchRefusal({'pending': 0, 'arbitration': 1}, empty, uncertain: false), isNotNull);
    expect(siteSwitchRefusal(clear, {'lines': [1]}, uncertain: false), isNotNull);
  });
}
