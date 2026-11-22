import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shopikaiss_terminal/src/offline/models.dart';
import 'package:shopikaiss_terminal/src/offline/store.dart';
import 'package:shopikaiss_terminal/src/register/register_adapter.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_engine.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_v2_server.dart';
import 'sync_v2_engine_test.dart' show serve21;

/// Remise à zéro de la boutique avant la production (2.1 lot 17, note A LOT-17-REMISE-A-ZERO-POUR-B-ET-C.md).
void main() {
  sqfliteFfiInit();
  late Directory dir;
  late SqfliteOfflineStore base;
  late FakeV2Server server;
  var uuids = 0;
  String newUuid() => 'abcdef00-0000-4000-8000-${(++uuids).toString().padLeft(12, '0')}';
  String iso(DateTime t) => '${t.toUtc().toIso8601String().substring(0, 19)}Z';

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('remise_a_zero_');
    base = await SqfliteOfflineStore.open(name: p.join(dir.path, 'caisse.db'), factory: databaseFactoryFfi);
    server = FakeV2Server.sellable();
  });
  tearDown(() async {
    await base.close();
    dir.deleteSync(recursive: true);
  });

  void serve({Map<String, dynamic>? reset}) {
    serve21(server, rules: {'remise_a_zero': ?reset});
    server
      ..capabilities = ['instantane.v1', 'stock.couverture', 'vente.especes', 'contrat.2_1', 'session.cloture', 'remise.zero']
      ..put('operateur', 'operateur:7', {
        'operateur_id': '7', 'nom': 'Awa', 'pin_empreinte': 'empreinte', 'droits': ['caisse_cloturer', 'ouverture_session', 'vente'],
        'remise_max_pourcent': null, 'remise_max_montant': null, 'approbateur_remise': false,
      }, critical: true)
      ..put('politique', 'session.ouverture_locale', {'cle_politique': 'session.ouverture_locale', 'valeur': true, 'source': 'boutique', 'verrouillee': false});
  }

  test('remise publiée : pièces d’avant effacées, opération refusée archivée, numéro au premier, catalogue gardé, une seule fois', () async {
    var t = DateTime.now().toUtc();
    serve();
    final e = V2Engine.onStore(base, transport: server, appVersion: 'essai', platform: 'android', newUuid: newUuid, clock: () => t,
        pinVerifier: (pin, hash) async => pin == '1234' && hash == 'empreinte', contract21: true);
    await e.load('https://boutique.exemple.ci');
    expect(await e.pair('ABCD-EFGH', model: 'Essai', appVersion: 'essai'), isNull);
    await e.sync();
    expect(await e.v2.read(V2Keys.contractRevision), contains('+remise1'));
    expect(e.shopResetSupported, isTrue);
    final awa = e.snapshot!.operators.firstWhere((o) => o.name == 'Awa');
    final savon = e.snapshot!.products.firstWhere((p) => p.name == 'Savon');
    final cash = e.snapshot!.methods.firstWhere((m) => m.code == 'especes');
    final epoch = await e.v2.read(V2Keys.epoch);

    // Essais : session, une vente intégrée, puis une vente restée dans la file.
    await e.closeSession(awa, cash: 0);
    await e.openSession(1000, awa);
    final first = await e.recordSale([CartLine(product: savon)], [CartPayment(method: cash, amount: 500, received: 500)], awa);
    await e.sync();
    expect(server.received[first.uuid]!['etat'], 'integree');
    t = t.add(const Duration(minutes: 1));
    final second = await e.recordSale([CartLine(product: savon)], [CartPayment(method: cash, amount: 500, received: 500)], awa);
    expect(second.number, isNot('HL2-$epoch-000001'));
    expect(await e.v2.uncoveredStock(), isNotEmpty);

    // La boutique est remise à zéro ; le serveur refuse toute opération d'avant.
    t = t.add(const Duration(minutes: 1));
    final at = t;
    const resetUuid = 'abcdef00-0000-4000-8000-0000000017aa';
    // Règle publiée par le journal (la boutique change de révision), comme après la commande d'exploitant.
    final shop = Map<String, dynamic>.from(server.entities['boutique|$fakeShop']!['donnees'] as Map);
    shop['regles'] = {...(shop['regles'] as Map), 'remise_a_zero': {'uuid': resetUuid, 'le': iso(at)}};
    server
      ..publish([
        {'type': 'boutique', 'critique': true, 'cle': fakeShop, 'revision': '900', 'action': 'upsert', 'donnees': shop},
        // La session des essais est effacée au serveur : retirée par la publication forcée.
        {'type': 'session', 'critique': false, 'cle': 'session:$fakeTerminal', 'revision': '900', 'action': 'suppression', 'donnees': null},
      ])
      ..verdict = ((op) => DateTime.parse(op['cree_le'] as String).isBefore(at) ? 'rejet_protocole' : 'integree')
      ..reasonFor = ((op) => DateTime.parse(op['cree_le'] as String).isBefore(at) ? {'code': 'remise_a_zero', 'message': 'Remise à zéro', 'details': null} : null);
    t = t.add(const Duration(minutes: 1));
    await e.sync();

    expect(server.received[second.uuid]!['etat'], 'rejet_protocole', reason: 'la vente d’essai part, refusée remise_a_zero');
    expect(await e.v2.operationRows(), isEmpty, reason: 'ventes, ouverture et refus effacés');
    expect(await e.v2.uncoveredStock(), isEmpty, reason: 'consommation des ventes effacées retirée');
    expect(await e.v2.read(V2Keys.resetUuid), resetUuid);
    expect(e.sessionOpen, isFalse);
    expect((e.pendingCount, e.refusedCount), (0, 0));
    expect(e.snapshot!.products.map((p) => p.name), contains('Savon'), reason: 'catalogue gardé');
    expect(e.shopResetNotice, contains('1 opération d’essai non intégrée écartée'));
    final archives = dir.listSync().whereType<File>().where((f) => p.basename(f.path).startsWith('remise-a-zero-')).toList();
    expect(archives, hasLength(1));
    final archive = jsonDecode(archives.single.readAsStringSync()) as Map;
    expect(archive['remise_uuid'], resetUuid);
    expect([for (final o in archive['operations'] as List) (o as Map)['uuid']], [second.uuid]);

    // Adaptateur : avis exposé, puis lu une fois.
    final adapter = LocalRegisterAdapter(e, newUuid: newUuid);
    await adapter.start();
    final status = await adapter.execute('status', {}, null);
    expect((status['shop_reset'] as Map)['supported'], isTrue);
    expect((status['shop_reset'] as Map)['notice'], contains('remise à zéro'));
    expect(((await adapter.execute('acknowledgeShopReset', {}, null))['shop_reset'] as Map)['notice'], isNull);
    await adapter.close();

    // Production : numéro local au premier, vente intégrée ; même uuid relu : rien effacé une deuxième fois.
    await e.openSession(0, awa);
    final real = await e.recordSale([CartLine(product: savon)], [CartPayment(method: cash, amount: 500, received: 500)], awa);
    // Numérotation reprise comme au premier jour : 1 = ouverture de la session, 2 = première vente.
    expect(real.number, 'HL2-$epoch-000002');
    await e.sync();
    expect(server.received[real.uuid]!['etat'], 'integree');
    await e.sync();
    expect((await e.v2.operationRows()).map((r) => (r['operation'] as Map)['uuid']), containsAll([real.uuid]));
    expect(e.shopResetNotice, isNull);
  });

  test('remise déjà faite avant l’appairage : uuid mémorisé, rien à effacer, aucun avis', () async {
    serve(reset: {'uuid': 'abcdef00-0000-4000-8000-0000000017bb', 'le': '2026-01-01T00:00:00Z'});
    final e = V2Engine.onStore(base, transport: server, appVersion: 'essai', platform: 'android', newUuid: newUuid,
        pinVerifier: (pin, hash) async => pin == '1234' && hash == 'empreinte', contract21: true);
    await e.load('https://boutique.exemple.ci');
    expect(await e.pair('ABCD-EFGH', model: 'Essai', appVersion: 'essai'), isNull);
    await e.sync();
    expect(await e.v2.read(V2Keys.resetUuid), 'abcdef00-0000-4000-8000-0000000017bb');
    expect(e.shopResetNotice, isNull, reason: 'terminal neuf : rien effacé, rien à dire');
    await e.sync();
    expect(await e.v2.read(V2Keys.resetUuid), 'abcdef00-0000-4000-8000-0000000017bb');
  });
}
