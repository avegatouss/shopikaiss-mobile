import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shopikaiss_terminal/src/offline/engine.dart';
import 'package:shopikaiss_terminal/src/offline/store.dart';
import 'package:shopikaiss_terminal/src/register/register_adapter.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'offline_test.dart' show FakeTransport;

/// Interface de commandes du moteur (C-REQ-001/004), sur SQLite réelle : panier conservé, encaissement idempotent par
/// identifiant d'opération, état d'une vente lu localement et définitif, refus certains sans écriture.
void main() {
  sqfliteFfiInit();
  late Directory dir;
  late SqfliteOfflineStore store;
  late FakeTransport transport;
  late LocalRegisterAdapter adapter;
  var ids = 0;
  String uuid() => '00000000-0000-4000-8000-${(ids++).toString().padLeft(12, '0')}';

  Future<LocalRegisterAdapter> boot() async {
    final engine = OfflineEngine(store: store, transport: transport, newUuid: uuid);
    await engine.load('https://boutique.exemple.ci');
    final a = LocalRegisterAdapter(engine, newUuid: uuid);
    await a.start();
    return a;
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('adaptateur_');
    store = await SqfliteOfflineStore.open(name: p.join(dir.path, 'caisse.db'), factory: databaseFactoryFfi);
    transport = FakeTransport();
    final engine = OfflineEngine(store: store, transport: transport, newUuid: uuid);
    await engine.load('https://boutique.exemple.ci');
    expect(await engine.pair('ABCD-EFGH', model: 'Windows', appVersion: '1.2.0'), isNull);
    adapter = LocalRegisterAdapter(engine, newUuid: uuid);
    await adapter.start();
  });
  tearDown(() async {
    await store.close();
    dir.deleteSync(recursive: true);
  });

  Future<Map<String, dynamic>> run(String command, [Map<String, dynamic> args = const {}, String? operation]) =>
      adapter.execute(command, args, operation);

  Future<void> cartOf2Soaps() async {
    await run('login', {'operator_id': 7, 'pin': '1234'});
    await run('scan', {'code': '6190000000011'});
    final view = await run('scan', {'code': '6190000000011'});
    expect((view['lines'] as List).single['quantity_label'], '2');
    await run('setPayment', {'method': 'especes', 'received': 5000});
  }

  test('vue schéma 1 : catalogue, panier, total ; encaissement impossible sans caissier identifié', () async {
    final view = await run('scan', {'code': '6190000000011'});
    expect(view['schema'], 1);
    expect(view['revision'], isA<int>());
    expect(view['ready'], isTrue);
    expect(view['can_pay'], isFalse, reason: 'aucun caissier identifié');
    expect(view['total_label'], '1 000 F');
    expect((view['products'] as List).first, containsPair('stock_label', '10'));
    await expectLater(run('login', {'operator_id': 7, 'pin': '0000'}), throwsA(isA<AdapterFailure>()));
    await run('login', {'operator_id': 7, 'pin': '1234'});
    expect((await run('view'))['can_pay'], isTrue);
  });

  test('C-REQ-004 : le panier est conservé et retrouvé après redémarrage de l’hôte', () async {
    await cartOf2Soaps();
    final draft = (await run('view'))['draft_id'];
    adapter = await boot(); // nouvel hôte sur la même base
    final view = await run('view');
    expect(view['draft_id'], draft);
    expect((view['lines'] as List).single['quantity_label'], '2');
    expect(view['payment_valid'], isTrue);
  });

  test('commitSale idempotent : rejoué avec le même identifiant, même vente, une seule opération', () async {
    await cartOf2Soaps();
    const op = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
    final first = await run('commitSale', const {}, op);
    expect(first['state'], 'committed');
    expect(first['number'], 'HL-001-000042');
    final replay = await run('commitSale', const {}, op);
    expect(replay['number'], first['number']);
    expect(await store.operations(), hasLength(1));
    expect((await run('view'))['lines'], isEmpty, reason: 'nouveau panier après la vente');

    // Hôte redémarré entre COMMIT et réponse : même réponse, toujours une seule vente.
    adapter = await boot();
    expect((await run('commitSale', const {}, op))['number'], first['number']);
    expect(await store.operations(), hasLength(1));
  });

  test('saleStatus : lu localement, attend l’encaissement en cours, « not_found » définitif ; jamais de réseau', () async {
    await cartOf2Soaps();
    const op = '11111111-2222-4333-8444-555555555555';
    final results = await Future.wait([run('commitSale', const {}, op), run('saleStatus', const {}, op)]);
    expect(results[1]['state'], 'committed', reason: 'la lecture passe après l’encaissement déjà demandé');
    expect(results[1]['number'], results[0]['number']);
    final unknown = await run('saleStatus', const {}, '99999999-2222-4333-8444-555555555555');
    expect(unknown, containsPair('state', 'not_found'));
    expect(unknown, containsPair('definitive', true));
    expect(transport.batches, isEmpty);
    expect(transport.stateCalls, isEmpty);
  });

  test('refus certain (paiement inexact) : not_committed, panier conservé, rien d’écrit', () async {
    await run('login', {'operator_id': 7, 'pin': '1234'});
    await run('scan', {'code': '6190000000011'});
    final failure = await run('setPayment', {'method': 'especes', 'amount': 500}).then<Object>((v) => v, onError: (Object e) => e);
    expect(failure, isA<AdapterFailure>().having((f) => f.notCommitted, 'notCommitted', isTrue));
    final noPayment = await run('commitSale', const {}, '22222222-2222-4333-8444-555555555555').then<Object>((v) => v, onError: (Object e) => e);
    expect(noPayment, isA<AdapterFailure>().having((f) => f.code, 'code', 'paiement_requis'));
    expect(await store.operations(), isEmpty);
    expect((await run('view'))['lines'], hasLength(1));
  });

  test('un panier encaissé ne peut plus être réécrit ; changer le panier invalide le paiement préparé', () async {
    await cartOf2Soaps();
    final draft = (await run('view'))['draft_id'] as String;
    final line = ((await run('view'))['lines'] as List).single['id'];
    expect((await run('changeQuantity', {'line_id': line, 'quantity': '3'}))['payment_valid'], isFalse);
    await run('setPayment', {'method': 'especes'});
    await run('commitSale', const {}, '33333333-2222-4333-8444-555555555555');
    expect(await adapter.engine.saveDraft(draft, 999, const {'lignes': []}), isFalse);
    expect(await store.openDrafts(), isEmpty);
  });

  test('historique et duplicata : prix et numéro tels qu’encaissés', () async {
    await cartOf2Soaps();
    const op = '44444444-2222-4333-8444-555555555555';
    await run('commitSale', const {}, op);
    final history = await run('history');
    expect((history['items'] as List).single, containsPair('operation_id', op));
    final ticket = (await run('reprint', const {}, op))['lines'] as List;
    expect(ticket.join('\n'), contains('HL-001-000042'));
    expect(ticket.join('\n'), contains('DUPLICATA'));
  });

  test('pair : appairage d’un poste neuf par commande (Windows), code refusé puis accepté', () async {
    final fresh = await SqfliteOfflineStore.open(name: p.join(dir.path, 'neuf.db'), factory: databaseFactoryFfi);
    final a = LocalRegisterAdapter(OfflineEngine(store: fresh, transport: transport, newUuid: uuid), newUuid: uuid);
    await a.start();
    expect((await a.execute('status', const {}, null))['paired'], isFalse);
    final args = {'origin': 'https://boutique.exemple.ci', 'model': 'Windows 11', 'app_version': '1.2.0'};
    await expectLater(a.execute('pair', {...args, 'code': 'MAUVAIS'}, null), throwsA(isA<AdapterFailure>()));
    final status = await a.execute('pair', {...args, 'code': 'ABCD-EFGH'}, null);
    expect(status['paired'], isTrue);
    expect(status['ready'], isTrue);
    await fresh.close();
  });

  test('synchronize planifie sans attendre et ne renvoie aucune vente à arbitrer', () async {
    await cartOf2Soaps();
    transport.verdict = (_) => 'a_arbitrer';
    await run('commitSale', const {}, '55555555-2222-4333-8444-555555555555');
    expect(await run('synchronize'), {'scheduled': true});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(transport.batches, hasLength(1));
    expect((await run('status'))['arbitration'], 1);
  });
}
