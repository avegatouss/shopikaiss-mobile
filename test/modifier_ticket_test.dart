import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shopikaiss_terminal/src/offline/engine.dart';
import 'package:shopikaiss_terminal/src/offline/models.dart';
import 'package:shopikaiss_terminal/src/offline/store.dart';
import 'package:shopikaiss_terminal/src/offline/ticket.dart';
import 'package:shopikaiss_terminal/src/offline/x_z_report.dart';
import 'package:shopikaiss_terminal/src/register/register_adapter.dart';
import 'package:shopikaiss_terminal/src/sync_v2/schema_validator.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_v2_server.dart';
import 'sync_v2_engine_test.dart' show serve21;

/// Modifier un ticket après encaissement (contrat 2.1 lot 11, A `2c11cfbd`, note MODIFIER-TICKET-POUR-B-ET-C.md).
void main() {
  sqfliteFfiInit();
  late Directory dir;
  late SqfliteOfflineStore base;
  late FakeV2Server server;
  var uuids = 0;
  String newUuid() => 'abcdef00-0000-4000-8000-${(++uuids).toString().padLeft(12, '0')}';

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('modifier_ticket_');
    base = await SqfliteOfflineStore.open(name: p.join(dir.path, 'caisse.db'), factory: databaseFactoryFfi);
    server = FakeV2Server.sellable();
  });
  tearDown(() async {
    await base.close();
    dir.deleteSync(recursive: true);
  });

  /// Codes responsables : 12345678 (Mariam), 87654321 (Paul) ; 11112222 est pris par les deux (doublon ancien).
  final codeMariam = r'$2y$12$' + 'm' * 53;
  final codePaul = r'$2y$12$' + 'p' * 53;
  Future<bool> verifier(String secret, String hash) async =>
      (secret == '1234' && hash == 'empreinte') ||
      (secret == '12345678' && hash == codeMariam) ||
      (secret == '87654321' && hash == codePaul) ||
      (secret == '11112222' && (hash == codeMariam || hash == codePaul));

  void serve({bool capability = true, bool option = true, bool duplicate = false}) {
    serve21(server, rules: {if (option) 'modification_ticket': {'actif': true, 'fenetre': 'same_day'}});
    server
      ..capabilities = ['instantane.v1', 'stock.couverture', 'vente.especes', 'vente.paiement_declare', 'contrat.2_1', if (capability) 'vente.modification']
      ..put('operateur', 'operateur:7', {
        'operateur_id': '7', 'nom': 'Awa', 'pin_empreinte': 'empreinte', 'droits': ['ouverture_session', 'remise', 'vente'],
        'remise_max_pourcent': null, 'remise_max_montant': null, 'approbateur_remise': false,
      }, critical: true)
      ..put('operateur', 'operateur:9', {
        'operateur_id': '9', 'nom': 'Mariam', 'pin_empreinte': 'empreinte', 'droits': ['vente'],
        'remise_max_pourcent': null, 'remise_max_montant': null, 'approbateur_remise': false,
        'approbateur_modification': true, 'code_autorisation_empreinte': codeMariam,
      })
      ..put('operateur', 'operateur:10', {
        'operateur_id': '10', 'nom': 'Paul', 'pin_empreinte': 'empreinte', 'droits': ['vente'],
        'remise_max_pourcent': null, 'remise_max_montant': null, 'approbateur_remise': false,
        'approbateur_modification': true, 'code_autorisation_empreinte': codePaul,
      });
  }

  Future<V2Engine> engine() async {
    final e = V2Engine.onStore(base, transport: server, appVersion: 'essai', platform: 'windows', newUuid: newUuid,
        pinVerifier: verifier, declaredPayments: true, contract21: true);
    await e.load('https://boutique.exemple.ci');
    expect(await e.pair('ABCD-EFGH', model: 'Essai', appVersion: 'essai'), isNull);
    expect((await e.sync()).reachable, isTrue);
    return e;
  }

  Operator awa(V2Engine e) => e.snapshot!.operators.firstWhere((o) => o.name == 'Awa');
  Product savon(V2Engine e) => e.snapshot!.products.firstWhere((p) => p.name == 'Savon');
  Product emballage(V2Engine e) => e.snapshot!.products.firstWhere((p) => p.name == 'Emballage');
  CartPayment cash(V2Engine e, int amount) => CartPayment(method: e.snapshot!.methods.firstWhere((m) => m.isCash), amount: amount, received: amount);
  BigInt qty(int n) => BigInt.from(n * 1000000);

  test('sans la capacité ou sans l’option de la boutique : rien de nouveau', () async {
    serve(capability: false);
    var e = await engine();
    expect(e.saleEditSupported, isFalse);
    final sale = await e.recordSale([CartLine(product: savon(e))], [cash(e, 500)], awa(e));
    expect(await e.saleEditCheck(awa(e), sale), 'Le serveur de la boutique ne propose pas encore cette fonction.');

    serve(option: false);
    e = await engine();
    expect(e.saleEditSupported, isFalse, reason: 'option éteinte : clé absente de boutique.regles');
    expect(e.saleEditUnavailable, 'Option désactivée : Paramètres › Règles de gestion › Correction d’une vente.');
  });

  test('adaptateur : coupure entre ticket de remplacement et effacement du panier ; réglages du ticket figés', () async {
    serve();
    final e = await engine();
    final sale = await e.recordSale([CartLine(product: savon(e), quantity: qty(2))], [cash(e, 1000)], awa(e));
    var adapter = LocalRegisterAdapter(e, newUuid: newUuid);
    await adapter.start();
    await adapter.execute('login', {'operator_id': 7, 'pin': '1234'}, null);
    await adapter.execute('startSaleEdit', {'sale_id': sale.uuid}, null);
    for (final (command, args) in [('setDelivery', {'amount': 100}), ('setNote', {'text': 'x'}), ('setWholesale', {'active': true})]) {
      await expectLater(adapter.execute(command, args, null), throwsA(isA<AdapterFailure>().having((f) => f.code, 'code', 'modification_en_cours')));
    }
    // Le moteur enregistre le ticket de remplacement, puis l'hôte s'arrête avant d'effacer le panier de correction.
    final mariam = await e.identifyEditApprover('12345678');
    await e.recordSaleEdit(awa(e), sale, [CartLine(product: savon(e))], approver: mariam, method: null, reason: null);
    await adapter.close();
    adapter = LocalRegisterAdapter(e, newUuid: newUuid);
    await adapter.start();
    await adapter.execute('login', {'operator_id': 7, 'pin': '1234'}, null);
    final view = await adapter.execute('view', {}, null);
    expect((view['sale_edit'], (view['lines'] as List).isEmpty), (null, true), reason: 'panier de correction libéré à la reprise');
    expect(await e.openDrafts(), isEmpty);
    await adapter.close();
  });

  test('code seul partout (remise, restaurant) : reconnu parmi tous les codes, habilitation vérifiée ensuite', () async {
    serve();
    final e = await engine();
    Operator named(String name) => e.snapshot!.operators.firstWhere((o) => o.name == name);
    expect((await e.identifyApprover('12345678', eligible: [named('Mariam')], notAllowed: 'ne peut pas.')).name, 'Mariam');
    await expectLater(e.identifyApprover('87654321', eligible: [named('Mariam')], notAllowed: 'ne peut pas autoriser cette remise.'),
        throwsA(isA<OfflineRefusal>().having((r) => r.message, 'message', 'Paul ne peut pas autoriser cette remise.')));
    await expectLater(e.identifyApprover('11112222', eligible: [named('Mariam'), named('Paul')], notAllowed: '.'),
        throwsA(isA<OfflineRefusal>().having((r) => r.message, 'message', contains('plusieurs responsables'))));
    await expectLater(e.identifyApprover('00000000', eligible: [named('Mariam')], notAllowed: '.'),
        throwsA(isA<OfflineRefusal>().having((r) => r.message, 'message', 'Code responsable inconnu.')));
    // Remise : sans responsable habilité (aucun approbateur_remise ici), le code ne suffit pas.
    await expectLater(
      e.authorizeDiscountByCode(cashier: awa(e), code: '12345678', reason: 'Client fidèle', lines: [CartLine(product: savon(e))], globalDiscount: 0),
      throwsA(isA<OfflineRefusal>().having((r) => r.message, 'message', contains('Mariam ne peut pas autoriser cette remise'))),
    );
  });

  test('codes responsables envoyés en même temps : comptés un à un, blocage dès le troisième échec (relecture du 23/11)', () async {
    serve();
    final e = await engine();
    Operator named(String name) => e.snapshot!.operators.firstWhere((o) => o.name == name);
    final results = await Future.wait([
      for (var i = 0; i < 5; i++)
        e.identifyApprover('0000000$i', eligible: [named('Mariam')], notAllowed: '.').then((_) => 'reconnu', onError: (Object r) => '$r'),
    ]);
    expect(results.where((r) => r == 'Code responsable inconnu.'), hasLength(3));
    expect(results.where((r) => r.startsWith('Trop d’essais')), hasLength(2), reason: 'les essais simultanés ne passent pas avant le blocage');
    await expectLater(e.identifyApprover('12345678', eligible: [named('Mariam')], notAllowed: '.'), throwsA(isA<OfflineRefusal>().having((r) => r.message, 'message', contains('Trop d’essais'))),
        reason: 'même le bon code attend la fin du blocage');
  });

  test('code responsable seul : un seul responsable reconnu ; inconnu compté ; doublon refusé', () async {
    serve();
    final e = await engine();
    expect(e.editApprovers.map((o) => o.name), unorderedEquals(['Mariam', 'Paul']));
    expect((await e.identifyEditApprover('87654321')).name, 'Paul');
    await expectLater(e.identifyEditApprover('99999999'), throwsA(isA<OfflineRefusal>().having((r) => r.message, 'message', 'Code responsable inconnu.')));
    await expectLater(e.identifyEditApprover('11112222'), throwsA(isA<OfflineRefusal>().having((r) => r.message, 'message', contains('plusieurs responsables'))));
    await expectLater(e.identifyEditApprover('1234'), throwsA(isA<OfflineRefusal>()));
    await expectLater(e.identifyEditApprover('00000000'), throwsA(isA<OfflineRefusal>()));
    await expectLater(e.identifyEditApprover('12345678'), throwsA(isA<OfflineRefusal>().having((r) => r.message, 'message', contains('Trop d’essais'))),
        reason: 'trois échecs : blocage progressif, comme les autres codes');
  });

  test('ticket modifié : contenu complet, différence remboursée, mouvements nets, mention imprimée ; envoyé après la vente', () async {
    serve();
    final e = await engine();
    final sale = await e.recordSale([CartLine(product: savon(e), quantity: qty(2))], [cash(e, 1000)], awa(e));
    expect(await e.saleEditCheck(awa(e), sale), isNull);
    final lines = [CartLine(product: savon(e)), CartLine(product: emballage(e), quantity: qty(3))];
    final preview = e.previewSaleEdit(sale, lines);
    expect((preview.originalTotal, preview.newTotal, preview.difference, preview.direction, preview.methodChoice), (1000, 800, -200, 'remboursement', false));

    final mariam = await e.identifyEditApprover('12345678');
    final edited = await e.recordSaleEdit(awa(e), sale, lines, approver: mariam, reason: 'Le client rend un savon');
    expect((edited.isSaleEdit, edited.isSale, edited.total, edited.content['remplace']), (true, true, 800, sale.number));
    expect(edited.content['paiements'], [{'moyen': 'especes', 'montant': 800, 'recu': null, 'reference': null}]);
    expect(await e.saleEditCheck(awa(e), sale), contains('déjà été modifié'));
    expect(await e.saleEditCheck(awa(e), edited), isNull, reason: 'le nouveau ticket se modifie à son tour');
    expect((await e.soldSinceSnapshot())[savon(e).id], qty(1), reason: '2 vendus, 1 rendu au stock');

    final (ticketLines, payments) = e.ticketParts(edited);
    final printed = offlineTicketLines(snapshot: e.snapshot!, operation: edited, lines: ticketLines, payments: payments, operatorName: 'Awa', paperWidth: 80).join('\n');
    expect(printed.replaceAll(RegExp(r'\s+'), ' '), contains('Remplace le ticket no ${sale.number} (ticket modifie)'));
    expect(printed, contains('Rembourse (Especes)'));

    // Pré-X local : le ticket de remplacement compte à la place de l'original ; rubrique « Tickets modifiés » du contrat.
    final facts = (await e.closureFacts())!;
    final detail = closureDetail(facts, [facts.openSession!], methodNames: const {'especes': 'Espèces'}, operatorName: (id) => id == 9 ? 'Mariam' : 'Awa');
    expect(((detail['summary'] as Map)['tickets'], (detail['summary'] as Map)['payable']), (1, 800));
    final contract = detailToContract(detail);
    final errors = SchemaValidator((file) => File('test/fixtures/contrat-v2/schemas/$file').readAsStringSync())
        .validate(contract, r'donnees-z-local-1.json#/$defs/detail_cloture');
    expect(errors, isEmpty, reason: errors.join(' ; '));
    final rubric = contract['modifications'] as Map;
    expect((rubric['count'], rubric['difference'], rubric['refunds']), (1, '-200', '200'));
    final row = (rubric['rows'] as List).single as Map;
    expect((row['original'], row['approver'], row['cashier'], row['source']), (sale.number, 'Mariam', 'Awa', 'terminal'));
    expect(row['removed'], [{'label': 'Savon', 'packaging': null, 'quantity': '1.000000', 'amount': '500'}]);
    expect(row['added'], [{'label': 'Emballage', 'packaging': null, 'quantity': '3.000000', 'amount': '300'}]);

    await e.sync();
    final sent = server.received.values.map((r) => r['operation'] as Map<String, dynamic>).toList();
    final operation = sent.firstWhere((o) => o['type'] == 'vente_modification');
    final vente = sent.firstWhere((o) => o['type'] == 'vente');
    expect(operation['sequence'] as int, greaterThan(vente['sequence'] as int));
    final content = operation['contenu'] as Map;
    expect(content['vente_ref'], {'operation_uuid': sale.uuid, 'vente_uuid': null, 'numero': sale.number});
    expect((content['a_payer_origine'], content['difference'], content['motif']), (1000, -200, 'Le client rend un savon'));
    expect(content['reglement'], {'moyen': 'especes', 'sens': 'remboursement', 'montant': 200, 'reference': null});
    expect((content['autorisation'] as Map)['approbateur_id'], '9');
    expect((content['autorisation'] as Map)['preuve'], startsWith('code_local|'));
    expect((content['lignes'] as List).length, 2, reason: 'contenu complet, pas un delta');
    expect((content['mouvements'] as List).single, allOf(containsPair('produit_uuid', fakeSavon), containsPair('variation', '1.000000')));
  });

  test('refus : moyen à choisir, remboursement trop grand, ticket vide, responsable inconnu, retour déjà fait', () async {
    serve();
    final e = await engine();
    final sale = await e.recordSale([CartLine(product: savon(e))], [cash(e, 500)], awa(e));
    final mariam = await e.identifyEditApprover('12345678');
    await expectLater(e.recordSaleEdit(awa(e), sale, const [], approver: mariam), throwsA(isA<OfflineRefusal>()));
    await expectLater(e.recordSaleEdit(awa(e), sale, [CartLine(product: savon(e))], approver: awa(e)),
        throwsA(isA<OfflineRefusal>().having((r) => r.message, 'message', contains('ne peut pas autoriser'))));
    final more = await e.recordSaleEdit(awa(e), sale, [CartLine(product: savon(e), quantity: qty(3))], approver: mariam);
    expect(((more.content['modification'] as Map)['reglement'] as Map)['sens'], 'encaissement');
    expect(more.content['paiements'], [{'moyen': 'especes', 'montant': 1500, 'recu': null, 'reference': null}]);
  });

  test('adaptateur : startSaleEdit, bandeau, encaissement bloqué, prepareSaleEdit, commitSaleEdit idempotent', () async {
    serve();
    final e = await engine();
    final sale = await e.recordSale([CartLine(product: savon(e), quantity: qty(2))], [cash(e, 1000)], awa(e));
    final adapter = LocalRegisterAdapter(e, newUuid: newUuid);
    await adapter.start();
    await adapter.execute('login', {'operator_id': 7, 'pin': '1234'}, null);
    final status = await adapter.execute('status', {}, null);
    expect(((status['capabilities'] as Map)['sale_edit'] as Map)['allowed'], isTrue);
    final history = (await adapter.execute('history', {}, null))['items'] as List;
    expect((history.single as Map)['edit_reason'], isNull);

    var view = await adapter.execute('startSaleEdit', {'sale_id': sale.uuid}, null);
    expect((view['sale_edit'] as Map)['number'], sale.number);
    expect((view['lines'] as List).single['quantity'], '2');
    expect(view['can_pay'], isFalse);
    await expectLater(adapter.execute('suspendDraft', {}, null), throwsA(isA<AdapterFailure>().having((f) => f.code, 'code', 'modification_en_cours')));
    await expectLater(adapter.execute('preparePayment', {}, null), throwsA(isA<AdapterFailure>().having((f) => f.code, 'code', 'modification_en_cours')));

    await adapter.execute('changeQuantity', {'line_id': (view['lines'] as List).single['id'], 'quantity': '3'}, null);
    final prepared = await adapter.execute('prepareSaleEdit', {}, null);
    expect((prepared['original_total'], prepared['new_total'], prepared['direction'], prepared['method_choice']), (1000, 1500, 'encaissement', false));
    expect(prepared['direction_label'], 'Complément à encaisser');

    const operation = 'abcdef00-0000-4000-8000-00000000beef';
    await expectLater(adapter.execute('commitSaleEdit', {'operation_id': operation, 'approval_code': '00000000'}, null),
        throwsA(isA<AdapterFailure>().having((f) => f.code, 'code', 'code_refuse')));
    final committed = await adapter.execute('commitSaleEdit', {'operation_id': operation, 'approval_code': '12345678', 'reason': null}, null);
    expect((committed['state'], committed['total']), ('committed', 1500));
    view = await adapter.execute('view', {}, null);
    expect((view['sale_edit'], (view['lines'] as List).isEmpty), (null, true), reason: 'panier libéré après validation');
    final again = await adapter.execute('commitSaleEdit', {'operation_id': operation, 'approval_code': '12345678'}, null);
    expect(again['number'], committed['number'], reason: 'rejeu : même ticket de remplacement');
    final items = (await adapter.execute('history', {}, null))['items'] as List;
    expect((items.first as Map)['replaces'], sale.number);
    expect((items.last as Map)['edit_reason'], contains('déjà été modifié'));
    await adapter.close();
  });
}
