import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shopikaiss_terminal/src/offline/catalogue_edit.dart';
import 'package:shopikaiss_terminal/src/offline/engine.dart';
import 'package:shopikaiss_terminal/src/offline/models.dart';
import 'package:shopikaiss_terminal/src/offline/store.dart';
import 'package:shopikaiss_terminal/src/register/register_adapter.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_v2_server.dart';
import 'sync_v2_engine_test.dart' show serve21;

/// Catalogue hors connexion (contrat 2.1 lot 10, A `c87b57c1`, note CATALOGUE-HORS-LIGNE-POUR-B-ET-C.md).
void main() {
  sqfliteFfiInit();
  late Directory dir;
  late SqfliteOfflineStore base;
  late FakeV2Server server;
  var uuids = 0;
  String newUuid() => 'abcdef00-0000-4000-8000-${(++uuids).toString().padLeft(12, '0')}';
  const category = '88888888-8888-4888-8888-888888888888';

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('catalogue_hors_ligne_');
    base = await SqfliteOfflineStore.open(name: p.join(dir.path, 'caisse.db'), factory: databaseFactoryFfi);
    server = FakeV2Server.sellable();
  });
  tearDown(() async {
    await base.close();
    dir.deleteSync(recursive: true);
  });

  /// Boutique 2.1 : Awa crée et modifie, Koffi vend seulement ; une catégorie « Pâtisserie ».
  void serve({bool capability = true}) {
    serve21(server);
    server
      ..capabilities = [
        'instantane.v1', 'stock.couverture', 'vente.especes', 'vente.paiement_declare', 'contrat.2_1',
        if (capability) ...['produit.creation', 'produit.modification'],
      ]
      ..put('categorie', category, {'nom': 'Pâtisserie', 'actif': true, 'ordre': 1})
      ..put('operateur', 'operateur:7', {
        'operateur_id': '7', 'nom': 'Awa', 'pin_empreinte': 'empreinte',
        'droits': ['ouverture_session', 'produits_creer', 'produits_modifier', 'remise', 'vente'],
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
  CartPayment cash(V2Engine e, int amount) => CartPayment(method: e.snapshot!.methods.firstWhere((m) => m.isCash), amount: amount, received: amount);
  Map<String, dynamic> sent(String type) => server.received.values.map((r) => r['operation'] as Map<String, dynamic>).lastWhere((o) => o['type'] == type);

  const gateau = NewProduct(name: ' Gâteau du jour ', reference: 'GAT-JOUR', barcodes: ['6190000000999'], categoryUuid: category, price: 1500, unlimitedStock: true);

  test('capacités et droits : rien sans la capacité ; créer et modifier selon le droit publié', () async {
    serve(capability: false);
    var e = await engine();
    expect(e.productCreationSupported, isFalse);
    expect(e.productCreateBlocker(named(e, 'Awa')), contains('non disponible'));
    await expectLater(e.createProduct(named(e, 'Awa'), gateau), throwsA(isA<OfflineRefusal>()));

    serve();
    server.snapshotReasons.clear();
    e = await engine();
    expect(server.snapshotReasons, isNotEmpty, reason: 'première annonce : instantané (+catalogue1) pour recevoir les droits');
    expect((e.productCreationSupported, e.productEditSupported), (true, true));
    expect(e.productCreateBlocker(named(e, 'Awa')), isNull);
    expect(e.productCreateBlocker(named(e, 'Koffi')), contains('Koffi'));
    expect(e.productEditBlocker(named(e, 'Koffi')), contains('Koffi'));
    expect(e.productCategories.single, (uuid: category, name: 'Pâtisserie'));
  });

  test('création : vendable tout de suite ici, opération avant la vente, ventes citant l’uuid local ; intégrée puis publiée', () async {
    serve();
    final e = await engine();
    final product = await e.createProduct(named(e, 'Awa'), gateau);
    expect((product.name, product.price, product.category, product.localState, product.unlimitedStock), ('Gâteau du jour', 1500, 'Pâtisserie', 'cree_local', true));
    expect(e.snapshot!.byCode('6190000000999')!.$1.id, product.id, reason: 'code-barres scannable hors connexion');
    final sale = await e.recordSale([CartLine(product: product)], [cash(e, 1500)], named(e, 'Awa'));
    expect(sale.isSale, isTrue);

    server.resultDetails = (op) => op['type'] == 'creation_produit'
        ? {'produit_uuid_canonique': (op['contenu'] as Map)['produit_uuid'], 'produit_resolution': {'decision': 'creee', 'champs_serveur': <String>[], 'decide_par': null}}
        : null;
    await e.sync();
    final creation = sent('creation_produit');
    final local = (creation['contenu'] as Map)['produit_uuid'] as String;
    expect(creation['contenu'], {
      'produit_uuid': local, 'nom': 'Gâteau du jour', 'reference': 'GAT-JOUR', 'codes_barres': ['6190000000999'], 'categorie_uuid': category,
      'prix': 1500, 'prix_achat': null, 'prix_gros': null, 'gros_quantite_min': null, 'stock_illimite': true,
    });
    final vente = sent('vente');
    expect((vente['contenu']['lignes'] as List).single['produit_uuid'], local);
    expect(creation['sequence'] as int, lessThan(vente['sequence'] as int), reason: 'création avant toute vente qui la cite');

    var change = (await e.catalogueChanges()).single;
    expect((change.kind, change.state, change.decision, change.canonicalUuid), ('creation', 'integre', 'creee', local));
    expect(e.snapshot!.products.any((p) => p.id == product.id), isTrue, reason: 'intégrée, pas encore publiée : la copie locale reste');

    server.publish([
      {'type': 'produit', 'critique': false, 'cle': local, 'revision': '1', 'action': 'upsert', 'donnees': {
        'nom': 'Gâteau du jour', 'reference': 'GAT-JOUR', 'categorie': 'Pâtisserie', 'prix': 1500, 'stock_illimite': true, 'actif': true, 'vente_locale': true,
        'categorie_uuid': category, 'marque': null, 'fournisseur': null, 'unite': null, 'prix_gros': null, 'gros_quantite_min': null,
        'seuil_alerte': null, 'cree_le': null, 'favori': false, 'promotions': <Map<String, dynamic>>[], 'image': null,
      }},
    ]);
    await e.sync();
    final published = e.snapshot!.products.firstWhere((p) => p.id == product.id);
    expect(published.localState, isNull, reason: 'la fiche du serveur remplace la copie locale, même identifiant');
    change = (await e.catalogueChanges()).single;
    expect(change.productId, product.id);
  });

  test('création : refus de saisie (nom, codes, bornes, gros > prix, code déjà connu) ; rejeu idempotent', () async {
    serve();
    final e = await engine();
    final awa = named(e, 'Awa');
    Future<void> refused(NewProduct p, Matcher message) => expectLater(e.createProduct(awa, p), throwsA(isA<OfflineRefusal>().having((r) => r.message, 'message', message)));
    await refused(const NewProduct(name: '  ', price: 10), contains('nom'));
    await refused(const NewProduct(name: 'X', price: 10, barcodes: ['619 000']), contains('invalide'));
    await refused(const NewProduct(name: 'X', price: 10, barcodes: ['1', '2', '3', '4', '5', '6']), contains('Cinq'));
    await refused(const NewProduct(name: 'X', price: 1000000001), contains('Prix de vente'));
    await refused(const NewProduct(name: 'X', price: 100, wholesalePrice: 150), contains('gros'));
    await refused(const NewProduct(name: 'X', price: 100, wholesaleMin: '0'), contains('Quantité'));
    await refused(const NewProduct(name: 'X', price: 100, categoryUuid: '99999999-9999-4999-8999-999999999999'), contains('Catégorie'));
    await expectLater(
      e.createProduct(awa, const NewProduct(name: 'X', price: 100, barcodes: ['6190000000011'])),
      throwsA(isA<OfflineRefusal>().having((r) => r.code, 'code', CatalogueValidation.codeUsed).having((r) => r.message, 'message', contains('Savon'))),
    );
    const operation = 'abcdef00-0000-4000-8000-00000000aaaa';
    final first = await e.createProduct(awa, const NewProduct(name: 'Tarte', price: 800, wholesalePrice: 700, wholesaleMin: '2,5'), operationUuid: operation);
    final again = await e.createProduct(awa, const NewProduct(name: 'Autre', price: 1), operationUuid: operation);
    expect(again.id, first.id, reason: 'même identifiant d’opération : même produit, aucune seconde création');
    expect((first.wholesalePrice, first.wholesaleMinimum), (700, BigInt.from(2500000)));
    expect((await e.catalogueChanges()).length, 1);
  });

  test('modification : avant/après et révision de base, affichée tout de suite ; rien à changer ; conflit à arbitrer', () async {
    serve();
    final e = await engine();
    final awa = named(e, 'Awa');
    final savon = e.snapshot!.byCode('6190000000011')!.$1;
    await expectLater(e.updateProduct(named(e, 'Koffi'), savon.id, {'prix': 600}), throwsA(isA<OfflineRefusal>()));
    await expectLater(e.updateProduct(awa, savon.id, {'prix': 500}),
        throwsA(isA<OfflineRefusal>().having((r) => r.code, 'code', CatalogueValidation.noChange)));
    await expectLater(e.updateProduct(awa, savon.id, {'prix_gros': 900}), throwsA(isA<OfflineRefusal>()));
    await expectLater(e.updateProduct(awa, savon.id, {'stock_illimite': true}), throwsA(isA<OfflineRefusal>()));
    final updated = await e.updateProduct(awa, savon.id, {'prix': 600, 'nom': 'Savon parfumé', 'gros_quantite_min': '12'});
    expect((updated.name, updated.price, updated.localState), ('Savon parfumé', 600, 'modifie_local'));
    expect(e.productFields(savon.id)!.wholesaleMin, '12.000000');

    server.verdict = (op) => op['type'] == 'modification_produit' ? 'a_arbitrer' : 'integree';
    server.reasonFor = (op) => op['type'] == 'modification_produit'
        ? {'code': 'produit.conflit_champs', 'message': 'Prix modifié entre-temps sur le web.', 'details': null}
        : null;
    await e.sync();
    expect(sent('modification_produit')['contenu'], {
      'produit_uuid': fakeSavon,
      'revision_base': '1',
      'champs': {
        'prix': {'avant': 500, 'apres': 600},
        'nom': {'avant': 'Savon', 'apres': 'Savon parfumé'},
        'gros_quantite_min': {'avant': null, 'apres': '12.000000'},
      },
    });
    final change = (await e.catalogueChanges()).single;
    expect((change.kind, change.state, change.reason, change.name), ('modification', 'conflit', 'Prix modifié entre-temps sur le web.', 'Savon parfumé'));
    final shown = e.snapshot!.products.firstWhere((p) => p.id == savon.id);
    expect((shown.price, shown.localState), (500, 'conflit'), reason: 'rien n’est appliqué au serveur : valeurs du serveur, état conflit');
  });

  test('création à arbitrer puis rattachée sur le web : la fiche locale disparaît, le stock vendu compte sur le produit existant', () async {
    serve();
    final e = await engine();
    final awa = named(e, 'Awa');
    final local = await e.createProduct(awa, const NewProduct(name: 'Savon bis', price: 450, barcodes: ['6190000000888']));
    await e.recordSale([CartLine(product: local, quantity: BigInt.from(2000000))], [cash(e, 900)], awa);
    // Panier en cours avec le produit local : il doit survivre au rattachement.
    final adapter = LocalRegisterAdapter(e, newUuid: newUuid);
    await adapter.start();
    await adapter.execute('login', {'operator_id': 7, 'pin': '1234'}, null);
    await adapter.execute('addProduct', {'product_id': local.id}, null);
    server.verdict = (op) => op['type'] == 'creation_produit' ? 'a_arbitrer' : 'recue';
    server.reasonFor = (op) => op['type'] == 'creation_produit'
        ? {'code': 'produit.correspondance', 'message': 'Code-barres ou référence déjà utilisés dans la boutique : à arbitrer.', 'details': null}
        : {'code': 'produit.attente_creation', 'message': 'En attente du produit.', 'details': null};
    await e.sync();
    expect(e.snapshot!.products.firstWhere((p) => p.id == local.id).localState, 'conflit', reason: 'toujours vendable ici, signalé');
    expect((await e.catalogueChanges()).single.state, 'conflit');

    // Arbitrage web : rattachée au Savon existant.
    final creation = sent('creation_produit');
    server.received[creation['uuid']]!
      ..['etat'] = 'integree'
      ..['version'] = 2
      ..['raison'] = null;
    server.resultDetails = (op) => op['type'] == 'creation_produit'
        ? {'produit_uuid_canonique': fakeSavon, 'produit_resolution': {'decision': 'rattachee', 'champs_serveur': <String>[], 'decide_par': '3'}}
        : null;
    await e.sync();
    final change = (await e.catalogueChanges()).single;
    expect((change.state, change.decision, change.canonicalUuid), ('rattache', 'rattachee', fakeSavon));
    expect(e.snapshot!.products.any((p) => p.id == local.id), isFalse, reason: 'remplacée par le produit existant');
    expect(e.snapshot!.byCode('6190000000888'), isNull);
    final savon = e.snapshot!.byCode('6190000000011')!.$1;
    expect((await e.soldSinceSnapshot())[savon.id], BigInt.from(2000000), reason: 'vente non couverte écrite sous l’uuid local, comptée sur le Savon');
    expect(e.snapshot!.byId(local.id)!.id, savon.id, reason: 'l’identifiant local mène au produit existant');
    final lines = (await adapter.execute('view', {}, null))['lines'] as List;
    expect((lines.single as Map)['name'], 'Savon', reason: 'la ligne du panier suit le rattachement au lieu de disparaître');
    await adapter.close();
  });

  test('adaptateur : catalogueForm, createProduct, productForEdit, updateProduct, catalogueChanges et local_state de la vue', () async {
    serve();
    final e = await engine();
    final adapter = LocalRegisterAdapter(e, newUuid: newUuid);
    await adapter.start();
    await adapter.execute('login', {'operator_id': 9, 'pin': '1234'}, null);
    var form = await adapter.execute('catalogueForm', {}, null);
    expect((form['create'] as Map)['allowed'], isFalse);
    await expectLater(adapter.execute('createProduct', {'name': 'Tarte', 'price': 800}, null),
        throwsA(isA<AdapterFailure>().having((f) => f.code, 'code', 'produit_refuse')));

    await adapter.execute('login', {'operator_id': 7, 'pin': '1234'}, null);
    form = await adapter.execute('catalogueForm', {}, null);
    expect((form['create'] as Map)['allowed'], isTrue);
    expect(form['categories'], [{'uuid': category, 'name': 'Pâtisserie'}]);
    expect((form['limits'] as Map)['barcodes'], 5);
    await expectLater(adapter.execute('createProduct', {'name': 'Tarte', 'price': '800'}, null),
        throwsA(isA<AdapterFailure>().having((f) => f.code, 'code', 'argument_invalide')));
    await expectLater(adapter.execute('createProduct', {'name': '', 'price': 800}, null),
        throwsA(isA<AdapterFailure>().having((f) => f.code, 'code', 'champ_invalide')));
    await expectLater(adapter.execute('createProduct', {'name': 'Tarte', 'price': 800, 'barcodes': ['6190000000011']}, null),
        throwsA(isA<AdapterFailure>().having((f) => f.code, 'code', 'code_deja_utilise')));
    final created = await adapter.execute('createProduct', {
      'name': 'Tarte', 'reference': null, 'barcodes': ['6190000000777'], 'category_uuid': category, 'price': 800,
      'purchase_price': 500, 'wholesale_price': null, 'wholesale_min': null, 'unlimited_stock': false,
    }, null);
    expect(created['local_state'], 'a_synchroniser');
    final id = created['product_id'] as int;
    await adapter.execute('scan', {'code': '6190000000777'}, null);
    var view = await adapter.execute('search', {'query': 'Tarte'}, null);
    expect((view['products'] as List).firstWhere((p) => p['id'] == id)['local_state'], 'cree_local');
    expect(((await adapter.execute('status', {}, null))['capabilities'] as Map)['product_create'], {'allowed': true, 'reason': null, 'network_required': false});

    final edit = await adapter.execute('productForEdit', {'product_id': id}, null);
    expect((edit['name'], edit['price'], edit['editable'], edit['local_state']), ('Tarte', 800, true, 'cree_local'));
    expect(edit['barcodes'], ['6190000000777']);
    await expectLater(adapter.execute('updateProduct', {'product_id': id, 'fields': {'price': 800}}, null),
        throwsA(isA<AdapterFailure>().having((f) => f.code, 'code', 'aucun_changement')));
    await expectLater(adapter.execute('updateProduct', {'product_id': id, 'fields': {'barcodes': []}}, null),
        throwsA(isA<AdapterFailure>().having((f) => f.code, 'code', 'argument_invalide')));
    await expectLater(adapter.execute('updateProduct', {'product_id': 999999, 'fields': {'price': 1}}, null),
        throwsA(isA<AdapterFailure>().having((f) => f.code, 'code', 'produit_inconnu')));
    await adapter.execute('updateProduct', {'product_id': id, 'fields': {'price': 900, 'wholesale_min': '3'}}, null);
    expect((await adapter.execute('productForEdit', {'product_id': id}, null))['wholesale_min_label'], '3');
    final items = (await adapter.execute('catalogueChanges', {}, null))['items'] as List;
    expect([for (final i in items) (i['kind'], i['state'])], [('modification', 'a_synchroniser'), ('creation', 'a_synchroniser')]);
    await e.sync();
    expect(sent('modification_produit')['contenu']['revision_base'], isNull, reason: 'fiche créée ici, pas encore reçue');
    await adapter.close();
  });
}
