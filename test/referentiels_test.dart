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

/// Référentiels sur le poste : catégorie et fournisseur (2.1 lot 18, note A LOT-18-REFERENTIELS-POUR-B-ET-C.md).
void main() {
  sqfliteFfiInit();
  late Directory dir;
  late SqfliteOfflineStore base;
  late FakeV2Server server;
  var uuids = 0;
  String newUuid() => 'abcdef00-0000-4000-8000-${(++uuids).toString().padLeft(12, '0')}';
  const boissons = '88888888-8888-4888-8888-888888888801';
  const adjame = '88888888-8888-4888-8888-888888888802';
  const ancien = '88888888-8888-4888-8888-888888888803';
  const droguerieServeur = 'c0000000-0000-4000-8000-000000000181';
  const koneServeur = 'f0000000-0000-4000-8000-000000000181';

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('referentiels_');
    base = await SqfliteOfflineStore.open(name: p.join(dir.path, 'caisse.db'), factory: databaseFactoryFfi);
    server = FakeV2Server.sellable();
  });
  tearDown(() async {
    await base.close();
    dir.deleteSync(recursive: true);
  });

  void serve({bool capability = true, bool rights = true}) {
    serve21(server);
    server
      ..capabilities = [
        'instantane.v1', 'stock.couverture', 'vente.especes', 'contrat.2_1', 'produit.creation', 'produit.modification',
        if (capability) 'referentiels.creation',
      ]
      ..put('categorie', boissons, {'nom': 'Boissons', 'actif': true, 'ordre': 1})
      ..put('fournisseur', adjame, {'nom': 'Grossiste Adjamé', 'telephone': null, 'actif': true})
      ..put('fournisseur', ancien, {'nom': 'Ancien fournisseur', 'telephone': '0101', 'actif': false})
      ..put('operateur', 'operateur:7', {
        'operateur_id': '7', 'nom': 'Awa', 'pin_empreinte': 'empreinte',
        'droits': ['ouverture_session', 'produits_creer', 'produits_modifier', 'vente', if (rights) ...['categories_creer', 'fournisseurs_creer']],
        'remise_max_pourcent': null, 'remise_max_montant': null, 'approbateur_remise': false,
      }, critical: true)
      // Le serveur garde son uuid : celui du poste devient un alias (note A §4).
      ..resultDetails = (op) => switch (op['type']) {
        'creation_categorie' => {'categorie_uuid_canonique': droguerieServeur, 'referentiel_resolution': {'decision': 'creee'}},
        'creation_fournisseur' => {'fournisseur_uuid_canonique': koneServeur, 'referentiel_resolution': {'decision': 'creee'}},
        _ => null,
      };
  }

  Future<V2Engine> engine() async {
    final e = V2Engine.onStore(base, transport: server, appVersion: 'essai', platform: 'android', newUuid: newUuid, pinVerifier: FakeV2Server.pinVerifier, contract21: true);
    await e.load('https://boutique.exemple.ci');
    expect(await e.pair('ABCD-EFGH', model: 'Essai', appVersion: 'essai'), isNull);
    await e.sync();
    return e;
  }

  Operator awa(V2Engine e) => e.snapshot!.operators.firstWhere((o) => o.name == 'Awa');
  Matcher refused(String text) => throwsA(isA<OfflineRefusal>().having((r) => r.message, 'message', contains(text)));

  test('créés hors connexion, cités par un produit, envoyés avant lui ; uuid du serveur repris partout ensuite', () async {
    serve();
    final e = await engine();
    expect(e.referencesSupported, isTrue);
    expect(e.supplierChoices.map((s) => s.name), ['Grossiste Adjamé'], reason: 'inactif non proposé');

    final category = await e.createCategory(awa(e), '  Droguerie ');
    expect((category.name, category.local), ('Droguerie', 'a_synchroniser'));
    expect((await e.createCategory(awa(e), 'droguerie')).uuid, category.uuid, reason: 'même nom : reprise, rien de créé');
    expect((await e.createCategory(awa(e), 'BOISSONS')).uuid, boissons);
    final supplier = await e.createSupplier(awa(e), 'Ets Koné', phone: '0700000018');
    expect(e.supplierChoices.map((s) => (s.name, s.local)), [('Ets Koné', 'a_synchroniser'), ('Grossiste Adjamé', null)]);

    final product = await e.createProduct(awa(e), NewProduct(name: 'Javel', price: 750, categoryUuid: category.uuid, supplierUuid: supplier.uuid));
    expect((product.category, product.supplier), ('Droguerie', 'Ets Koné'));
    final ops = [for (final r in (await e.v2.operationRows()).reversed) r['operation'] as Map];
    expect(ops.map((o) => o['type']).where((t) => t != 'ouverture_session' && t != 'cloture_session'), ['creation_categorie', 'creation_fournisseur', 'creation_produit']);
    for (final o in ops) {
      expect(fakeValidator.validate(o, 'operation.json'), isEmpty, reason: '${o['type']}');
    }
    final created = ops.last['contenu'] as Map;
    expect((created['categorie_uuid'], created['fournisseur_uuid']), (category.uuid, supplier.uuid), reason: 'uuid du poste, résolu par le serveur');
    expect((ops[ops.length - 2]['contenu'] as Map)['telephone'], '0700000018');

    await e.sync();
    // Intégrés, pas encore publiés : les fiches locales tiennent lieu de celles du serveur, sous son uuid.
    final fields = e.productFields(product.id)!;
    expect((fields.categoryUuid, fields.supplierUuid), (droguerieServeur, koneServeur));
    expect(e.categoryChoices.where((c) => c.uuid == droguerieServeur).single.local, isNull);
    expect(e.supplierChoices.map((s) => s.uuid), containsAll([koneServeur, adjame]));
    expect(e.supplierChoices.any((s) => s.uuid == supplier.uuid), isFalse);

    // Publiée par le serveur, écrite autrement (rattachement) : son nom l'emporte.
    server.publish([
      {'type': 'categorie', 'critique': false, 'cle': droguerieServeur, 'revision': '900', 'action': 'upsert', 'donnees': {'nom': 'DROGUERIE', 'actif': true, 'ordre': 3}},
    ]);
    await e.sync();
    expect(e.categoryChoices.where((c) => c.uuid == droguerieServeur).single.name, 'DROGUERIE');

    // Modification : `avant` = uuid du serveur, jamais l'uuid local.
    await e.updateProduct(awa(e), product.id, {'fournisseur_uuid': adjame}, expected: {'fournisseur_uuid': koneServeur});
    final edit = (await e.v2.operationRows()).first['operation'] as Map;
    expect(fakeValidator.validate(edit, 'operation.json'), isEmpty);
    expect((edit['contenu'] as Map)['champs'], {'fournisseur_uuid': {'avant': koneServeur, 'apres': adjame}});
    expect(e.snapshot!.products.firstWhere((x) => x.id == product.id).supplier, 'Grossiste Adjamé');
    await expectLater(e.updateProduct(awa(e), product.id, {'fournisseur_uuid': ancien}), refused('Fournisseur inconnu'));

    // Adaptateur : listes, droits, création.
    final adapter = LocalRegisterAdapter(e, newUuid: newUuid);
    await adapter.start();
    await adapter.execute('login', {'operator_id': 7, 'pin': '1234'}, null);
    final form = await adapter.execute('catalogueForm', {}, null);
    expect((form['references_supported'], (form['create_supplier'] as Map)['allowed']), (true, true));
    expect((form['suppliers'] as List).map((s) => (s as Map)['name']), containsAll(['Grossiste Adjamé', 'Ets Koné']));
    const id = 'abcdef00-0000-4000-8000-0000000018aa';
    final made = await adapter.execute('createSupplier', {'name': 'Sotra Distribution', 'phone': null, 'operation_id': id}, null);
    expect((made['name'], made['local_state']), ('Sotra Distribution', 'a_synchroniser'));
    expect((await adapter.execute('createSupplier', {'name': 'Sotra Distribution', 'operation_id': id}, null))['uuid'], made['uuid'], reason: 'rejeu');
    await adapter.close();
  });

  test('sans la capacité ou sans le droit : rien de proposé, création refusée, aucun fournisseur envoyé', () async {
    serve(capability: false);
    var e = await engine();
    expect(e.referencesSupported, isFalse);
    expect(e.supplierChoices, isEmpty);
    expect(e.categoryCreateBlocker(awa(e)), contains('non disponible'));
    await expectLater(e.createSupplier(awa(e), 'X'), refused('non disponible'));
    await expectLater(e.createProduct(awa(e), const NewProduct(name: 'Y', price: 100, supplierUuid: adjame)), refused('serveur sans référentiels'));

    await base.close();
    base = await SqfliteOfflineStore.open(name: p.join(dir.path, 'caisse-2.db'), factory: databaseFactoryFfi);
    serve(rights: false);
    e = await engine();
    expect(e.categoryCreateBlocker(awa(e)), 'Awa n’a pas le droit de créer une catégorie.');
    expect(e.supplierCreateBlocker(awa(e)), 'Awa n’a pas le droit de créer un fournisseur.');
    // Choisir un fournisseur existant ne demande que le droit de la fiche.
    final product = await e.createProduct(awa(e), const NewProduct(name: 'Eau', price: 300, supplierUuid: adjame));
    expect(product.supplier, 'Grossiste Adjamé');
  });
}
