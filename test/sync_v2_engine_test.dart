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
}
