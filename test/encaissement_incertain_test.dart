import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shopikaiss_terminal/src/offline/models.dart';
import 'package:shopikaiss_terminal/src/offline/store.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_v2_server.dart';
import 'sync_v2_engine_test.dart' show serve21;

/// Encaissement à l'issue incertaine (audit M02, relecture de A du 23/11) : l'écran garde le même identifiant de vente
/// pour le panier ; un nouvel essai après une vente déjà enregistrée ne crée rien, même si le panier a changé entre-temps,
/// et le ticket suit la vente enregistrée.
void main() {
  sqfliteFfiInit();
  late Directory dir;
  late SqfliteOfflineStore base;
  late FakeV2Server server;
  var uuids = 0;
  String newUuid() => 'abcdef00-0000-4000-8000-${(++uuids).toString().padLeft(12, '0')}';

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('incertain_');
    base = await SqfliteOfflineStore.open(name: p.join(dir.path, 'caisse.db'), factory: databaseFactoryFfi);
    server = FakeV2Server.sellable();
    serve21(server);
  });
  tearDown(() async {
    await base.close();
    dir.deleteSync(recursive: true);
  });

  test('vente déjà enregistrée, panier modifié puis nouvel essai : aucune seconde vente, écart détecté, ticket de l’opération', () async {
    final e = V2Engine.onStore(base, transport: server, appVersion: 'essai', platform: 'android', newUuid: newUuid,
        pinVerifier: FakeV2Server.pinVerifier, contract21: true, clock: () => DateTime.utc(2026, 11, 23, 15));
    await e.load('https://boutique.exemple.ci');
    expect(await e.pair('ABCD-EFGH', model: 'Téléphone', appVersion: 'essai'), isNull);
    await e.sync();
    final operator = e.snapshot!.operators.single;
    final product = e.snapshot!.byCode('6190000000011')!.$1;
    final method = e.snapshot!.methods.single;
    CartLine soaps(int n) => CartLine(product: product, quantity: BigInt.from(n * 1000000));
    const attempt = 'aaaaaaaa-bbbb-4ccc-8ddd-0000000000c1';
    const draft = 'aaaaaaaa-bbbb-4ccc-8ddd-0000000000d1';

    // Premier essai : la vente est écrite, puis l'écran perd la réponse (erreur technique après l'écriture).
    final first = await e.recordSale([soaps(1)], [CartPayment(method: method, amount: 500, received: 500)], operator, draftUuid: draft, operationUuid: attempt);
    final firstTotal = (first.content['total'] as num).toInt();

    // L'écran retrouve la vente par son identifiant d'essai, avant tout nouveau paiement.
    final found = await e.saleStatus(attempt);
    expect(found?.uuid, first.uuid);

    // Le caissier a ajouté un savon entre-temps : l'écart est détecté.
    expect(e.saleMatches(found!, [soaps(2)], firstTotal * 2), isFalse);
    expect(e.saleMatches(found, [soaps(1)], firstTotal), isTrue);

    // Même s'il repaie le panier modifié avec le même identifiant, rien de nouveau n'est écrit.
    final again = await e.recordSale([soaps(2)], [CartPayment(method: method, amount: 1000, received: 1000)], operator, draftUuid: draft, operationUuid: attempt);
    expect(again.uuid, first.uuid);
    expect((await e.history()).where((o) => o.isSale), hasLength(1), reason: 'aucune seconde vente');

    // Le ticket suit l'opération enregistrée : 1 savon, 500 payés, pas le panier modifié.
    final (lines, payments) = e.ticketParts(again);
    expect([for (final l in lines) l.quantity], [BigInt.from(1000000)]);
    expect([for (final p in payments) p.amount], [500]);
  });
}
