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

/// Essai réel des lots 2.1 contre la démo (jamais la production), sur une base déjà appairée :
///
///   SK_ORIGINE=https://demo.khoga.ci SK_BASE=dossier SK_PHASE=phase SK_OPERATEUR=3 SK_PIN=… \
///     flutter test test/integration/essai_parite_test.dart
///
/// Phases : `parcours` (client créé, vente citée, panier partagé publié, repris et supprimé, retour si la boutique les
/// ouvre) ; `retour` (SK_VENTE) ; `fusion` (SK_TELEPHONE, déjà saisi côté web) ; `paniers` (reprend et supprime les paniers Essai B) ; `cloture` (comptage à l'aveugle de SK_ESPECES francs, ferme la session du terminal).
void main() {
  final env = Platform.environment;
  final origin = env['SK_ORIGINE'] ?? 'https://demo.khoga.ci';
  final phase = env['SK_PHASE'] ?? 'parcours';
  final dir = env['SK_BASE'] ?? (throw StateError('SK_BASE requis (dossier de la base appairée).'));
  void note(String line) {
    // ignore: avoid_print
    print(line);
  }

  test('essai réel parité — phase $phase', () async {
    sqfliteFfiInit();
    final store = await SqfliteOfflineStore.open(name: p.join(dir, 'caisse.db'), factory: databaseFactoryFfi);
    final engine = V2Engine.onStore(store, transport: HttpV2Transport(), appVersion: 'essai-B-parite', platform: 'windows',
        declaredPayments: true, contract21: true, imageDirectory: p.join(dir, 'images'));
    await engine.load(origin);
    final adapter = LocalRegisterAdapter(engine, newUuid: () => const Uuid().v4());
    await adapter.start();
    Future<Map<String, dynamic>> run(String command, [Map<String, dynamic> args = const {}, String? operation]) =>
        adapter.execute(command, args, operation);

    /// Une étape refusée est notée et n'arrête pas les suivantes : l'essai sert à relever chaque sort.
    Future<Map<String, dynamic>?> step(String label, String command, [Map<String, dynamic> args = const {}, String? operation]) async {
      try {
        final result = await run(command, args, operation);
        note('OK $label');
        return result;
      } on AdapterFailure catch (f) {
        note('REFUS $label : ${f.code} — ${f.message}');
        return null;
      }
    }

    Future<void> sync(String label) async {
      final r = await engine.sync();
      note('synchro $label : envoyées ${r.sent}, intégrées ${r.integrated}, à arbitrer ${r.pending}, refusées ${r.refused} ${r.message ?? ''}');
    }

    // Fusion : le terminal ne doit pas lire la fiche créée sur le web avant d'envoyer la sienne.
    if (phase != 'fusion') {
      await sync('initiale');
      expect(engine.blockReason, isNull, reason: engine.blockReason);
    }
    final status = await run('status');
    final capabilities = status['capabilities'] as Map;
    note('capacités : ${[for (final k in ['customer', 'customer_create', 'shared_carts', 'returns', 'close_session', 'image_schedule']) '$k=${(capabilities[k] as Map)['allowed']}'].join(' ')}');
    note('session ouverte : ${engine.sessionOpen} · clients ${(await engine.searchCustomers('')).length}');
    await run('login', {'operator_id': int.parse(env['SK_OPERATEUR'] ?? '3'), 'pin': env['SK_PIN'] ?? ''});
    await run('clear');

    final s = engine.snapshot!;
    final product = s.products.firstWhere((x) => x.packagings.isEmpty && !x.unlimitedStock && x.signedStock > BigInt.from(5000000) && x.price >= 500);
    note('produit : ${product.name}, ${product.price} F, stock ${product.signedStock}');

    if (phase == 'parcours') {
      // Client créé hors ligne puis intégré.
      final stamp = DateTime.now().millisecondsSinceEpoch.toString();
      final phone = '07${stamp.substring(stamp.length - 8)}';
      final customer = await step('création client', 'createCustomer', {'name': 'Essai B $stamp', 'phone': phone}, const Uuid().v4());
      note('client : ${customer?['customer'] ?? customer}');
      await sync('après client');
      note('client retrouvé : ${[for (final c in await engine.searchCustomers(phone)) '${c.name} attente=${c.pending}'].join(', ')}');

      // Vente citant le client, alerte de stock relevée sur la vue.
      final found = (await engine.searchCustomers(phone)).firstOrNull;
      await run('addProduct', {'product_id': product.id});
      if (found != null) await step('client sur la vente', 'setCustomer', {'uuid': found.uuid, 'name': found.name});
      var view = await run('view');
      note('ligne : ${{for (final k in ['stock_after_label', 'stock_alert']) k: ((view['lines'] as List).single as Map)[k]}}');
      final payable = (await run('preparePayment'))['payable'] as int;
      await run('setPayment', {'method': 'especes', 'received': payable + 1000});
      final saleId = const Uuid().v4();
      final sale = await step('vente avec client', 'commitSale', {}, saleId);
      note('vente ${sale?['number']} total ${sale?['total']}');
      await sync('après vente');
      final state = await engine.saleStatus(saleId);
      note('sort : ${state?.serverStatus} · ${state?.serverNumber} · ${state?.message ?? ''}');

      // Panier partagé : publié, listé, repris, remis en attente, supprimé.
      await run('addProduct', {'product_id': product.id});
      await step('mise en attente', 'suspendDraft', {'label': 'Essai B $stamp'});
      await sync('après mise en attente');
      var drafts = await run('drafts');
      final shared = [for (final d in drafts['shared'] as List) d as Map].where((d) => d['label'] == 'Essai B $stamp').toList();
      note('paniers : locaux ${(drafts['items'] as List).length}, partagés ${(drafts['shared'] as List).length}, celui-ci ${shared.length}');
      if (shared.isNotEmpty) {
        final id = shared.single['shared_id'];
        final resumed = await step('reprise du panier', 'resumeShared', {'shared_id': id});
        note('lignes reprises : ${(resumed?['lines'] as List?)?.length}');
        await step('vidage du panier repris', 'clear');
        await sync('après reprise');
        await step('suppression du panier', 'deleteShared', {'shared_id': id});
        await sync('après suppression');
        drafts = await run('drafts');
        note('encore listé : ${[for (final d in drafts['shared'] as List) (d as Map)['label']].contains('Essai B $stamp')}');
      }

      // Retour : ouvert seulement si la boutique l'a réglé ; sinon relever le refus.
      final preview = await step('vente retournable', 'returnableSale', {'sale_id': saleId});
      if (preview != null) {
        final line = (preview['lines'] as List).first as Map;
        final lines = [{'line_id': line['line_id'], 'quantity': '1'}];
        note('aperçu : ${await step('aperçu du retour', 'previewReturn', {'sale_id': saleId, 'lines': lines})}');
        final done = await step('retour', 'commitReturn', {'sale_id': saleId, 'lines': lines, 'reason': 'Essai B'}, const Uuid().v4());
        note('retour : $done');
        await sync('après retour');
      }
    }

    if (phase == 'retour') {
      final saleId = env['SK_VENTE']!;
      final closure = await engine.lastClosure();
      note('dernière clôture : ${closure?.serverStatus} · ${closure?.message ?? ''} · ${closure?.content['z'] ?? closure?.content.keys.toList()}');
      if (!engine.sessionOpen) {
        await step('ouverture de session', 'openSession', {'float': 10000});
        await sync('après ouverture');
      }
      final preview = await step('vente retournable', 'returnableSale', {'sale_id': saleId});
      note('lignes : ${preview?['lines']}');
      if (preview != null) {
        final line = (preview['lines'] as List).first as Map;
        final lines = [{'line_id': line['line_id'], 'quantity': '1'}];
        note('aperçu : ${await step('aperçu du retour', 'previewReturn', {'sale_id': saleId, 'lines': lines})}');
        final done = await step('retour', 'commitReturn', {'sale_id': saleId, 'lines': lines, 'reason': 'Essai B retour'}, const Uuid().v4());
        note('retour : $done');
        await sync('après retour');
      }
      for (final o in (await engine.history()).reversed.take(3)) {
        note('${o.number} ${o.type} → ${o.serverStatus} ${o.serverNumber ?? ''} ${o.message ?? ''}');
      }
    }

    if (phase == 'fusion') {
      final phone = env['SK_TELEPHONE']!;
      final created = await step('création client', 'createCustomer', {'name': 'Essai B fusion', 'phone': phone}, const Uuid().v4());
      note('client local : ${created?['customer'] ?? created}');
      await sync('envoi');
      await Future<void>.delayed(const Duration(seconds: 7));
      await sync('journal');
      note('clients trouvés : ${[for (final c in await engine.searchCustomers(phone)) '${c.uuid} ${c.name} attente=${c.pending}'].join(', ')}');
    }

    if (phase == 'paniers') {
      var drafts = await run('drafts');
      note('partagés : ${drafts['shared']}');
      for (final d in [for (final x in drafts['items'] as List) x as Map]) {
        note('local supprimé : ${await step('suppression du panier local', 'deleteDraft', {'draft_id': d['draft_id']}) != null}');
        await sync('après suppression locale');
      }
      drafts = await run('drafts');
      for (final d in [for (final x in drafts['shared'] as List) x as Map].where((x) => '${x['label']}'.startsWith(env['SK_LIBELLE'] ?? 'Essai B'))) {
        final id = d['shared_id'];
        final resumed = await step('reprise du panier', 'resumeShared', {'shared_id': id});
        note('lignes reprises : ${(resumed?['lines'] as List?)?.length}');
        await sync('après reprise');
        await step('vidage du panier repris', 'clear');
        final deleted = await step('suppression du panier', 'deleteShared', {'shared_id': id});
        note('suppression : ${deleted != null}');
        await sync('après suppression');
      }
      drafts = await run('drafts');
      note('partagés restants : ${drafts['shared']}');
    }

    if (phase == 'cloture') {
      final closed = await step('clôture', 'closeSession', {'cash': int.parse(env['SK_ESPECES'] ?? '0'), 'comment': 'Essai B clôture', 'counts': <Object>[]}, const Uuid().v4());
      note('réponse : ${closed == null ? null : closed['last_closure'] ?? closed['status'] ?? 'reçue'}');
      await sync('après clôture');
      note('session ouverte : ${engine.sessionOpen}');
      for (final o in (await engine.history()).reversed.take(3)) {
        note('${o.number} ${o.type} → ${o.serverStatus} ${o.serverNumber ?? ''} ${o.message ?? ''}');
      }
    }
    await adapter.close();
    await store.close();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
