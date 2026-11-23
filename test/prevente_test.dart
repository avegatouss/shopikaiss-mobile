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

/// Prévente / réservations (contrat 2.1 lot 15, note A LOT-15-PREVENTE-POUR-B-ET-C.md).
void main() {
  sqfliteFfiInit();
  late Directory dir;
  late SqfliteOfflineStore base;
  late FakeV2Server server;
  var uuids = 0;
  String newUuid() => 'abcdef00-0000-4000-8000-${(++uuids).toString().padLeft(12, '0')}';

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('prevente_');
    base = await SqfliteOfflineStore.open(name: p.join(dir.path, 'caisse.db'), factory: databaseFactoryFfi);
    server = FakeV2Server.sellable();
  });
  tearDown(() async {
    await base.close();
    dir.deleteSync(recursive: true);
  });

  void serve({bool option = true, bool ventilated = false}) {
    serve21(server, rules: {if (option) 'prevente': {'actif': true, if (ventilated) 'z_acompte': 'moyen_origine'}});
    server
      ..capabilities = [
        'instantane.v1', 'stock.couverture', 'vente.especes', 'vente.paiement_declare', 'contrat.2_1', 'session.cloture', 'prevente.v1',
        if (ventilated) 'prevente.ventilation',
      ]
      ..put('moyen_paiement', 'moyen:wave', {'code': 'wave', 'nom': 'Wave', 'especes': false, 'local': true, 'reference': 'aucune'})
      ..put('politique', 'paiements.moyens_locaux', {'cle_politique': 'paiements.moyens_locaux', 'valeur': ['especes', 'wave'], 'source': 'boutique', 'verrouillee': false})
      ..put('operateur', 'operateur:7', {
        'operateur_id': '7', 'nom': 'Awa', 'pin_empreinte': 'empreinte', 'droits': ['caisse_cloturer', 'ouverture_session', 'prevente', 'vente'],
        'remise_max_pourcent': null, 'remise_max_montant': null, 'approbateur_remise': false,
      }, critical: true)
      ..put('politique', 'session.ouverture_locale', {'cle_politique': 'session.ouverture_locale', 'valeur': true, 'source': 'boutique', 'verrouillee': false});
  }

  Future<V2Engine> engine() async {
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
  BigInt qty(int n) => BigInt.from(n * 1000000);
  Matcher refused(String text) => throwsA(isA<OfflineRefusal>().having((r) => r.message, 'message', contains(text)));
  Map sent(V2Engine e, String uuid) => server.received[uuid]!['operation'] as Map;

  test('créer avec acompte espèces, retirer par la vente (acompte déduit), double retrait refusé, tiroir juste', () async {
    serve();
    final e = await engine();
    await e.closeSession(awa(e), cash: 0);
    await e.openSession(0, awa(e));
    expect(e.preSaleBlocker(awa(e)), isNull);

    final created = await e.createPreSale(awa(e),
        customerName: 'Koffi', customerPhone: '07 00 00 00 01', lines: [CartLine(product: savon(e), quantity: qty(3))],
        deposit: 1000, depositMethod: method(e, 'especes'), received: 2000, note: 'Pour midi', operationUuid: 'abcdef00-0000-4000-8000-0000000000a1');
    expect(RegExp(r'^[A-Z0-9]{6}$').hasMatch(created.code), isTrue);
    expect(created.code[0], isNot('W'));
    expect((created.total, created.deposit, created.due, created.open, created.local), (1500, 1000, 500, true, true));
    expect((await e.createPreSale(awa(e), customerName: 'X', lines: [CartLine(product: savon(e))], operationUuid: 'abcdef00-0000-4000-8000-0000000000a1')).uuid,
        created.uuid, reason: 'rejeu : même prévente');
    expect((await e.preSales(query: created.code.toLowerCase())).single.uuid, created.uuid);
    expect((await e.preSales(query: '0700000001')).single.uuid, created.uuid, reason: 'recherche par téléphone');
    expect((await e.closingGaps(1000, const [])).cash, isFalse, reason: 'acompte espèces au tiroir');

    final cart = e.preSaleCart(created);
    expect(cart.single.quantity, qty(3));
    final sale = await e.recordSale(cart, [CartPayment(method: method(e, 'especes'), amount: 500, received: 500)], awa(e),
        extras: SaleExtras(preSale: PreSaleUse(uuid: created.uuid, code: created.code, deposit: created.deposit)));
    expect((await e.preSales()).single.status, 'retiree');
    await expectLater(
      e.recordSale(cart, [CartPayment(method: method(e, 'especes'), amount: 500, received: 500)], awa(e),
          extras: SaleExtras(preSale: PreSaleUse(uuid: created.uuid, code: created.code, deposit: created.deposit))),
      refused('déjà retirée'),
    );
    expect((await e.closingGaps(1500, const [])).cash, isFalse, reason: 'l’acompte déduit n’entre pas une seconde fois');
    final preX = (await e.closureDocument(ZKind.preX, ZVersion.detailed))!;
    expect(preX.ticket.toString(), contains('Acomptes de prévente reçus (1)'));

    await e.sync();
    final saleSent = sent(e, sale.uuid);
    expect((saleSent['contenu'] as Map)['prevente_uuid'], created.uuid);
    expect([for (final p in ((saleSent['contenu'] as Map)['paiements'] as List).cast<Map>()) (p['moyen'], p['montant'])], [('acompte_prevente', 1000), ('especes', 500)]);
    final convert = server.received.values.firstWhere((r) => (r['operation'] as Map)['type'] == 'prevente_convertir')['operation'] as Map;
    expect((convert['contenu'] as Map), {'prevente_uuid': created.uuid, 'vente_operation_uuid': sale.uuid, 'acompte_impute': 1000});
    expect(server.received.values.every((r) => r['etat'] == 'integree'), isTrue, reason: 'toutes conformes au contrat');
  });

  test('acompte ventilé (option de boutique) : présentation seulement, tiroir et encaissements inchangés', () async {
    // Exemple de PREVENTE-VENTILATION-Z : 1 000 d'acompte en espèces une session, retrait avec 500 en espèces la suivante.
    serve(ventilated: true);
    final e = await engine();
    await e.closeSession(awa(e), cash: 0);
    await e.openSession(0, awa(e));
    final cash = await e.createPreSale(awa(e), customerName: 'Koffi', lines: [CartLine(product: savon(e), quantity: qty(3))],
        deposit: 1000, depositMethod: method(e, 'especes'), received: 1000);
    final wave = await e.createPreSale(awa(e), customerName: 'Ama', lines: [CartLine(product: savon(e))], deposit: 200, depositMethod: method(e, 'wave'));
    await e.closeSession(awa(e), cash: 1000);
    await e.openSession(0, awa(e));
    await e.recordSale(e.preSaleCart(cash), [CartPayment(method: method(e, 'especes'), amount: 500, received: 500)], awa(e),
        extras: SaleExtras(preSale: PreSaleUse(uuid: cash.uuid, code: cash.code, deposit: cash.deposit)));
    await e.recordSale(e.preSaleCart(wave), [CartPayment(method: method(e, 'especes'), amount: 300, received: 300)], awa(e),
        extras: SaleExtras(preSale: PreSaleUse(uuid: wave.uuid, code: wave.code, deposit: wave.deposit)));

    final preX = (await e.closureDocument(ZKind.preX, ZVersion.detailed))!;
    final titles = [for (final s in (preX.ticket['rubriques'] as List).cast<Map>()) s['titre']];
    expect(titles.indexOf('Ventes par moyen (acomptes ventilés)'), titles.indexOf('Encaissements par moyen') + 1, reason: 'juste après les encaissements');
    expect([for (final r in (preX.model['paiements'] as List).cast<Map>()) '${r['code']}:${r['count']}:${r['amount']}'],
        unorderedEquals(['acompte_prevente:2:1200', 'especes:2:800']), reason: 'encaissements du contrat inchangés');
    expect([for (final r in (preX.model['paiements_ventiles'] as List).cast<Map>()) '${r['code']}:${r['count']}:${r['amount']}'],
        ['especes:2:1800', 'wave:0:200'], reason: 'acomptes rangés sous leur moyen d’origine ; total 2 000 = encaissements');
    final short = (await e.closureDocument(ZKind.preX, ZVersion.short))!;
    expect([for (final s in (short.ticket['rubriques'] as List).cast<Map>()) s['titre']], contains('Ventes par moyen (acomptes ventilés)'));
    expect(preX.ticket.toString(), contains('Total des ventes'));
    expect(preX.ticket.toString(), contains(preSaleVentilationMention));
    expect((await e.closingGaps(800, const [])).cash, isFalse, reason: 'le tiroir attend l’argent reçu : 500 + 300');

    // Opérations envoyées au serveur : inchangées (paiement technique acompte_prevente, rien de ventilé).
    await e.closeSession(awa(e), cash: 800);
    await e.sync();
    final sent = server.received.values.map((r) => r['operation'] as Map).toList();
    final conversions = [for (final o in sent) if (o['type'] == 'vente' && (o['contenu'] as Map)['prevente_uuid'] != null) o];
    expect([for (final o in conversions) for (final p in ((o['contenu'] as Map)['paiements'] as List).cast<Map>()) '${p['moyen']}:${p['montant']}'],
        unorderedEquals(['acompte_prevente:1000', 'especes:500', 'acompte_prevente:200', 'especes:300']));
    expect(sent.toString(), isNot(contains('ventil')));
    expect(server.received.values.every((r) => r['etat'] == 'integree'), isTrue);
  });

  test('acompte ventilé : règle absente, origine inconnue ou remboursement d’un autre moyen → « Acompte prévente »', () async {
    serve();
    final e = await engine();
    expect(await e.preSaleOrigins(), isNull, reason: 'sans la règle, présentation du contrat');
    await e.closeSession(awa(e), cash: 0);
    await e.openSession(0, awa(e));
    final p = await e.createPreSale(awa(e), customerName: 'Koffi', lines: [CartLine(product: savon(e))], deposit: 200, depositMethod: method(e, 'wave'));
    await e.recordSale(e.preSaleCart(p), [CartPayment(method: method(e, 'especes'), amount: 300, received: 300)], awa(e),
        extras: SaleExtras(preSale: PreSaleUse(uuid: p.uuid, code: p.code, deposit: p.deposit)));
    final facts = (await e.closureFacts())!;
    final session = facts.sessions.last;
    final detail = sessionDetail(facts, session, ZContext.of(e.snapshot!));
    final payments = (detail['payments'] as List).cast<Map>();
    List<String> rows(Map<String, Map<String, int>> origins) => [
      for (final r in ventilatedPayments(payments, [session], ZContext.of(e.snapshot!, preSaleOrigins: origins))!) '${r['code']}:${r['count']}:${r['amount']}',
    ];
    expect(rows({}), unorderedEquals(['especes:1:300', 'acompte_prevente:1:200']), reason: 'origine inconnue : jamais supposée espèces');
    expect(rows({p.uuid: {'wave': 200, 'especes': -50}}), unorderedEquals(['especes:1:300', 'acompte_prevente:1:200']), reason: 'nets incohérents');
    expect(rows({p.uuid: {'wave': 250}}), unorderedEquals(['especes:1:300', 'acompte_prevente:1:200']), reason: 'nets ≠ imputé');
    expect(rows({p.uuid: {'wave': 200}}), unorderedEquals(['especes:1:300', 'wave:0:200']));
  });

  test('panne entre vente et conversion : rien n’est gardé, la prévente ne se retire qu’une fois (audit M01)', () async {
    serve();
    final e = await engine();
    await e.closeSession(awa(e), cash: 0);
    await e.openSession(0, awa(e));
    final p = await e.createPreSale(awa(e), customerName: 'Test audit', lines: [CartLine(product: savon(e))], deposit: 200, depositMethod: method(e, 'especes'));
    await base.database.execute(
        "CREATE TRIGGER panne_conversion BEFORE INSERT ON v2_operations WHEN NEW.type = 'prevente_convertir' BEGIN SELECT RAISE(ABORT, 'panne'); END");
    final extras = SaleExtras(preSale: PreSaleUse(uuid: p.uuid, code: p.code, deposit: p.deposit));
    final pay = [CartPayment(method: method(e, 'especes'), amount: 300, received: 300)];
    await expectLater(e.recordSale(e.preSaleCart(p), pay, awa(e), extras: extras), throwsA(anything));
    expect(await e.v2.operationsOfType('vente'), isEmpty, reason: 'vente annulée avec sa conversion (même transaction)');
    expect((await e.preSales()).single.open, isTrue);

    await base.database.execute('DROP TRIGGER panne_conversion');
    final sale = await e.recordSale(e.preSaleCart(p), pay, awa(e), extras: extras);
    expect(sale.isSale, isTrue);
    expect((await e.v2.operationsOfType('vente')).length, 1);
    expect((await e.preSales()).single.open, isFalse);
    await expectLater(e.recordSale(e.preSaleCart(p), pay, awa(e), extras: extras), refused('déjà retirée'));
    expect((await e.v2.operationsOfType('vente')).length, 1, reason: 'l’acompte ne sert qu’une fois');
  });

  test('désistement avec remboursement partiel Wave, sans acompte, prévente d’un autre poste, refus', () async {
    serve();
    final e = await engine();
    await e.closeSession(awa(e), cash: 0);
    await e.openSession(0, awa(e));
    final waved = await e.createPreSale(awa(e), customerName: 'Mariam', lines: [CartLine(product: savon(e))], deposit: 500, depositMethod: method(e, 'wave'));
    final free = await e.createPreSale(awa(e), customerName: 'Paul', lines: [CartLine(product: savon(e))]);
    expect(free.deposit, 0);
    await expectLater(e.cancelPreSale(awa(e), waved.uuid, reason: ' '), refused('motif'));
    await expectLater(e.cancelPreSale(awa(e), waved.uuid, reason: 'Désiste', refund: 600, refundMethod: method(e, 'wave')), refused('de 0 à'));
    final cancelled = await e.cancelPreSale(awa(e), waved.uuid, reason: 'Désiste', refund: 300, refundMethod: method(e, 'wave'));
    expect((cancelled.status, cancelled.refunded, cancelled.deposit), ('desistee', 300, 200));
    expect((await e.closingGaps(0, const [SessionCount(method: 'wave', amount: 200)])).methods, isEmpty, reason: 'Wave : 500 reçus − 300 rendus');
    await expectLater(
      e.recordSale([CartLine(product: savon(e))], [CartPayment(method: method(e, 'especes'), amount: 300, received: 300)], awa(e),
          extras: SaleExtras(preSale: PreSaleUse(uuid: waved.uuid, code: waved.code, deposit: 200))),
      refused('annulée'),
    );
    await expectLater(e.createPreSale(awa(e), customerName: ' ', lines: [CartLine(product: savon(e))]), refused('nom du client'));
    await expectLater(e.createPreSale(awa(e), customerName: 'A', lines: [CartLine(product: savon(e))], deposit: 900, depositMethod: method(e, 'especes')), refused('acompte'));

    // Prévente d'un autre poste, publiée : retrouvée par son code, retirable ici.
    server.publish([
      {'type': 'prevente', 'critique': false, 'cle': 'abcdef00-0000-4000-8000-0000000000f1', 'revision': '50', 'action': 'upsert', 'donnees': {
        'code': 'WABCD2', 'statut': 'ouverte', 'client': {'nom': 'Awa web', 'telephone': null, 'client_uuid': null}, 'retrait_prevu': null,
        'lignes': [{'ligne_uuid': 'abcdef00-0000-4000-8000-0000000000f2', 'produit_uuid': fakeSavon, 'conditionnement_uuid': null, 'libelle': 'Savon', 'quantite': '1.000000', 'prix_unitaire': 500, 'remise': 0, 'total': 500}],
        'total': 500, 'acompte': 0, 'acompte_moyen': null, 'terminal_origine_uuid': null, 'auteur_operateur_id': '7', 'cree_le': '2026-11-22T08:00:00Z', 'modifie_le': '2026-11-22T08:00:00Z', 'note': null,
      }},
    ]);
    await e.sync();
    final web = (await e.preSales(query: 'wabcd2')).single;
    expect((web.local, web.open, e.preSaleCart(web).single.product.name), (false, true, 'Savon'));
    expect((await e.preSales(openOnly: true)).map((p) => p.customerName).toSet(), {'Paul', 'Awa web'});

    serve(option: false);
    await base.close();
    base = await SqfliteOfflineStore.open(name: p.join(dir.path, 'caisse-2.db'), factory: databaseFactoryFfi);
    final off = await engine();
    expect(off.preSaleSupported, isFalse);
  });

  test('adaptateur : prévente depuis le panier, facture, retrait par le panier (acompte déduit), vente convertie', () async {
    serve();
    final e = await engine();
    await e.closeSession(awa(e), cash: 0);
    await e.openSession(0, awa(e));
    final adapter = LocalRegisterAdapter(e, newUuid: newUuid);
    await adapter.start();
    await adapter.execute('login', {'operator_id': 7, 'pin': '1234'}, null);
    expect((((await adapter.execute('status', {}, null))['capabilities'] as Map)['pre_sale'] as Map)['allowed'], isTrue);
    await adapter.execute('addProduct', {'product_id': savon(e).id}, null);
    await adapter.execute('addProduct', {'product_id': savon(e).id}, null);
    // Livraison au panier : la prévente ne la reprend pas, refus explicite plutôt qu'un montant perdu.
    await adapter.execute('setDelivery', {'amount': 200}, null);
    await expectLater(adapter.execute('createPreSale', {'customer_name': 'Koffi'}, 'abcdef00-0000-4000-8000-0000000000b9'),
        throwsA(isA<AdapterFailure>().having((f) => f.code, 'code', 'prevente_refusee')));
    await adapter.execute('setDelivery', {'amount': 0}, null);
    final created = (await adapter.execute('createPreSale', {'customer_name': 'Koffi', 'deposit': 400, 'method': 'especes', 'received': 500}, 'abcdef00-0000-4000-8000-0000000000b1'))['pre_sale'] as Map;
    expect((created['total'], created['deposit'], created['due']), (1000, 400, 600));
    expect(((await adapter.execute('view', {}, null))['lines'] as List), isEmpty, reason: 'panier vidé');
    final ticket = await adapter.execute('preSaleTicket', {'pre_sale_id': created['id'], 'paper_width': 80}, null);
    expect((ticket['lines'] as List).take(2), ['FACTURE DE PRÉVENTE', 'CODE : ${created['code']}']);
    expect(ticket['escpos_base64'], isNotEmpty);

    final listed = (await adapter.execute('preSales', {'query': created['code'], 'open_only': true}, null))['pre_sales'] as List;
    expect(listed.single['id'], created['id']);
    final view = await adapter.execute('loadPreSale', {'pre_sale_id': created['id']}, null);
    expect((view['pre_sale'] as Map)['code'], created['code']);
    expect(((view['totals'] as Map)['payable_label'] as String).replaceAll(RegExp(r'\D'), ''), '600');
    await adapter.execute('setPayment', {'method': 'especes', 'received': 600}, null);
    final sold = await adapter.execute('commitSale', {}, 'abcdef00-0000-4000-8000-0000000000b2');
    expect(sold['state'], 'committed');
    expect((await e.preSales()).single.status, 'retiree');
    await expectLater(adapter.execute('loadPreSale', {'pre_sale_id': created['id']}, null),
        throwsA(isA<AdapterFailure>().having((f) => f.code, 'code', 'prevente_fermee')));
    await adapter.close();
  });
}
