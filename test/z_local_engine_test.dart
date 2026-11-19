import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shopikaiss_terminal/src/offline/models.dart';
import 'package:shopikaiss_terminal/src/offline/store.dart';
import 'package:shopikaiss_terminal/src/offline/x_z_report.dart';
import 'package:shopikaiss_terminal/src/sync_v2/contract_schemas.dart';
import 'package:shopikaiss_terminal/src/sync_v2/schema_validator.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_engine.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_v2_server.dart';
import 'sync_v2_engine_test.dart' show serve21;

/// Lot « Z local » côté moteur (contrat z-local-c3610bbb) : annonce de `z.local` avec `contrat.2_1`, instantané à la
/// première annonce, `z.session` et `z.journee` stockées, détail figé remonté à la clôture, audits d'édition émis,
/// mention « journée partielle » quand le journal n'est plus à jour, `restaurant.interface` stockée et tolérante.
void main() {
  sqfliteFfiInit();
  late Directory dir;
  late SqfliteOfflineStore base;
  late FakeV2Server server;
  var uuids = 0;
  String newUuid() => 'abcdef00-0000-4000-8000-${(++uuids).toString().padLeft(12, '0')}';
  final moment = DateTime.utc(2026, 11, 19, 12);
  const pdv = '8b000000-0000-4000-8000-000000000001';
  const otherTerminal = '11111111-2222-4333-8444-666666666666';
  Map<String, dynamic> fixture(String name) =>
      Map<String, dynamic>.from(jsonDecode(File('test/fixtures/contrat-v2/fixtures/valides/$name.json').readAsStringSync()) as Map);

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('moteur_zlocal_');
    base = await SqfliteOfflineStore.open(name: p.join(dir.path, 'caisse.db'), factory: databaseFactoryFfi);
    server = FakeV2Server.sellable();
    serve21(server);
    server
      ..capabilities = [...server.capabilities, 'session.cloture']
      ..authorizationExpires = '2026-11-20T00:00:00Z'
      ..put('operateur', 'operateur:7', {
        'operateur_id': '7', 'nom': 'Awa', 'pin_empreinte': 'empreinte', 'droits': ['caisse_cloturer', 'ouverture_session', 'vente'],
        'remise_max_pourcent': null, 'remise_max_montant': null, 'approbateur_remise': false,
      }, critical: true);
  });
  tearDown(() async {
    await base.close();
    dir.deleteSync(recursive: true);
  });

  Map<String, dynamic> zSession() {
    final z = fixture('donnees-z-local--z-session');
    return {...z, 'terminal_uuid': fakeTerminal, 'session_uuid': fakeSession, 'fond_initial': 20000};
  }

  Map<String, dynamic> zDay({List<Map<String, dynamic>> open = const []}) =>
      {...fixture('donnees-z-local--z-journee'), 'terminaux': [fakeTerminal, otherTerminal], 'sessions_ouvertes': open};

  Future<V2Engine> paired({DateTime Function()? clock}) async {
    final e = V2Engine.onStore(base, transport: server, appVersion: 'essai', platform: 'android', newUuid: newUuid,
        pinVerifier: FakeV2Server.pinVerifier, contract21: true, clock: clock ?? () => moment);
    await e.load('https://boutique.exemple.ci');
    expect(await e.pair('ABCD-EFGH', model: 'Essai', appVersion: 'essai'), isNull);
    return e;
  }

  CartLine savon(V2Engine e) => CartLine(product: e.snapshot!.byCode('6190000000011')!.$1, quantity: BigInt.from(1000000));

  test('z.local : annoncée avec contrat.2_1, instantané à la première obtention, z.session et z.journee stockées', () async {
    final e = await paired();
    expect(server.requests.lastWhere((r) => r.path == '/etat').headers['X-Caisse-Capacites'], contains('z.local'));
    expect(await e.v2.read(V2Keys.contractRevision), isNot(contains('+zlocal')), reason: 'serveur sans z.local');
    expect(e.zLocalSupported, isFalse);

    server
      ..capabilities = [...server.capabilities, 'z.local']
      ..put('z.session', 'z_session:$fakeTerminal', zSession())
      ..put('z.journee', 'z_journee:$pdv', zDay());
    final snapshots = server.snapshotReasons.length;
    await e.sync();
    expect(await e.v2.read(V2Keys.contractRevision), endsWith('+zlocal1'));
    expect(server.snapshotReasons.length, snapshots + 1, reason: 'première annonce : instantané pour l’état courant');
    expect((await e.v2.entities('z.session')).keys, ['z_session:$fakeTerminal']);
    expect((await e.v2.entities('z.journee')).keys, ['z_journee:$pdv']);
    expect(e.zLocalSupported, isTrue);

    // Une entité z.* non conforme est ignorée sans arrêter le journal (types non critiques).
    server.publish([
      {'type': 'z.journee', 'critique': false, 'cle': 'z_journee:autre', 'revision': '50', 'action': 'upsert', 'donnees': {...zDay(), 'statut': 'inconnu'}},
    ]);
    final report = await e.sync();
    expect(report.message, isNull);
    expect(await e.v2.read(V2Keys.blocked), isNull);
    expect((await e.v2.entities('z.journee')).keys, ['z_journee:$pdv']);

    // Relance de l'application : la forme reste connue hors connexion.
    final again = V2Engine.onStore(base, transport: server, appVersion: 'essai', platform: 'android', newUuid: newUuid,
        pinVerifier: FakeV2Server.pinVerifier, contract21: true, clock: () => moment);
    await again.load('https://boutique.exemple.ci');
    expect(again.v2.zLocal, isTrue);
  });

  test('pré-X et Z de session : fond publié, retours en ligne, audits émis, détail figé envoyé à la clôture', () async {
    server
      ..capabilities = [...server.capabilities, 'z.local']
      ..put('z.session', 'z_session:$fakeTerminal', zSession())
      ..put('z.journee', 'z_journee:$pdv', zDay());
    final e = await paired();
    final awa = e.snapshot!.operators.firstWhere((o) => o.id == 7);
    final method = e.snapshot!.methods.firstWhere((m) => m.isCash);
    expect((await e.recordSale([savon(e)], [CartPayment(method: method, amount: 500, received: 500)], awa)).isSale, isTrue);

    // Pré-X : session ouverte en ligne, fond et retour en ligne publiés.
    final preX = (await e.closureDocument(ZKind.preX, ZVersion.detailed))!;
    final text = preX.layout(paperWidth: 80).lines.join('\n');
    expect(text, contains('20 000 FCFA'));
    expect(text, contains('Retour V-000123'));
    expect((preX.model['synthese'] as Map)['returns_amount'], 1000);
    // Une opération par impression, chacune son uuid ; acceptées par le serveur.
    await e.recordEdition(awa, preX);
    await e.recordEdition(awa, preX);
    final editions = await e.v2.operationsOfType('edition_pre_x');
    expect(editions, hasLength(2));
    expect({for (final o in editions) (o['operation'] as Map)['uuid']}, hasLength(2));
    expect(((editions.first['operation'] as Map)['contenu'] as Map)['session_uuid'], fakeSession);

    // Pré-Z de la journée : session publiée de Comptoir 2 + session ouverte d'ici (sans montant), journal frais.
    final preZ = (await e.closureDocument(ZKind.preZ, ZVersion.short))!;
    expect(preZ.partial, isFalse);
    expect((preZ.model['synthese'] as Map)['revenue'], 5000);
    await e.recordEdition(awa, preZ);
    expect(((await e.v2.operationsOfType('edition_pre_z')).single['operation'] as Map)['contenu'],
        containsPair('sessions', ['5e55a0d1-0000-4000-8000-000000000002']));

    await e.sync();
    for (final type in ['edition_pre_x', 'edition_pre_z']) {
      for (final o in await e.v2.operationsOfType(type)) {
        expect(o['etat'], V2OperationState.integrated, reason: '$type conforme au contrat du serveur');
      }
    }

    // Clôture : le détail du Z de session part dans cloture_session.contenu.detail, conforme, et le Z l'imprime tel quel.
    await e.closeSession(awa, cash: 20500);
    final closure = (await e.v2.operationsOfType('cloture_session')).single['operation'] as Map;
    final detail = (closure['contenu'] as Map)['detail'] as Map;
    expect(e.v2.validator.validate(detail, r'donnees-z-local-1.json#/$defs/detail_cloture'), isEmpty);
    expect([(detail['summary'] as Map)['revenue'], (detail['summary'] as Map)['returns_amount'], detail['payments_count']], ['500', '1000', 1]);
    final z = (await e.closureDocument(ZKind.session, ZVersion.detailed))!;
    expect(detailToContract({'summary': {...z.model['synthese'] as Map<String, dynamic>}..remove('cash_difference')})['summary'], detail['summary']);
    await e.recordEdition(awa, z);
    expect(await e.v2.operationsOfType('edition_pre_x'), hasLength(2), reason: 'un Z de session n’est pas une édition provisoire');
    await e.sync();
    expect(server.received[closure['uuid']]!['etat'], 'integree');
  });

  test('« Journée partielle » : autre terminal ouvert, puis journal en échec', () async {
    var now = moment;
    server
      ..capabilities = [...server.capabilities, 'z.local']
      ..put('z.journee', 'z_journee:$pdv', zDay());
    final e = await paired(clock: () => now);
    expect((await e.closureDocument(ZKind.preZ, ZVersion.detailed))!.partial, isFalse);

    server.publish([
      {'type': 'z.journee', 'critique': false, 'cle': 'z_journee:$pdv', 'revision': '60', 'action': 'upsert', 'donnees': zDay(open: [
        {'session_uuid': '5e55a0d1-0000-4000-8000-000000000003', 'terminal_uuid': otherTerminal, 'terminal_nom': 'Comptoir 2', 'caissier': 'Yao Kouassi', 'operateur_id': '8', 'ouverte_le': '2026-11-19T11:00:00Z'},
      ])},
    ]);
    await e.sync();
    final open = (await e.closureDocument(ZKind.preZ, ZVersion.detailed))!;
    expect([open.partial, open.edition!['partielle']], [true, true]);
    expect(open.layout(paperWidth: 58).lines.join(' '), contains('Journee partielle'));

    // Journal frais sans autre session ouverte, puis échec de synchronisation ; puis journal trop ancien (3 × 10 s).
    server.publish([
      {'type': 'z.journee', 'critique': false, 'cle': 'z_journee:$pdv', 'revision': '61', 'action': 'upsert', 'donnees': zDay()},
    ]);
    await e.sync();
    expect((await e.closureDocument(ZKind.preZ, ZVersion.detailed))!.partial, isFalse);
    server.failStatus = 0;
    await e.sync();
    expect((await e.closureDocument(ZKind.preZ, ZVersion.detailed))!.partial, isTrue, reason: 'dernière synchronisation échouée');
    server.failStatus = null;
    await e.sync();
    expect((await e.closureDocument(ZKind.preZ, ZVersion.detailed))!.partial, isFalse);
    now = moment.add(const Duration(seconds: 31));
    expect((await e.closureDocument(ZKind.preZ, ZVersion.detailed))!.partial, isTrue, reason: 'journal plus vieux que 3 × changements_secondes');
  });

  test('sans z.local au serveur : aucun détail à la clôture, aucun audit d’édition', () async {
    final e = await paired();
    final awa = e.snapshot!.operators.firstWhere((o) => o.id == 7);
    final preX = (await e.closureDocument(ZKind.preX, ZVersion.short))!;
    expect(preX.edition, isNotNull);
    await e.recordEdition(awa, preX);
    expect(await e.v2.operationsOfType('edition_pre_x'), isEmpty);
    await e.closeSession(awa, cash: 0);
    final closure = (await e.v2.operationsOfType('cloture_session')).single['operation'] as Map;
    expect((closure['contenu'] as Map).containsKey('detail'), isFalse);
  });

  test('restaurant.interface : stockée par point de vente, valeur inconnue ramenée au défaut, donnée invalide ignorée', () async {
    final store = V2Store(base.database, SchemaValidator((file) => contractV2Schemas[file]!))
      ..contract21 = true
      ..restaurant = true;
    final published = fixture('donnees--restaurant-interface');
    Map<String, dynamic> change(String key, String revision, Map<String, dynamic> data) =>
        {'type': 'restaurant.interface', 'critique': false, 'cle': key, 'revision': revision, 'action': 'upsert', 'donnees': data};
    final result = await store.applyChanges({
      'groupes': [
        {'changements': [change('interface:$pdv', '1', published)]},
        {'changements': [change('interface:b1000000-0000-4000-8000-000000000002', '2', {...published, 'point_de_vente_uuid': 'b1000000-0000-4000-8000-000000000002', 'navigation_carte': 'grille'})]},
        {'changements': [change('interface:b1000000-0000-4000-8000-000000000003', '3', {...published, 'point_de_vente_uuid': 'pas-un-uuid'})]},
        {'changements': [change('interface:b1000000-0000-4000-8000-000000000004', '4', {'point_de_vente_uuid': 'b1000000-0000-4000-8000-000000000004'})]},
      ],
      'curseur_suivant': 'c-4',
    });
    expect([result.groups, result.blockedBy], [4, null]);
    final stored = await store.entities('restaurant.interface');
    expect(stored['interface:$pdv'], published);
    expect(stored['interface:b1000000-0000-4000-8000-000000000002']!['navigation_carte'], 'chips');
    expect(stored.containsKey('interface:b1000000-0000-4000-8000-000000000003'), isFalse, reason: 'non conforme : ignorée sans bloquer');
    expect(stored['interface:b1000000-0000-4000-8000-000000000004'], containsPair('demander_couverts', true), reason: 'champs absents : défauts');
    expect(await store.read(V2Keys.cursor), 'c-4');
  });
}
