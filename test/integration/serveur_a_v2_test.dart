@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shopikaiss_terminal/src/offline/store.dart';
import 'package:shopikaiss_terminal/src/sync_v2/canonical_json.dart';
import 'package:shopikaiss_terminal/src/sync_v2/contract_schemas.dart';
import 'package:shopikaiss_terminal/src/sync_v2/decimal6.dart';
import 'package:shopikaiss_terminal/src/sync_v2/schema_validator.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_client.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_sale.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_store.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_sync.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_transport.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

/// Essai du client v2 (contrat 2.0.0-l1) contre le serveur de la session A (base ISOLÉE, jamais la production).
///
///   SK_ORIGINE=http://127.0.0.1:8130 SK_V2_CODE=XXXX-XXXX flutter test test/integration/serveur_a_v2_test.dart
///
/// Facultatifs : SK_TVA (taux, `18.000000`) et SK_TVA_INCLUSE (1/0), pour un serveur 2.0.0 qui ne publie pas encore
/// l'entité `boutique` (B-REQ-005, contrat 2.0.1). Attention : l'appairage v2 révoque l'application v1 appairée sur le même terminal. Chaque exécution
/// enregistre UNE vraie vente d'une unité sur le serveur d'intégration.
/// Sondage du journal au rythme conseillé par `/etat` jusqu'à la couverture des mouvements de [opUuid].
Future<void> waitCoverage(V2Store store, V2Sync sync, String opUuid, void Function(String) note) async {
  final state = jsonDecode((await store.read(V2Keys.serverState))!) as Map;
  final every = Duration(seconds: (state['delais'] as Map)['changements_secondes'] as int);
  for (var i = 0; i < 6 && (await store.movements(opUuid)).any((m) => m['couvert_le'] == null); i++) {
    await Future<void>.delayed(every);
    final report = await sync.run();
    note('sondage ${i + 1} : $report ; curseur ${await store.read(V2Keys.cursor)}');
  }
}

void main() {
  final origin = Platform.environment['SK_ORIGINE'] ?? 'http://127.0.0.1:8130';
  final code = Platform.environment['SK_V2_CODE'];
  // Reprise d'un essai interrompu : dossier de sa base (déjà appairée) et UUID de sa vente ; aucun nouveau code ni vente.
  final resume = Platform.environment['SK_V2_REPRISE'];
  final resumeOp = Platform.environment['SK_V2_VENTE'];
  final envVat = V2Vat(rate: Platform.environment['SK_TVA'] ?? '0.000000', included: Platform.environment['SK_TVA_INCLUSE'] != '0');

  test('client v2 : appairage, instantané, vente, renvoi identique, états, couverture par le journal, accusé', () async {
    sqfliteFfiInit();
    final dir = Directory.systemTemp.createTempSync('integration_b_v2_');
    void note(String line) {
      // ignore: avoid_print
      print(line);
    }

    final base = await SqfliteOfflineStore.open(name: p.join(dir.path, 'caisse.db'), factory: databaseFactoryFfi);
    final validator = SchemaValidator((file) => contractV2Schemas[file]!);
    final store = V2Store(base.database, validator);
    final client = CaisseV2Client(apiBase: '$origin/api/caisse/v2', transport: HttpV2Transport(), appVersion: 'integration-B-v2', localSchema: offlineSchemaVersion);
    final sync = V2Sync(client, store);
    const uuid = Uuid();

    final pairing = await sync.pair(code!, platform: 'android', model: 'Essai B v2', newUuid: uuid.v4);
    note('appairage : époque ${pairing.epoch}, terminal ${pairing.device['terminal_nom']} (${pairing.terminalUuid}), '
        'dernière séquence ${pairing.lastSequence}, capacités ${pairing.capabilities}');

    var report = await sync.run();
    note('1re synchronisation : $report ; entités ${await store.counts()} ; curseur ${await store.read(V2Keys.cursor)}');
    expect(report.complete, isTrue, reason: '$report ${report.failure}');
    final state = jsonDecode((await store.read(V2Keys.serverState))!) as Map;
    note('autorisation : ${state['autorisation']} ; restreintes : ${[for (final f in state['fonctions_restreintes'] as List) f['fonction']]}');

    final products = await store.entities('produit');
    final stocks = await store.estimatedStock();
    final productUuid = products.entries
        .where((e) => e.value['vente_locale'] == true && e.value['stock_illimite'] != true && (e.value['prix'] as int) > 0 && (stocks[e.key] ?? 0) >= Decimal6.scale)
        .map((e) => e.key)
        .first;
    final before = stocks[productUuid]!;
    final operator = (await store.entities('operateur')).values.firstWhere((o) => (o['droits'] as List).contains('vente'));
    final session = (await store.entities('session'))['session:${pairing.terminalUuid}'];
    note('article ${products[productUuid]!['nom']} (${products[productUuid]!['prix']} F), stock ${Decimal6.format(before)} ; '
        'caissier ${operator['nom']} (${operator['operateur_id']}) ; session $session');

    // TVA publiée par le serveur 2.0.1 (entité boutique) ; serveur 2.0.0 : SK_TVA / SK_TVA_INCLUSE.
    final shopVat = await store.shopVat();
    final vat = shopVat ?? envVat;
    note('TVA : ${vat.rate} ${vat.included ? 'incluse' : 'ajoutée'} (${shopVat == null ? 'environnement, serveur 2.0.0' : 'entité boutique 2.0.1'})');
    final builder = V2SaleBuilder(products: products, packagings: await store.entities('conditionnement'), revisions: const {}, newUuid: uuid.v4);
    final cart = [V2CartLine(productUuid: productUuid, quantityMicros: Decimal6.scale)];
    final payable = builder.payable(cart, vat: vat);
    final opUuid = uuid.v4();
    final draft = uuid.v4();
    final epoch = int.parse((await store.read(V2Keys.epoch))!);
    final cursor = await store.read(V2Keys.cursor);
    final policies = await store.read(V2Keys.policiesVersion) ?? '0';
    final op = await store.recordOperation(
      (seq) => v2Operation(
        uuid: opUuid,
        type: 'vente',
        deviceUuid: pairing.deviceUuid,
        epoch: epoch,
        sequence: seq,
        createdAt: DateTime.now(),
        operatorId: operator['operateur_id'] as String,
        policiesVersion: policies,
        catalogueCursor: cursor,
        content: builder.content(
          numberLocal: 'HL2-$epoch-${seq.toString().padLeft(6, '0')}',
          draftUuid: draft,
          sessionUuid: (session?['session_uuid'] as String?) ?? uuid.v4(),
          cart: cart,
          payments: [V2Payment(method: 'especes', amount: payable, received: payable)],
          vat: vat,
        ),
      ),
      draftUuid: draft,
    );
    note('vente locale $opUuid séquence ${op['sequence']} : $payable F ; stock estimé ${Decimal6.format((await store.estimatedStock())[productUuid]!)}');
    expect((await store.estimatedStock())[productUuid], before - Decimal6.scale);

    report = await sync.run();
    final local = (await store.operation(opUuid))!;
    note('2e synchronisation : $report ; état ${local['etat']} v${local['version_etat']}, numéro ${local['numero_serveur']}, '
        'raison ${local['raison']}, couverture ${local['couverture_curseur']}');
    expect(local['etat'], anyOf('integree', 'a_arbitrer', 'recue'), reason: 'raison : ${local['raison']}');

    // Renvoi identique (réponse supposée perdue) : même état, aucun retraitement.
    final replay = await client.submit([Map<String, dynamic>.from(local['operation'] as Map)]);
    note('renvoi identique : ${replay.single['etat']} v${replay.single['version_etat']}');
    expect(replay.single['etat'], local['etat']);
    expect(replay.single['version_etat'], local['version_etat']);
    expect(CanonicalJson.operationFingerprint(local['operation'] as Map<String, dynamic>), op['empreinte']);

    final states = await client.operationStates([opUuid, uuid.v4()]);
    note('états : ${[for (final s in states) s['etat']]}');
    expect(states.last['etat'], 'inconnue');

    // Couverture : la projection couvrante arrive par le journal ; jamais de double décompte. Le serveur ne rebalaye
    // son état qu'au plus toutes les 5 s : sondage au rythme conseillé (`delais.changements_secondes`), une minute au plus.
    await waitCoverage(store, sync, opUuid, note);
    final covered = (await store.movements(opUuid)).every((m) => m['couvert_le'] != null);
    final projection = (await store.entities('stock.projection'))[productUuid]!['quantite'];
    note('couverture : ${covered ? 'mouvement couvert' : 'pas encore couvert'} ; projection $projection ; '
        'stock estimé ${Decimal6.format((await store.estimatedStock())[productUuid]!)} ; file ${await store.queueStats()}');
    if (local['etat'] == 'integree') {
      expect(covered, isTrue);
      expect((await store.estimatedStock())[productUuid], Decimal6.parseSigned(projection as String));
      expect(Decimal6.parseSigned(projection), before - Decimal6.scale);
    }
    await base.close();
    dir.deleteSync(recursive: true);
  }, skip: code == null ? 'SK_V2_CODE absent : essai contre le serveur d’intégration de A non lancé.' : false, timeout: const Timeout(Duration(minutes: 3)));

  test('reprise : couverture par le journal d’une vente intégrée lors d’un essai précédent', () async {
    sqfliteFfiInit();
    void note(String line) {
      // ignore: avoid_print
      print(line);
    }

    final base = await SqfliteOfflineStore.open(name: p.join(resume!, 'caisse.db'), factory: databaseFactoryFfi);
    final store = V2Store(base.database, SchemaValidator((file) => contractV2Schemas[file]!));
    final client = CaisseV2Client(apiBase: '$origin/api/caisse/v2', transport: HttpV2Transport(), appVersion: 'integration-B-v2', localSchema: offlineSchemaVersion);
    final sync = V2Sync(client, store);
    final local = (await store.operation(resumeOp!))!;
    final product = ((local['operation'] as Map)['contenu']['mouvements'] as List).single['produit_uuid'] as String;
    note('reprise : vente ${local['numero_serveur']} (${local['etat']}), curseur ${await store.read(V2Keys.cursor)}, '
        'stock estimé ${Decimal6.format((await store.estimatedStock())[product]!)}');
    await sync.run();
    await waitCoverage(store, sync, resumeOp, note);
    final projection = (await store.entities('stock.projection'))[product]!['quantite'] as String;
    final estimated = (await store.estimatedStock())[product]!;
    note('couverture : ${(await store.movements(resumeOp)).single['couvert_le'] != null ? 'mouvement couvert' : 'NON couvert'} ; '
        'projection $projection ; stock estimé ${Decimal6.format(estimated)}');
    expect((await store.movements(resumeOp)).single['couvert_le'], isNotNull);
    expect(estimated, Decimal6.parseSigned(projection), reason: 'aucun double décompte');
    await base.close();
  }, skip: resume == null || resumeOp == null ? 'SK_V2_REPRISE / SK_V2_VENTE absents.' : false, timeout: const Timeout(Duration(minutes: 3)));
}
