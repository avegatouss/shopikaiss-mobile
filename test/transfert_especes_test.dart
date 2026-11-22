import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shopikaiss_terminal/src/offline/engine.dart';
import 'package:shopikaiss_terminal/src/offline/models.dart';
import 'package:shopikaiss_terminal/src/offline/store.dart';
import 'package:shopikaiss_terminal/src/offline/x_z_report.dart';
import 'package:shopikaiss_terminal/src/register/register_adapter.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_v2_server.dart';
import 'sync_v2_engine_test.dart' show serve21;

/// Transfert de fin de journée des mobile money vers les espèces (lot 16, note A LOT-16-TRANSFERT-ESPECES-POUR-B-ET-C.md).
void main() {
  sqfliteFfiInit();
  late Directory dir;
  late SqfliteOfflineStore base;
  late FakeV2Server server;
  var uuids = 0;
  String newUuid() => 'abcdef00-0000-4000-8000-${(++uuids).toString().padLeft(12, '0')}';

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('transfert_especes_');
    base = await SqfliteOfflineStore.open(name: p.join(dir.path, 'caisse.db'), factory: databaseFactoryFfi);
    server = FakeV2Server.sellable();
  });
  tearDown(() async {
    await base.close();
    dir.deleteSync(recursive: true);
  });

  void serve({bool rule = true, bool right = true}) {
    serve21(server, rules: {if (rule) 'transfert_especes': {'actif': true, 'moyens': ['wave', 'carte']}});
    server
      ..capabilities = ['instantane.v1', 'stock.couverture', 'vente.especes', 'vente.paiement_declare', 'contrat.2_1', 'session.cloture', 'transfert.especes']
      ..put('moyen_paiement', 'moyen:wave', {'code': 'wave', 'nom': 'Wave', 'especes': false, 'local': true, 'reference': 'aucune'})
      ..put('politique', 'paiements.moyens_locaux', {'cle_politique': 'paiements.moyens_locaux', 'valeur': ['especes', 'wave'], 'source': 'boutique', 'verrouillee': false})
      ..put('operateur', 'operateur:7', {
        'operateur_id': '7', 'nom': 'Awa', 'pin_empreinte': 'empreinte',
        'droits': ['caisse_cloturer', 'ouverture_session', 'vente', if (right) 'transfert_especes'],
        'remise_max_pourcent': null, 'remise_max_montant': null, 'approbateur_remise': false,
      }, critical: true)
      ..put('politique', 'session.ouverture_locale', {'cle_politique': 'session.ouverture_locale', 'valeur': true, 'source': 'boutique', 'verrouillee': false});
  }

  var bases = 0;
  Future<V2Engine> engine({bool fresh = false}) async {
    if (fresh) {
      await base.close();
      base = await SqfliteOfflineStore.open(name: p.join(dir.path, 'caisse-${++bases}.db'), factory: databaseFactoryFfi);
    }
    final e = V2Engine.onStore(base, transport: server, appVersion: 'essai', platform: 'android', newUuid: newUuid,
        pinVerifier: (pin, hash) async => pin == '1234' && hash == 'empreinte', declaredPayments: true, contract21: true);
    await e.load('https://boutique.exemple.ci');
    expect(await e.pair('ABCD-EFGH', model: 'Essai', appVersion: 'essai'), isNull);
    expect((await e.sync()).reachable, isTrue);
    return e;
  }

  Operator awa(V2Engine e) => e.snapshot!.operators.firstWhere((o) => o.name == 'Awa');
  Product savon(V2Engine e) => e.snapshot!.products.firstWhere((p) => p.name == 'Savon');
  PaymentMethodInfo method(V2Engine e, String code) => e.snapshot!.methods.firstWhere((m) => m.code == code);
  Matcher refused(String text) => throwsA(isA<OfflineRefusal>().having((r) => r.message, 'message', contains(text)));

  test('solde wave de la session vers les espèces : aperçu, opération conforme, attendu de clôture, pré-X, livre', () async {
    serve();
    final e = await engine();
    // Session ouverte ici : fond 1 000, une vente espèces 500, deux ventes Wave 500 + 1 000.
    await e.closeSession(awa(e), cash: 0);
    await e.openSession(1000, awa(e));
    await e.recordSale([CartLine(product: savon(e))], [CartPayment(method: method(e, 'especes'), amount: 500, received: 500)], awa(e));
    await e.recordSale([CartLine(product: savon(e))], [CartPayment(method: method(e, 'wave'), amount: 500)], awa(e));
    await e.recordSale([CartLine(product: savon(e), quantity: BigInt.from(2000000))], [CartPayment(method: method(e, 'wave'), amount: 1000)], awa(e));
    expect(e.cashTransferSupported, isTrue);
    expect(await e.cashTransferPreview(), [('wave', 1500)], reason: 'carte réglée mais sans solde ; espèces jamais');
    expect(await e.cashTransferBlocker(awa(e)), isNull);

    final done = await e.recordCashTransfer(awa(e), reason: 'Dépôt du soir', operationUuid: 'abcdef00-0000-4000-8000-00000000ca01');
    final sent = (await e.v2.operation(done.uuid))!['operation'] as Map;
    expect(fakeValidator.validate(sent, 'operation.json'), isEmpty);
    expect((sent['contenu'] as Map)['lignes'], [{'moyen': 'wave', 'montant': 1500}]);
    expect((await e.recordCashTransfer(awa(e), operationUuid: done.uuid)).uuid, done.uuid, reason: 'rejeu : même opération');
    expect(await e.cashTransferPreview(), isEmpty);
    expect(await e.cashTransferBlocker(awa(e)), 'Aucun solde mobile money à transférer.');

    // Clôture : espèces attendues 1 000 + 500 + 1 500 ; Wave attendu 0.
    expect((await e.closingGaps(3000, const [SessionCount(method: 'wave', amount: 0)])).cash, isFalse);
    expect((await e.closingGaps(3000, const [SessionCount(method: 'wave', amount: 0)])).methods, isEmpty);
    expect((await e.closingGaps(1500, const [])).cash, isTrue, reason: 'sans le transfert, l’attendu serait 1 500');

    final document = (await e.closureDocument(ZKind.preX, ZVersion.detailed))!;
    expect(document.ticket.toString(), contains('Transferts vers les esp'));
    final book = (await e.localCashBook(awa(e), from: e.today, to: e.today))!;
    expect(book.rows.where((r) => r.nature.startsWith('Transfert')).map((r) => (r.cashIn, r.others)), [(1500, 0), (0, -1500)]);

    await e.sync();
    expect(server.received[done.uuid]!['etat'], 'integree');
  });

  test('refus : sans règle, sans droit, sans session ; adaptateur : aperçu, capacité, transfert idempotent', () async {
    serve(rule: false);
    var e = await engine();
    expect(e.cashTransferSupported, isFalse);
    expect(await e.cashTransferBlocker(awa(e)), contains('non disponible'));

    serve(right: false);
    e = await engine(fresh: true);
    expect(await e.cashTransferBlocker(awa(e)), 'Awa n’a pas le droit de transférer vers les espèces.');

    serve();
    e = await engine(fresh: true);
    await e.closeSession(awa(e), cash: 0);
    expect(await e.cashTransferBlocker(awa(e)), 'Aucune session de caisse ouverte sur ce terminal.');
    await expectLater(e.recordCashTransfer(awa(e)), refused('Aucune session'));
    await e.openSession(0, awa(e));
    await e.recordSale([CartLine(product: savon(e))], [CartPayment(method: method(e, 'wave'), amount: 500)], awa(e));

    final adapter = LocalRegisterAdapter(e, newUuid: newUuid);
    await adapter.start();
    await adapter.execute('login', {'operator_id': 7, 'pin': '1234'}, null);
    final status = await adapter.execute('status', {}, null);
    expect(((status['capabilities'] as Map)['cash_transfer'] as Map)['allowed'], isTrue);
    final preview = await adapter.execute('cashTransferPreview', {}, null);
    expect((preview['total'], (preview['lines'] as List).single['name']), (500, 'Wave'));
    const id = 'abcdef00-0000-4000-8000-00000000ca02';
    final committed = await adapter.execute('commitCashTransfer', {'reason': null}, id);
    expect((committed['operation_id'], committed['total']), (id, 500));
    expect((await adapter.execute('commitCashTransfer', {}, id))['operation_id'], id);
    expect(((await adapter.execute('status', {}, null))['capabilities'] as Map)['cash_transfer']['reason'], 'Aucun solde mobile money à transférer.');
    await adapter.close();
  });
}
