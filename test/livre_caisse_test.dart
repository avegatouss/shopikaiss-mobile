import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shopikaiss_terminal/src/offline/engine.dart';
import 'package:shopikaiss_terminal/src/offline/models.dart';
import 'package:shopikaiss_terminal/src/offline/store.dart';
import 'package:shopikaiss_terminal/src/register/register_adapter.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_engine.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_transport.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_v2_server.dart';
import 'sync_v2_engine_test.dart' show serve21;

/// Livre de caisse sur le poste (contrat 2.1 lot 14, note A LOT-14-LIVRE-CAISSE-POUR-B-ET-C.md).
void main() {
  sqfliteFfiInit();
  late Directory dir;
  late SqfliteOfflineStore base;
  late FakeV2Server server;
  var uuids = 0;
  var clock = DateTime.now();
  String newUuid() => 'abcdef00-0000-4000-8000-${(++uuids).toString().padLeft(12, '0')}';
  Map<String, dynamic> fixture(String name) =>
      Map<String, dynamic>.from(jsonDecode(File('test/fixtures/contrat-v2/fixtures/valides/$name.json').readAsStringSync()) as Map);

  setUp(() async {
    clock = DateTime.now();
    dir = Directory.systemTemp.createTempSync('livre_caisse_');
    base = await SqfliteOfflineStore.open(name: p.join(dir.path, 'caisse.db'), factory: databaseFactoryFfi);
    server = FakeV2Server.sellable();
  });
  tearDown(() async {
    await base.close();
    dir.deleteSync(recursive: true);
  });

  void serve({bool capability = true}) {
    serve21(server);
    Map<String, dynamic> operator(String id, String name, List<String> rights) => {
      'operateur_id': id, 'nom': name, 'pin_empreinte': 'empreinte', 'droits': rights,
      'remise_max_pourcent': null, 'remise_max_montant': null, 'approbateur_remise': false,
    };
    server
      ..capabilities = ['instantane.v1', 'stock.couverture', 'vente.especes', 'vente.paiement_declare', 'contrat.2_1', 'session.cloture', if (capability) 'livre_caisse.v1']
      ..put('operateur', 'operateur:7', operator('7', 'Awa', ['caisse_cloturer', 'livre_caisse_voir', 'ouverture_session', 'vente']), critical: true)
      ..put('operateur', 'operateur:8', operator('8', 'Koffi', ['ouverture_session', 'vente']), critical: true)
      ..put('politique', 'session.ouverture_locale', {'cle_politique': 'session.ouverture_locale', 'valeur': true, 'source': 'boutique', 'verrouillee': false});
  }

  Future<V2Engine> engine() async {
    final e = V2Engine.onStore(base, transport: server, appVersion: 'essai', platform: 'windows', newUuid: newUuid, clock: () => clock,
        pinVerifier: (pin, hash) async => pin == '1234' && hash == 'empreinte', declaredPayments: true, contract21: true);
    await e.load('https://boutique.exemple.ci');
    expect(await e.pair('ABCD-EFGH', model: 'Essai', appVersion: 'essai'), isNull);
    expect((await e.sync()).reachable, isTrue);
    return e;
  }

  Operator op(V2Engine e, String name) => e.snapshot!.operators.firstWhere((o) => o.name == name);
  Product savon(V2Engine e) => e.snapshot!.products.firstWhere((p) => p.name == 'Savon');
  CartPayment cash(V2Engine e, int amount) => CartPayment(method: e.snapshot!.methods.firstWhere((m) => m.isCash), amount: amount, received: amount);
  Matcher refused(String text) => throwsA(isA<OfflineRefusal>().having((r) => r.message, 'message', contains(text)));

  /// Session ouverte par Awa ici (fond 1 000), une vente espèces de 500, clôturée à 1 500.
  Future<void> daySession(V2Engine e) async {
    await e.closeSession(op(e, 'Awa'), cash: 0);
    await e.openSession(1000, op(e, 'Awa'));
    await e.recordSale([CartLine(product: savon(e))], [cash(e, 500)], op(e, 'Awa'));
    await e.closeSession(op(e, 'Awa'), cash: 1500);
  }

  test('livre local : colonnes du web, ordre de la session, totaux ; caissier limité à ses sessions ; période contrôlée', () async {
    serve();
    final e = await engine();
    await daySession(e);
    final today = e.today;
    final book = (await e.localCashBook(op(e, 'Awa'), from: today, to: today))!;
    // Session ouverte au web et clôturée ici : sa clôture seule, attendu inconnu (fond inconnu du poste).
    expect((book.rows.first.nature, book.rows.first.expected, book.rows.first.counted), ('Clôture (poste)', null, 0));
    expect([for (final r in book.rows.skip(1)) (r.nature, r.method, r.cashIn, r.cashOut, r.others)], [
      ('Ouverture de session (fond de caisse)', 'Espèces', 1000, 0, 0),
      ('Ventes encaissées', 'Espèces', 500, 0, 0),
      ('Clôture (poste)', 'Espèces', 0, 0, 0),
    ]);
    final closure = book.rows.last;
    expect((closure.expected, closure.counted, closure.difference, closure.isClosure), (1500, 1500, 0, true));
    expect((book.cashIn, book.cashOut, book.salesCount, book.salesAmount, book.online, book.storeWide), (1500, 0, 1, 500, false, false));
    expect([for (final m in book.methods) (m.method, m.collected, m.refunded, m.net)], [('Espèces', 500, 0, 500)]);
    expect((await e.localCashBook(op(e, 'Koffi'), from: today, to: today))!.rows, isEmpty, reason: 'caissier sans le droit : ses sessions seulement');
    expect((await e.localCashBook(op(e, 'Awa'), from: shiftDay(today, -3), to: shiftDay(today, -1)))!.rows, isEmpty);
    await expectLater(e.localCashBook(op(e, 'Awa'), from: today, to: shiftDay(today, -1)), refused('précède'));
  });

  test('livre en ligne : gérant seulement, pages réunies, PIN jamais transmis, copie gardée 30 jours puis effacée, refus lisibles', () async {
    serve();
    final e = await engine();
    final today = e.today;
    expect((e.onlineCashBookSupported, e.canReadOnlineCashBook(op(e, 'Awa')), e.canReadOnlineCashBook(op(e, 'Koffi'))), (true, true, false));
    server.cashBookPages = (query) => query['suite'] == null ? fixture('livre-caisse-reponse--page-avec-suite') : fixture('livre-caisse-reponse--nominal');
    final from = shiftDay(today, -7);
    final book = await e.fetchCashBook(op(e, 'Awa'), from: from, to: today);
    expect(server.lastCashBookQuery, {'du': from, 'au': today, 'operateur_id': '7', 'suite': '2026-11-19'});
    final nominal = fixture('livre-caisse-reponse--nominal');
    expect((book.online, book.storeWide, book.rows.length), (true, true, (nominal['mouvements'] as List).length));
    expect(book.cashIn, (nominal['totaux_page'] as Map)['entree_especes']);
    expect(book.salesCount, (nominal['totaux_par_moyen'] as Map)['ventes_nombre']);
    expect((await e.cachedCashBook(op(e, 'Awa')))!.rows.length, book.rows.length);
    expect(await e.cachedCashBook(op(e, 'Koffi')), isNull, reason: 'copie montrée seulement à un gérant');

    await expectLater(e.fetchCashBook(op(e, 'Koffi'), from: today, to: today), refused('réservé aux gérants'));
    await expectLater(e.fetchCashBook(op(e, 'Awa'), from: shiftDay(today, -40), to: today), refused('30 jours'));
    await expectLater(e.fetchCashBook(op(e, 'Awa'), from: today, to: shiftDay(today, 1)), refused('après aujourd’hui'));
    server.cashBookRefusal = const V2Response(403, {
      'erreur': {'code': 'politique_refusee', 'message': 'Refusé', 'reessayer_apres_secondes': null, 'details': {'motif': 'droit_absent'}},
    });
    await expectLater(e.fetchCashBook(op(e, 'Awa'), from: today, to: today), refused('Voir les rapports'));
    server.cashBookRefusal = const V2Response(0, null);
    await expectLater(e.fetchCashBook(op(e, 'Awa'), from: today, to: today), refused('Boutique injoignable'));

    // Copie de plus de 30 jours : effacée.
    clock = clock.add(const Duration(days: 31));
    expect(await e.cachedCashBook(op(e, 'Awa')), isNull);
    clock = clock.subtract(const Duration(days: 31));
    expect(await e.cachedCashBook(op(e, 'Awa')), isNull, reason: 'effacée, pas seulement masquée');
  });

  test('sans la capacité : livre en ligne non proposé ; adaptateur : cashBook, cashBookOnline, cashBookCached, capacité', () async {
    serve(capability: false);
    var e = await engine();
    expect(e.onlineCashBookSupported, isFalse);
    await expectLater(e.fetchCashBook(op(e, 'Awa'), from: e.today, to: e.today), refused('non disponible'));

    serve();
    e = await engine();
    await daySession(e);
    final adapter = LocalRegisterAdapter(e, newUuid: newUuid);
    await adapter.start();
    await adapter.execute('login', {'operator_id': 7, 'pin': '1234'}, null);
    final status = await adapter.execute('status', {}, null);
    expect(((status['capabilities'] as Map)['cash_book_online'] as Map)['allowed'], isTrue);
    final local = await adapter.execute('cashBook', {'from': e.today, 'to': e.today}, null);
    expect((((local['book'] as Map)['mouvements']) as List).length, 4);
    expect(((local['book'] as Map)['totaux_page'] as Map)['entree_especes'], 1500);
    await expectLater(adapter.execute('cashBook', {'from': '22/11/2026', 'to': e.today}, null),
        throwsA(isA<AdapterFailure>().having((f) => f.code, 'code', 'argument_invalide')));
    server.cashBookPages = (_) => fixture('livre-caisse-reponse--nominal');
    final online = await adapter.execute('cashBookOnline', {'from': e.today, 'to': e.today}, null);
    expect((online['book'] as Map)['en_ligne'], isTrue);
    expect(((await adapter.execute('cashBookCached', {}, null))['book'] as Map)['genere_le'], isNotNull);
    await adapter.execute('logout', {}, null);
    await adapter.execute('login', {'operator_id': 8, 'pin': '1234'}, null);
    final koffi = await adapter.execute('status', {}, null);
    expect(((koffi['capabilities'] as Map)['cash_book_online'] as Map)['reason'], 'Livre en ligne réservé aux gérants.');
    expect((await adapter.execute('cashBookCached', {}, null))['book'], isNull);
    await adapter.close();
  });
}
