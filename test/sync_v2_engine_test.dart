import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shopikaiss_terminal/src/offline/engine.dart';
import 'package:shopikaiss_terminal/src/offline/models.dart';
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
    // Intégrée : la session locale cède la place à celle du serveur (fermée ici : aucune publiée).
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
      'prix_gros': null, 'gros_quantite_min': null, 'seuil_alerte': null, 'cree_le': null,
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
          'fuseau': 'Africa/Abidjan',
        },
        'ticket': {'raison_sociale': null, 'adresse': null, 'telephone': null, 'ncc': null, 'entete': null, 'pied': null, 'largeur_papier': 80},
        'devise_secondaire': {'libelle': 'EUR', 'taux': '655.957000'},
      }, critical: true)
      ..put('categorie', hygiene, {'nom': 'Hygiène', 'ordre': 2, 'actif': true})
      ..put('categorie', services, {'nom': 'Services', 'ordre': 1, 'actif': true})
      ..put('produit', fakeSavon, produit21('Savon', 'SAV', 500, false, hygiene, 'Dove'))
      ..put('produit', fakeService, produit21('Emballage', null, 100, true, services, null))
      ..put('conditionnement', fakePack, {'produit_uuid': fakeSavon, 'nom': 'Carton de 12', 'coefficient': '12.000000', 'prix': 5500, 'defaut': false, 'actif': true, 'prix_gros': null})
      ..put('moyen_paiement', 'moyen:especes', {'code': 'especes', 'nom': 'Espèces', 'especes': true, 'local': true, 'reference': 'aucune'})
      ..put('moyen_paiement', 'moyen:wave', {'code': 'wave', 'nom': 'Wave', 'especes': false, 'local': true, 'reference': 'obligatoire'})
      ..put('politique', 'paiements.moyens_locaux', {'cle_politique': 'paiements.moyens_locaux', 'valeur': ['especes', 'wave'], 'source': 'boutique', 'verrouillee': false})
      ..put('operateur', 'operateur:7', operateur21('7', 'Awa', 'empreinte', ['ouverture_session', 'remise', 'vente'], '5.000000', 40), critical: true)
      ..put('operateur', 'operateur:8', operateur21('8', 'Stagiaire', null, <String>[], null, null));

    final e = V2Engine.onStore(base, transport: server, appVersion: 'essai', platform: 'windows', newUuid: newUuid,
        pinVerifier: FakeV2Server.pinVerifier, declaredPayments: true, contract21: true);
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
    final prepared = await adapter.execute('preparePayment', {}, null);
    expect([for (final m in prepared['methods'] as List) m['reference']]..sort(), ['aucune', 'obligatoire']);
    await adapter.close();
  });
}
