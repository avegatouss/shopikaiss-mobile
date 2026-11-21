import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shopikaiss_terminal/src/offline/store.dart';
import 'package:shopikaiss_terminal/src/register/register_adapter.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_engine.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_v2_server.dart';
import 'sync_v2_engine_test.dart' show serve21;

/// Documents de clôture de l'adaptateur : rendu à la largeur demandée, édition pré-X / pré-Z conservée EN ATTENTE sur le
/// terminal (survit au redémarrage de l'hôte), confirmée une seule fois, jamais émise sans confirmation, purgée après 24 h
/// ou au-delà de 100 ; droits (caissier identifié, `caisse_cloturer` pour le pré-Z).
void main() {
  sqfliteFfiInit();
  late Directory dir;
  late SqfliteOfflineStore base;
  late FakeV2Server server;
  var uuids = 0;
  var adapterUuids = 0;
  String newUuid() => 'abcdef00-0000-4000-8000-${(++uuids).toString().padLeft(12, '0')}';
  String adapterUuid() => 'adad0000-0000-4000-8000-${(++adapterUuids).toString().padLeft(12, '0')}';
  final moment = DateTime.utc(2026, 11, 19, 12);
  late DateTime now;
  const pdv = '8b000000-0000-4000-8000-000000000001';
  Map<String, dynamic> fixture(String name) =>
      Map<String, dynamic>.from(jsonDecode(File('test/fixtures/contrat-v2/fixtures/valides/$name.json').readAsStringSync()) as Map);
  Map<String, dynamic> operatorData(String id, String name, List<String> rights) => {
    'operateur_id': id, 'nom': name, 'pin_empreinte': 'empreinte', 'droits': rights,
    'remise_max_pourcent': null, 'remise_max_montant': null, 'approbateur_remise': false,
  };

  setUp(() async {
    now = moment;
    dir = Directory.systemTemp.createTempSync('adaptateur_cloture_');
    base = await SqfliteOfflineStore.open(name: p.join(dir.path, 'caisse.db'), factory: databaseFactoryFfi);
    server = FakeV2Server.sellable();
    serve21(server);
    server
      ..capabilities = [...server.capabilities, 'session.cloture', 'z.local']
      ..authorizationExpires = '2026-11-21T00:00:00Z'
      ..put('operateur', 'operateur:7', operatorData('7', 'Awa', ['caisse_cloturer', 'ouverture_session', 'vente']), critical: true)
      ..put('operateur', 'operateur:8', operatorData('8', 'Yao', ['ouverture_session', 'vente']), critical: true)
      ..put('z.session', 'z_session:$fakeTerminal', {...fixture('donnees-z-local--z-session'), 'terminal_uuid': fakeTerminal, 'session_uuid': fakeSession, 'fond_initial': 20000})
      ..put('z.journee', 'z_journee:$pdv', {...fixture('donnees-z-local--z-journee'), 'terminaux': [fakeTerminal], 'sessions_ouvertes': <Map<String, dynamic>>[]});
  });
  tearDown(() async {
    await base.close();
    dir.deleteSync(recursive: true);
  });

  Future<V2Engine> paired() async {
    final e = V2Engine.onStore(base, transport: server, appVersion: 'essai', platform: 'windows', newUuid: newUuid,
        pinVerifier: FakeV2Server.pinVerifier, contract21: true, clock: () => now);
    await e.load('https://boutique.exemple.ci');
    expect(await e.pair('ABCD-EFGH', model: 'Essai', appVersion: 'essai'), isNull);
    expect(e.zLocalSupported, isTrue);
    return e;
  }

  Future<String?> failure(LocalRegisterAdapter adapter, String command, Map<String, dynamic> args) async {
    try {
      await adapter.execute(command, args, null);
      return null;
    } on AdapterFailure catch (e) {
      return e.code;
    }
  }

  test('pré-X : rendu à 42 colonnes, édition en attente, confirmée une seule fois après redémarrage de l’hôte', () async {
    final e = await paired();
    final adapter = LocalRegisterAdapter(e, newUuid: adapterUuid);
    await adapter.execute('login', {'operator_id': 7, 'pin': '1234'}, null);

    final doc = await adapter.execute('closureDocument', {'kind': 'pre-x', 'version': 'detailed', 'columns': 42}, null);
    final lines = (doc['lines'] as List).cast<String>();
    expect(doc['columns'], 42);
    expect(lines, contains('=' * 42));
    expect(lines.every((l) => l.length <= 42), isTrue);
    expect(base64Decode(doc['escpos_base64'] as String), isNotEmpty);
    expect((doc['ticket'] as Map)['titre'], isNotNull);
    final id = doc['edition_id'] as String;
    expect(id, isNotEmpty);
    // Rendu seul : rien n'est émis (le ticket n'est peut-être pas sorti).
    expect(await e.v2.operationsOfType('edition_pre_x'), isEmpty);

    // L'hôte redémarre : nouvel adaptateur, aucun caissier identifié ; l'édition attend toujours sur le terminal.
    await adapter.close();
    final again = LocalRegisterAdapter(e, newUuid: adapterUuid);
    final recorded = await again.execute('recordEdition', {'edition_id': id}, null);
    expect(recorded, {'edition_id': id, 'recorded': true});
    final editions = await e.v2.operationsOfType('edition_pre_x');
    expect(editions, hasLength(1));
    expect((editions.single['operation'] as Map)['uuid'], id, reason: 'UUID de l’opération = edition_id');
    expect((editions.single['operation'] as Map)['operateur_id'], '7');

    // Arrêt simulé entre l'émission et l'écriture de la confirmation : le moteur refuse un second UUID identique.
    final awa = e.snapshot!.operators.firstWhere((o) => o.id == 7);
    final again2 = (await e.closureDocument('pre-x', 'detailed'))!;
    await e.recordEdition(awa, again2, operationUuid: id);
    expect(await e.v2.operationsOfType('edition_pre_x'), hasLength(1));

    // Rejeu : même réponse, aucune seconde opération.
    expect(await again.execute('recordEdition', {'edition_id': id}, null), recorded);
    expect(await e.v2.operationsOfType('edition_pre_x'), hasLength(1));

    // Une seconde impression est une seconde édition, avec son propre identifiant.
    await again.execute('login', {'operator_id': 7, 'pin': '1234'}, null);
    final second = await again.execute('closureDocument', {'kind': 'pre-x', 'version': 'short', 'paper_width': 58}, null);
    expect([second['columns'], second['paper_width']], [32, 58]);
    expect(second['edition_id'], isNot(id));
    await again.execute('recordEdition', {'edition_id': second['edition_id']}, null);
    expect(await e.v2.operationsOfType('edition_pre_x'), hasLength(2));
    await e.sync();
    for (final o in await e.v2.operationsOfType('edition_pre_x')) {
      expect(o['etat'], V2OperationState.integrated);
    }
    await again.close();
  });

  test('droits : caissier identifié, pré-Z réservé à caisse_cloturer ; arguments contrôlés', () async {
    final e = await paired();
    final adapter = LocalRegisterAdapter(e, newUuid: adapterUuid);
    expect(await failure(adapter, 'closureDocument', {'kind': 'pre-x', 'version': 'detailed'}), 'caissier_requis');

    await adapter.execute('login', {'operator_id': 8, 'pin': '1234'}, null);
    expect(await failure(adapter, 'closureDocument', {'kind': 'pre-z', 'version': 'detailed'}), 'document_interdit');
    final preX = await adapter.execute('closureDocument', {'kind': 'pre-x', 'version': 'detailed'}, null);
    expect(preX['columns'], 48, reason: 'largeur de l’adaptateur par défaut (80 mm)');
    for (final args in [
      {'kind': 'z-jour', 'version': 'detailed'},
      {'kind': 'pre-x', 'version': 'long'},
      {'kind': 'pre-x', 'version': 'short', 'columns': 40},
      {'kind': 'pre-x', 'version': 'short', 'paper_width': 76},
      {'kind': 'pre-x', 'version': 'short', 'duplicate': 'oui'},
    ]) {
      expect(await failure(adapter, 'closureDocument', args), 'argument_invalide', reason: '$args');
    }
    expect(await failure(adapter, 'recordEdition', const {}), 'argument_invalide');

    await adapter.execute('logout', const {}, null);
    await adapter.execute('login', {'operator_id': 7, 'pin': '1234'}, null);
    final preZ = await adapter.execute('closureDocument', {'kind': 'pre-z', 'version': 'short'}, null);
    expect(preZ['edition_id'], isNotNull);
    await adapter.execute('recordEdition', {'edition_id': preZ['edition_id']}, null);
    expect(await e.v2.operationsOfType('edition_pre_z'), hasLength(1));
    await adapter.close();
  });

  test('édition jamais confirmée : jamais émise, oubliée après 24 h ou au-delà de 100', () async {
    final e = await paired();
    final adapter = LocalRegisterAdapter(e, newUuid: adapterUuid);
    await adapter.execute('login', {'operator_id': 7, 'pin': '1234'}, null);

    final stale = (await adapter.execute('closureDocument', {'kind': 'pre-x', 'version': 'short'}, null))['edition_id'] as String;
    now = moment.add(const Duration(hours: 24, minutes: 1));
    expect(await adapter.execute('recordEdition', {'edition_id': stale}, null),
        {'edition_id': stale, 'recorded': false, 'reason': 'edition_inconnue'});
    expect(await failure(adapter, 'recordEdition', {'edition_id': 'inconnue'}), isNull);

    final ids = <String>[];
    for (var i = 0; i < 101; i++) {
      ids.add((await adapter.execute('closureDocument', {'kind': 'pre-x', 'version': 'short'}, null))['edition_id'] as String);
    }
    expect((await adapter.execute('recordEdition', {'edition_id': ids.first}, null))['recorded'], isFalse, reason: 'la plus ancienne au-delà de 100');
    expect((await adapter.execute('recordEdition', {'edition_id': ids[1]}, null))['recorded'], isTrue);
    expect((await adapter.execute('recordEdition', {'edition_id': ids.last}, null))['recorded'], isTrue);
    expect(await e.v2.operationsOfType('edition_pre_x'), hasLength(2), reason: 'seules les éditions confirmées sont émises');
    await adapter.close();
  });
}
