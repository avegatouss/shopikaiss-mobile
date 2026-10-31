@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shopikaiss_terminal/src/offline/store.dart';
import 'package:shopikaiss_terminal/src/register/register_adapter.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_engine.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_transport.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

/// Essai réel du contrat 2.1 contre la démo (jamais la production), par phases sur une base conservée :
///
///   SK_ORIGINE=https://demo.khoga.ci SK_BASE=dossier SK_PHASE=phase SK_OPERATEUR=3 SK_PIN=… \
///     flutter test test/integration/essai_21_test.dart
///
/// Phases : `appairage` (SK_CODE, instantané 2.0, relevé sans vente) ; `vente_declaree` (moitié espèces, moitié Wave
/// avec référence) ; `contrat21` (annonce contrat.2_1, nouvel instantané, relevé) ; `vente21` (remise %, remise globale,
/// arrondi espèces ; SK_REMISE_LIGNE et SK_REMISE_GLOBALE en %) ; `catalogue` (badges et images, sans vente) ; `etat` (synchronisation et sort des ventes).
void main() {
  final env = Platform.environment;
  if (env['SK_BASE'] == null) {
    test('essai réel 2.1', () {}, skip: 'SK_BASE absent : recette démo non demandée.');
    return;
  }
  final origin = env['SK_ORIGINE'] ?? 'https://demo.khoga.ci';
  final phase = env['SK_PHASE'] ?? 'etat';
  final dir = env['SK_BASE'] ?? (throw StateError('SK_BASE requis (dossier de la base conservée).'));
  void note(String line) {
    // ignore: avoid_print
    print(line);
  }

  test('essai réel 2.1 — phase $phase', () async {
    sqfliteFfiInit();
    Directory(dir).createSync(recursive: true);
    final store = await SqfliteOfflineStore.open(name: p.join(dir, 'caisse.db'), factory: databaseFactoryFfi);
    final engine = V2Engine.onStore(store, transport: HttpV2Transport(), appVersion: 'essai-B-2.1', platform: 'windows',
        declaredPayments: true, contract21: phase == 'contrat21' || phase == 'vente21' || phase == 'catalogue' || env['SK_21'] == '1',
        imageDirectory: p.join(dir, 'images'));
    await engine.load(origin);
    if (phase == 'appairage') {
      expect(await engine.pair(env['SK_CODE']!, model: 'Essai B (poste de dev)', appVersion: 'essai-B-2.1'), isNull);
    }
    final report = await engine.sync();
    note('synchro : envoyées ${report.sent}, intégrées ${report.integrated}, à arbitrer ${report.pending}, refusées ${report.refused}, '
        'joignable ${report.reachable} ${report.message ?? ''}');
    expect(engine.blockReason, isNull, reason: engine.blockReason);

    final s = engine.snapshot!;
    final adapter = LocalRegisterAdapter(engine, newUuid: () => const Uuid().v4());
    await adapter.start();
    final operatorId = int.parse(env['SK_OPERATEUR'] ?? '3');
    final operator = s.operatorById(operatorId)!;
    note('boutique ${s.store.name} · TVA ${s.store.vatRate} ${s.store.vatIncluded ? 'incluse' : 'ajoutée'} · session ${engine.sessionOpen}');
    note('remise ligne ${s.rules.maxLineDiscountPercent} % · remise globale ${s.rules.maxGlobalDiscountPercent} % · '
        'droit remise ${engine.hasRight(operator, 'remise')} · plafond rôle ligne/1000 F ${engine.maxLineDiscountFor(operator, 1000)} · '
        'arrondi espèces ${engine.cashRounding} · extras 2.1 ${engine.saleExtrasSupported} · % ${engine.percentRounding}');
    note('moyens : ${[for (final m in s.methods) '${m.code} (${m.referenceMode})'].join(', ')}');
    note('catégories : ${s.categories.take(8).join(', ')}');
    final sellable = s.products.where((x) => x.unlimitedStock || x.signedStock > BigInt.from(5000000)).toList();
    note('produits vendables : ${[for (final x in sellable.take(6)) '${x.id} ${x.name} ${x.price} F'].join(' | ')}');

    if (phase == 'vente_declaree' || phase == 'vente21') {
      await adapter.execute('login', {'operator_id': operatorId, 'pin': env['SK_PIN'] ?? ''}, null);
      await adapter.execute('clear', {}, null);
      final product = sellable.firstWhere((x) => x.packagings.isEmpty && x.price >= 500);
      await adapter.execute('addProduct', {'product_id': product.id}, null);
      var view = await adapter.execute('addProduct', {'product_id': product.id}, null);
      final lineId = (view['lines'] as List).single['id'] as String;
      if (phase == 'vente21') {
        final lineDiscount = env['SK_REMISE_LIGNE'];
        if (lineDiscount != null) view = await adapter.execute('setLineDiscount', {'line_id': lineId, 'percent': lineDiscount}, null);
        final global = env['SK_REMISE_GLOBALE'];
        if (global != null) view = await adapter.execute('setGlobalDiscount', {'percent': global}, null);
        view = await adapter.execute('setNote', {'text': 'Essai B contrat 2.1'}, null);
      }
      note('panier : ${(view['lines'] as List).single['name']} × 2 · totaux ${view['totals']}');
      final payable = (await adapter.execute('preparePayment', {}, null))['payable'] as int;
      if (phase == 'vente_declaree') {
        final cash = payable ~/ 2;
        view = await adapter.execute('setPayments', {
          'payments': [
            {'method': 'especes', 'amount': cash, 'received': cash},
            {'method': 'wave', 'amount': payable - cash, 'reference': 'ESSAI-B-${DateTime.now().millisecondsSinceEpoch}'},
          ],
        }, null);
      } else {
        view = await adapter.execute('setPayment', {'method': 'especes', 'received': ((payable ~/ 1000) + 1) * 1000}, null);
      }
      note('paiement : ${view['payment']} · paiements ${view['payments']}');
      final operationId = const Uuid().v4();
      final sale = await adapter.execute('commitSale', {}, operationId);
      note('vente locale ${sale['number']} (${sale['operation_id']}) total ${sale['total']}');
      final after = await engine.sync();
      note('synchro : envoyées ${after.sent}, intégrées ${after.integrated}, à arbitrer ${after.pending}, refusées ${after.refused}');
      final status = await engine.saleStatus(operationId);
      note('sort : ${status!.serverStatus} · numéro serveur ${status.serverNumber} · ${status.message ?? ''}');
    }
    if (phase == 'catalogue') {
      final day = DateTime.now().toIso8601String().substring(0, 10);
      note('badge Nouveau : ${engine.newBadgeDays} jours · produits ${s.products.length}');
      note('favoris ${s.products.where((x) => x.favorite).length} · promotions ${s.products.where((x) => x.promotions.isNotEmpty).length}, '
          'actives ${s.products.where((x) => x.promotionLabel(day) != null).length} · nouveaux '
          '${s.products.where((x) => x.isNew(engine.newBadgeDays, DateTime.now())).length} · seuil ${s.products.where((x) => x.alertThreshold != null).length} · '
          'images ${s.products.where((x) => x.image != null).length}');
      note('téléchargées : ${await engine.downloadImages()}, puis ${await engine.downloadImages()}');
      note('en cache : ${s.products.where((x) => x.image != null && engine.imagePath(x.image!) != null).length}');
    }
    if (phase == 'etat') {
      for (final o in (await engine.history()).reversed.take(5)) {
        note('${o.number} → ${o.serverStatus} ${o.serverNumber ?? ''} ${o.message ?? ''}');
      }
    }
    await adapter.close();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
