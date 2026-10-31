import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shopikaiss_terminal/src/offline/engine.dart';
import 'package:shopikaiss_terminal/src/offline/models.dart';
import 'package:shopikaiss_terminal/src/offline/web_rules.dart';
import 'package:shopikaiss_terminal/src/offline/store.dart';
import 'package:shopikaiss_terminal/src/register/register_adapter.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_engine.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'offline_test.dart' show FakeTransport;
import 'support/fake_v2_server.dart';

/// Moteur v2 vu par les écrans et l'hôte Windows (même interface que la caisse v1) contre le faux serveur du contrat.
void main() {
  sqfliteFfiInit();
  late Directory dir;
  late SqfliteOfflineStore base;
  late FakeV2Server server;
  var uuids = 0;
  String newUuid() => 'abcdef00-0000-4000-8000-${(++uuids).toString().padLeft(12, '0')}';

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('moteur_v2_');
    base = await SqfliteOfflineStore.open(name: p.join(dir.path, 'caisse.db'), factory: databaseFactoryFfi);
    server = FakeV2Server.sellable();
  });
  tearDown(() async {
    await base.close();
    dir.deleteSync(recursive: true);
  });

  Future<V2Engine> engine({DateTime? at}) async {
    final e = V2Engine.onStore(base, transport: server, appVersion: 'essai', platform: 'android', newUuid: newUuid,
        clock: at == null ? null : () => at, pinVerifier: FakeV2Server.pinVerifier);
    await e.load('https://boutique.exemple.ci');
    return e;
  }

  Future<V2Engine> paired() async {
    final e = await engine();
    expect(await e.pair('ABCD-EFGH', model: 'Essai', appVersion: 'essai'), isNull);
    return e;
  }

  CartLine savon(V2Engine e, {int units = 1}) =>
      CartLine(product: e.snapshot!.byCode('6190000000011')!.$1, quantity: BigInt.from(units * 1000000));

  CartPayment cash(V2Engine e, int amount) => CartPayment(method: e.snapshot!.methods.single, amount: amount, received: amount);

  test('appairage : catalogue de la projection présenté aux écrans (entiers locaux stables, stock, règles, session)', () async {
    final e = await paired();
    final s = e.snapshot!;
    expect(e.blockReason, isNull);
    expect(e.permanentLocal, isTrue);
    expect(s.store.vatRate, '18.000000');
    expect(s.methods.map((m) => m.code), ['especes']);
    expect(s.operators.map((o) => o.name), ['Awa'], reason: 'seuls les opérateurs autorisés à vendre');
    final product = s.byCode('6190000000011')!.$1;
    expect(product.name, 'Savon');
    expect(product.stockMicros, BigInt.from(10000000));
    expect(product.packagings.single.name, 'Carton de 12');
    expect(s.rules.sessionOpening, isTrue);
    expect(e.sessionOpen, isTrue, reason: 'session du serveur sous session:<terminal>');

    // Rechargement : mêmes identifiants entiers (paniers conservés, protocole de l'hôte Windows).
    final again = await engine();
    expect(again.snapshot!.byCode('6190000000011')!.$1.id, product.id);
    expect(again.snapshot!.byCode('6190000000011')!.$1.packagings.single.id, product.packagings.single.id);
  });

  test('vente : figée en v2, consommation locale, rejeu idempotent, envoi, numéro serveur, couverture sans double décompte', () async {
    final e = await paired();
    final operator = e.snapshot!.operators.single;
    final line = savon(e, units: 2);
    final sale = await e.recordSale([line], [cash(e, 1000)], operator, draftUuid: 'brouillon-1', operationUuid: 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee');
    expect(sale.number, startsWith('HL2-3-'));
    expect(sale.status, OperationStatus.pending);
    expect(e.pendingCount, 1);
    expect((await e.soldSinceSnapshot())[line.product.id], BigInt.from(2000000));

    final replay = await e.recordSale([line], [cash(e, 1000)], operator, draftUuid: 'brouillon-1', operationUuid: 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee');
    expect(replay.number, sale.number, reason: 'même commande rejouée : même vente');
    await expectLater(e.recordSale([line], [cash(e, 1000)], operator, draftUuid: 'brouillon-1'), throwsA(isA<OfflineRefusal>()),
        reason: 'second encaissement du même panier');

    final report = await e.sync();
    expect(report.integrated, 1);
    final status = (await e.saleStatus(sale.uuid))!;
    expect(status.serverStatus, 'integree');
    expect(status.serverNumber, 'V-20261029-0001');
    expect(e.pendingCount, 0);

    // Le serveur publie la projection qui couvre la vente : stock 10 → 8, consommation locale retirée.
    server.publish([
      {'type': 'stock.projection', 'critique': false, 'cle': fakeSavon, 'revision': '2', 'action': 'upsert',
        'donnees': {'produit_uuid': fakeSavon, 'lot_uuid': null, 'quantite': '8.000000'}, 'operations_couvertes': [sale.uuid]},
    ]);
    await e.sync();
    expect(e.snapshot!.byCode('6190000000011')!.$1.stockMicros, BigInt.from(8000000));
    expect((await e.soldSinceSnapshot())[line.product.id], anyOf(isNull, BigInt.zero));

    // Historique et ticket au format des écrans.
    final history = await e.history();
    expect(history.single.content['total'], 1000);
    final (lines, payments) = e.ticketParts(history.single);
    expect(lines.single.product.name, 'Savon');
    expect(lines.single.quantity, BigInt.from(2000000));
    expect(payments.single.amount, 1000);
  });

  test('règles : paiement non espèces, opérateur sans droit, autorisation retirée ou expirée', () async {
    final e = await paired();
    final operator = e.snapshot!.operators.single;
    final mobile = CartPayment(method: PaymentMethodInfo({'code': 'wave', 'nom': 'Wave', 'especes': false}), amount: 500);
    await expectLater(e.recordSale([savon(e)], [mobile], operator), throwsA(isA<OfflineRefusal>()));
    final intern = Operator({'id': 8, 'nom': 'Stagiaire'});
    await expectLater(e.recordSale([savon(e)], [cash(e, 500)], intern), throwsA(isA<OfflineRefusal>()));

    server.authorized = false;
    await e.sync();
    expect(e.blockReason, contains('Désactivée par la boutique'));
    await expectLater(e.recordSale([savon(e)], [cash(e, 500)], operator), throwsA(isA<OfflineRefusal>()));

    server.authorized = true;
    server.authorizationExpires = '2026-10-29T09:00:00Z';
    await e.sync();
    final late = await engine(at: DateTime.utc(2026, 10, 29, 10));
    expect(late.blockReason, contains('expirée'));
  });

  test('ouverture de session locale : la vente porte la session ouverte localement, puis le serveur fait foi', () async {
    server.entities.remove('session|session:$fakeTerminal');
    final e = await paired();
    expect(e.sessionOpen, isFalse);
    final operator = e.snapshot!.operators.single;
    await expectLater(e.recordSale([savon(e)], [cash(e, 500)], operator), throwsA(isA<OfflineRefusal>()));
    final opening = await e.openSession(0, operator);
    expect(e.sessionOpen, isTrue);
    final sale = await e.recordSale([savon(e)], [cash(e, 500)], operator);
    final stored = (await V2Store(base.database, fakeValidator).operation(sale.uuid))!;
    expect(((stored['operation'] as Map)['contenu'] as Map)['session_uuid'], opening.uuid);

    await e.sync();
    expect((await e.saleStatus(opening.uuid))!.serverStatus, 'integree');
    // Intégrée, pas encore rendue par le journal : la vente suivante reste possible.
    expect(e.sessionOpen, isTrue);
    // Toujours rien du journal après le délai : le serveur fait foi (fermée ici : aucune publiée).
    await e.v2.db.update('v2_operations', {'maj_le': '2020-01-01T00:00:00Z'}, where: 'uuid = ?', whereArgs: [opening.uuid]);
    await e.sync();
    expect(e.sessionOpen, isFalse);
  });

  test('PIN : vérifié contre l’empreinte reçue ; PIN non défini refusé sans compter d’échec', () async {
    final e = await paired();
    final operator = e.snapshot!.operators.single;
    expect(await e.checkPin(operator, '0000'), isFalse);
    expect(await e.checkPin(operator, '1234'), isTrue);
    final noPin = Operator({'id': 9, 'nom': 'Sans PIN', 'pin': null});
    expect(e.pinDefined(noPin), isFalse);
    for (var i = 0; i < 5; i++) {
      expect(await e.checkPin(noPin, '1234'), isFalse);
    }
    expect(await e.pinLockedFor(noPin), isNull, reason: 'aucun échec compté');
  });

  test('clé web (2.0.2) rangée pour la caisse web ; serveur 2.0.1 sans clé toléré', () async {
    final e = await paired();
    expect(e.webToken, server.webKey);
    expect(await base.read(StoreKeys.webToken), server.webKey);
    server.webKey = null;
    final again = await engine();
    expect(await again.pair('ABCD-EFGH', model: 'Essai', appVersion: 'essai'), isNull);
    expect(again.webToken, isNull);
  });

  test('installation 1.1.5 mise à jour : l’ancienne file v1 est envoyée par ses routes, puis plus rien en v1', () async {
    final legacy = FakeTransport();
    final v1 = OfflineEngine(store: base, transport: legacy);
    await v1.load('https://boutique.exemple.ci');
    expect(await v1.pair('ABCD-EFGH', model: 'Essai', appVersion: '1.1.5'), isNull);
    final product = v1.snapshot!.products.first;
    final total = CartLine(product: product).total;
    await v1.recordSale([CartLine(product: product)], [CartPayment(method: v1.snapshot!.methods.firstWhere((m) => m.isCash), amount: total)],
        v1.snapshot!.operators.first);
    expect((await base.counts()).pending, 1);

    final e = V2Engine.onStore(base, transport: server, appVersion: 'essai', platform: 'android', newUuid: newUuid, legacyTransport: legacy);
    await e.load('https://boutique.exemple.ci');
    expect(await e.pair('ABCD-EFGH', model: 'Essai', appVersion: 'essai'), isNull);
    expect((await base.counts()).pending, 0, reason: 'ancienne file vidée par la v1');
    expect(e.pendingCount, 0);
  });

  test('adaptateur Windows sur v2 (C-REQ-005) : capacités, ouverture de session, détail des montants, verrouillage', () async {
    server.entities.remove('session|session:$fakeTerminal');
    final e = await paired();
    final adapter = LocalRegisterAdapter(e, newUuid: newUuid);
    await adapter.start();
    var status = await adapter.execute('status', {}, null);
    expect((status['capabilities'] as Map)['sell']['allowed'], isFalse);
    expect((status['capabilities'] as Map)['sell']['reason'], 'Identifiez le caissier.');

    await adapter.execute('login', {'operator_id': 7, 'pin': '1234'}, null);
    status = await adapter.execute('status', {}, null);
    expect((status['capabilities'] as Map)['sell']['reason'], contains('Aucune session'));
    expect((status['capabilities'] as Map)['open_session']['allowed'], isTrue);

    status = await adapter.execute('openSession', {'float': 5000}, null);
    expect(status['session_open'], isTrue);
    expect((status['session'] as Map)['local'], isTrue);
    expect((status['capabilities'] as Map)['sell']['allowed'], isTrue);
    await expectLater(adapter.execute('openSession', {'float': 0}, null), throwsA(isA<AdapterFailure>()));

    await adapter.execute('scan', {'code': '6190000000011'}, null);
    final view = await adapter.execute('setPayment', {'method': 'especes', 'received': 1000}, null);
    final totals = view['totals'] as Map;
    expect(totals['payable_label'], '500 F');
    expect(totals['vat_label'], '76 F', reason: 'TVA 18 % incluse dans 500 F, calculée par le moteur');
    expect(totals['base_ht_label'], '424 F');
    expect((view['payment'] as Map)['change_label'], '500 F');
    expect(((view['lines'] as List).single as Map)['unit_price_label'], '500 F');

    final sale = await adapter.execute('commitSale', {}, 'aaaaaaaa-bbbb-4ccc-8ddd-000000000001');
    expect(sale['state'], 'committed');

    status = await adapter.execute('logout', {}, null);
    expect(status['operator'], isNull);
    expect((status['capabilities'] as Map)['sell']['allowed'], isFalse);
    expect((await adapter.execute('saleStatus', {}, 'aaaaaaaa-bbbb-4ccc-8ddd-000000000001'))['state'], 'committed',
        reason: 'un encaissement se vérifie toujours, même verrouillé');
    await adapter.close();
  });

  test('adaptateur (C-REQ-005 lot 2) : catégories, remise de ligne selon droit et politique, paniers en attente, paiements', () async {
    server
      ..put('produit', fakeSavon, {'nom': 'Savon', 'reference': 'SAV', 'categorie': 'Hygiène', 'prix': 500, 'stock_illimite': false, 'actif': true, 'vente_locale': true})
      ..put('politique', 'remises.ligne_max_pourcent', {'cle_politique': 'remises.ligne_max_pourcent', 'valeur': 10, 'source': 'boutique', 'verrouillee': false});
    final e = await paired();
    var adapter = LocalRegisterAdapter(e, newUuid: newUuid);
    await adapter.start();
    await adapter.execute('login', {'operator_id': 7, 'pin': '1234'}, null);

    // Catégories : liste du catalogue et filtre.
    var view = await adapter.execute('search', {'query': '', 'category': 'Hygiène'}, null);
    expect(view['categories'], ['Hygiène']);
    expect([for (final p in view['products'] as List) p['name']], ['Savon']);
    view = await adapter.execute('search', {'query': ''}, null);
    expect((view['products'] as List).length, 2);

    // Remise : refusée sans le droit `remise`.
    await adapter.execute('scan', {'code': '6190000000011'}, null);
    await adapter.execute('scan', {'code': '6190000000011'}, null);
    final lineId = ((await adapter.execute('view', {}, null))['lines'] as List).single['id'] as String;
    var status = await adapter.execute('status', {}, null);
    expect((status['capabilities'] as Map)['discount']['reason'], contains('droit'));
    await expectLater(adapter.execute('setLineDiscount', {'line_id': lineId, 'amount': 50}, null),
        throwsA(isA<AdapterFailure>().having((f) => f.code, 'code', 'remise_refusee')));

    // Avec le droit : plafond de 10 % de 1 000 F.
    server.publish([
      {
        'type': 'operateur',
        'critique': true,
        'cle': 'operateur:7',
        'revision': '2',
        'action': 'upsert',
        'donnees': {'operateur_id': '7', 'nom': 'Awa', 'pin_empreinte': 'empreinte', 'droits': ['ouverture_session', 'remise', 'vente']},
      },
    ]);
    await e.sync();
    status = await adapter.execute('status', {}, null);
    expect((status['capabilities'] as Map)['discount'], containsPair('allowed', true));
    expect((status['capabilities'] as Map)['discount']['max_percent'], 10);
    await expectLater(adapter.execute('setLineDiscount', {'line_id': lineId, 'amount': 150}, null), throwsA(isA<AdapterFailure>()));
    view = await adapter.execute('setLineDiscount', {'line_id': lineId, 'amount': 100}, null);
    expect((view['totals'] as Map)['payable_label'], '900 F');
    expect((view['totals'] as Map)['discounts_label'], '100 F');
    expect(((view['lines'] as List).single as Map)['discount'], 100);

    // Quantité réduite : la remise dépasse le plafond, l'encaissement est bloqué avec son motif.
    view = await adapter.execute('changeQuantity', {'line_id': lineId, 'quantity': '1'}, null);
    expect(view['can_pay'], isFalse);
    expect(view['pay_reason'], contains('au-delà du maximum'));
    view = await adapter.execute('setLineDiscount', {'line_id': lineId, 'amount': 50}, null);
    expect(view['can_pay'], isTrue);

    // Paniers en attente : suspendre, nouveau panier, reprendre (le courant part en attente à son tour), redémarrage.
    final first = view['draft_id'] as String;
    view = await adapter.execute('suspendDraft', {}, null);
    expect(view['lines'], isEmpty);
    expect(view['suspended_count'], 1);
    await adapter.execute('search', {'query': 'Emballage'}, null);
    final serviceId = ((await adapter.execute('view', {}, null))['products'] as List).single['id'] as int;
    view = await adapter.execute('addProduct', {'product_id': serviceId}, null);
    final second = view['draft_id'] as String;
    final drafts = await adapter.execute('drafts', {}, null);
    expect((drafts['items'] as List).single, containsPair('draft_id', first));
    expect((drafts['items'] as List).single['total_label'], '450 F');
    view = await adapter.execute('resumeDraft', {'draft_id': first}, null);
    expect(view['draft_id'], first);
    expect(view['suspended_count'], 1);
    expect(((view['lines'] as List).single as Map)['discount'], 50, reason: 'la remise est conservée avec le panier');

    await adapter.close();
    adapter = LocalRegisterAdapter(e, newUuid: newUuid);
    await adapter.start();
    await adapter.execute('login', {'operator_id': 7, 'pin': '1234'}, null);
    view = await adapter.execute('view', {}, null);
    expect(view['draft_id'], first, reason: 'au redémarrage, le panier courant est repris, pas un panier en attente');

    // Paiements : édition invalide = paiements effacés et validation impossible ; deux lignes d'espèces refusées.
    await adapter.execute('setPayment', {'method': 'especes', 'received': 1000}, null);
    expect((await adapter.execute('view', {}, null))['payment_valid'], isTrue);
    await expectLater(
      adapter.execute('setPayments', {
        'payments': [
          {'method': 'especes', 'amount': 400},
        ],
      }, null),
      throwsA(isA<AdapterFailure>()),
    );
    view = await adapter.execute('view', {}, null);
    expect(view['payment_valid'], isFalse);
    expect(view['payments'], isEmpty, reason: 'aucun retour silencieux à l\'ancien paiement valide');
    await expectLater(
      adapter.execute('setPayments', {
        'payments': [
          {'method': 'especes', 'amount': 200},
          {'method': 'especes', 'amount': 250},
        ],
      }, null),
      throwsA(isA<AdapterFailure>().having((f) => f.message, 'message', contains('Une seule ligne'))),
    );
    await expectLater(adapter.execute('commitSale', {}, 'aaaaaaaa-bbbb-4ccc-8ddd-000000000002'), throwsA(isA<AdapterFailure>()));
    view = await adapter.execute('setPayments', {
      'payments': [
        {'method': 'especes', 'amount': 450, 'received': 500},
      ],
    }, null);
    expect((view['payment'] as Map)['change_label'], '50 F');
    expect((view['payment'] as Map)['remaining_label'], '0 F');
    final sale = await adapter.execute('commitSale', {}, 'aaaaaaaa-bbbb-4ccc-8ddd-000000000002');
    expect(sale['total'], 450);
    final recorded = await e.saleStatus('aaaaaaaa-bbbb-4ccc-8ddd-000000000002');
    expect(((recorded!.content['lignes'] as List).single as Map)['remise'], 50);

    // Le panier en attente reste, et se reprend après la vente ; supprimé, il disparaît.
    expect((await adapter.execute('drafts', {}, null))['items'], hasLength(1));
    view = await adapter.execute('resumeDraft', {'draft_id': second}, null);
    expect(view['suspended_count'], 0);
    await adapter.execute('deleteDraft', {'draft_id': second}, null);
    expect((await adapter.execute('view', {}, null))['lines'], isEmpty);
    await expectLater(adapter.execute('resumeDraft', {'draft_id': second}, null), throwsA(isA<AdapterFailure>()));
    await adapter.close();
  });

  test('moteur : remise refusée sans le droit, à l\'encaissement même si l\'écran l\'a laissée passer', () async {
    server.put('politique', 'remises.ligne_max_pourcent', {'cle_politique': 'remises.ligne_max_pourcent', 'valeur': 10, 'source': 'boutique', 'verrouillee': false});
    final e = await paired();
    final operator = e.snapshot!.operators.firstWhere((o) => o.id == 7);
    final line = savon(e)..discount = 50;
    await expectLater(e.recordSale([line], [cash(e, 450)], operator),
        throwsA(isA<OfflineRefusal>().having((r) => r.message, 'message', contains('remise'))));
  });

  test('moyens déclarés : hors connexion comme les espèces, seulement si le moteur ET le serveur ont la capacité', () async {
    server
      ..put('moyen_paiement', 'moyen:wave', {'code': 'wave', 'nom': 'Wave', 'especes': false, 'local': true})
      ..put('politique', 'paiements.moyens_locaux', {'cle_politique': 'paiements.moyens_locaux', 'valeur': ['especes', 'wave'], 'source': 'boutique', 'verrouillee': false});

    // Interrupteur coupé (état livré) : espèces seules, même si le serveur annonce la capacité.
    server.capabilities = ['instantane.v1', 'stock.couverture', 'vente.especes', 'vente.paiement_declare'];
    var e = await paired();
    expect([for (final m in e.snapshot!.methods) m.code], ['especes']);

    // Interrupteur actif mais serveur sans la capacité : espèces seules.
    server.capabilities = ['instantane.v1', 'stock.couverture', 'vente.especes'];
    e = V2Engine.onStore(base, transport: server, appVersion: 'essai', platform: 'windows', newUuid: newUuid,
        pinVerifier: FakeV2Server.pinVerifier, declaredPayments: true);
    await e.load('https://boutique.exemple.ci');
    await e.sync();
    expect([for (final m in e.snapshot!.methods) m.code], ['especes']);

    // Les deux : Wave proposé ; vente mixte enregistrée sans réseau, référence figée, pas de « reçu » hors espèces.
    server.capabilities = ['instantane.v1', 'stock.couverture', 'vente.especes', 'vente.paiement_declare'];
    await e.sync();
    expect([for (final m in e.snapshot!.methods) m.code]..sort(), ['especes', 'wave']);
    final wave = e.snapshot!.methods.firstWhere((m) => m.code == 'wave');
    final sale = await e.recordSale([savon(e)], [CartPayment(method: e.snapshot!.methods.firstWhere((m) => m.isCash), amount: 300, received: 300), CartPayment(method: wave, amount: 200, reference: 'T-8F2K1')],
        e.snapshot!.operators.first, operationUuid: 'aaaaaaaa-bbbb-4ccc-8ddd-0000000000d1');
    final stored = (await e.v2.operation(sale.uuid))!['operation'] as Map;
    final payments = ((stored['contenu'] as Map)['paiements'] as List).cast<Map>();
    expect([for (final p in payments) [p['moyen'], p['montant'], p['recu'], p['reference']]], [
      ['especes', 300, 300, null],
      ['wave', 200, null, 'T-8F2K1'],
    ]);
    await e.sync();
    expect((await e.saleStatus(sale.uuid))!.serverStatus, 'integree');
  });

  test('contrat 2.1 (lot 1a) : nouvel instantané au passage en 2.1, catégories ordonnées, marque, plafonds du rôle, référence obligatoire', () async {
    server.put('politique', 'remises.ligne_max_pourcent', {'cle_politique': 'remises.ligne_max_pourcent', 'valeur': 10, 'source': 'boutique', 'verrouillee': false});
    final before = await paired();
    expect(before.snapshot!.categories, isEmpty);

    // Le serveur passe en forme 2.1 (il ne la rend qu'à un client qui annonce contrat.2_1).
    const hygiene = '0c000000-0000-4000-8000-000000000001';
    const services = '0c000000-0000-4000-8000-000000000002';
    Map<String, dynamic> produit21(String nom, String? ref, int prix, bool illimite, String categorie, String? marque) => {
      'nom': nom, 'reference': ref, 'categorie': null, 'prix': prix, 'stock_illimite': illimite, 'actif': true, 'vente_locale': true,
      'categorie_uuid': categorie, 'marque': marque, 'fournisseur': 'Grossiste Plateau', 'unite': {'code': 'pce', 'nom': 'Pièce'},
      'prix_gros': null, 'gros_quantite_min': null, 'seuil_alerte': null, 'cree_le': null, 'favori': false, 'promotions': <Map<String, dynamic>>[], 'image': null,
    };
    Map<String, dynamic> operateur21(String id, String nom, String? pin, List<String> droits, String? pourcent, int? montant) => {
      'operateur_id': id, 'nom': nom, 'pin_empreinte': pin, 'droits': droits,
      'remise_max_pourcent': pourcent, 'remise_max_montant': montant, 'approbateur_remise': false,
    };
    server
      ..capabilities = ['instantane.v1', 'stock.couverture', 'vente.especes', 'vente.paiement_declare', 'contrat.2_1']
      ..put('boutique', fakeShop, {
        'nom': 'Boutique', 'devise': 'FCFA', 'tva_taux': '18.000000', 'tva_incluse': true,
        'regles': {
          'remise_pourcentage_arrondi': 'down', 'arrondi_especes': null, 'trop_percu': 'cash_change', 'moins_a_un': 'refuse',
          'livraison_droit': null, 'ouverture_session': 'automatic', 'survente': 'refuse',
          'gros': {'actif': false, 'mode': 'cart', 'quantite_min': null, 'droit': null, 'remises': 'refuse', 'prix_lot': 'refuse'},
          'fuseau': 'Africa/Abidjan', 'nouveau_jours': 7,
        },
        'ticket': {'raison_sociale': null, 'adresse': null, 'telephone': null, 'ncc': null, 'entete': null, 'pied': null, 'largeur_papier': 80},
        'devise_secondaire': {'libelle': 'EUR', 'taux': '655.957000'},
      }, critical: true)
      ..put('categorie', hygiene, {'nom': 'Hygiène', 'ordre': 2, 'actif': true})
      ..put('categorie', services, {'nom': 'Services', 'ordre': 1, 'actif': true})
      ..put('produit', fakeSavon, {
        ...produit21('Savon', 'SAV', 500, false, hygiene, 'Dove'),
        'favori': true,
        'seuil_alerte': '1000.000000',
        'cree_le': '${DateTime.now().toUtc().subtract(const Duration(days: 3)).toIso8601String().substring(0, 19)}Z',
        'promotions': [
          {'libelle': 'Ancien bon', 'du': null, 'au': '2020-01-01', 'exclusions': <Map<String, String>>[]},
          {'libelle': 'Bon -10 %', 'du': '2020-01-02', 'au': '2099-12-31', 'exclusions': [{'du': '2030-01-01', 'au': '2030-01-31'}]},
        ],
        'image': {'uuid': '0d000000-0000-4000-8000-000000000001', 'empreinte': 'a' * 64, 'octets': 2048, 'largeur': 640, 'hauteur': 480},
      })
      ..put('produit', fakeService, produit21('Emballage', null, 100, true, services, null))
      ..put('conditionnement', fakePack, {'produit_uuid': fakeSavon, 'nom': 'Carton de 12', 'coefficient': '12.000000', 'prix': 5500, 'defaut': false, 'actif': true, 'prix_gros': null})
      ..put('moyen_paiement', 'moyen:especes', {'code': 'especes', 'nom': 'Espèces', 'especes': true, 'local': true, 'reference': 'aucune'})
      ..put('moyen_paiement', 'moyen:wave', {'code': 'wave', 'nom': 'Wave', 'especes': false, 'local': true, 'reference': 'obligatoire'})
      ..put('politique', 'paiements.moyens_locaux', {'cle_politique': 'paiements.moyens_locaux', 'valeur': ['especes', 'wave'], 'source': 'boutique', 'verrouillee': false})
      ..put('operateur', 'operateur:7', operateur21('7', 'Awa', 'empreinte', ['ouverture_session', 'remise', 'vente'], '5.000000', 40), critical: true)
      ..put('operateur', 'operateur:8', operateur21('8', 'Stagiaire', null, <String>[], null, null));

    final codeHash = r'$2y$12$' + 'a' * 53;
    final e = V2Engine.onStore(base, transport: server, appVersion: 'essai', platform: 'windows', newUuid: newUuid,
        pinVerifier: (secret, hash) async => hash == codeHash ? secret == '12345678' : FakeV2Server.pinVerifier(secret, hash),
        declaredPayments: true, contract21: true);
    await e.load('https://boutique.exemple.ci');
    final report = await e.sync();
    expect(report.reachable, isTrue);
    expect(e.blockReason, isNull);

    final s = e.snapshot!;
    expect(s.categories, ['Services', 'Hygiène'], reason: 'ordre de la boutique, pas alphabétique');
    final savonProduct = s.byCode('6190000000011')!.$1;
    expect([savonProduct.category, savonProduct.brand, savonProduct.supplier, savonProduct.unit], ['Hygiène', 'Dove', 'Grossiste Plateau', 'Pièce']);
    expect(s.search('dove').single.name, 'Savon');

    // Plafonds : terminal 10 %, rôle 5 % et 40 F par vente ; le plus petit s'applique.
    final awa = s.operators.firstWhere((o) => o.id == 7);
    expect(e.maxLineDiscountFor(awa, 1000), 50);
    expect(e.maxSaleDiscountFor(awa), 40);
    final cashMethod = s.methods.firstWhere((m) => m.isCash);
    final tooMuch = savon(e, units: 2)..discount = 45;
    await expectLater(e.recordSale([tooMuch], [CartPayment(method: cashMethod, amount: 955, received: 955)], awa),
        throwsA(isA<OfflineRefusal>().having((r) => r.message, 'message', contains('par vente'))));

    // Référence obligatoire pour Wave.
    final wave = s.methods.firstWhere((m) => m.code == 'wave');
    expect(wave.referenceMode, 'obligatoire');
    await expectLater(e.recordSale([savon(e)], [CartPayment(method: wave, amount: 500)], awa),
        throwsA(isA<OfflineRefusal>().having((r) => r.message, 'message', contains('Référence obligatoire'))));
    final sale = await e.recordSale([savon(e)], [CartPayment(method: wave, amount: 500, reference: 'T-1')], awa,
        operationUuid: 'aaaaaaaa-bbbb-4ccc-8ddd-0000000000e1');
    expect(sale.isSale, isTrue);

    // Adaptateur : catégories, marque et mode de référence exposés.
    final adapter = LocalRegisterAdapter(e, newUuid: newUuid);
    await adapter.start();
    final view = await adapter.execute('search', {'query': '', 'category': 'Hygiène'}, null);
    expect((view['products'] as List).single, containsPair('brand', 'Dove'));
    // Badges : présentation seule, le prix ne change pas ; le premier bon valide à la date du jour.
    final card = (view['products'] as List).single as Map;
    expect([card['favorite'], card['promotion'], card['is_new'], card['low_stock'], card['price_label']], [isTrue, 'Bon -10 %', isTrue, isTrue, '500 F']);
    expect(card['image'], {'uuid': '0d000000-0000-4000-8000-000000000001', 'hash': 'a' * 64, 'width': 640, 'height': 480, 'path': null});
    final bon = savonProduct.promotions.last;
    expect([bon.activeOn('2030-01-15'), bon.activeOn('2030-02-01'), bon.activeOn('2020-01-01')], [isFalse, isTrue, isFalse]);
    final prepared = await adapter.execute('preparePayment', {}, null);
    expect([for (final m in prepared['methods'] as List) m['reference']]..sort(), ['aucune', 'obligatoire']);
    await adapter.execute('scan', {'code': '6190000000011'}, null);
    await expectLater(
      adapter.execute('setPayments', {
        'payments': [
          {'method': 'especes', 'amount': 300},
          {'method': 'wave', 'amount': 300, 'reference': 'T-2'},
        ],
      }, null),
      throwsA(isA<AdapterFailure>().having((f) => f.message, 'message', 'Trop-perçu électronique : en ligne seulement. Saisissez le montant exact.')),
    );

    // Lot 1c : code d'autorisation d'un responsable, seuils du caissier puis de l'approbateur.
    Map<String, dynamic> responsable(String id, String nom, String seuil) => {
      ...operateur21(id, nom, null, ['remise', 'vente'], seuil, null),
      'approbateur_remise': true,
      'code_autorisation_empreinte': codeHash,
    };
    server.publish([
      for (final o in [responsable('9', 'Chef', '8.000000'), responsable('10', 'Adjoint', '6.000000')])
        {'type': 'operateur', 'critique': false, 'cle': 'operateur:${o['operateur_id']}', 'revision': '2', 'action': 'upsert', 'donnees': o},
    ]);
    await e.sync();
    expect(e.blockReason, isNull, reason: 'empreinte acceptée par le schéma');
    final operators = e.snapshot!.operators;
    final chef = operators.firstWhere((o) => o.id == 9);
    final adjoint = operators.firstWhere((o) => o.id == 10);
    expect(e.enterableLineDiscount(awa, 1000), 100, reason: 'le plafond de la boutique reste, le seuil du rôle se lève');
    expect(e.maxLineDiscountFor(awa, 1000), 50);
    Future<OfflineOperation> sell(int discount, Operator who, {SaleApproval? approval}) => e.recordSale(
      [savon(e, units: 2)..discount = discount],
      [CartPayment(method: cashMethod, amount: 1000 - discount, received: 1000 - discount)],
      who,
      extras: SaleExtras(approval: approval),
    );
    Matcher refused(String text) => throwsA(isA<OfflineRefusal>().having((r) => r.message, 'message', contains(text)));
    await expectLater(sell(70, awa), refused('autorisation d’un responsable requise'));
    final seventy = [savon(e, units: 2)..discount = 70];
    expect([for (final o in e.approversFor(awa, seventy, 0)) o.name], ['Chef'], reason: 'le seuil de l’adjoint ne couvre pas 7 %');
    Future<SaleApproval> authorize(Operator who, int discount, {Operator? cashier, String code = '12345678', String reason = 'Client fidèle'}) => e.authorizeDiscount(
      cashier: cashier ?? awa, approver: who, code: code, reason: reason, lines: [savon(e, units: 2)..discount = discount], globalDiscount: 0,
    );
    await expectLater(authorize(adjoint, 70), refused('ne peut pas autoriser'));
    await expectLater(authorize(chef, 90, cashier: chef), refused('ne peut pas autoriser'));
    await expectLater(authorize(chef, 70, reason: '  '), refused('motif'));
    // Blocage après 3 échecs : même le bon code est refusé, le compteur reste propre à ce responsable.
    for (var i = 0; i < 3; i++) {
      await expectLater(authorize(adjoint, 55, code: '00000000'), refused('Code d’autorisation incorrect'));
    }
    await expectLater(authorize(adjoint, 55), refused('Trop d’essais'));
    expect(await e.approvalLockedFor(chef), isNull);
    await expectLater(authorize(chef, 70, code: '1234'), refused('Code d’autorisation incorrect'));

    final approval = await authorize(chef, 70);
    await expectLater(sell(70, awa, approval: SaleApproval(approverId: 10, reason: 'x', verifiedAt: approval.verifiedAt)), refused('ne peut pas autoriser'));
    await expectLater(sell(120, awa, approval: approval), refused('maximum hors ligne'));
    final approved = await sell(70, awa, approval: approval);
    Future<Object?> authorizations(String uuid) async => (await e.v2.operation(uuid))!['operation']['contenu']['autorisations'];
    expect(await authorizations(approved.uuid), [
      {'type': 'remise', 'approbateur_id': '9', 'motif': 'Client fidèle', 'preuve': 'code_local|${approval.verifiedAt}'},
    ]);
    final unneeded = await sell(40, awa, approval: approval);
    expect(await authorizations(unneeded.uuid), isEmpty, reason: 'dans le seuil du caissier : aucune autorisation inscrite');

    // Adaptateur : la vue annonce l'autorisation, commitSale la reçoit.
    await adapter.execute('clear', {}, null);
    await adapter.execute('login', {'operator_id': 7, 'pin': '1234'}, null);
    await adapter.execute('scan', {'code': '6190000000011'}, null);
    final scanned = await adapter.execute('scan', {'code': '6190000000011'}, null);
    final lineId = ((scanned['lines'] as List).single as Map)['id'];
    final discounted = await adapter.execute('setLineDiscount', {'line_id': lineId, 'amount': 70}, null);
    expect(discounted['discount_approval'], {
      'required': true,
      'approvers': [{'id': 9, 'name': 'Chef'}],
    });
    await adapter.execute('setPayment', {'method': 'especes', 'received': 930}, null);
    const operation = 'aaaaaaaa-bbbb-4ccc-8ddd-0000000000e2';
    await expectLater(adapter.execute('commitSale', {}, operation), throwsA(isA<AdapterFailure>().having((f) => f.code, 'code', 'autorisation_requise')));
    await expectLater(
      adapter.execute('commitSale', {'approval': {'approver_id': 9, 'code': '00000000', 'reason': 'Client fidèle'}}, operation),
      throwsA(isA<AdapterFailure>().having((f) => f.code, 'code', 'autorisation_refusee')),
    );
    final committed = await adapter.execute('commitSale', {'approval': {'approver_id': 9, 'code': '12345678', 'reason': 'Client fidèle'}}, operation);
    expect(committed['state'], 'committed');
    expect((await authorizations(operation) as List).single, containsPair('approbateur_id', '9'));

    // Lot 2 : clients. Première obtention de client.lecture : nouvel instantané, une fois.
    const publishedCustomer = 'c1000000-0000-4000-8000-000000000001';
    server
      ..capabilities = [...server.capabilities, 'client.lecture', 'client.creation']
      ..put('client', publishedCustomer, {'nom': 'Éléonore Koné', 'telephone': '+2250707070707', 'type': 'particulier', 'tarif': 'detail', 'actif': true})
      ..put('client', 'c1000000-0000-4000-8000-000000000002', {'nom': 'Client de passage', 'telephone': null, 'type': 'passage', 'tarif': 'detail', 'actif': true});
    expect(e.customersSupported, isFalse);
    final snapshotsBefore = server.snapshotReasons.length;
    await e.sync();
    expect(e.blockReason, isNull);
    await e.sync();
    expect(server.snapshotReasons.skip(snapshotsBefore), ['reparation'], reason: 'un seul instantané pour les clients');
    expect(e.customersSupported, isTrue);
    expect([for (final c in await e.searchCustomers('')) c.name], ['Éléonore Koné'], reason: 'le client de passage n’est pas proposé');
    expect((await e.searchCustomers('eleonore')).single.uuid, publishedCustomer);
    expect((await e.searchCustomers('07 07')).single.uuid, publishedCustomer);

    final cashier = e.snapshot!.operators.firstWhere((o) => o.id == 7);
    await expectLater(e.createCustomer(cashier, name: 'Nouveau'), refused('n’a pas le droit de créer un client'));
    server.publish([
      {'type': 'operateur', 'critique': true, 'cle': 'operateur:7', 'revision': '3', 'action': 'upsert',
       'donnees': operateur21('7', 'Awa', 'empreinte', ['clients_creer', 'ouverture_session', 'remise', 'vente'], '5.000000', 40)},
    ]);
    await e.sync();
    final creator = e.snapshot!.operators.firstWhere((o) => o.id == 7);
    expect(e.canCreateCustomer(creator), isTrue);
    await expectLater(e.createCustomer(creator, name: 'Sans nom', phone: 'abc'), refused('illisible'));
    expect((await e.createCustomer(creator, name: 'Doublon', phone: '07 07 07 07 07')).uuid, publishedCustomer, reason: 'même téléphone : fiche existante');
    final created = await e.createCustomer(creator, name: '  Bintou  ', phone: '05 05 05 05 05', operationUuid: 'aaaaaaaa-bbbb-4ccc-8ddd-0000000000f1');
    expect((created.name, created.pending), ('Bintou', true));
    final replay = await e.createCustomer(creator, name: 'Bintou', operationUuid: 'aaaaaaaa-bbbb-4ccc-8ddd-0000000000f1');
    expect(replay.uuid, created.uuid);
    expect((await e.searchCustomers('bintou')).single.pending, isTrue);

    final customerSale = await e.recordSale([savon(e)], [CartPayment(method: cashMethod, amount: 500, received: 500)], creator, extras: SaleExtras(customer: created));
    final saleContent = (await e.v2.operation(customerSale.uuid))!['operation']['contenu'] as Map;
    expect([saleContent['client_uuid'], saleContent['client_nom']], [created.uuid, 'Bintou']);
    expect(customerSale.content['client_nom'], 'Bintou');
    await expectLater(
      e.recordSale([savon(e)], [CartPayment(method: cashMethod, amount: 500, received: 500)], creator, extras: const SaleExtras(customer: Customer(uuid: 'c1000000-0000-4000-8000-0000000000ff', name: 'Inconnu'))),
      refused('plus disponible'),
    );
    await e.sync();
    final order = [for (final r in server.received.values) (r['operation'] as Map)['type']];
    expect(order.indexOf('creation_client') < order.lastIndexOf('vente'), isTrue, reason: 'la création précède la vente qui la cite');
    expect((await e.searchCustomers('bintou')).single.uuid, created.uuid, reason: 'intégrée, pas encore revenue par le journal : reste choisissable');
    server.publish([
      {'type': 'client', 'critique': false, 'cle': 'c1000000-0000-4000-8000-0000000000f2', 'revision': '9', 'action': 'upsert',
        'donnees': {'nom': 'Bintou Traoré', 'telephone': '+2250505050505', 'type': 'particulier', 'tarif': 'detail', 'actif': true}},
    ]);
    await e.sync();
    expect((await e.searchCustomers('bintou')).single.uuid, 'c1000000-0000-4000-8000-0000000000f2', reason: 'fiche fusionnée : même téléphone, aucun doublon');
    final afterMerge = await e.recordSale([savon(e)], [CartPayment(method: cashMethod, amount: 500, received: 500)], creator, extras: SaleExtras(customer: created));
    expect(afterMerge.isSale, isTrue, reason: 'l’uuid du terminal reste accepté');

    // Adaptateur : client du panier conservé et transmis à la vente.
    final found = await adapter.execute('searchCustomers', {'query': 'koné'}, null);
    expect(((found['customers'] as List).single as Map)['uuid'], publishedCustomer);
    await adapter.execute('scan', {'code': '6190000000011'}, null);
    final withCustomer = await adapter.execute('setCustomer', {'uuid': publishedCustomer, 'name': 'Éléonore Koné'}, null);
    expect((withCustomer['customer'] as Map)['name'], 'Éléonore Koné');
    await adapter.execute('setPayment', {'method': 'especes', 'received': 500}, null);
    await adapter.execute('commitSale', {}, 'aaaaaaaa-bbbb-4ccc-8ddd-0000000000e3');
    expect((await e.v2.operation('aaaaaaaa-bbbb-4ccc-8ddd-0000000000e3'))!['operation']['contenu']['client_uuid'], publishedCustomer);

    // Lot 3 : clôture à l'aveugle, droit et capacité exigés, session fermée sans attendre le serveur, Z conservé.
    final noRight = e.snapshot!.operators.firstWhere((o) => o.id == 7);
    expect(e.canCloseSession(noRight), isFalse);
    await expectLater(e.closeSession(noRight, cash: 1000), refused('non disponible'));
    server.capabilities = [...server.capabilities, 'session.cloture'];
    server.publish([
      {'type': 'operateur', 'critique': true, 'cle': 'operateur:7', 'revision': '4', 'action': 'upsert',
       'donnees': operateur21('7', 'Awa', 'empreinte', ['caisse_cloturer', 'clients_creer', 'ouverture_session', 'remise', 'vente'], '5.000000', 40)},
      {'type': 'politique', 'critique': false, 'cle': 'session.ouverture_locale', 'revision': '2', 'action': 'upsert',
       'donnees': {'cle_politique': 'session.ouverture_locale', 'valeur': true, 'source': 'boutique', 'verrouillee': false}},
    ]);
    await e.sync();
    final closer = e.snapshot!.operators.firstWhere((o) => o.id == 7);
    expect(e.canCloseSession(closer), isTrue);
    await expectLater(adapter.execute('closeSession', {'cash': 0}, null), completes);
    expect(e.sessionOpen, isFalse, reason: 'fermée sur le terminal avant toute réponse du serveur');
    final closure = await e.lastClosure();
    expect(closure!.content['session_uuid'], fakeSession);
    expect(closure.content['commentaire'], isNull, reason: 'session ouverte en ligne : attendu inconnu, commentaire facultatif');
    server.resultDetails = (op) => op['type'] == 'cloture_session'
        ? {'z': {'cloture_uuid': 'c2000000-0000-4000-8000-000000000001', 'compte': 0, 'theorique': 0, 'ecart': 0, 'mode': 'V1'}}
        : null;
    await e.sync();
    expect((await e.lastClosure())!.content['z'], containsPair('mode', 'V1'));
    expect(e.sessionOpen, isFalse, reason: 'intégrée : pas de réouverture avant la publication de la session close');

    // Session ouverte sur ce terminal : attendu connu, l'écart exige un commentaire, jamais de montant rendu.
    await e.openSession(1000, closer);
    final cashSale = await e.recordSale([savon(e)], [CartPayment(method: cashMethod, amount: 500, received: 500)], closer);
    expect(cashSale.isSale, isTrue);
    expect((await e.closingGaps(1500, const [])).cash, isFalse);
    expect((await e.closingGaps(1400, const [])).cash, isTrue);
    await expectLater(e.closeSession(closer, cash: 1400), refused('indiquez un commentaire'));
    await expectLater(e.closeSession(closer, cash: 1500, others: const [SessionCount(method: 'wave', amount: 300)]), refused('justification'));
    await e.closeSession(closer, cash: 1400, comment: 'Erreur de monnaie');
    expect(e.sessionOpen, isFalse);
    server.verdict = (op) => op['type'] == 'cloture_session' ? 'a_arbitrer' : 'integree';
    await e.sync();
    await expectLater(e.openSession(0, closer), refused('arbitrage'));
    server.verdict = null;

    // Lot 4 : paniers partagés. Première obtention : un instantané ; seul le panier de ce point de vente est listé.
    const webCart = 'ca000000-0000-4000-8000-000000000001';
    const otherShopCart = 'ca000000-0000-4000-8000-000000000002';
    Map<String, dynamic> panier(List<String> terminaux, {int prix = 450}) => {
      'etat': 'en_attente', 'libelle': 'Table 4', 'auteur_operateur_id': '7', 'terminal_origine_uuid': fakeTerminal, 'terminaux': terminaux, 'repris_par': null,
      'contenu': {
        'lignes': [
          {'produit_uuid': fakeSavon, 'conditionnement_uuid': null, 'libelle': 'Savon', 'quantite': '2.000000', 'coefficient': '1.000000', 'prix_unitaire': prix, 'remise': 0},
        ],
        'client_uuid': null, 'client_nom': null, 'remise_globale': 0, 'livraison': 0, 'note': 'À livrer', 'tarif': 'detail',
      },
      'cree_le': '2026-10-29T07:00:00Z', 'modifie_le': '2026-10-29T07:00:00Z',
    };
    final before4 = server.snapshotReasons.length;
    server
      ..capabilities = [...server.capabilities, 'panier.partage']
      ..put('panier', webCart, panier([fakeTerminal]))
      ..put('panier', otherShopCart, panier(['0d000000-0000-4000-8000-0000000000ff']));
    await e.sync();
    await e.sync();
    expect(e.blockReason, isNull);
    expect(server.snapshotReasons.skip(before4), ['reparation']);
    expect((await e.sharedCarts()).map((c) => c.uuid), [webCart]);
    // Suppression demandée ici : retiré de la liste aussitôt, même si le journal ne l'a pas encore confirmée.
    const gone = '0e000000-0000-4000-8000-000000000002';
    server.publish([{'type': 'panier', 'critique': false, 'cle': gone, 'revision': '9', 'action': 'upsert', 'donnees': panier([fakeTerminal])}]);
    await e.sync();
    expect((await e.sharedCarts()).map((c) => c.uuid), contains(gone));
    await e.deleteSharedCart(e.snapshot!.operators.first, gone);
    expect((await e.sharedCarts()).map((c) => c.uuid), isNot(contains(gone)));

    // Reprise : prix figé du panier, conservé dans la vente, panier consommé.
    server.takenElsewhere.add(webCart);
    await expectLater(e.takeSharedCart(closer, webCart), refused('déjà repris'));
    server.takenElsewhere.clear();
    final held = await e.takeSharedCart(closer, webCart);
    expect([held.ref.claimed, held.lines.single.unitPrice, held.lines.single.quantity, held.note], [isTrue, 450, BigInt.from(2000000), 'À livrer']);
    await e.sync();
    expect(server.taken.length, 2, reason: 'reprise renouvelée à la synchronisation');

    // Vente au prix figé : la clôture en arbitrage est d'abord résolue, la session du serveur reste ouverte.
    final stuck = (await e.lastClosure())!.uuid;
    server.received[stuck]!..['etat'] = 'resolue'..['version'] = 2;
    await e.sync();
    expect(e.sessionOpen, isTrue);
    final frozen = await e.recordSale(held.lines, [CartPayment(method: cashMethod, amount: 900, received: 900)], closer, extras: const SaleExtras(sharedCart: webCart));
    final frozenContent = (await e.v2.operation(frozen.uuid))!['operation']['contenu'] as Map;
    expect([(frozenContent['lignes'] as List).single['prix_unitaire'], frozenContent['panier_uuid']], [450, webCart]);
    // Suspendu de nouveau : nouvel uuid, remplace l'ancien repris ; non repris : suppression explicite d'abord.
    final replaced = await e.suspendShared(closer, held.lines, const SaleExtras(), previous: held.ref);
    expect(replaced.uuid, isNot(webCart));
    final replacedContent = (await e.v2.operation(replaced.uuid))!['operation']['contenu'] as Map;
    expect(replacedContent['remplace_uuid'], webCart);
    final again = await e.suspendShared(closer, held.lines, const SaleExtras(), previous: replaced);
    expect(((await e.v2.operation(again.uuid))!['operation']['contenu'] as Map)['remplace_uuid'], isNull);
    final types = [for (final r in (await e.v2.operationRows()).take(2)) (r['operation'] as Map)['type']];
    expect(types, ['panier_suspendre', 'panier_supprimer']);
    expect(await e.sharedCartState(again.uuid), 'local');

    await e.sync();
    expect(await e.sharedCartState(again.uuid), 'local', reason: 'intégré, pas encore revenu par le journal : la copie locale reste');
    await e.v2.db.update('v2_operations', {'maj_le': '2020-01-01T00:00:00Z'}, where: 'uuid = ?', whereArgs: [again.uuid]);
    expect(await e.sharedCartState(again.uuid), 'disparu', reason: 'toujours absent après le délai : vendu ou supprimé ailleurs');

    // Lot 5 : retours fermés par défaut ; ouverts par la capacité, la politique et les droits.
    expect(e.returnsOpen(closer), isFalse);
    await expectLater(e.recordReturn(closer, frozen.uuid, const {}, 'x'), refused('non autorisé'));
    Map<String, dynamic> politique(String cle, Object valeur) => {
      'type': 'politique', 'critique': false, 'cle': cle, 'revision': '3', 'action': 'upsert',
      'donnees': {'cle_politique': cle, 'valeur': valeur, 'source': 'boutique', 'verrouillee': false},
    };
    server.capabilities = [...server.capabilities, 'retour.especes'];
    server.publish([
      politique('retours.mode', 'especes'),
      politique('retours.max_montant', 500),
      politique('retours.delai_jours', 1),
      {'type': 'operateur', 'critique': true, 'cle': 'operateur:7', 'revision': '5', 'action': 'upsert',
       'donnees': operateur21('7', 'Awa', 'empreinte', ['caisse_cloturer', 'clients_creer', 'ouverture_session', 'remise', 'retour_creer', 'retour_rembourser_especes', 'vente'], '5.000000', 40)},
    ]);
    await e.sync();
    expect(e.blockReason, isNull);
    final refunder = e.snapshot!.operators.firstWhere((o) => o.id == 7);
    expect(e.returnsOpen(refunder), isTrue);
    final line = (await e.returnableLines(frozen.uuid)).single;
    expect(line.remaining, 2000000);
    expect(await e.returnAmount(frozen.uuid, {line.lineUuid: 1000000}), 450);
    await expectLater(e.recordReturn(refunder, frozen.uuid, {line.lineUuid: 1000000}, '  '), refused('motif'));
    await expectLater(e.recordReturn(refunder, frozen.uuid, {line.lineUuid: 2000000}, 'Abîmé'), refused('limité'));
    await expectLater(e.returnAmount(frozen.uuid, {line.lineUuid: 3000000}), refused('dépasse'));
    final stockBefore = (await e.soldSinceSnapshot()).values.fold<BigInt>(BigInt.zero, (a, b) => a + b);
    final refund = await e.recordReturn(refunder, frozen.uuid, {line.lineUuid: 1000000}, 'Abîmé');
    final refundContent = (await e.v2.operation(refund.uuid))!['operation']['contenu'] as Map;
    expect(refundContent['montant'], 450);
    expect((refundContent['mouvements'] as List).single['variation'], '1.000000');
    expect((await e.soldSinceSnapshot()).values.fold<BigInt>(BigInt.zero, (a, b) => a + b), stockBefore - BigInt.from(1000000), reason: 'stock remis localement');
    expect((await e.returnableLines(frozen.uuid)).single.remaining, 1000000);
    final viaAdapter = await adapter.execute('previewReturn', {'sale_id': frozen.uuid, 'lines': [{'line_id': line.lineUuid, 'quantity': '1'}]}, null);
    expect(viaAdapter['amount'], 450);

    // Parts qui ne tombent pas juste (remise globale répartie sur deux lignes) : la règle de reste n'est pas publiée, le terminal ne rend rien.
    server.publish([politique('remises.globale_max_pourcent', 50)]);
    await e.sync();
    final emballage = e.snapshot!.products.firstWhere((p) => p.name == 'Emballage');
    final split = await e.recordSale(
      [CartLine(product: emballage), CartLine(product: emballage)],
      [CartPayment(method: cashMethod, amount: 199, received: 199)],
      refunder,
      extras: const SaleExtras(globalDiscount: 1),
    );
    await expectLater(e.returnableLines(split.uuid), refused('faites-le en ligne'));
    // Règle publiée : le même retour se chiffre sur le terminal.
    server.publish([
      {'type': 'boutique', 'critique': true, 'cle': fakeShop, 'revision': '9', 'action': 'upsert', 'donnees': {
        ...(server.entities['boutique|$fakeShop']!['donnees'] as Map<String, dynamic>),
        'regles': {...(server.entities['boutique|$fakeShop']!['donnees'] as Map)['regles'] as Map, 'retour_residuel': 'largest_fraction'},
      }},
    ]);
    await e.sync();
    expect(e.blockReason, isNull, reason: 'clé acceptée par le schéma');
    final splitLines = await e.returnableLines(split.uuid);
    expect(await e.returnAmount(split.uuid, {splitLines.first.lineUuid: 1000000}), 100);
    expect(await e.returnAmount(split.uuid, {splitLines.last.lineUuid: 1000000}), 99);
    // Règles de reste, comme ReturnService : net 100 sur trois lignes égales, parts arrondies 33 × 3 ; net 200 : 67 × 3 = 201.
    expect(archivedShares(100, [1, 1, 1], null), isNull, reason: 'règle non publiée');
    expect(archivedShares(100, [1, 1, 1], 'refuse'), [33, 33, 33], reason: 'parts sous le net : le serveur les garde');
    expect(archivedShares(100, [1, 1, 1], 'largest_fraction'), [34, 33, 33]);
    expect(archivedShares(200, [1, 1, 1], 'refuse'), isNull);
    expect(archivedShares(200, [1, 1, 1], 'last_line'), [66, 66, 68]);
    expect(archivedShares(200, [1, 1, 1], 'largest_share'), [68, 66, 66]);
    expect(archivedShares(200, [1, 1, 1], 'largest_fraction'), [67, 67, 66]);
    expect(archivedShares(90, [1, 2], 'refuse'), [30, 60], reason: 'parts exactes : la règle ne joue pas');
    // Arrondi demi vers le haut, cumul par ligne : 333 + 334 + 333.
    expect(archivedShare(100, 33, 99), 33);
    expect(archivedShare(1000, 1, 3), 333);
    expect(returnedAmount(1000, 1000000, 1000000, 3000000), 334);
    await adapter.close();
  });

  test('images : téléchargées hors vente, empreinte vérifiée, 429 respecté, fichiers périmés retirés', () async {
    final cache = Directory.systemTemp.createTempSync('images_');
    var moment = DateTime.now();
    addTearDown(() => cache.deleteSync(recursive: true));
    const uuid = '0d000000-0000-4000-8000-000000000001';
    final bytes = utf8.encode('image jpeg');
    final hash = sha256.convert(bytes).toString();
    serve21(server);
    server.put('produit', fakeSavon, {
      ...(server.entities['produit|$fakeSavon']!['donnees'] as Map).cast<String, dynamic>(),
      'image': {'uuid': uuid, 'empreinte': hash, 'octets': bytes.length, 'largeur': 10, 'hauteur': 10},
    });
    File(p.join(cache.path, '${'b' * 64}.jpg')).writeAsBytesSync([1]);
    final e = V2Engine.onStore(base, transport: server, appVersion: 'essai', platform: 'windows', newUuid: newUuid,
        pinVerifier: FakeV2Server.pinVerifier, contract21: true, imageDirectory: cache.path, clock: () => moment);
    await e.load('https://boutique.exemple.ci');
    expect(await e.pair('ABCD-EFGH', model: 'x', appVersion: 'essai'), isNull);
    await e.sync();
    final image = e.snapshot!.products.firstWhere((x) => x.image != null).image!;
    expect(e.imagePath(image), isNull);

    // Contenu altéré : jamais gardé.
    server.images[uuid] = utf8.encode('autre contenu');
    expect(await e.downloadImages(), 0);
    expect(e.imagePath(image), isNull);

    // 429 : pause, aucune autre requête d'image avant la fin du délai.
    server.imageStatus = 429;
    expect(await e.downloadImages(), 0);
    final calls = server.requests.length;
    server.imageStatus = null;
    server.images[uuid] = bytes;
    expect(await e.downloadImages(), 0);
    expect(server.requests.length, calls);

    // Après le délai : téléchargée une seule fois, fichier périmé retiré.
    moment = moment.add(const Duration(seconds: 31));
    expect(await e.downloadImages(), 1);
    expect(File(e.imagePath(image)!).readAsBytesSync(), bytes);
    expect(File(p.join(cache.path, '${'b' * 64}.jpg')).existsSync(), isFalse);
    expect(await e.downloadImages(), 0);
  });

  test('images : plage horaire configurée, lot arrêté dès que la vente commence', () async {
    final cache = Directory.systemTemp.createTempSync('images_');
    var moment = DateTime.now();
    addTearDown(() => cache.deleteSync(recursive: true));
    const uuid = '0d000000-0000-4000-8000-000000000001';
    final bytes = utf8.encode('image jpeg');
    server.images[uuid] = bytes;
    serve21(server);
    server.put('produit', fakeSavon, {
      ...(server.entities['produit|$fakeSavon']!['donnees'] as Map).cast<String, dynamic>(),
      'image': {'uuid': uuid, 'empreinte': sha256.convert(bytes).toString(), 'octets': bytes.length, 'largeur': 10, 'hauteur': 10},
    });
    final e = V2Engine.onStore(base, transport: server, appVersion: 'essai', platform: 'windows', newUuid: newUuid,
        pinVerifier: FakeV2Server.pinVerifier, contract21: true, imageDirectory: cache.path, clock: () => moment);
    await e.load('https://boutique.exemple.ci');
    expect(await e.pair('ABCD-EFGH', model: 'x', appVersion: 'essai'), isNull);
    await e.sync();
    final adapter = LocalRegisterAdapter(e, newUuid: newUuid);
    await adapter.start();
    final hour = moment.hour;
    String at(int hours) => '${((hour + hours) % 24).toString().padLeft(2, '0')}:00';

    await expectLater(adapter.execute('setImageSettings', {'start': '25:00', 'end': '06:00'}, null),
        throwsA(isA<AdapterFailure>().having((f) => f.code, 'code', 'reglage_refuse')));
    final settings = await adapter.execute('setImageSettings', {'start': at(1), 'end': at(2)}, null);
    expect(settings, {'start': at(1), 'end': at(2), 'images_cached': 0, 'images_total': 1});

    // Hors plage : aucune requête, réglage relu après relance du moteur.
    final calls = server.requests.length;
    expect(await e.downloadImages(), 0);
    expect(server.requests.length, calls);
    final reloaded = V2Engine.onStore(base, transport: server, appVersion: 'essai', platform: 'windows', newUuid: newUuid,
        pinVerifier: FakeV2Server.pinVerifier, contract21: true, imageDirectory: cache.path, clock: () => moment);
    await reloaded.load('https://boutique.exemple.ci');
    expect(reloaded.imageWindow, e.imageWindow);
    expect(reloaded.saleExtrasSupported, isTrue, reason: 'redémarrage hors connexion : contrat 2.1 conservé');

    // Dans la plage : le panier repris arrête le lot avant la requête.
    moment = moment.add(const Duration(hours: 1));
    expect(await e.downloadImages(interrupted: () => true), 0);
    expect(server.requests.length, calls);
    expect(await e.downloadImages(interrupted: () => false), 1);

    // Plage retirée : à toute heure, comme avant.
    expect((await adapter.execute('setImageSettings', {}, null))['images_cached'], 1);
    expect(e.imageWindow, isNull);
    await adapter.close();
  });

  test('contrat 2.1 (lot 1b) : remise %, remise globale, livraison, note, arrondi espèces — intégrée au franc près', () async {
    // En 2.0 : remise globale, livraison et note indisponibles, avec le motif.
    final legacy = await paired();
    final legacyAdapter = LocalRegisterAdapter(legacy, newUuid: newUuid);
    await legacyAdapter.start();
    final legacyCaps = (await legacyAdapter.execute('status', {}, null))['capabilities'] as Map;
    expect(legacyCaps['global_discount']['reason'], contains('contrat 2.1'));
    await expectLater(legacyAdapter.execute('setNote', {'text': 'x'}, null),
        throwsA(isA<AdapterFailure>().having((f) => f.code, 'code', 'fonction_indisponible')));
    await legacyAdapter.close();


    // Boutique en 2.1 : TVA 18 % ajoutée, pourcentages au franc inférieur, espèces arrondies à 25 F au plus proche.
    serve21(server, vatIncluded: false, rules: {'remise_pourcentage_arrondi': 'down', 'arrondi_especes': {'pas': 25, 'mode': 'nearest'}});
    server.cashRounding = (step: 25, mode: 'nearest');
    final e = V2Engine.onStore(base, transport: server, appVersion: 'essai', platform: 'windows', newUuid: newUuid,
        pinVerifier: FakeV2Server.pinVerifier, declaredPayments: true, contract21: true);
    await e.load('https://boutique.exemple.ci');
    await e.sync();
    expect(e.saleExtrasSupported, isTrue);
    expect(e.snapshot!.rules.maxGlobalDiscountPercent, 5);

    final adapter = LocalRegisterAdapter(e, newUuid: newUuid);
    await adapter.start();
    await adapter.execute('login', {'operator_id': 7, 'pin': '1234'}, null);
    for (var i = 0; i < 3; i++) {
      await adapter.execute('scan', {'code': '6190000000011'}, null);
    }
    await adapter.execute('search', {'query': 'Emballage'}, null);
    final serviceId = ((await adapter.execute('view', {}, null))['products'] as List).single['id'] as int;
    var view = await adapter.execute('addProduct', {'product_id': serviceId}, null);
    final serviceLine = (view['lines'] as List).firstWhere((l) => l['name'] == 'Emballage')['id'] as String;
    await adapter.execute('changeQuantity', {'line_id': serviceLine, 'quantity': '5'}, null);
    view = await adapter.execute('setLineDiscount', {'line_id': serviceLine, 'percent': '10'}, null);
    expect((view['lines'] as List).firstWhere((l) => l['id'] == serviceLine)['discount'], 50);
    // Plafond global = politique remises.globale_max_pourcent (5 %), pas celle des lignes (10 %).
    await expectLater(adapter.execute('setGlobalDiscount', {'percent': '6'}, null),
        throwsA(isA<AdapterFailure>().having((f) => f.code, 'code', 'remise_refusee')));
    await adapter.execute('setGlobalDiscount', {'percent': '5,0'}, null);
    await adapter.execute('setDelivery', {'amount': 300}, null);
    view = await adapter.execute('setNote', {'text': 'Livrer à Cocody'}, null);

    // Sous-total 1 950 ; remise globale tronqué(97,5) = 97 ; X = 1 853 ; TVA arrondi(333,54) = 334 ; + 300 = 2 487.
    var totals = view['totals'] as Map;
    expect([totals['gross_label'], totals['discounts_label'], totals['global_discount_label'], totals['vat_label'], totals['delivery_label'], totals['payable_label']],
        ['1 950 F', '50 F', '97 F', '334 F', '300 F', '2 487 F']);
    expect([view['note'], (view['global_discount_entry'] as Map)['valeur']], ['Livrer à Cocody', '5']);

    // Pourcentages recalculés quand la quantité change (comme le web).
    view = await adapter.execute('changeQuantity', {'line_id': serviceLine, 'quantity': '6'}, null);
    expect((view['lines'] as List).firstWhere((l) => l['id'] == serviceLine)['discount'], 60);
    expect((view['totals'] as Map)['global_discount_label'], '102 F', reason: 'tronqué(5 % de 2 040)');
    view = await adapter.execute('changeQuantity', {'line_id': serviceLine, 'quantity': '5'}, null);
    expect((view['totals'] as Map)['payable_label'], '2 487 F');

    // Espèces : montant exact 2 487, tiroir 2 475 (reste 12 ; 24 ≤ 25 → bas), reçu 3 000 → monnaie 525.
    view = await adapter.execute('setPayment', {'method': 'especes', 'received': 3000}, null);
    final payment = view['payment'] as Map;
    expect([payment['amount_label'], payment['cash_due_label'], payment['rounding_label'], payment['change_label']], ['2 487 F', '2 475 F', '-12 F', '525 F']);
    expect(view['change'], 525);

    final sale = await adapter.execute('commitSale', {}, 'aaaaaaaa-bbbb-4ccc-8ddd-0000000000f1');
    expect(sale['total'], 2487);
    final op = (await e.v2.operation('aaaaaaaa-bbbb-4ccc-8ddd-0000000000f1'))!['operation'] as Map;
    final content = op['contenu'] as Map;
    expect((op['versions'] as Map)['calcul'], '2');
    expect(content['totaux'], {'brut': 2000, 'remises': 147, 'base_ht': 1853, 'tva': 334, 'a_payer': 2487});
    expect([content['remise_globale'], content['remise_globale_saisie'], content['livraison'], content['note']],
        [97, {'type': 'pourcentage', 'valeur': '5'}, 300, 'Livrer à Cocody']);
    final lines = (content['lignes'] as List).cast<Map>();
    expect(lines.firstWhere((l) => l['remise'] == 50)['remise_saisie'], {'type': 'pourcentage', 'valeur': '10'});
    final cashPayment = (content['paiements'] as List).single as Map;
    expect([cashPayment['montant'], cashPayment['recu'], cashPayment['monnaie'], cashPayment['ecart_arrondi']], [2487, 3000, 525, -12]);

    // Ticket local : la monnaie est celle rendue sur le montant arrondi, pas sur le montant exact.
    final ticket = await adapter.execute('reprint', {}, 'aaaaaaaa-bbbb-4ccc-8ddd-0000000000f1');
    expect((ticket['lines'] as List).join(' '), contains('525'));

    // Le serveur (recoupement de CoherenceVente 4bb14454) l'intègre.
    await e.sync();
    expect((await e.saleStatus('aaaaaaaa-bbbb-4ccc-8ddd-0000000000f1'))!.serverStatus, 'integree');

    // Politique remises.globale_max_pourcent ramenée à 0 : remise globale grisée avec le motif de A.
    server.publish([
      {
        'type': 'politique', 'critique': false, 'cle': 'remises.globale_max_pourcent', 'revision': '2', 'action': 'upsert',
        'donnees': {'cle_politique': 'remises.globale_max_pourcent', 'valeur': 0, 'source': 'boutique', 'verrouillee': false},
      },
    ]);
    await e.sync();
    final caps = (await adapter.execute('status', {}, null))['capabilities'] as Map;
    expect(caps['global_discount']['reason'], 'Remise globale non autorisée hors ligne dans cette boutique.');
    await adapter.close();
  });
}

/// Catalogue de la boutique d'essai en forme 2.1 (lot 1a), règles commerciales [rules] fusionnées aux défauts.
void serve21(FakeV2Server server, {bool vatIncluded = true, Map<String, dynamic> rules = const {}, int globalMaxPercent = 5}) {
  Map<String, dynamic> product(String nom, String? ref, int prix, bool illimite) => {
    'nom': nom, 'reference': ref, 'categorie': null, 'prix': prix, 'stock_illimite': illimite, 'actif': true, 'vente_locale': true,
    'categorie_uuid': null, 'marque': null, 'fournisseur': null, 'unite': null,
    'prix_gros': null, 'gros_quantite_min': null, 'seuil_alerte': null, 'cree_le': null, 'favori': false, 'promotions': <Map<String, dynamic>>[], 'image': null,
  };
  server
    ..capabilities = ['instantane.v1', 'stock.couverture', 'vente.especes', 'vente.paiement_declare', 'contrat.2_1']
    ..put('boutique', fakeShop, {
      'nom': 'Boutique', 'devise': 'FCFA', 'tva_taux': '18.000000', 'tva_incluse': vatIncluded,
      'regles': {
        'remise_pourcentage_arrondi': 'down', 'arrondi_especes': null, 'trop_percu': 'refuse', 'moins_a_un': 'refuse',
        'livraison_droit': null, 'ouverture_session': 'automatic', 'survente': 'refuse',
        'gros': {'actif': false, 'mode': 'cart', 'quantite_min': null, 'droit': null, 'remises': 'refuse', 'prix_lot': 'refuse'},
        'fuseau': 'Africa/Abidjan', 'nouveau_jours': null,
        ...rules,
      },
      'ticket': {'raison_sociale': null, 'adresse': null, 'telephone': null, 'ncc': null, 'entete': null, 'pied': null, 'largeur_papier': 80},
      'devise_secondaire': null,
    }, critical: true)
    ..put('produit', fakeSavon, product('Savon', 'SAV', 500, false))
    ..put('produit', fakeService, product('Emballage', null, 100, true))
    ..put('conditionnement', fakePack, {'produit_uuid': fakeSavon, 'nom': 'Carton de 12', 'coefficient': '12.000000', 'prix': 5500, 'defaut': false, 'actif': true, 'prix_gros': null})
    ..put('moyen_paiement', 'moyen:especes', {'code': 'especes', 'nom': 'Espèces', 'especes': true, 'local': true, 'reference': 'aucune'})
    ..put('politique', 'remises.ligne_max_pourcent', {'cle_politique': 'remises.ligne_max_pourcent', 'valeur': 10, 'source': 'boutique', 'verrouillee': false})
    ..put('politique', 'remises.globale_max_pourcent', {'cle_politique': 'remises.globale_max_pourcent', 'valeur': globalMaxPercent, 'source': 'boutique', 'verrouillee': false})
    ..put('operateur', 'operateur:7', {
      'operateur_id': '7', 'nom': 'Awa', 'pin_empreinte': 'empreinte', 'droits': ['ouverture_session', 'remise', 'vente'],
      'remise_max_pourcent': null, 'remise_max_montant': null, 'approbateur_remise': false,
    }, critical: true)
    ..put('operateur', 'operateur:8', {
      'operateur_id': '8', 'nom': 'Stagiaire', 'pin_empreinte': null, 'droits': <String>[],
      'remise_max_pourcent': null, 'remise_max_montant': null, 'approbateur_remise': false,
    });
}
