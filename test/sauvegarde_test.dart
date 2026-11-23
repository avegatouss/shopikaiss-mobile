import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shopikaiss_terminal/src/offline/engine.dart';
import 'package:shopikaiss_terminal/src/offline/models.dart';
import 'package:shopikaiss_terminal/src/offline/store.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_backup.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_engine.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_v2_server.dart';
import 'sync_v2_engine_test.dart' show serve21;

/// Sauvegarde locale cohérente et reprise sur un autre appareil (plan §7.6, RESTAURANT-1 §2.3 et §5.4, lot R-6).
void main() {
  sqfliteFfiInit();
  late Directory dir;
  late FakeV2Server server;
  var uuids = 0;
  String newUuid() => 'abcdef00-0000-4000-8000-${(++uuids).toString().padLeft(12, '0')}';

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sauvegarde_');
    server = FakeV2Server.sellable();
    serve21(server);
  });
  final opened = <SqfliteOfflineStore>[];
  tearDown(() async {
    for (final s in opened) {
      await s.close();
    }
    opened.clear();
    dir.deleteSync(recursive: true);
  });

  Future<SqfliteOfflineStore> open(String name) async {
    final store = await SqfliteOfflineStore.open(name: p.join(dir.path, name), factory: databaseFactoryFfi);
    opened.add(store);
    return store;
  }

  Future<V2Engine> engine(SqfliteOfflineStore base, {String platform = 'android'}) async {
    final e = V2Engine.onStore(base, transport: server, appVersion: 'essai', platform: platform, newUuid: newUuid,
        pinVerifier: FakeV2Server.pinVerifier, contract21: true, announceRestaurant: true, clock: () => DateTime.utc(2026, 11, 23, 12));
    await e.load('https://boutique.exemple.ci');
    return e;
  }

  test('sauvegarde sans jeton, restaurée ailleurs, reprise déclarée une fois, ventes non envoyées reprises sans doublon', () async {
    final phone = await open('telephone.db');
    final a = await engine(phone);
    expect(await a.pair('ABCD-EFGH', model: 'Téléphone', appVersion: 'essai'), isNull);
    await a.sync();
    final operator = a.snapshot!.operators.single;
    final savon = CartLine(product: a.snapshot!.byCode('6190000000011')!.$1, quantity: BigInt.from(1000000));
    final payment = CartPayment(method: a.snapshot!.methods.single, amount: 500, received: 500);

    // Une vente envoyée, une autre restée sur le téléphone (réseau coupé).
    final sent = await a.recordSale([savon], [payment], operator);
    await a.sync();
    server.failStatus = 0;
    final kept = await a.recordSale([savon], [payment], operator);
    await a.sync();
    server.failStatus = null;

    final (bytes, info) = await a.createBackup();
    expect([info.platform, info.deviceUuid, info.epoch, info.unsent, info.shopName], ['android', fakeDevice, 3, 1, 'Boutique']);
    expect(info.lastSequence, greaterThanOrEqualTo(2));
    final text = utf8.decode(GZipCodec().decode(bytes));
    expect(text, isNot(contains('jeton-appareil-0123456789')), reason: 'jamais le jeton de l’appareil');
    expect(CaisseBackup.inspect(bytes).toJson(), info.toJson());

    // Poste Windows de reprise, déjà installé (installation propre gardée).
    final windows = await open('windows.db');
    await windows.write(V2Keys.installation, '99999999-9999-4999-8999-999999999999');
    var b = await engine(windows, platform: 'windows');
    final restored = await b.restoreBackup(bytes);
    expect(restored.deviceUuid, fakeDevice);
    expect(b.paired, isFalse, reason: 'appairage à refaire : nouvelle époque');
    expect(await windows.read(V2Keys.installation), '99999999-9999-4999-8999-999999999999');
    expect(jsonDecode((await windows.read(V2Keys.recovery))!), {'appareil_uuid': fakeDevice, 'epoque': 3, 'derniere_sequence': info.lastSequence});
    expect((await b.restoredBackup())!.platform, 'android');
    expect([for (final s in await b.history()) s.uuid], containsAll([sent.uuid, kept.uuid]));

    // Restaurer par-dessus une caisse qui a encore des opérations à envoyer : refusé.
    await expectLater(a.restoreBackup(bytes), throwsA(isA<OfflineRefusal>().having((r) => r.message, 'message', contains('non envoyée'))));
    await expectLater(b.restoreBackup(utf8.encode('pas une sauvegarde')), throwsA(isA<OfflineRefusal>().having((r) => r.message, 'message', contains('n’est pas une sauvegarde'))));

    // Nouvel appairage : la reprise part avec le premier /etat, une seule fois ; la vente gardée part, sans doublon.
    b = await engine(windows, platform: 'windows');
    server.requests.clear();
    expect(await b.pair('ABCD-EFGH', model: 'Poste', appVersion: 'essai'), isNull);
    final declared = [for (final r in server.requests) if (r.path == '/etat') r.headers['X-Caisse-Reprise']];
    expect(declared.whereType<String>().map(jsonDecode).toList(), [
      {'appareil_uuid': fakeDevice, 'epoque': 3, 'derniere_sequence': info.lastSequence},
    ]);
    expect(await windows.read(V2Keys.recovery), isNull);
    await b.sync();
    expect([for (final r in server.requests) if (r.path == '/etat') r.headers['X-Caisse-Reprise']].whereType<String>().length, 1);
    expect(server.received[kept.uuid]?['etat'], 'integree');
    expect(server.received.keys.where((k) => k == sent.uuid).length, 1);
  });

  test('sauvegardes automatiques : écriture complète, seules les plus récentes gardées', () async {
    final e = await engine(await open('caisse.db'));
    final target = Directory(p.join(dir.path, 'sauvegardes'));
    for (var i = 0; i < 7; i++) {
      final (bytes, _) = await e.createBackup();
      await CaisseBackup.writeRotating(target, bytes, at: DateTime(2026, 11, 23, 12, 0, i), keep: 3);
    }
    final kept = await CaisseBackup.backups(target);
    expect([for (final f in kept) p.basename(f.path)], ['caisse-20261123-120006.skcaisse', 'caisse-20261123-120005.skcaisse', 'caisse-20261123-120004.skcaisse']);
    expect(target.listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);
    expect(CaisseBackup.inspect(kept.first.readAsBytesSync()).platform, 'android');
  });

  test('version de base différente : refusée sans rien toucher', () async {
    final base = await open('caisse.db');
    final e = await engine(base);
    final (bytes, _) = await e.createBackup();
    final data = jsonDecode(utf8.decode(GZipCodec().decode(bytes))) as Map;
    (data['sauvegarde'] as Map)['version_base'] = 99;
    final altered = GZipCodec().encode(utf8.encode(jsonEncode(data)));
    final other = await engine(await open('autre.db'));
    await other.v2.write('temoin', 'gardé');
    await expectLater(other.restoreBackup(altered), throwsA(isA<OfflineRefusal>().having((r) => r.message, 'message', contains('même version'))));
    expect(await other.v2.read('temoin'), 'gardé');
  });
}
