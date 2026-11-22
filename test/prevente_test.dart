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

  void serve({bool option = true}) {
    serve21(server, rules: {if (option) 'prevente': {'actif': true}});
    server
      ..capabilities = ['instantane.v1', 'stock.couverture', 'vente.especes', 'vente.paiement_declare', 'contrat.2_1', 'session.cloture', 'prevente.v1']
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
