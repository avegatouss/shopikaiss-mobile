import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:shopikaiss_terminal/src/offline/engine.dart';
import 'package:shopikaiss_terminal/src/offline/local_prices.dart';
import 'package:shopikaiss_terminal/src/offline/models.dart';
import 'package:shopikaiss_terminal/src/offline/receipt_settings.dart';
import 'package:shopikaiss_terminal/src/offline/store.dart';
import 'package:shopikaiss_terminal/src/offline/ticket.dart';
import 'package:shopikaiss_terminal/src/register/register_adapter.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_engine.dart';
import 'package:shopikaiss_terminal/src/windows/platform/receipt_logo.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_v2_server.dart';
import 'sync_v2_engine_test.dart' show serve21;

/// Prix modifiable à la vente hors connexion (contrat 2.1 lot 9, capacité `prix.modifiable`, A 4176383b).
void main() {
  sqfliteFfiInit();
  late Directory dir;
  late SqfliteOfflineStore base;
  late FakeV2Server server;
  var uuids = 0;
  String newUuid() => 'abcdef00-0000-4000-8000-${(++uuids).toString().padLeft(12, '0')}';

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('prix_modifiable_');
    base = await SqfliteOfflineStore.open(name: p.join(dir.path, 'caisse.db'), factory: databaseFactoryFfi);
    server = FakeV2Server.sellable();
  });
  tearDown(() async {
    await base.close();
    dir.deleteSync(recursive: true);
  });

  Map<String, dynamic> product(String nom, String? ref, int prix, {bool editable = false}) => {
    'nom': nom, 'reference': ref, 'categorie': null, 'prix': prix, 'stock_illimite': true, 'actif': true, 'vente_locale': true,
    'categorie_uuid': null, 'marque': null, 'fournisseur': null, 'unite': null,
    'prix_gros': null, 'gros_quantite_min': null, 'seuil_alerte': null, 'cree_le': null, 'favori': false, 'promotions': <Map<String, dynamic>>[], 'image': null,
    if (editable) 'prix_modifiable': true,
  };

  /// Boutique 2.1 : « Savon » coché à 1 000 F, « Emballage » non coché ; Awa a le droit, Koffi non.
  void serve({bool capability = true}) {
    serve21(server);
    server
      ..capabilities = [
        'instantane.v1', 'stock.couverture', 'vente.especes', 'vente.paiement_declare', 'contrat.2_1', 'panier.partage',
        if (capability) 'prix.modifiable',
      ]
      ..put('produit', fakeSavon, product('Savon', 'SAV', 1000, editable: true))
      ..put('produit', fakeService, product('Emballage', null, 100))
      ..put('operateur', 'operateur:7', {
        'operateur_id': '7', 'nom': 'Awa', 'pin_empreinte': 'empreinte', 'droits': ['ouverture_session', 'prix_vente_modifier', 'remise', 'vente'],
        'remise_max_pourcent': null, 'remise_max_montant': null, 'approbateur_remise': false,
      }, critical: true)
      ..put('operateur', 'operateur:9', {
        'operateur_id': '9', 'nom': 'Koffi', 'pin_empreinte': 'empreinte', 'droits': ['remise', 'vente'],
        'remise_max_pourcent': null, 'remise_max_montant': null, 'approbateur_remise': false,
      });
  }

  Future<V2Engine> engine() async {
    final e = V2Engine.onStore(base, transport: server, appVersion: 'essai', platform: 'windows', newUuid: newUuid,
        pinVerifier: FakeV2Server.pinVerifier, declaredPayments: true, contract21: true);
    await e.load('https://boutique.exemple.ci');
    expect(await e.pair('ABCD-EFGH', model: 'Essai', appVersion: 'essai'), isNull);
    expect((await e.sync()).reachable, isTrue);
    return e;
  }

  Operator named(V2Engine e, String name) => e.snapshot!.operators.firstWhere((o) => o.name == name);

  test('coordonnées du ticket reçues en v2 puis imprimées hors connexion sans mention technique', () async {
    serve();
    server.put('boutique', fakeShop, {
      ...(server.entities['boutique|$fakeShop']!['donnees'] as Map).cast<String, dynamic>(),
      'ticket': {'raison_sociale': 'TBC Essai', 'adresse': 'Abidjan, rue du test', 'telephone': '+225 0102030405', 'ncc': 'NCC-TEST', 'entete': null, 'pied': null, 'largeur_papier': 80},
    }, critical: true);
    final e = await engine();
    expect(e.snapshot!.store.address, 'Abidjan, rue du test');
    expect(e.snapshot!.store.phone, '+225 0102030405');
    final lines = [CartLine(product: e.snapshot!.byCode('6190000000011')!.$1)];
    final payments = [CartPayment(method: e.snapshot!.methods.single, amount: 1000, received: 1000)];
    final sale = await e.recordSale(lines, payments, named(e, 'Awa'));
    final printed = offlineTicketLines(snapshot: e.snapshot!, operation: sale, lines: lines, payments: payments, operatorName: 'Awa', paperWidth: 80).join('\n');
    expect(printed, contains('Abidjan, rue du test'));
    expect(printed, contains('+225 0102030405'));
    expect(printed, isNot(contains('Numero definitif')));
  });

  test('prix mémorisé local : reprise, scan, droits, conditionnement, retour au prix habituel et désactivation', () async {
    serve();
    final e = await engine();
    var adapter = LocalRegisterAdapter(e, newUuid: newUuid);
    await adapter.start();
    await adapter.execute('login', {'operator_id': 7, 'pin': '1234'}, null);
    expect((await adapter.execute('localPriceSettings', {}, null))['enabled'], false);
    await adapter.execute('setLocalPriceSettings', {'enabled': true}, null);
    final product = e.snapshot!.byCode('6190000000011')!.$1;
    var view = await adapter.execute('addProduct', {'product_id': product.id}, null);
    await adapter.execute('setLinePrice', {'line_id': (view['lines'] as List).single['id'], 'amount': 1750}, null);
    await adapter.execute('clear', {}, null);
    await adapter.close();
    adapter = LocalRegisterAdapter(e, newUuid: newUuid);
    await adapter.start();
    await adapter.execute('login', {'operator_id': 7, 'pin': '1234'}, null);
    view = await adapter.execute('scan', {'code': '6190000000011'}, null);
    expect((view['lines'] as List).single['entered_price'], 1750);
    expect((view['products'] as List).firstWhere((p) => p['id'] == product.id)['price_label'], '1 750 F');
    await adapter.execute('clear', {}, null);
    view = await adapter.execute('addProduct', {'product_id': product.id, 'packaging_id': product.packagings.single.id}, null);
    expect((view['lines'] as List).single['entered_price'], null);
    await adapter.execute('clear', {}, null);
    await adapter.execute('login', {'operator_id': 9, 'pin': '1234'}, null);
    view = await adapter.execute('addProduct', {'product_id': product.id}, null);
    expect((view['lines'] as List).single['entered_price'], null);
    await expectLater(adapter.execute('setLocalPriceSettings', {'enabled': true}, null), throwsA(isA<AdapterFailure>()));
    await adapter.execute('clear', {}, null);
    await adapter.execute('login', {'operator_id': 7, 'pin': '1234'}, null);
    view = await adapter.execute('addProduct', {'product_id': product.id}, null);
    await adapter.execute('setLinePrice', {'line_id': (view['lines'] as List).single['id'], 'amount': null}, null);
    expect((await adapter.execute('localPriceSettings', {}, null))['prices'], isEmpty);
    await adapter.execute('setLinePrice', {'line_id': (view['lines'] as List).single['id'], 'amount': 1800}, null);
    await adapter.execute('setLocalPriceSettings', {'enabled': false}, null);
    await adapter.execute('clear', {}, null);
    view = await adapter.execute('addProduct', {'product_id': product.id}, null);
    expect((view['lines'] as List).single['entered_price'], null);
    expect((await adapter.execute('localPriceSettings', {}, null))['prices'], isEmpty);
    await adapter.close();
  });

  test('capacité et catalogue : prix_modifiable reçu, droit publié, motifs de refus par ligne', () async {
    serve();
    final e = await engine();
    expect(e.editablePriceSupported, isTrue);
    final savon = e.snapshot!.byCode('6190000000011')!.$1;
    final emballage = e.snapshot!.products.firstWhere((x) => x.name == 'Emballage');
    expect(savon.priceEditable, isTrue);
    expect(emballage.priceEditable, isFalse);

    final awa = named(e, 'Awa');
    final koffi = named(e, 'Koffi');
    expect(e.enteredPriceBlocker(awa, CartLine(product: savon)), isNull);
    expect(e.enteredPriceBlocker(koffi, CartLine(product: savon)), contains('n’a pas le droit de modifier le prix'));
    expect(e.enteredPriceBlocker(null, CartLine(product: savon)), 'Identifiez le caissier.');
    expect(e.enteredPriceBlocker(awa, CartLine(product: emballage)), contains('ne se modifie pas'));
    expect(e.enteredPriceBlocker(awa, CartLine(product: savon, packaging: savon.packagings.single)), contains('unité de base'));
  });

  test('sans la capacité côté serveur : aucun prix saisi, ni à l’écran ni à l’encaissement', () async {
    serve(capability: false);
    final e = await engine();
    expect(e.editablePriceSupported, isFalse);
    final savon = e.snapshot!.byCode('6190000000011')!.$1;
    expect(e.enteredPriceBlocker(named(e, 'Awa'), CartLine(product: savon)), contains('non disponible'));
    final line = CartLine(product: savon, enteredPrice: 1500);
    await expectLater(
      e.recordSale([line], [CartPayment(method: e.snapshot!.methods.single, amount: 1500, received: 1500)], named(e, 'Awa')),
      throwsA(isA<OfflineRefusal>()),
    );
  });

  test('modèle : le prix saisi remplace le prix habituel, retire le tarif gros, la remise se calcule sur lui', () {
    final p = Product({'id': 1, 'nom': 'Gâteau', 'prix': 1000, 'prix_gros': 800, 'prix_modifiable': true});
    final tier = CartTier(rules: null, cart: false);
    final line = CartLine(product: p, quantity: BigInt.from(2000000), tier: tier, enteredPrice: 1500);
    expect(line.unitPrice, 1500);
    expect(line.usualPrice, 1000);
    expect(line.base, 3000);
    expect(line.wholesale, isFalse);
    line.enteredPrice = null;
    expect(line.unitPrice, 1000);
  });

  test('adaptateur : setLinePrice, remise sur le prix saisi, brouillon conservé, vente au prix saisi et au tarif détail', () async {
    serve();
    final e = await engine();
    var adapter = LocalRegisterAdapter(e, newUuid: newUuid);
    await adapter.start();
    await adapter.execute('login', {'operator_id': 7, 'pin': '1234'}, null);
    var status = await adapter.execute('status', {}, null);
    expect((status['capabilities'] as Map)['line_price'], containsPair('allowed', true));

    await adapter.execute('scan', {'code': '6190000000011'}, null);
    var view = await adapter.execute('scan', {'code': '6190000000011'}, null);
    final lineId = (view['lines'] as List).single['id'] as String;
    var line = (view['lines'] as List).single as Map;
    expect(line['price_editable'], isTrue);
    expect(line['price_edit_reason'], isNull);
    expect(line['entered_price'], isNull);
    expect(line['usual_price'], 1000);

    // Bornes et forme de l'argument.
    await expectLater(adapter.execute('setLinePrice', {'line_id': lineId, 'amount': -1}, null),
        throwsA(isA<AdapterFailure>().having((f) => f.code, 'code', 'prix_invalide')));
    await expectLater(adapter.execute('setLinePrice', {'line_id': lineId, 'amount': 1000000001}, null),
        throwsA(isA<AdapterFailure>().having((f) => f.code, 'code', 'prix_invalide')));
    await expectLater(adapter.execute('setLinePrice', {'line_id': lineId, 'amount': '1500'}, null),
        throwsA(isA<AdapterFailure>().having((f) => f.code, 'code', 'argument_invalide')));
    await expectLater(adapter.execute('setLinePrice', {'line_id': 'inconnue', 'amount': 1500}, null),
        throwsA(isA<AdapterFailure>().having((f) => f.code, 'code', 'ligne_inconnue')));

    // Exemple de la note de A : 1 000 F au catalogue, 1 500 F saisi, quantité 2, remise de 10 % → 300, total 2 700.
    view = await adapter.execute('setLinePrice', {'line_id': lineId, 'amount': 1500}, null);
    line = (view['lines'] as List).single as Map;
    expect(line['entered_price'], 1500);
    expect(line['unit_price_label'], '1 500 F');
    expect(line['usual_price_label'], '1 000 F');
    view = await adapter.execute('setLineDiscount', {'line_id': lineId, 'percent': '10'}, null);
    expect(((view['lines'] as List).single as Map)['discount'], 300);
    expect((view['totals'] as Map)['payable_label'], '2 700 F');

    // Redémarrage : le prix saisi est conservé avec le panier.
    await adapter.close();
    adapter = LocalRegisterAdapter(e, newUuid: newUuid);
    await adapter.start();
    await adapter.execute('login', {'operator_id': 7, 'pin': '1234'}, null);
    view = await adapter.execute('view', {}, null);
    expect(((view['lines'] as List).single as Map)['entered_price'], 1500);
    expect((view['totals'] as Map)['payable_label'], '2 700 F');

    // Un caissier sans le droit ne peut pas encaisser un prix saisi par un autre.
    await adapter.execute('logout', {}, null);
    await adapter.execute('login', {'operator_id': 9, 'pin': '1234'}, null);
    view = await adapter.execute('view', {}, null);
    expect(((view['lines'] as List).single as Map)['price_editable'], isFalse);
    expect(view['can_pay'], isFalse);
    expect(view['pay_reason'], contains('Prix saisi sur « Savon »'));
    await expectLater(adapter.execute('setLinePrice', {'line_id': lineId, 'amount': 1200}, null),
        throwsA(isA<AdapterFailure>().having((f) => f.code, 'code', 'prix_refuse')));
    await adapter.execute('logout', {}, null);
    await adapter.execute('login', {'operator_id': 7, 'pin': '1234'}, null);

    view = await adapter.execute('setPayment', {'method': 'especes', 'received': 3000}, null);
    expect(view['can_pay'], isTrue);
    final sale = await adapter.execute('commitSale', {}, 'aaaaaaaa-bbbb-4ccc-8ddd-000000000009');
    expect(sale['state'], 'committed');
    await e.sync();
    final sent = server.received['aaaaaaaa-bbbb-4ccc-8ddd-000000000009']!;
    expect(sent['etat'], 'integree');
    final saleLine = (((sent['operation'] as Map)['contenu'] as Map)['lignes'] as List).single as Map;
    expect(saleLine['prix_unitaire'], 1500);
    expect(saleLine['remise'], 300);
    expect(saleLine['total'], 2700);
    expect(saleLine['tarif'], 'detail');
    expect(saleLine['remise_saisie'], {'type': 'pourcentage', 'valeur': '10'});
    await adapter.close();
  });

  test('adaptateur : produit non coché et conditionnement refusés ; retour au prix habituel avec null', () async {
    serve();
    final e = await engine();
    final adapter = LocalRegisterAdapter(e, newUuid: newUuid);
    await adapter.start();
    await adapter.execute('login', {'operator_id': 7, 'pin': '1234'}, null);
    await adapter.execute('search', {'query': 'Emballage'}, null);
    final serviceId = ((await adapter.execute('view', {}, null))['products'] as List).single['id'] as int;
    var view = await adapter.execute('addProduct', {'product_id': serviceId}, null);
    final service = (view['lines'] as List).single as Map;
    expect(service['price_editable'], isFalse);
    expect(service['price_edit_reason'], contains('ne se modifie pas'));
    await expectLater(adapter.execute('setLinePrice', {'line_id': service['id'], 'amount': 50}, null),
        throwsA(isA<AdapterFailure>().having((f) => f.code, 'code', 'prix_refuse')));

    final savon = e.snapshot!.byCode('6190000000011')!.$1;
    view = await adapter.execute('addProduct', {'product_id': savon.id, 'packaging_id': savon.packagings.single.id}, null);
    final carton = (view['lines'] as List).firstWhere((l) => l['id'] != service['id']) as Map;
    expect(carton['price_editable'], isFalse);
    await expectLater(adapter.execute('setLinePrice', {'line_id': carton['id'], 'amount': 5000}, null),
        throwsA(isA<AdapterFailure>().having((f) => f.code, 'code', 'prix_refuse')));

    view = await adapter.execute('addProduct', {'product_id': savon.id}, null);
    final unit = (view['lines'] as List).firstWhere((l) => l['id'] != service['id'] && l['id'] != carton['id']) as Map;
    view = await adapter.execute('setLinePrice', {'line_id': unit['id'], 'amount': 0}, null);
    expect((view['lines'] as List).firstWhere((l) => l['id'] == unit['id'])['unit_price_label'], '0 F');
    view = await adapter.execute('setLinePrice', {'line_id': unit['id'], 'amount': null}, null);
    final back = (view['lines'] as List).firstWhere((l) => l['id'] == unit['id']) as Map;
    expect(back['entered_price'], isNull);
    expect(back['unit_price_label'], '1 000 F');
    await adapter.close();
  });

  test('mise en attente : un panier à prix saisi reste sur ce terminal ; le moteur refuse de le partager', () async {
    serve();
    final e = await engine();
    expect(e.sharedCartsSupported, isTrue);
    final savon = e.snapshot!.byCode('6190000000011')!.$1;
    await expectLater(
      e.suspendShared(named(e, 'Awa'), [CartLine(product: savon, enteredPrice: 1500)], const SaleExtras()),
      throwsA(isA<OfflineRefusal>().having((r) => r.message, 'message', contains('ne se partage pas'))),
    );

    final adapter = LocalRegisterAdapter(e, newUuid: newUuid);
    await adapter.start();
    await adapter.execute('login', {'operator_id': 7, 'pin': '1234'}, null);
    var view = await adapter.execute('scan', {'code': '6190000000011'}, null);
    final lineId = (view['lines'] as List).single['id'] as String;
    await adapter.execute('setLinePrice', {'line_id': lineId, 'amount': 1500}, null);
    final operationsBefore = server.received.length;
    view = await adapter.execute('suspendDraft', {}, null);
    expect(view['suspended_count'], 1);
    await e.sync();
    expect(server.received.length, operationsBefore, reason: 'aucun panier_suspendre envoyé');
    final drafts = await adapter.execute('drafts', {}, null);
    final id = (drafts['items'] as List).single['draft_id'] as String;
    view = await adapter.execute('resumeDraft', {'draft_id': id}, null);
    expect(((view['lines'] as List).single as Map)['entered_price'], 1500);
    await adapter.close();
  });

  test('moteur : prix saisi refusé sans le droit, hors bornes ou sur une commande restaurant, même si l’écran l’a laissé passer', () async {
    serve();
    final e = await engine();
    final savon = e.snapshot!.byCode('6190000000011')!.$1;
    CartPayment cash(int amount) => CartPayment(method: e.snapshot!.methods.single, amount: amount, received: amount);
    await expectLater(e.recordSale([CartLine(product: savon, enteredPrice: 1500)], [cash(1500)], named(e, 'Koffi')),
        throwsA(isA<OfflineRefusal>().having((r) => r.message, 'message', contains('modifier le prix'))));
    await expectLater(e.recordSale([CartLine(product: savon, enteredPrice: 1000000001)], [cash(1000000001)], named(e, 'Awa')),
        throwsA(isA<OfflineRefusal>()));
    final sold = await e.recordSale([CartLine(product: savon, enteredPrice: 1500)], [cash(1500)], named(e, 'Awa'));
    expect(((sold.content['lignes'] as List).single as Map)['prix_unitaire'], 1500);
  });
  test('prix mémorisés, chemin Android (LocalPrices) : même mémoire que l’adaptateur, mêmes refus', () async {
    serve();
    final e = await engine();
    final adapter = LocalRegisterAdapter(e, newUuid: newUuid);
    await adapter.start();
    await adapter.execute('login', {'operator_id': 7, 'pin': '1234'}, null);
    await adapter.execute('setLocalPriceSettings', {'enabled': true}, null);
    final savon = e.snapshot!.byCode('6190000000011')!.$1;
    final view = await adapter.execute('addProduct', {'product_id': savon.id}, null);
    await adapter.execute('setLinePrice', {'line_id': (view['lines'] as List).single['id'], 'amount': 1750}, null);
    await adapter.close();

    // La caisse Android lit la même mémoire (même clé par boutique).
    final memory = await LocalPrices.read(e);
    expect(memory.enabled, isTrue);
    expect(memory.priceFor(e, named(e, 'Awa'), CartLine(product: savon)), 1750);
    expect(memory.priceFor(e, named(e, 'Koffi'), CartLine(product: savon)), isNull, reason: 'caissier sans le droit');
    expect(memory.priceFor(e, named(e, 'Awa'), CartLine(product: savon, packaging: savon.packagings.single)), isNull, reason: 'conditionnement');
    await expectLater(LocalPrices.setEnabled(e, named(e, 'Koffi'), false), throwsA(isA<StateError>()));
    expect(await LocalPrices.remember(e, savon.id, 1800), isTrue);
    expect((await LocalPrices.read(e)).prices['${savon.id}'], 1800);
    expect(await LocalPrices.remember(e, savon.id, null), isTrue);
    expect((await LocalPrices.read(e)).prices, isEmpty);
    await LocalPrices.remember(e, savon.id, 1900);
    await LocalPrices.setEnabled(e, named(e, 'Awa'), false);
    expect((await LocalPrices.read(e)).prices, isEmpty, reason: 'désactiver efface la mémoire');
    expect(await LocalPrices.remember(e, savon.id, 2000), isFalse, reason: 'désactivée : rien n’est mémorisé');
  });

  int count(Uint8List bytes, List<int> pattern) {
    var n = 0;
    for (var i = 0; i + pattern.length <= bytes.length; i++) {
      var ok = true;
      for (var j = 0; j < pattern.length && ok; j++) {
        ok = bytes[i + j] == pattern[j];
      }
      if (ok) n++;
    }
    return n;
  }

  test('réglages des tickets par boutique : logo, QR, lien, DONT TVA et exemplaires (parité Windows)', () async {
    serve();
    final e = await engine();
    final defaults = await ReceiptSettings.read(e);
    expect((defaults.copies, defaults.qrEnabled, defaults.link, defaults.logoPng), (1, true, '', null));
    expect(ReceiptSettings.key(e.snapshot!), 'ticket-reglages-v1:$fakeShop', reason: 'rangé par boutique, pas pour tout le poste');
    await expectLater(const ReceiptSettings(link: 'ftp://exemple').write(e), throwsA(isA<FormatException>()));

    final logo = normalizeReceiptLogo(Uint8List.fromList(img.encodePng(img.Image(width: 40, height: 20)..clear(img.ColorRgb8(0, 0, 0)))));
    await ReceiptSettings(copies: 3, qrEnabled: true, link: 'https://exemple.ci', logoPng: logo).write(e);
    final settings = await ReceiptSettings.read(e);
    expect((settings.copies, settings.link, settings.logoPng!.length), (3, 'https://exemple.ci', logo.length));

    const lines = ['BOUTIQUE', 'Ticket HL2-1-0001', 'TOTAL           2 700 F', 'dont TVA 18 %     412 F'];
    expect(ReceiptSettings.saleLines(lines).last, startsWith('DONT TVA 18 %'));
    final cut = [0x1D, 0x56, 66, 0];
    final raster = [0x1D, 0x76, 0x30, 0];
    final sale = settings.saleBytes(lines, paperWidth: 58);
    expect(count(sale, cut), 3, reason: 'trois exemplaires, un seul envoi');
    final one = count(settings.saleBytes(lines, paperWidth: 58, copies: 1), raster);
    expect(one, greaterThanOrEqualTo(3), reason: 'logo, QR résumé et QR du lien (une image peut tenir sur plusieurs bandes)');
    expect(count(sale, raster), 3 * one);
    expect(String.fromCharCodes(sale), contains('DONT TVA 18 %'));
    final duplicate = settings.saleBytes(lines, paperWidth: 80, copies: 1);
    expect(count(duplicate, cut), 1);
    final bare = const ReceiptSettings(qrEnabled: false).saleBytes(lines, paperWidth: 80);
    expect((count(bare, cut), count(bare, raster)), (1, 0), reason: 'sans logo ni QR : texte seul');
    expect(bare.sublist(0, 5), [0x1B, 0x40, 0x1B, 0x64, 3], reason: 'trois lignes avant le texte (marges C 398a128)');
    expect(bare.sublist(bare.length - 7), [0x1B, 0x64, 2, 0x1D, 0x56, 66, 0], reason: 'deux lignes avant la coupe');

  });
  test('panier identique au ticket précédent : avertissement seulement, effacé par une vente différente', () async {
    serve();
    final e = await engine();
    final savon = e.snapshot!.byCode('6190000000011')!.$1;
    final emballage = e.snapshot!.products.firstWhere((p) => p.name == 'Emballage');
    final cash = e.snapshot!.methods.firstWhere((m) => m.isCash);
    Future<void> sell(Product product, int price) =>
        e.recordSale([CartLine(product: product)], [CartPayment(method: cash, amount: price, received: price)], named(e, 'Awa'));
    expect(await e.sameAsPreviousSale([CartLine(product: savon)]), isFalse);
    await sell(savon, 1000);
    expect(await e.sameAsPreviousSale([CartLine(product: savon)]), isTrue);
    expect(await e.sameAsPreviousSale([CartLine(product: savon, quantity: BigInt.from(2000000))]), isFalse);
    await sell(savon, 1000);
    await sell(emballage, 100);
    expect(await e.sameAsPreviousSale([CartLine(product: savon)]), isFalse, reason: 'vente différente intercalée');
  });
}
