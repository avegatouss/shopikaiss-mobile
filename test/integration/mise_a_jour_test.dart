@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shopikaiss_terminal/src/offline/api.dart';
import 'package:shopikaiss_terminal/src/offline/engine.dart';
import 'package:shopikaiss_terminal/src/offline/models.dart';
import 'package:shopikaiss_terminal/src/offline/money.dart';
import 'package:shopikaiss_terminal/src/offline/store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Essai de mise à jour (phase 2) : la base d'un terminal 1.1.5 (schéma 1) qui a des ventes hors ligne EN ATTENTE est
/// ouverte par cette version (migration additive vers le schéma courant), puis synchronisée contre le serveur en ligne
/// (démo, serveur de main : sans couverture B-REQ-002 ni `/etats`).
///
/// La phase 1 (code de main, hors dépôt) a écrit `caisse_hors_ligne.db` et `phase1.json` dans SK_MAJ_DOSSIER :
///
///   SK_ORIGINE=https://demo.khoga.ci SK_MAJ_DOSSIER=C:/chemin flutter test test/integration/mise_a_jour_test.dart
///
/// Enregistre ensuite UNE vente d'une unité avec cette version.
void main() {
  final origin = Platform.environment['SK_ORIGINE'];
  final dossier = Platform.environment['SK_MAJ_DOSSIER'];

  test('mise à jour 1.1.5 → courante : ventes en attente conservées, envoyées une fois, stock sans double décompte', () async {
    sqfliteFfiInit();
    void note(String line) {
      // ignore: avoid_print
      print(line);
    }

    final phase1 = jsonDecode(File(p.join(dossier!, 'phase1.json')).readAsStringSync()) as Map<String, dynamic>;
    final productId = phase1['produit_id'] as int;
    final waiting = List<String>.from(phase1['ventes'] as List);

    final store = await SqfliteOfflineStore.open(name: p.join(dossier, 'caisse_hors_ligne.db'), factory: databaseFactoryFfi);
    final transport = HttpRegisterTransport(appVersion: 'essai-mise-a-jour');
    final engine = OfflineEngine(store: store, transport: transport);
    try {
      final version = (await store.database.rawQuery('PRAGMA user_version')).single.values.single;
      note('Schéma après ouverture : $version');
      expect(version, offlineSchemaVersion);

      await engine.load(origin!);
      expect(engine.paired, isTrue, reason: 'appairage conservé');
      final pending = await store.operations(status: OperationStatus.pending);
      note('En attente après mise à jour : ${pending.map((o) => '${o.type} ${o.number ?? ''}').join(', ')}');
      for (final uuid in waiting) {
        expect(pending.map((o) => o.uuid), contains(uuid), reason: 'vente en attente conservée');
      }
      final sold = (await engine.soldSinceSnapshot())[productId];
      note('Consommation locale de « ${phase1['produit']} » avant envoi : ${sold == null ? 0 : formatMicros(sold)}');
      expect(sold, BigInt.from(3000000), reason: 'les deux ventes en attente comptent dans le stock estimé');

      final report = await engine.sync();
      note('Synchronisation : envoyées ${report.sent}, intégrées ${report.integrated}, à arbitrer ${report.pending}, '
          'refusées ${report.refused}, différées ${report.deferred} ${report.message ?? ''}');
      expect(report.reachable, isTrue);
      final sent = {for (final o in await store.operations()) o.uuid: o};
      for (final uuid in waiting) {
        note('  $uuid → ${sent[uuid]!.serverStatus} ${sent[uuid]!.serverNumber ?? ''} ${sent[uuid]!.message ?? ''}');
        expect(sent[uuid]!.serverStatus, 'integree');
      }

      expect(await engine.refreshSnapshot(), isNull);
      final after = engine.snapshot!.products.firstWhere((x) => x.id == productId);
      final left = (await engine.soldSinceSnapshot())[productId];
      note('Stock serveur : avant ${formatMicros(BigInt.parse(phase1['stock_avant'] as String))}, après ${formatMicros(after.stockMicros)} ; '
          'consommation locale restante ${left == null ? 0 : formatMicros(left)}');
      expect(left, anyOf(isNull, BigInt.zero), reason: 'ventes intégrées couvertes : aucun double décompte');

      // Vente faite avec cette version, puis envoi : même chemin que sur le terrain.
      final s = engine.snapshot!;
      final operator = s.operators.firstWhere((o) => o.id == phase1['operateur_id'], orElse: () => s.operators.first);
      final cash = s.methods.firstWhere((m) => m.isCash);
      final line = CartLine(product: after, quantity: BigInt.from(1000000));
      final payable = saleTotals([line.total], s.store.vatRate, s.store.vatIncluded).payable;
      final sale = await engine.recordSale([line], [CartPayment(method: cash, amount: payable)], operator, draftUuid: 'maj-${DateTime.now().microsecondsSinceEpoch}');
      final second = await engine.sync();
      final mine = (await store.operations()).firstWhere((o) => o.uuid == sale.uuid);
      note('Vente de la nouvelle version ${sale.number} → ${mine.serverStatus} ${mine.serverNumber ?? ''} (envoyées ${second.sent})');
      expect(mine.serverStatus, 'integree');
      expect(await engine.refreshSnapshot(), isNull);
      final last = engine.snapshot!.products.firstWhere((x) => x.id == productId);
      note('Stock serveur final ${formatMicros(last.stockMicros)} ; en attente ${(await store.counts()).pending}');
      expect(last.stockMicros, after.stockMicros - BigInt.from(1000000));
      expect((await engine.soldSinceSnapshot())[productId], anyOf(isNull, BigInt.zero));
    } finally {
      await store.close();
    }
  }, skip: origin == null || dossier == null ? 'SK_ORIGINE / SK_MAJ_DOSSIER absents' : false, timeout: const Timeout(Duration(minutes: 3)));
}
