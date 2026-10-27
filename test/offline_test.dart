import 'dart:convert';
import 'dart:io';

import 'package:bcrypt/bcrypt.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/offline/api.dart';
import 'package:shopikaiss_terminal/src/offline/engine.dart';
import 'package:shopikaiss_terminal/src/offline/models.dart';
import 'package:shopikaiss_terminal/src/offline/money.dart';
import 'package:shopikaiss_terminal/src/offline/store.dart';
import 'package:shopikaiss_terminal/src/offline/ticket.dart';

/// Serveur simulé : réponses du contrat `/api/caisse/v1` (ADR-421).
class FakeTransport implements RegisterTransport {
  bool online = true;
  int statusCode = 200;
  Map<String, dynamic> snapshotBody = sampleSnapshot();
  final List<List<Map<String, dynamic>>> batches = [];
  String Function(Map<String, dynamic> operation) verdict = (_) => 'integree';
  final Set<String> poisoned = {};

  ApiResponse _maybe(ApiResponse Function() ok) => !online ? const ApiResponse(0, {'message': 'hors ligne'}) : ok();

  @override
  Future<ApiResponse> pair(String apiBase, String code, String model, String appVersion) async => _maybe(
    () => code == 'ABCD-EFGH'
        ? const ApiResponse(200, {
            'jeton': 'abcdefabcdef.secret',
            'cle_web': 'cle',
            'appareil': {'nom': 'Caisse 1', 'terminal': 'Comptoir'},
          })
        : const ApiResponse(422, {'erreur': 'code_invalide', 'message': 'Code d’appairage invalide ou expiré.'}),
  );

  @override
  Future<ApiResponse> status(String apiBase, String token) async => _maybe(
    () =>
        statusCode == 200 ? const ApiResponse(200, {'operations_a_arbitrer': 0}) : ApiResponse(statusCode, const {'erreur': 'appareil_non_reconnu'}),
  );

  @override
  Future<ApiResponse> snapshot(String apiBase, String token) async => _maybe(() => ApiResponse(200, snapshotBody));

  @override
  Future<ApiResponse> synchronize(String apiBase, String token, List<Map<String, dynamic>> operations) async => _maybe(() {
    batches.add(operations);
    // Opération « empoisonnée » : le serveur plante (500) sur tout lot qui la contient.
    if (operations.any((o) => poisoned.contains(o['uuid']))) return const ApiResponse(500, {'message': 'Erreur du serveur'});
    return ApiResponse(200, {
      'resultats': [
        for (final o in operations)
          {
            'uuid': o['uuid'],
            'statut': verdict(o),
            'numero': verdict(o) == 'integree' ? 'V-${o['sequence']}' : null,
            'message': verdict(o) == 'integree' ? null : 'motif',
          },
      ],
    });
  });
}

Map<String, dynamic> sampleSnapshot({bool session = true, int lastSequence = 41, int maxSales = 500, int discount = 10}) => {
  'version': 1,
  'disponible': true,
  'raison': null,
  'boutique': {
    'nom': 'Boutique Élégance',
    'raison_sociale': 'Élégance SARL',
    'adresse': 'Cocody, Abidjan',
    'telephone': '0700000000',
    'tva_taux': '18.000000',
    'tva_incluse': true,
    'devise': 'FCFA',
    'pied': 'Merci de votre visite !',
  },
  'terminal': {'id': 1, 'nom': 'Comptoir', 'prefixe_tickets': 'HL-001'},
  'appareil': {'uuid': 'x', 'nom': 'Caisse 1', 'derniere_sequence': lastSequence},
  'reglages': {
    'duree_max_heures': 72,
    'ventes_max': maxSales,
    'montant_max_vente': null,
    'remise_ligne_max_pourcent': discount,
    'ouverture_session': true,
    'mode_caissier': 'pin',
    'rafraichissement_minutes': 30,
    'sondage_secondes': 20,
    'bascule': 'automatique',
    'exclusivite': 'session',
  },
  'session': session ? {'uuid': 's', 'ouverte_le': '2026-10-18T08:00:00+00:00', 'caissier_id': 7} : null,
  'dernier_caissier_id': 7,
  'licence_expire_le': null,
  'moyens': [
    {'code': 'especes', 'nom': 'Espèces', 'especes': true},
    {'code': 'wave', 'nom': 'Wave', 'especes': false},
  ],
  'caissiers': [
    {'id': 7, 'nom': 'Awa Koné', 'pin': BCrypt.hashpw('1234', BCrypt.gensalt(logRounds: 4)).replaceFirst(r'$2a$', r'$2y$')},
  ],
  'produits': [
    {
      'id': 10,
      'uuid': 'p',
      'nom': 'Savon à l’huile',
      'reference': 'SAV-1',
      'categorie': null,
      'prix': 1000,
      'stock_illimite': false,
      'stock': '10.000000',
      'conditionnements': [
        {'id': 3, 'nom': 'Carton de 12', 'coefficient': '12.000000', 'prix': 11000, 'defaut': false},
      ],
      'codes': [
        {'code': '6190000000011', 'conditionnement_id': null},
        {'code': '6190000000028', 'conditionnement_id': 3},
      ],
    },
    {
      'id': 11,
      'uuid': 'q',
      'nom': 'Riz parfumé 1 kg',
      'reference': null,
      'categorie': null,
      'prix': 333,
      'stock_illimite': false,
      'stock': '-2.000000',
      'conditionnements': [],
      'codes': [],
    },
  ],
  'genere_le': '2026-10-18T09:00:00+00:00',
  'empreinte': 'e',
};

void main() {
  group('Calcul identique au serveur (SaleCalculator)', () {
    final fixture = jsonDecode(File('test/fixtures/calcul_serveur.json').readAsStringSync()) as Map<String, dynamic>;
    final cases = fixture['cas'] as List;

    test('${cases.length} paniers calculés par le serveur donnent les mêmes totaux sur le terminal', () {
      for (final raw in cases) {
        final c = raw as Map<String, dynamic>;
        final totals = <int>[];
        for (final l in (c['lignes'] as List)) {
          final line = l as Map<String, dynamic>;
          totals.add(lineTotal(line['unit_price'] as int, parseMicros(line['quantity'] as String)!, line['line_discount'] as int));
        }
        expect(totals, c['totaux_lignes'], reason: jsonEncode(c));
        final sale = saleTotals(totals, c['tva'] as String, c['mode'] == 'INCLUSE');
        expect([sale.gross, sale.vat, sale.net, sale.baseHt], [c['brut'], c['tva_montant'], c['net'], c['base_ht']], reason: jsonEncode(c));
      }
    });

    test('quantités décimales lues et écrites comme le serveur', () {
      expect(parseMicros('2'), BigInt.from(2000000));
      expect(parseMicros('0,5'), BigInt.from(500000));
      expect(parseMicros('1.1234567'), isNull);
      expect(formatMicros(BigInt.from(1250000)), '1.25');
      expect(formatMicros(BigInt.from(3000000)), '3');
      expect(maxLineDiscount(1999, 10), 199);
      expect(formatFcfa(1250000), '1 250 000 F');
    });
  });

  group('Caisse hors ligne', () {
    late MemoryOfflineStore store;
    late FakeTransport transport;
    late DateTime clock;
    late OfflineEngine engine;
    var uuid = 0;

    Future<OfflineEngine> paired() async {
      store = MemoryOfflineStore();
      transport = FakeTransport();
      clock = DateTime(2026, 10, 18, 10);
      engine = OfflineEngine(store: store, transport: transport, clock: () => clock, newUuid: () => 'u-${uuid++}');
      await engine.load('https://boutique.exemple.ci');
      expect(await engine.pair('ABCD-EFGH', model: 'SUNMI T2', appVersion: '1.1.0'), isNull);
      return engine;
    }

    Operator cashier() => engine.snapshot!.operators.first;
    PaymentMethodInfo cash() => engine.snapshot!.methods.first;
    CartLine soap({int quantity = 2, int discount = 0}) =>
        CartLine(product: engine.snapshot!.products.first, quantity: BigInt.from(quantity * 1000000), discount: discount);

    test('appairage : code refusé, puis jeton, clé web et catalogue', () async {
      store = MemoryOfflineStore();
      transport = FakeTransport();
      engine = OfflineEngine(store: store, transport: transport);
      await engine.load('https://boutique.exemple.ci');
      expect(engine.blockReason, contains('non appairée'));
      expect(await engine.pair('MAUVAIS', model: 'x', appVersion: '1'), 'Code d’appairage invalide ou expiré.');
      expect(await engine.pair('ABCD-EFGH', model: 'x', appVersion: '1'), isNull);
      expect(engine.paired, isTrue);
      expect(engine.webToken, 'cle');
      expect(engine.snapshot!.products, hasLength(2));
      expect(store.values[StoreKeys.apiBase], 'https://boutique.exemple.ci/api/caisse/v1');
      expect(engine.blockReason, isNull);
    });

    test('vente : numéro du terminal à la suite de la séquence, payload du contrat, monnaie', () async {
      await paired();
      final sale = await engine.recordSale([soap()], [CartPayment(method: cash(), amount: 2000, received: 5000)], cashier());
      expect(sale.number, 'HL-001-000042');
      expect(sale.sequence, 42);
      final payload = sale.toPayload();
      expect(payload['type'], 'vente');
      expect(payload['caissier_id'], 7);
      expect(payload['contenu'], {
        'lignes': [
          {'produit_id': 10, 'conditionnement_id': null, 'quantite': '2', 'prix_unitaire': 1000, 'remise': 0},
        ],
        'paiements': [
          {'moyen': 'especes', 'montant': 2000, 'recu': 5000},
        ],
        'total': 2000,
      });
      expect(payload['date'], startsWith('2026-10-18T10:00:00'));
      final second = await engine.recordSale([soap(quantity: 1)], [CartPayment(method: cash(), amount: 1000)], cashier());
      expect(second.number, 'HL-001-000043');
      expect(engine.pendingCount, 2);
      expect((await engine.soldSinceSnapshot())[10], BigInt.from(3000000));
    });

    test('règles : paiement inexact, remise au-delà du maximum, moyen non autorisé', () async {
      await paired();
      expect(() => engine.recordSale([soap()], [CartPayment(method: cash(), amount: 1500)], cashier()), throwsA(isA<OfflineRefusal>()));
      expect(() => engine.recordSale([soap(discount: 201)], [CartPayment(method: cash(), amount: 1799)], cashier()), throwsA(isA<OfflineRefusal>()));
      final ok = await engine.recordSale([soap(discount: 200)], [CartPayment(method: cash(), amount: 1800)], cashier());
      expect(ok.total, 1800);
      final foreign = PaymentMethodInfo({'code': 'credit', 'nom': 'Crédit'});
      expect(() => engine.recordSale([soap()], [CartPayment(method: foreign, amount: 2000)], cashier()), throwsA(isA<OfflineRefusal>()));
    });

    test('limites : session absente, durée hors ligne, nombre de ventes', () async {
      await paired();
      transport.snapshotBody = sampleSnapshot(session: false, maxSales: 2);
      await engine.refreshSnapshot();
      expect(() => engine.recordSale([soap()], [CartPayment(method: cash(), amount: 2000)], cashier()), throwsA(isA<OfflineRefusal>()));
      final opening = await engine.openSession(5000, cashier());
      expect(opening.type, 'ouverture_session');
      expect(engine.sessionOpen, isTrue);
      await engine.recordSale([soap()], [CartPayment(method: cash(), amount: 2000)], cashier());
      expect(engine.blockReason, isNull);
      await engine.recordSale([soap()], [CartPayment(method: cash(), amount: 2000)], cashier());
      expect(engine.blockReason, contains('Nombre maximal'));

      transport.snapshotBody = sampleSnapshot();
      transport.online = false;
      clock = clock.add(const Duration(hours: 73));
      expect(engine.blockReason, contains('Durée hors ligne dépassée'));
    });

    test('synchronisation : ordre de séquence, statuts du serveur, file vidée', () async {
      await paired();
      transport.online = false;
      expect(await engine.probe(), isFalse);
      expect(engine.lastUnreachable, isTrue);
      for (var i = 0; i < 3; i++) {
        await engine.recordSale([soap(quantity: 1)], [CartPayment(method: cash(), amount: 1000)], cashier());
      }
      transport.online = true;
      transport.verdict = (o) => o['sequence'] == 43 ? 'a_arbitrer' : 'integree';
      final report = await engine.sync();
      expect(report.sent, 3);
      expect(report.integrated, 2);
      expect(report.pending, 1);
      expect(engine.pendingCount, 0);
      expect(transport.batches.single.map((o) => o['sequence']), [42, 43, 44]);
      final history = await engine.history();
      expect(history.map((o) => o.serverStatus), ['integree', 'a_arbitrer', 'integree']);
      expect(history.first.serverNumber, 'V-42');
    });

    test('boutique changée avec une file en attente : la file reste à l’ancienne boutique', () async {
      await paired();
      await engine.recordSale([soap()], [CartPayment(method: cash(), amount: 2000)], cashier());
      await engine.load('https://autre.exemple.ci');
      expect(engine.shopMismatch, isTrue);
      expect(engine.apiBase, 'https://boutique.exemple.ci/api/caisse/v1');
      expect(engine.blockReason, contains('ancienne boutique'));
      expect(await engine.pair('ABCD-EFGH', model: 'x', appVersion: '1'), contains('ancienne boutique'));
      expect((await engine.sync()).integrated, 1);
      await engine.load('https://autre.exemple.ci');
      expect(engine.shopMismatch, isFalse);
      expect(engine.paired, isFalse);
      expect(engine.apiBase, 'https://autre.exemple.ci/api/caisse/v1');
    });

    test('révocation : un 401 retire le jeton et bloque la vente hors ligne', () async {
      await paired();
      transport.statusCode = 401;
      expect(await engine.probe(), isFalse);
      expect(engine.paired, isFalse);
      expect(engine.blockReason, contains('révoquée'));
    });

    test('PIN : empreinte bcrypt du serveur (\$2y\$) vérifiée sur le terminal', () async {
      await paired();
      expect(await engine.checkPin(cashier(), '1234'), isTrue);
      expect(await engine.checkPin(cashier(), '9999'), isFalse);
      expect(await engine.checkPin(cashier(), '12'), isFalse);
    });

    test('ticket : largeur du rouleau, numéro hors ligne, sans accents', () async {
      await paired();
      final lines = [soap()];
      final payments = [CartPayment(method: cash(), amount: 2000, received: 5000)];
      final sale = await engine.recordSale(lines, payments, cashier());
      for (final width in [58, 80]) {
        final ticket = offlineTicketLines(
          snapshot: engine.snapshot!,
          operation: sale,
          lines: lines,
          payments: payments,
          operatorName: 'Awa Koné',
          paperWidth: width,
        );
        expect(ticket.every((l) => l.length <= (width == 80 ? 48 : 32)), isTrue, reason: ticket.join('\n'));
        expect(ticket.join('\n'), contains('HL-001-000042'));
        expect(ticket.join('\n'), contains('Elegance SARL'));
        expect(ticket.join('\n'), contains('Monnaie rendue'));
        expect(ticket.join('\n'), contains('dont TVA 18 %'));
        expect(ticket.any((l) => RegExp(r'[^\x20-\x7E]').hasMatch(l)), isFalse);
      }
      expect(offlineTicketBytes(['A', 'B']).length, greaterThan(4));
    });

    test('recherche et code-barres de conditionnement', () async {
      await paired();
      final s = engine.snapshot!;
      expect(s.search('savon').single.id, 10);
      expect(s.search('HUILE').single.id, 10);
      expect(s.byCode('6190000000028')!.$2, 3);
      expect(s.products[1].signedStock, BigInt.from(-2000000));
    });

    test('une opération qui fait planter le serveur est isolée : les autres partent, elle reste pour un nouvel essai', () async {
      await paired();
      final first = await engine.recordSale([soap(quantity: 1)], [CartPayment(method: cash(), amount: 1000)], cashier());
      final poison = await engine.recordSale([soap(quantity: 1)], [CartPayment(method: cash(), amount: 1000)], cashier());
      final last = await engine.recordSale([soap(quantity: 1)], [CartPayment(method: cash(), amount: 1000)], cashier());
      transport.poisoned.add(poison.uuid);

      final report = await engine.sync();
      expect(report.integrated, 2);
      expect(report.deferred, 1);
      expect(report.message, contains('nouvel essai'));
      final history = {for (final o in await engine.history()) o.uuid: o};
      expect(history[first.uuid]!.status, OperationStatus.sent);
      expect(history[last.uuid]!.status, OperationStatus.sent);
      expect(history[poison.uuid]!.status, OperationStatus.pending);
      expect(history[poison.uuid]!.message, contains('(500)'));
      expect(engine.pendingCount, 1);

      transport.poisoned.clear();
      expect((await engine.sync()).integrated, 1, reason: 'Gardée, elle repart à la synchronisation suivante.');
      expect(engine.pendingCount, 0);
    });

    test('coupure pendant l’isolement : arrêt immédiat, rien n’est marqué', () async {
      await paired();
      final sale = await engine.recordSale([soap(quantity: 1)], [CartPayment(method: cash(), amount: 1000)], cashier());
      transport.online = false;
      final report = await engine.sync();
      expect(report.reachable, isFalse);
      expect((await engine.history()).single.status, OperationStatus.pending);
      expect(sale.message, isNull);
    });

    test('PIN : trois échecs bloquent, même après redémarrage de l’application ; un succès remet à zéro', () async {
      await paired();
      for (var i = 0; i < 3; i++) {
        expect(await engine.checkPin(cashier(), '9999'), isFalse);
      }
      expect(await engine.pinLockedFor(cashier()), isNotNull);
      expect(await engine.checkPin(cashier(), '1234'), isFalse, reason: 'Bon PIN refusé pendant le blocage.');

      // Redémarrage : nouveau moteur sur la même mémoire du terminal.
      final restarted = OfflineEngine(store: store, transport: transport, clock: () => clock);
      await restarted.load('https://boutique.exemple.ci');
      expect(await restarted.pinLockedFor(restarted.snapshot!.operators.first), isNotNull);

      clock = clock.add(const Duration(seconds: 31));
      expect(await restarted.checkPin(restarted.snapshot!.operators.first, '1234'), isTrue);
      expect(await restarted.pinLockedFor(restarted.snapshot!.operators.first), isNull);
      expect(store.values['${StoreKeys.pinFailures}7'], isNull);
    });

    test('réimpression : prix et quantités tels qu’encaissés, article disparu du catalogue nommé par son numéro', () async {
      await paired();
      final sale = await engine.recordSale(
        [soap(quantity: 2, discount: 100)],
        [CartPayment(method: cash(), amount: 1900, received: 2000)],
        cashier(),
      );
      final changed = sampleSnapshot();
      (changed['produits'] as List).removeAt(0);
      transport.snapshotBody = changed;
      await engine.refreshSnapshot();

      final (lines, payments) = engine.ticketParts(sale);
      expect(lines.single.label, 'Article n° 10');
      expect(lines.single.unitPrice, 1000);
      expect(lines.single.quantity, BigInt.from(2000000));
      expect(lines.single.total, 1900);
      expect(payments.single.change, 100);
      final ticket = offlineTicketLines(
        snapshot: engine.snapshot!,
        operation: sale,
        lines: lines,
        payments: payments,
        operatorName: 'Awa',
        paperWidth: 58,
        duplicate: true,
      );
      expect(ticket.join('\n'), contains('DUPLICATA'));
      expect(ticket.join('\n'), contains(sale.number));
    });
  });
}
