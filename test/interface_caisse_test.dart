import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shopikaiss_terminal/src/offline/register_interface.dart';
import 'package:shopikaiss_terminal/src/offline/store.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_v2_server.dart';
import 'sync_v2_engine_test.dart' show serve21;

/// Interface réglable de la caisse (contrat 2.1 lot 13, note A LOT-13-INTERFACE-POUR-B-ET-C.md).
void main() {
  Map<String, dynamic> fixture(String name) =>
      Map<String, dynamic>.from(jsonDecode(File('test/fixtures/contrat-v2/fixtures/valides/$name.json').readAsStringSync()) as Map);

  test('forme publiée : défauts = écran d’avant, échelle du web, ordre, clés et tailles inconnues ignorées', () {
    final defaults = RegisterInterface.fromJson(fixture('donnees--interface-caisse-defauts'));
    expect((defaults.origin, defaults.locked, defaults.productScale, defaults.payScale), ('defaut', false, 1.0, 1.0));
    for (final key in RegisterInterface.known.keys) {
      expect(defaults.visible(key), isTrue, reason: key);
    }
    expect([for (final s in RegisterInterface.sizes) RegisterInterface.scaleOf(s)], [.85, 1, 1.2, 1.45]);

    final ui = RegisterInterface.fromJson({
      'origine': 'terminal', 'verrouille': true, 'tuile_categorie': 'l', 'tuile_produit': 'xl', 'police_compacte': 'zz', 'bouton_payer': 's',
      'elements': [
        {'cle': 'recherche', 'visible': true, 'ordre': 1},
        {'cle': 'scanner', 'visible': true, 'ordre': 2},
        {'cle': 'marques', 'visible': false, 'ordre': 3},
        {'cle': 'cle_future', 'visible': false, 'ordre': 4},
      ],
    });
    expect((ui.locked, ui.categoryScale, ui.productScale, ui.compactScale, ui.payScale), (true, 1.2, 1.45, 1.0, .85));
    expect(ui.visible('marques'), isFalse);
    expect(ui.visible('categories'), isTrue, reason: 'absent de la liste : visible, à sa place');
    expect(ui.sorted(['scanner', 'recherche']), ['recherche', 'scanner']);
    expect(ui.sorted(['vue', 'scanner', 'note']), ['scanner', 'vue', 'note'], reason: 'non réglés : après, dans l’ordre habituel');
  });

  test('réglage local : prime sauf verrou ; aller-retour JSON ; couleur d’opérateur stable et initiales', () {
    final published = RegisterInterface.fromJson(fixture('donnees--interface-caisse-terminal-verrouille'));
    final local = RegisterInterface.defaults.copyWith(productTile: 'xl', elements: {'marques': (false, 1)});
    expect(RegisterInterface.effective(published, local), same(published), reason: published.locked ? 'verrouillée' : 'non verrouillée');
    const open = RegisterInterface(origin: 'boutique');
    expect(RegisterInterface.effective(open, local), same(local));
    expect(RegisterInterface.effective(open, null), same(open));
    final back = RegisterInterface.fromJson(jsonDecode(local.encode()) as Map, origin: 'local');
    expect((back.productTile, back.visible('marques'), back.origin), ('xl', false, 'local'));

    expect(operatorArgb(7), operatorArgb(7));
    expect(operatorArgb(7), isNot(operatorArgb(8)));
    expect([operatorInitials('Awa Koné'), operatorInitials('Mariam'), operatorInitials('  Jean  Paul  Kouassi ')], ['AK', 'MA', 'JK']);
  });

  group('moteur', () {
    sqfliteFfiInit();
    late Directory dir;
    late SqfliteOfflineStore base;
    late FakeV2Server server;
    setUp(() async {
      dir = Directory.systemTemp.createTempSync('interface_caisse_');
      base = await SqfliteOfflineStore.open(name: p.join(dir.path, 'caisse.db'), factory: databaseFactoryFfi);
      server = FakeV2Server.sellable();
    });
    tearDown(() async {
      await base.close();
      dir.deleteSync(recursive: true);
    });

    Future<V2Engine> engine() async {
      final e = V2Engine.onStore(base, transport: server, appVersion: 'essai', platform: 'android', declaredPayments: true, contract21: true);
      await e.load('https://boutique.exemple.ci');
      expect(await e.pair('ABCD-EFGH', model: 'Essai', appVersion: 'essai'), isNull);
      expect((await e.sync()).reachable, isTrue);
      return e;
    }

    test('seule l’entité de ce terminal s’applique ; sans la capacité, défauts', () async {
      serve21(server);
      final mine = fixture('donnees--interface-caisse-terminal-verrouille');
      server
        ..capabilities = [...server.capabilities, 'caisse.interface']
        ..put('interface_caisse', fakeTerminal, mine)
        ..put('interface_caisse', 'ffffffff-0000-4000-8000-000000000099', fixture('donnees--interface-caisse-defauts'));
      final e = await engine();
      expect(e.publishedInterface.origin, mine['origine']);
      expect(e.publishedInterface.locked, mine['verrouille']);
      expect(e.publishedInterface.productTile, mine['tuile_produit']);
    });

    test('sans caisse.interface : écran d’avant', () async {
      serve21(server);
      server.put('interface_caisse', fakeTerminal, fixture('donnees--interface-caisse-terminal-verrouille'));
      final e = await engine();
      expect(e.publishedInterface, same(RegisterInterface.defaults));
    });
  });
}
