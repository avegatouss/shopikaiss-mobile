import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shopikaiss_terminal/src/offline/engine.dart';
import 'package:shopikaiss_terminal/src/offline/models.dart';
import 'package:shopikaiss_terminal/src/offline/store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'offline_test.dart' show FakeTransport, sampleSnapshot;

/// Caisse autonome, lot B : base SQLite réelle (pas de mémoire), migration du schéma 1 et règles du stock local.
void main() {
  sqfliteFfiInit();
  final factory = databaseFactoryFfi;
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('caisse_v2_'));
  tearDown(() => dir.deleteSync(recursive: true));

  String dbPath() => p.join(dir.path, 'caisse_hors_ligne.db');

  /// Base telle que l'écrit l'application 1.1.5 (schéma 1), avec une file et un PIN bloqué.
  Future<void> createV1(List<Map<String, Object?>> operations, {Map<String, String> kv = const {}}) async {
    final db = await factory.openDatabase(
      dbPath(),
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute('CREATE TABLE kv (cle TEXT PRIMARY KEY, valeur TEXT)');
          await db.execute(
            'CREATE TABLE operations (uuid TEXT PRIMARY KEY, sequence INTEGER NOT NULL UNIQUE, type TEXT NOT NULL, '
            'numero TEXT, date TEXT NOT NULL, caissier_id INTEGER NOT NULL, contenu TEXT NOT NULL, statut TEXT NOT NULL, '
            'statut_serveur TEXT, numero_serveur TEXT, message TEXT, transmise_le TEXT)',
          );
          await db.execute('CREATE INDEX operations_statut ON operations (statut, sequence)');
        },
      ),
    );
    for (final e in kv.entries) {
      await db.insert('kv', {'cle': e.key, 'valeur': e.value});
    }
    for (final o in operations) {
      await db.insert('operations', o);
    }
    await db.close();
  }

  Map<String, Object?> v1Sale(String uuid, int sequence, String status, {String? serverStatus, int quantity = 2, int? packaging}) => {
    'uuid': uuid,
    'sequence': sequence,
    'type': 'vente',
    'numero': 'HL-001-${sequence.toString().padLeft(6, '0')}',
    'date': '2026-10-18T10:00:00.000Z',
    'caissier_id': 7,
    // Contenu écrit par la 1.1.5, conservé à l'octet près (son empreinte côté serveur en dépend).
    'contenu':
        '{"lignes":[{"produit_id":10,"conditionnement_id":$packaging,"quantite":"$quantity","prix_unitaire":1000,"remise":0}],'
        '"paiements":[{"moyen":"especes","montant":2000,"recu":2000}],"total":2000}',
    'statut': status,
    'statut_serveur': serverStatus,
    'numero_serveur': null,
    'message': null,
    'transmise_le': status == 'en_attente' ? null : '2026-10-18T11:00:00.000Z',
  };

  group('Migration du schéma 1 vers 2 (mise à jour de l’application installée)', () {
    test('UUID, séquences, contenus, statuts et PIN bloqué conservés ; mouvements reconstitués', () async {
      await createV1(
        [
          v1Sale('a', 42, 'en_attente', quantity: 2, packaging: 3),
          v1Sale('b', 43, 'transmise', serverStatus: 'integree'),
          v1Sale('c', 44, 'transmise', serverStatus: 'a_arbitrer'),
          {
            'uuid': 'd',
            'sequence': 41,
            'type': 'ouverture_session',
            'numero': null,
            'date': '2026-10-18T08:00:00.000Z',
            'caissier_id': 7,
            'contenu': '{"fond":5000}',
            'statut': 'en_attente',
          },
        ],
        kv: {
          StoreKeys.snapshot: jsonEncode(sampleSnapshot()),
          StoreKeys.lastSequence: '44',
          '${StoreKeys.pinFailures}7': '4|2026-10-18T10:05:00.000Z',
        },
      );
      final reader = await factory.openDatabase(dbPath(), options: OpenDatabaseOptions(readOnly: true));
      final before = await reader.query('operations', orderBy: 'sequence');
      await reader.close();

      final store = await SqfliteOfflineStore.open(name: dbPath(), factory: factory);
      final db = await factory.openDatabase(dbPath());
      expect(await db.getVersion(), offlineSchemaVersion);
      final after = await db.query('operations', orderBy: 'sequence');
      for (var i = 0; i < before.length; i++) {
        for (final column in before[i].keys) {
          expect(after[i][column], before[i][column], reason: 'colonne $column de ${before[i]['uuid']}');
        }
      }
      expect(await store.read('${StoreKeys.pinFailures}7'), '4|2026-10-18T10:05:00.000Z');
      expect(await store.read(StoreKeys.lastSequence), '44');

      // Vente en attente : 2 cartons de 12 = 24 unités consommées, non couvertes. Ventes transmises : couvertes, comme en 1.1.5.
      final pending = await store.movements('a');
      expect(pending.single.quantityMicros, -24000000);
      expect(pending.single.coveredAt, isNull);
      expect((await store.movements('b')).single.coveredAt, isNotNull);
      expect((await store.movements('c')).single.coveredAt, isNotNull);
      expect(await store.movements('d'), isEmpty);
      expect(await store.uncoveredStock(), {10: -24000000});
      expect((await store.counts()).pending, 2);
      expect((await store.counts()).arbitration, 1);
      // Le mouvement d'une opération a toujours le même identifiant (migration rejouable, reprise).
      expect(pending.single.uuid, movementUuid('a', 0));
      await db.close();
      await store.close();
    });

    test('une application plus ancienne ne lit ni n’efface un schéma plus récent', () async {
      final store = await SqfliteOfflineStore.open(name: dbPath(), factory: factory);
      await store.write('cle', 'valeur');
      await store.close();
      await expectLater(
        factory.openDatabase(
          dbPath(),
          options: OpenDatabaseOptions(version: 1, onDowngrade: (db, o, n) => throw StateError('trop ancienne')),
        ),
        throwsA(anything),
      );
      final reopened = await SqfliteOfflineStore.open(name: dbPath(), factory: factory);
      expect(await reopened.read('cle'), 'valeur');
      await reopened.close();
    });
  });

  group('Vente atomique et stock local (SQLite réel)', () {
    late SqfliteOfflineStore store;
    late FakeTransport transport;
    late DateTime clock;
    late OfflineEngine engine;
    var uuid = 0;

    setUp(() async {
      store = await SqfliteOfflineStore.open(name: dbPath(), factory: factory);
      transport = FakeTransport();
      clock = DateTime(2026, 10, 18, 10);
      engine = OfflineEngine(
        store: store,
        transport: transport,
        clock: () => clock,
        newUuid: () => '00000000-0000-4000-8000-${(uuid++).toString().padLeft(12, '0')}',
      );
      await engine.load('https://boutique.exemple.ci');
      expect(await engine.pair('ABCD-EFGH', model: 'SUNMI T2', appVersion: '1.2.0'), isNull);
    });
    tearDown(() => store.close());

    Operator cashier() => engine.snapshot!.operators.first;
    PaymentMethodInfo cash() => engine.snapshot!.methods.first;
    CartLine soap(int quantity, {Packaging? packaging}) =>
        CartLine(product: engine.snapshot!.products.first, packaging: packaging, quantity: BigInt.from(quantity * 1000000));
    Future<void> serverStock(String quantity) async {
      final body = sampleSnapshot();
      ((body['produits'] as List).first as Map)['stock'] = quantity;
      transport.snapshotBody = body;
    }

    test('LOC-02 : deux encaissements simultanés du même panier = une vente, une séquence, une consommation', () async {
      final results = await Future.wait([
        for (var i = 0; i < 2; i++)
          engine
              .recordSale([soap(1)], [CartPayment(method: cash(), amount: 1000)], cashier(), draftUuid: 'panier-1')
              .then<Object>((o) => o, onError: (Object e) => e),
      ]);
      expect(results.whereType<OfflineOperation>(), hasLength(1));
      expect(results.whereType<OfflineRefusal>().single.message, contains('déjà été encaissé'));
      expect(await store.operations(), hasLength(1));
      expect(await store.uncoveredStock(), {10: -1000000});
      // Panier suivant : nouvelle séquence, à la suite.
      final next = await engine.recordSale([soap(1)], [CartPayment(method: cash(), amount: 1000)], cashier(), draftUuid: 'panier-2');
      expect(next.sequence, 43);
    });

    test('LOC-03 : une vente enregistrée est retrouvée après redémarrage, sans réencaissement', () async {
      final sale = await engine.recordSale([soap(2)], [CartPayment(method: cash(), amount: 2000)], cashier(), draftUuid: 'panier-1');
      await store.close();
      store = await SqfliteOfflineStore.open(name: dbPath(), factory: factory);
      final restarted = OfflineEngine(store: store, transport: transport, clock: () => clock);
      await restarted.load('https://boutique.exemple.ci');
      expect((await restarted.history()).single.uuid, sale.uuid);
      expect(restarted.pendingSales, 1);
      await expectLater(
        restarted.recordSale([soap(2)], [CartPayment(method: cash(), amount: 2000)], cashier(), draftUuid: 'panier-1'),
        throwsA(isA<OfflineRefusal>()),
      );
      expect(await store.operations(), hasLength(1));
    });

    test('STK-01 : stock 10, vente de 3 → 7 ; après l’accusé seul toujours 7 ; après le catalogue du serveur toujours 7', () async {
      await serverStock('10.000000');
      expect(await engine.refreshSnapshot(), isNull);
      double estimated(Map<int, BigInt> sold) => (engine.snapshot!.products.first.stockMicros - (sold[10] ?? BigInt.zero)).toInt() / 1e6;

      await engine.recordSale([soap(3)], [CartPayment(method: cash(), amount: 3000)], cashier());
      expect(estimated(await engine.soldSinceSnapshot()), 7);

      clock = clock.add(const Duration(minutes: 1));
      await engine.sync(); // accusé « integree » : le catalogue local ne le reflète pas encore
      expect(estimated(await engine.soldSinceSnapshot()), 7);

      clock = clock.add(const Duration(minutes: 1));
      await serverStock('7.000000'); // le serveur a intégré la vente
      expect(await engine.refreshSnapshot(), isNull);
      expect(estimated(await engine.soldSinceSnapshot()), 7);
      expect((await store.movements((await store.operations()).single.uuid)).single.coveredAt, isNotNull);
    });

    test('un catalogue demandé AVANT l’intégration ne couvre pas la vente (pas de double déduction ni de remontée)', () async {
      await engine.recordSale([soap(3)], [CartPayment(method: cash(), amount: 3000)], cashier());
      final sale = (await store.operations()).single;
      // Intégration connue à 10:05, catalogue dont la demande est partie à 10:00 (réponse arrivée après).
      sale
        ..status = OperationStatus.sent
        ..serverStatus = 'integree'
        ..resolvedAt = clock.add(const Duration(minutes: 5));
      await store.update(sale);
      await store.saveSnapshot(json: jsonEncode(sampleSnapshot()), at: clock.add(const Duration(minutes: 6)), coverResolvedBefore: clock);
      expect(await store.uncoveredStock(), {10: -3000000});
    });

    test('STK-03 : vente à arbitrer : consommation gardée, jamais purgée ni renvoyée ; intégrée plus tard puis couverte', () async {
      transport.verdict = (_) => 'a_arbitrer';
      await engine.recordSale([soap(2)], [CartPayment(method: cash(), amount: 2000)], cashier());
      await engine.sync();
      expect(engine.localArbitrationCount, 1);
      await engine.refreshSnapshot();
      expect(await store.uncoveredStock(), {10: -2000000});

      // 40 jours plus tard (au-delà des 30 jours de conservation) : toujours là.
      await store.purgeSent(const Duration(days: -1)); // tout ce qui a été transmis avant demain
      expect(await store.operations(), hasLength(1));

      // Synchronisations suivantes : la vente à arbitrer n'est JAMAIS renvoyée (en v1, un renvoi relancerait son
      // intégration à la place de la décision de la boutique).
      final sent = transport.batches.length;
      clock = clock.add(const Duration(hours: 1));
      await engine.sync();
      expect(transport.batches, hasLength(sent));

      // Sort connu plus tard par une lecture seule (B-REQ-004 / v2) : intégrée.
      final sale = (await store.operations()).single
        ..serverStatus = 'integree'
        ..resolvedAt = clock;
      await store.update(sale);
      expect((await store.counts()).arbitration, 0);
      expect(await store.uncoveredStock(), {10: -2000000}, reason: 'pas encore de catalogue demandé après l’intégration');

      clock = clock.add(const Duration(minutes: 1));
      await engine.refreshSnapshot();
      expect(await store.uncoveredStock(), isEmpty);
      await store.purgeSent(const Duration(days: -1)); // tout ce qui a été transmis avant demain
      expect(await store.operations(), isEmpty);
    });

    Map<String, dynamic> withCoverage({String stock = '10.000000', List<String> integrees = const [], List<String> aArbitrer = const [], List<String> ecartees = const []}) {
      final body = sampleSnapshot();
      ((body['produits'] as List).first as Map)['stock'] = stock;
      body['couverture_stock'] = {'depuis_sequence': 42, 'integrees': integrees, 'a_arbitrer': aArbitrer, 'ecartees': ecartees, 'tronque': false};
      return body;
    }

    test('B-REQ-002 : couverture exacte du serveur, sans horloge ; plus ancienne vente non couverte demandée', () async {
      final first = await engine.recordSale([soap(3)], [CartPayment(method: cash(), amount: 3000)], cashier());
      final second = await engine.recordSale([soap(2)], [CartPayment(method: cash(), amount: 2000)], cashier());
      transport.verdict = (o) => o['uuid'] == second.uuid ? 'a_arbitrer' : 'integree';
      await engine.sync();

      // Le serveur dit : la 1re est dans ce stock (10 − 3 = 7), la 2e est à arbitrer (pas dans le stock).
      transport.snapshotBody = withCoverage(stock: '7.000000', integrees: [first.uuid], aArbitrer: [second.uuid]);
      expect(await engine.refreshSnapshot(), isNull);
      expect(transport.lastSince, 42, reason: 'séquence de la plus ancienne vente non couverte');
      expect(await store.uncoveredStock(), {10: -2000000});

      // Même si l'horloge du terminal recule, la couverture ne dépend que des listes du serveur.
      clock = clock.subtract(const Duration(days: 2));
      transport.snapshotBody = withCoverage(stock: '7.000000', aArbitrer: [second.uuid]);
      await engine.refreshSnapshot();
      expect(await store.uncoveredStock(), {10: -2000000});
      expect(transport.lastSince, 43);
    });

    test('B-REQ-002 : une vente intégrée connue par le référentiel est alignée et couverte ; une écartée aussi', () async {
      transport.verdict = (_) => 'a_arbitrer';
      final kept = await engine.recordSale([soap(1)], [CartPayment(method: cash(), amount: 1000)], cashier());
      final dropped = await engine.recordSale([soap(2)], [CartPayment(method: cash(), amount: 2000)], cashier());
      await engine.sync();
      transport.snapshotBody = withCoverage(integrees: [kept.uuid], ecartees: [dropped.uuid]);
      await engine.refreshSnapshot();
      final history = {for (final o in await store.operations()) o.uuid: o};
      expect(history[kept.uuid]!.serverStatus, 'integree');
      expect(history[dropped.uuid]!.serverStatus, 'ecartee');
      expect(await store.uncoveredStock(), isEmpty);
      expect(engine.localArbitrationCount, 0);
    });

    test('B-REQ-004 : le sort des ventes à arbitrer est LU (/etats), jamais renvoyé', () async {
      transport.verdict = (_) => 'a_arbitrer';
      final sale = await engine.recordSale([soap(1)], [CartPayment(method: cash(), amount: 1000)], cashier());
      await engine.sync();
      final batches = transport.batches.length;

      transport.states = {sale.uuid: 'integree'};
      clock = clock.add(const Duration(minutes: 6));
      await engine.sync();
      expect(transport.batches, hasLength(batches), reason: 'aucun renvoi : il relancerait l’intégration');
      expect(transport.stateCalls.single, [sale.uuid]);
      final read = (await store.operations()).single;
      expect(read.serverStatus, 'integree');
      expect(read.serverNumber, 'V-9');
      expect(engine.localArbitrationCount, 0);

      // « inconnue » (autre terminal, purge) ne change rien.
      transport.verdict = (_) => 'a_arbitrer';
      final other = await engine.recordSale([soap(1)], [CartPayment(method: cash(), amount: 1000)], cashier());
      await engine.sync();
      clock = clock.add(const Duration(minutes: 6));
      await engine.sync();
      expect((await store.operations()).firstWhere((o) => o.uuid == other.uuid).serverStatus, 'a_arbitrer');
    });

    test('B-REQ-004 : serveur antérieur sans /etats : aucune erreur, plus de tentative', () async {
      transport.verdict = (_) => 'a_arbitrer';
      await engine.recordSale([soap(1)], [CartPayment(method: cash(), amount: 1000)], cashier());
      await engine.sync();
      transport.statesStatus = 404;
      clock = clock.add(const Duration(minutes: 6));
      expect((await engine.sync()).reachable, isTrue);
      clock = clock.add(const Duration(minutes: 6));
      await engine.sync();
      expect(transport.stateCalls, hasLength(1));
    });

    test('vente locale permanente : lue du référentiel, faux par défaut', () async {
      expect(engine.permanentLocal, isFalse);
      final body = sampleSnapshot();
      (body['reglages'] as Map)['vente_locale_permanente'] = true;
      transport.snapshotBody = body;
      await engine.refreshSnapshot();
      expect(engine.permanentLocal, isTrue);
    });

    test('STK-04 : la conversion du conditionnement est figée à l’encaissement', () async {
      final carton = engine.snapshot!.products.first.packaging(3)!;
      await engine.recordSale(
        [soap(1, packaging: carton)],
        [CartPayment(method: cash(), amount: 11000)],
        cashier(),
      );
      // Le carton passe à 24 au catalogue : la vente déjà faite reste à 12 unités.
      final body = sampleSnapshot();
      (((body['produits'] as List).first as Map)['conditionnements'] as List).first['coefficient'] = '24.000000';
      transport.snapshotBody = body;
      await engine.refreshSnapshot();
      expect((await engine.soldSinceSnapshot())[10], BigInt.from(12000000));
    });
  });
}
