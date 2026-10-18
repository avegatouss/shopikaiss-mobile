// Essai de bout en bout contre une boutique ShopiKaiss réelle (serveur local ou de recette), hors de `flutter test` :
//
//   flutter test integration_local/serveur_local_test.dart \
//     --dart-define=SK_URL=http://127.0.0.1:8765 --dart-define=SK_CODE1=XXXX-XXXX --dart-define=SK_CODE2=YYYY-YYYY
//
// Deux terminaux de la même boutique vendent hors ligne le même article (stock 5 : 4 + 3 vendus), puis synchronisent.
// Voir docs/CAISSE-HORS-LIGNE.md (« Essai de bout en bout »).
import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/offline/api.dart';
import 'package:shopikaiss_terminal/src/offline/engine.dart';
import 'package:shopikaiss_terminal/src/offline/models.dart';
import 'package:shopikaiss_terminal/src/offline/store.dart';

/// Transport réel qu'on peut « débrancher » pour simuler la coupure.
class SwitchableTransport implements RegisterTransport {
  SwitchableTransport(this.inner);

  final RegisterTransport inner;
  bool online = true;
  static const _off = ApiResponse(0, {'message': 'coupure simulée'});

  @override
  Future<ApiResponse> pair(String a, String c, String m, String v) async => online ? inner.pair(a, c, m, v) : _off;
  @override
  Future<ApiResponse> status(String a, String t) async => online ? inner.status(a, t) : _off;
  @override
  Future<ApiResponse> snapshot(String a, String t) async => online ? inner.snapshot(a, t) : _off;
  @override
  Future<ApiResponse> synchronize(String a, String t, List<Map<String, dynamic>> o) async => online ? inner.synchronize(a, t, o) : _off;
}

void main() {
  const url = String.fromEnvironment('SK_URL');
  const code1 = String.fromEnvironment('SK_CODE1');
  const code2 = String.fromEnvironment('SK_CODE2');

  test('deux terminaux vendent hors ligne puis synchronisent', () async {
    if (url.isEmpty || code1.isEmpty || code2.isEmpty) {
      markTestSkipped('SK_URL, SK_CODE1 et SK_CODE2 requis');
      return;
    }
    final t1 = SwitchableTransport(HttpRegisterTransport(appVersion: 'essai'));
    final t2 = SwitchableTransport(HttpRegisterTransport(appVersion: 'essai'));
    final e1 = OfflineEngine(store: MemoryOfflineStore(), transport: t1);
    final e2 = OfflineEngine(store: MemoryOfflineStore(), transport: t2);
    await e1.load(url);
    await e2.load(url);
    expect(await e1.pair(code1, model: 'Essai 1', appVersion: 'essai'), isNull);
    expect(await e2.pair(code2, model: 'Essai 2', appVersion: 'essai'), isNull);

    final s1 = e1.snapshot!;
    expect(s1.available, isTrue);
    expect(s1.sessionOpen, isTrue);
    final soap = s1.products.firstWhere((p) => p.name.startsWith('Savon'));
    final rice = s1.products.firstWhere((p) => p.name.startsWith('Riz'));
    expect(s1.byCode('6190000000011')!.$1.id, soap.id);
    final cashier = s1.operators.firstWhere((o) => o.name == 'Awa Koné');
    expect(await e1.checkPin(cashier, '1234'), isTrue);
    expect(await e1.checkPin(cashier, '0000'), isFalse);

    // Coupure : les deux terminaux vendent le même savon (stock 5) et du riz au poids.
    t1.online = false;
    t2.online = false;
    expect(await e1.probe(), isFalse);
    expect(e1.blockReason, isNull);
    final cash1 = s1.methods.firstWhere((m) => m.isCash);
    final lines1 = [CartLine(product: soap, quantity: BigInt.from(4000000)), CartLine(product: rice, quantity: BigInt.from(500000))];
    final sale1 = await e1.recordSale(lines1, [CartPayment(method: cash1, amount: 4167, received: 5000)], cashier);
    final s2 = e2.snapshot!;
    final soap2 = s2.products.firstWhere((p) => p.id == soap.id);
    final sale2 = await e2.recordSale([CartLine(product: soap2, quantity: BigInt.from(3000000))],
        [CartPayment(method: s2.methods.firstWhere((m) => m.isCash), amount: 3000, received: 3000)], s2.operators.firstWhere((o) => o.id == cashier.id));
    expect(sale1.number, isNot(sale2.number));
    expect(sale1.total, 4167);

    // Retour de la connexion.
    t1.online = true;
    t2.online = true;
    expect(await e1.probe(), isTrue);
    final r1 = await e1.sync();
    final r2 = await e2.sync();
    expect([r1.integrated, r2.integrated], [1, 1], reason: '${r1.message} ${r2.message} ${(await e1.history()).map((o) => o.message)}');
    final h1 = (await e1.history()).single;
    expect(h1.serverStatus, 'integree');
    expect(h1.serverNumber, isNotNull);

    // Renvoi du même lot : aucune vente en double, même numéro.
    final again = await HttpRegisterTransport().synchronize(e1.apiBase!, (await e1.store.read(StoreKeys.token))!, [sale1.toPayload()]);
    expect((again.body['resultats'] as List).single['numero'], h1.serverNumber);

    expect(await e1.refreshSnapshot(), isNull);
    final after = e1.snapshot!.products.firstWhere((p) => p.id == soap.id);
    expect(after.signedStock, BigInt.from(-2000000), reason: 'stock 5 − 4 − 3 : la vente hors ligne n’est jamais refusée');
    // ignore: avoid_print
    print('Ventes intégrées : ${h1.serverNumber} (ticket ${sale1.number}) et ${(await e2.history()).single.serverNumber} (ticket ${sale2.number})');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
