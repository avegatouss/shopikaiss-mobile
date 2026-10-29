@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shopikaiss_terminal/src/offline/api.dart';
import 'package:shopikaiss_terminal/src/offline/engine.dart';
import 'package:shopikaiss_terminal/src/offline/models.dart';
import 'package:shopikaiss_terminal/src/offline/money.dart';
import 'package:shopikaiss_terminal/src/offline/store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Essai d'intégration du palier « vente locale v1 » contre le serveur de la session A (base ISOLÉE, jamais la production).
///
/// Vrai moteur, vrai transport HTTP, vraie base SQLite. Ne s'exécute que si un code d'appairage est fourni :
///
///   SK_ORIGINE=http://127.0.0.1:8130 SK_CODE=XXXX-XXXX SK_PERMANENT=1 flutter test test/integration/serveur_a_test.dart
///
/// SK_PERMANENT : 1 pour le terminal pilote (vente locale permanente), 0 pour un terminal au comportement par défaut.
/// Chaque exécution enregistre UNE vraie vente d'une unité sur le serveur d'intégration.
void main() {
  final origin = Platform.environment['SK_ORIGINE'] ?? 'http://127.0.0.1:8130';
  final code = Platform.environment['SK_CODE'];
  final permanent = Platform.environment['SK_PERMANENT'] == '1';

  test('palier vente locale v1 : appairage, vente, accusé, couverture exacte, renvoi identique, lecture d’état', () async {
    sqfliteFfiInit();
    final dir = Directory.systemTemp.createTempSync('integration_b_');
    final log = StringBuffer();
    void note(String line) {
      log.writeln(line);
      // ignore: avoid_print
      print(line);
    }

    final store = await SqfliteOfflineStore.open(name: p.join(dir.path, 'caisse.db'), factory: databaseFactoryFfi);
    final transport = HttpRegisterTransport(appVersion: 'integration-B');
    final engine = OfflineEngine(store: store, transport: transport);
    try {
      await engine.load(origin);
      expect(await engine.pair(code!, model: 'Essai B (poste de développement)', appVersion: 'integration-B'), isNull, reason: 'appairage');
      final snapshot = engine.snapshot!;
      note('Appairé : ${engine.deviceName} ; terminal ${snapshot.terminal.name} ; préfixe ${snapshot.terminal.ticketPrefix}');
      note('vente_locale_permanente = ${snapshot.rules.permanentLocal} ; couverture_stock présente = ${snapshot.coverage != null}');
      expect(engine.permanentLocal, permanent, reason: 'réglage du terminal');
      expect(snapshot.coverage, isNotNull, reason: 'serveur B-REQ-002');
      expect(engine.blockReason, isNull, reason: 'vente locale possible');

      final operator = snapshot.operators.first;
      if (!engine.sessionOpen) {
        await engine.openSession(0, operator);
        note('Session ouverte hors ligne (fond 0).');
      }
      final cash = snapshot.methods.firstWhere((m) => m.isCash);
      final product = snapshot.products.firstWhere(
        (x) => !x.unlimitedStock && !x.negativeStock && x.stockMicros >= BigInt.from(1000000) && x.price > 0 && x.packagings.isEmpty,
      );
      final before = product.stockMicros;
      final line = CartLine(product: product, quantity: BigInt.from(1000000));
      final payable = saleTotals([line.total], snapshot.store.vatRate, snapshot.store.vatIncluded).payable;

      final draft = 'integration-${DateTime.now().microsecondsSinceEpoch}';
      final sale = await engine.recordSale([line], [CartPayment(method: cash, amount: payable)], operator, draftUuid: draft);
      note('Vente locale ${sale.number} (${sale.uuid}) : 1 × « ${product.name} » = $payable F ; stock serveur avant ${formatMicros(before)}');
      expect((await engine.soldSinceSnapshot())[product.id], BigInt.from(1000000));

      final report = await engine.sync();
      final sent = (await store.operations()).firstWhere((o) => o.uuid == sale.uuid);
      note('Accusé : ${sent.serverStatus} ${sent.serverNumber ?? ''} ${sent.message ?? ''} (envoyées ${report.sent})');
      expect(report.reachable, isTrue);
      expect(sent.serverStatus, isIn(['integree', 'a_arbitrer']));
      expect((await engine.soldSinceSnapshot())[product.id], BigInt.from(1000000), reason: 'l’accusé seul ne couvre rien');

      expect(await engine.refreshSnapshot(), isNull);
      final coverage = engine.snapshot!.coverage!;
      final after = engine.snapshot!.products.firstWhere((x) => x.id == product.id);
      final uncovered = (await engine.soldSinceSnapshot())[product.id];
      note('Référentiel : depuis_sequence ${coverage.sinceSequence} ; integrees ${coverage.integrated.contains(sale.uuid)} ; '
          'a_arbitrer ${coverage.arbitration.contains(sale.uuid)} ; stock serveur après ${after.negativeStock ? '-' : ''}${formatMicros(after.stockMicros)} ; '
          'consommation locale restante ${uncovered == null ? 0 : formatMicros(uncovered)}');
      if (sent.serverStatus == 'integree') {
        expect(coverage.integrated, contains(sale.uuid));
        expect(uncovered, anyOf(isNull, BigInt.zero), reason: 'couverture exacte : la vente est dans le stock reçu');
        expect(after.stockMicros, before - BigInt.from(1000000), reason: 'stock estimé = stock serveur, sans double déduction');
      } else {
        expect(coverage.arbitration, contains(sale.uuid));
        expect(uncovered, BigInt.from(1000000), reason: 'à arbitrer : consommation gardée');
      }

      // Renvoi identique (réponse perdue simulée) : même état, aucun doublon.
      final again = await transport.synchronize(engine.apiBase!, (await store.read(StoreKeys.token))!, [sent.toPayload()]);
      final result = Map<String, dynamic>.from((again.body['resultats'] as List).single as Map);
      note('Renvoi identique : ${result['statut']} ${result['numero'] ?? ''}');
      expect(result['statut'], sent.serverStatus);
      expect(result['numero'], sent.serverNumber);

      // Lecture d'état sans effet de bord (B-REQ-004).
      final states = await transport.operationStates(engine.apiBase!, (await store.read(StoreKeys.token))!, [sale.uuid]);
      final state = Map<String, dynamic>.from((states.body['etats'] as List).single as Map);
      note('POST /etats : ${state['statut']} ${state['numero'] ?? ''}');
      expect(state['statut'], sent.serverStatus);

      // Second encaissement du même panier (double appui) : refusé localement, aucune deuxième vente.
      await expectLater(
        engine.recordSale([line], [CartPayment(method: cash, amount: payable)], operator, draftUuid: draft),
        throwsA(isA<OfflineRefusal>()),
      );
      note('Second encaissement du même panier : refusé localement.');
      await engine.sync();
      note('Bilan : ${(await store.counts()).pending} en attente après synchronisation.');
    } finally {
      File(p.join(Directory.systemTemp.path, 'integration_b_${permanent ? 'pilote' : 'defaut'}.log')).writeAsStringSync(log.toString());
      await store.close();
      dir.deleteSync(recursive: true);
    }
  }, skip: code == null ? 'SK_CODE absent : essai contre le serveur d’intégration de la session A non demandé' : false, timeout: const Timeout(Duration(minutes: 3)));
}
