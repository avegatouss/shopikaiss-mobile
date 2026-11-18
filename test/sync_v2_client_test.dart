import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shopikaiss_terminal/src/offline/store.dart';
import 'package:shopikaiss_terminal/src/sync_v2/canonical_json.dart';
import 'package:shopikaiss_terminal/src/sync_v2/contract_schemas.dart';
import 'package:shopikaiss_terminal/src/sync_v2/decimal6.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_client.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_sale.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_store.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_sync.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_v2_server.dart';

void main() {
  sqfliteFfiInit();
  late Directory dir;
  late SqfliteOfflineStore base;
  late V2Store store;
  late FakeV2Server server;
  late CaisseV2Client client;
  late V2Sync sync;
  var ids = 0;
  String uuid() => 'abcdef00-0000-4000-8000-${(ids++).toString().padLeft(12, '0')}';

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('sync_v2_');
    base = await SqfliteOfflineStore.open(name: p.join(dir.path, 'caisse.db'), factory: databaseFactoryFfi);
    store = V2Store(base.database, fakeValidator);
    server = FakeV2Server();
    client = CaisseV2Client(apiBase: 'https://boutique.exemple.ci/api/caisse/v2', transport: server, appVersion: '1.2.0', localSchema: offlineSchemaVersion);
    sync = V2Sync(client, store);
    await sync.pair('ABCD-EFGH', platform: 'android', model: 'Essai', newUuid: uuid);
  });
  tearDown(() async {
    await base.close();
    dir.deleteSync(recursive: true);
  });

  /// Vente locale v2 de [quantity] savons (ou d'un carton), payée en espèces.
  Future<Map<String, dynamic>> sell(String quantity, {String? packaging, String? operationUuid, String? draft}) async {
    final products = await store.entities('produit');
    final packs = await store.entities('conditionnement');
    final builder = V2SaleBuilder(products: products, packagings: packs, revisions: const {}, newUuid: uuid);
    final cart = [V2CartLine(productUuid: fakeSavon, packagingUuid: packaging, quantityMicros: Decimal6.parseInput(quantity)!)];
    final vat = (await store.shopVat())!;
    final payable = builder.payable(cart, vat: vat);
    final device = jsonDecode((await store.read(V2Keys.device))!) as Map;
    final epoch = int.parse((await store.read(V2Keys.epoch))!);
    final opUuid = operationUuid ?? uuid();
    final draftUuid = draft ?? uuid();
    final cursor = await store.read(V2Keys.cursor);
    final policies = await store.read(V2Keys.policiesVersion) ?? '0';
    return store.recordOperation(
      (seq) => v2Operation(
        uuid: opUuid,
        type: 'vente',
        deviceUuid: device['uuid'] as String,
        epoch: epoch,
        sequence: seq,
        createdAt: DateTime.utc(2026, 10, 29, 8),
        operatorId: '7',
        policiesVersion: policies,
        catalogueCursor: cursor,
        content: builder.content(
          numberLocal: 'HL2-3-${seq.toString().padLeft(6, '0')}',
          draftUuid: draftUuid,
          sessionUuid: fakeSession,
          cart: cart,
          payments: [V2Payment(method: 'especes', amount: payable, received: payable)],
          vat: vat,
        ),
      ),
      draftUuid: draftUuid,
    );
  }

  Future<int> stock() async => (await store.estimatedStock())[fakeSavon]!;

  test('les schémas embarqués sont exactement ceux du contrat (copie de A)', () {
    for (final f in Directory('test/fixtures/contrat-v2/schemas').listSync().whereType<File>()) {
      // Fins de ligne neutralisées : la copie Git peut être en CRLF sur Windows, le contenu JSON est le même.
      String lf(String? s) => (s ?? '').replaceAll('\r\n', '\n');
      expect(lf(contractV2Schemas[p.basename(f.path)]), lf(f.readAsStringSync()), reason: p.basename(f.path));
    }
    expect(contractV2Schemas, hasLength(14), reason: 'révision 2.1 : donnees-2.1.json et passes.json ; restaurant-1 : donnees-restaurant-1.json');
  });

  test('Decimal6 : format du contrat, arrondi demi supérieur comme Brick\\Math', () {
    expect(Decimal6.format(2500000), '2.500000');
    expect(Decimal6.format(-12000000), '-12.000000');
    expect(Decimal6.parseInput('0,5'), 500000);
    expect(Decimal6.parseInput('1.1234567'), isNull);
    expect(Decimal6.amount(333, 1500000), 500); // 499,5 → 500
    expect(Decimal6.multiply(333333, 3000000), 999999);
    expect(Decimal6.label(1500000), '1,5');
  });

  test('premier démarrage : instantané vérifié, projection et curseur posés ensemble, accusé envoyé', () async {
    final report = await sync.run();
    expect(report.complete, isTrue, reason: '$report');
    expect(report.bootstrapped, isTrue);
    expect(await store.read(V2Keys.cursor), 'c-10');
    expect((await store.counts())['produit'], 2);
    expect(await stock(), 10000000);
    expect(server.lastAck!['curseur_applique'], 'c-10');
    expect(server.requests.first.path, '/appairage');
    expect(server.requests[1].headers['X-Caisse-Capacites'], 'vente.especes,stock.couverture,instantane.v1');
  });

  test('page d’instantané altérée : rien n’est appliqué, ni projection ni curseur', () async {
    server.corruptPage = true;
    final report = await sync.run();
    expect(report.failure?.code, 'empreinte_page');
    expect(await store.read(V2Keys.cursor), isNull);
    expect(await store.counts(), isEmpty);
  });

  test('vente v2 : conforme au contrat, recoupée comme CoherenceVente, empreinte vérifiable', () async {
    await sync.run();
    final op = await sell('2', packaging: fakePack);
    expect(fakeValidator.validate(op, 'operation.json'), isEmpty);
    expect(coherenceGaps(op), isEmpty);
    expect(CanonicalJson.operationFingerprint(op), op['empreinte']);
    final line = (op['contenu']['lignes'] as List).single as Map;
    expect(line['quantite_base'], '24.000000');
    expect(line['total'], 11000);
    // TVA 18 % incluse (entité boutique, 2.0.1) : 11000 × 18 / 118 = 1677,97 → 1678 ; à payer inchangé.
    expect(op['contenu']['tva'], {'taux': '18.000000', 'incluse': true});
    expect(op['contenu']['totaux'], {'brut': 11000, 'remises': 0, 'base_ht': 9322, 'tva': 1678, 'a_payer': 11000});
    expect((op['contenu']['mouvements'] as List).single['variation'], '-24.000000');
    expect(op['sequence'], 1, reason: 'séquence reprise après derniere_sequence du serveur');
    expect(await stock(), 10000000 - 24000000, reason: 'stock estimé négatif autorisé et visible');
  });

  test('un brouillon ne donne qu’une vente ; rien n’est écrit si la vente est refusée', () async {
    await sync.run();
    await sell('1', draft: 'dddddddd-0000-4000-8000-000000000001');
    await expectLater(sell('1', draft: 'dddddddd-0000-4000-8000-000000000001'), throwsA(isA<V2SaleRefused>()));
    expect((await store.queueStats())['non_envoyees'], 1);
    expect(await store.read(V2Keys.nextSequence), '2', reason: 'séquence non consommée par le refus');
  });

  test('couverture (exemple du doc 01) : 10 → vente de 3 → 7 ; intégrée → 7 ; projection 7 couvrante → 7, jamais 4 ni 10', () async {
    await sync.run();
    final op = await sell('3');
    expect(await stock(), 7000000);
    await sync.run();
    expect((await store.operation(op['uuid'] as String))!['etat'], 'integree');
    expect(await stock(), 7000000, reason: 'l’acquittement « integree » ne couvre rien');
    server.publish([
      {'type': 'stock.projection', 'critique': false, 'cle': fakeSavon, 'revision': '2', 'action': 'upsert',
        'donnees': {'produit_uuid': fakeSavon, 'lot_uuid': null, 'quantite': '7.000000'}, 'operations_couvertes': [op['uuid']]},
    ]);
    await sync.run();
    expect(await stock(), 7000000);
    expect((await store.movements(op['uuid'] as String)).single['couvert_le'], isNotNull);
  });

  test('réponse perdue après COMMIT serveur : « envoi inconnu », renvoi identique, une seule vente côté serveur', () async {
    await sync.run();
    final op = await sell('1');
    server.loseNextOperationsResponse = true;
    final first = await sync.run();
    expect(first.failure?.outcomeUnknown, isTrue);
    expect((await store.operation(op['uuid'] as String))!['etat'], V2OperationState.sendUnknown);
    final second = await sync.run();
    expect(second.complete, isTrue);
    expect(server.received, hasLength(1));
    final sent = server.requests.where((r) => r.path == '/operations').map((r) => ((r.body as Map)['operations'] as List).single).toList();
    expect(sent, hasLength(2));
    expect(CanonicalJson.encode(sent[0]), CanonicalJson.encode(sent[1]), reason: 'renvoi octet pour octet identique');
    expect((await store.operation(op['uuid'] as String))!['numero_serveur'], 'V-20261029-0001');
  });

  test('rejet_protocole : quarantaine conservée, jamais renvoyée ; les autres ventes passent', () async {
    await sync.run();
    final bad = await sell('1');
    final good = await sell('1');
    server.verdict = null;
    // Altération après coup (défaut simulé) : le serveur rejette l'empreinte.
    await base.database.update('v2_operations', {'operation': CanonicalJson.encode({...bad, 'cree_le': '2026-10-29T09:00:00Z'})},
        where: 'uuid = ?', whereArgs: [bad['uuid']]);
    final report = await sync.run();
    expect(report.rejected, 1);
    expect(report.integrated, 1);
    final quarantined = await store.operation(bad['uuid'] as String);
    expect(quarantined!['etat'], V2OperationState.rejected);
    expect((quarantined['raison'] as Map)['code'], 'empreinte_invalide');
    expect((await store.operation(good['uuid'] as String))!['etat'], 'integree');
    await sync.run();
    expect(server.requests.where((r) => r.path == '/operations'), hasLength(1), reason: 'la quarantaine n’est pas renvoyée');
  });

  test('à arbitrer : consommation gardée, état relu par /operations/etats sans renvoi ; résolue → consommation retirée', () async {
    await sync.run();
    server.verdict = (_) => 'a_arbitrer';
    final op = await sell('2');
    await sync.run();
    expect(await stock(), 8000000);
    await sync.run();
    expect(server.requests.where((r) => r.path == '/operations'), hasLength(1));
    expect(server.requests.where((r) => r.path == '/operations/etats'), hasLength(2));
    server.publish([
      {'type': 'operation_etat', 'critique': false, 'cle': op['uuid'], 'revision': '2', 'action': 'upsert',
        'donnees': {'operation_uuid': op['uuid'], 'etat': 'resolue', 'version_etat': '2', 'raison': null}},
    ]);
    server.received[op['uuid']]!['etat'] = 'resolue';
    server.received[op['uuid']]!['version'] = 2;
    await sync.run();
    expect((await store.operation(op['uuid'] as String))!['etat'], 'resolue');
    expect(await stock(), 10000000);
  });

  test('type critique inconnu : arrêt avant son groupe, curseur non avancé ; les groupes déjà vus restent idempotents', () async {
    await sync.run();
    server.publish([
      {'type': 'produit', 'critique': false, 'cle': fakeSavon, 'revision': '2', 'action': 'upsert',
        'donnees': {'nom': 'Savon noir', 'reference': 'SAV', 'categorie': null, 'prix': 600, 'stock_illimite': false, 'actif': true, 'vente_locale': true}},
    ]);
    server.publish([{'type': 'credit.solde', 'critique': true, 'cle': 'client:1', 'revision': '1', 'action': 'upsert', 'donnees': {'solde': 1}}]);
    final report = await sync.run();
    expect(report.blockedBy, 'credit.solde');
    expect(await store.read(V2Keys.cursor), 'c-10');
    expect((await store.entities('produit'))[fakeSavon]!['prix'], 600, reason: 'groupe précédent appliqué');
    expect(await store.read(V2Keys.blocked), 'credit.solde');
    server.publish([{'type': 'notes.internes', 'critique': false, 'cle': 'n1', 'revision': '1', 'action': 'upsert', 'donnees': {'x': 1}}]);
    expect((await sync.run()).blockedBy, 'credit.solde', reason: 'jamais sauté silencieusement');
  });

  test('révision dépassée ignorée ; suppression gardée en pierre tombale', () async {
    await sync.run();
    server.publish([
      {'type': 'produit', 'critique': false, 'cle': fakeService, 'revision': '5', 'action': 'suppression', 'donnees': null},
    ]);
    server.publish([
      {'type': 'produit', 'critique': false, 'cle': fakeService, 'revision': '4', 'action': 'upsert',
        'donnees': {'nom': 'Ancien', 'reference': null, 'categorie': null, 'prix': 1, 'stock_illimite': true, 'actif': true, 'vente_locale': true}},
    ]);
    await sync.run();
    expect((await store.entities('produit')).containsKey(fakeService), isFalse);
  });

  test('curseur expiré (410) : nouvel instantané avec réconciliation, file conservée', () async {
    await sync.run();
    await sell('1');
    await sell('2');
    await sync.run();
    final kept = await sell('1'); // pas encore envoyée
    server.publish([{'type': 'moyen_paiement', 'critique': false, 'cle': 'moyen:om', 'revision': '1', 'action': 'upsert',
      'donnees': {'code': 'om', 'nom': 'Orange Money', 'especes': false, 'local': false}}]);
    server.prunedThrough = 100;
    // L'envoi passe d'abord, puis le journal répond 410 : instantané.
    final report = await sync.run();
    expect(report.bootstrapped, isTrue, reason: '$report');
    expect((await store.operation(kept['uuid'] as String))!['etat'], 'integree');
    expect((await store.entities('moyen_paiement')).containsKey('moyen:om'), isTrue);
    expect(await store.read(V2Keys.cursor), 'c-11');
    // Les trois ventes sont « integrees » dans la couverture du manifeste : reflétées par sa projection (10 dans ce
    // faux serveur), leur consommation locale est retirée — pas de double décompte.
    expect(await stock(), 10000000);
  });

  test('401 : révocation notée, file conservée, aucune donnée effacée', () async {
    await sync.run();
    final op = await sell('1');
    client.token = 'jeton-revoque-0000000000';
    final report = await sync.run();
    expect(report.failure?.kind, V2FailureKind.unauthorized);
    expect(await store.read(V2Keys.revoked), 'appareil_non_reconnu');
    expect((await store.operation(op['uuid'] as String))!['etat'], V2OperationState.toSend);
    expect(await stock(), 9000000);
  });

  test('429 et 5xx : Retry-After rendu, résultat inconnu pour 5xx, rien de perdu', () async {
    await sync.run();
    await sell('1');
    server.failStatus = 429;
    server.failCode = 'trop_de_requetes';
    var report = await sync.run();
    expect(report.failure?.kind, V2FailureKind.throttled);
    expect(report.failure?.retryAfter, const Duration(seconds: 3));
    server.failStatus = 503;
    server.failCode = 'indisponible';
    report = await sync.run();
    expect(report.failure?.outcomeUnknown, isTrue);
    server.failStatus = null;
    expect((await sync.run()).integrated, 1);
    final delay = CaisseV2Client.backoff(3, retryAfter: const Duration(seconds: 3));
    expect(delay.inSeconds, inInclusiveRange(3, 5));
  });

  test('migration 3 → 4 : tables v2 ajoutées, file v1 intacte', () async {
    final path = p.join(dir.path, 'ancienne.db');
    final old = await SqfliteOfflineStore.open(name: path, factory: databaseFactoryFfi);
    await old.database.insert('kv', {'cle': 'jeton', 'valeur': 'v1'});
    for (final t in ['v2_entites', 'v2_operations', 'v2_mouvements', 'v2_paniers_consommes']) {
      await old.database.execute('DROP TABLE $t');
    }
    await old.database.setVersion(3);
    await old.close();
    final reopened = await SqfliteOfflineStore.open(name: path, factory: databaseFactoryFfi);
    expect(await reopened.database.getVersion(), 4);
    expect(await reopened.read('jeton'), 'v1');
    expect(await reopened.database.query('v2_operations'), isEmpty);
    await reopened.close();
  });
}
