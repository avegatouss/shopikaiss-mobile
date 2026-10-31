import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/offline/money.dart';
import 'package:shopikaiss_terminal/src/offline/web_rules.dart';

/// Exemples chiffrés du référentiel de parité (PARITE-CAISSE-WEB.md §3.15), obtenus par A avec le vrai code PHP.
void main() {
  int base(int price, String quantity) => lineBase(price, parseMicros(quantity)!);

  test('E1 — TVA ajoutée, remise de ligne %, remise globale %, livraison, arrondi espèces', () {
    final a = base(1500, '3');
    final b = base(2750, '2');
    final discountB = percentDiscount(b, parsePercent('10'), rounding: 'down');
    expect([a, b, discountB], [4500, 5500, 550]);
    final global = percentDiscount(a + b - discountB, parsePercent('5'), rounding: 'down');
    expect(global, 472);
    final t = webTotals(lineBases: [a, b], lineDiscounts: [0, discountB], globalDiscount: global, vatRate: '18.000000', vatIncluded: false, delivery: 1000);
    expect([t.subtotal, t.vat, t.net, t.baseHt, t.payable], [9450, 1616, 10594, 8978, 11594]);
    expect([t.gross, t.discounts], [10000, 1022], reason: 'brut et remises au sens du contrat (avant remises de ligne)');
    final cash = cashLine(11594, rounding: (step: 25, mode: 'nearest'), received: 20000);
    expect([cash.due, cash.change, cash.roundingGap], [11600, 8400, 6]);
  });

  test('E2 — TVA incluse, conditionnement, article à la mesure, arrondi down contre nearest', () {
    final carton = base(4800, '1');
    final kilo = base(1250, '1.235');
    final article = base(2999, '1');
    expect([carton, kilo], [4800, 1544]);
    final down = percentDiscount(article, parsePercent('12,5'), rounding: 'down');
    final nearest = percentDiscount(article, parsePercent('12.50'), rounding: 'nearest');
    expect([down, nearest], [374, 375]);
    final td = webTotals(lineBases: [carton, kilo, article], lineDiscounts: [0, 0, down], vatRate: '18.000000', vatIncluded: true);
    expect([td.subtotal, td.vat, td.baseHt, td.payable], [8969, 1368, 7601, 8969]);
    final tn = webTotals(lineBases: [carton, kilo, article], lineDiscounts: [0, 0, nearest], vatRate: '18.000000', vatIncluded: true);
    expect([tn.subtotal, tn.vat, tn.baseHt, tn.payable], [8968, 1368, 7600, 8968]);
    expect(formatPercent(parsePercent('12,50')), '12.5');
  });

  test('E6 et E7 — arrondi espèces vers le bas, au plus proche, vers le haut ; paiement mixte', () {
    final e6 = cashLine(7480, rounding: (step: 50, mode: 'down'));
    expect([e6.due, e6.change, e6.roundingGap], [7450, 0, -30]);
    expect(cashRound(7475, step: 50, mode: 'nearest'), 7450, reason: 'égalité vers le bas');
    expect(cashRound(7476, step: 50, mode: 'nearest'), 7500);
    expect(cashRound(7451, step: 50, mode: 'up'), 7500);
    final e7 = cashLine(4010, rounding: (step: 25, mode: 'nearest'), received: 5000);
    expect([e7.due, e7.change, e7.roundingGap], [4000, 1000, -10]);
    expect(4010 + 6000, 10010, reason: 'payé = montants exacts, jamais arrondis');
    // Exemple du contrat 2.1 §7.7 : 1 237 F, pas de 25 vers le bas.
    final c = cashLine(1237, rounding: (step: 25, mode: 'down'));
    expect([c.amount, c.roundingGap, c.due], [1237, -12, 1225]);
  });

  test('E8 — arrondis de TVA', () {
    final added = webTotals(lineBases: [base(333, '3')], lineDiscounts: [0], vatRate: '18.000000', vatIncluded: false);
    expect([added.subtotal, added.vat, added.payable], [999, 180, 1179]);
    final included = webTotals(lineBases: [999], lineDiscounts: [0], vatRate: '18.000000', vatIncluded: true);
    expect([included.vat, included.baseHt, included.payable], [152, 847, 999]);
  });

  test('E10 — bornes et refus (textes du web)', () {
    expect(() => webTotals(lineBases: [1000], lineDiscounts: [0], globalDiscount: 1500, vatRate: '0', vatIncluded: true),
        throwsA(isA<WebRuleRefusal>().having((r) => r.message, 'message', 'La remise globale dépasse le montant du panier.')));
    expect(() => enteredDiscount(type: 'montant', value: '1200', base: 1000, rounding: 'down', label: 'X'),
        throwsA(isA<WebRuleRefusal>().having((r) => r.message, 'message', 'La remise sur « X » (1 200 F) dépasse sa base de calcul (1 000 F).')));
    for (final bad in ['12,345', '0', '100.01', '1000', 'abc']) {
      expect(() => parsePercent(bad), throwsA(isA<WebRuleRefusal>()), reason: bad);
    }
    expect(percentDiscount(999, parsePercent('100'), rounding: 'nearest'), 999, reason: 'plafonné à la base');
  });

  test('E11 — seuil de remise du rôle : comparaison exacte', () {
    final ten = parseMicros('10.000000')!;
    expect(exceedsPercent(1544, 15400, ten), isTrue);
    expect(exceedsPercent(1540, 15400, ten), isFalse);
  });

  test('stock : demande convertie, alertes de la caisse web, plage horaire', () {
    final u = BigInt.from(1000000);
    expect(baseQuantity(u * BigInt.two, '12.000000'), u * BigInt.from(24));
    expect(stockAlert(u * BigInt.from(10), u * BigInt.from(2), null, null), isNull);
    expect(stockAlert(u * BigInt.from(10), u * BigInt.from(8), u * BigInt.from(3), null)!.message, 'Stock faible : il restera 2 après cette vente (seuil 3). Vente possible.');
    expect(stockAlert(u, u * BigInt.from(4), null, 'refuser')!.message, contains('refus strict'));
    expect(stockAlert(-u, u, null, 'autoriser_avec_droit')!.message, startsWith('Stock insuffisant : 0 pour une demande de 1.'));
    expect(validTimeWindow('22:00', '06:00'), isTrue);
    expect(validTimeWindow('22:00', '22:00'), isFalse);
    expect(validTimeWindow('24:00', '06:00'), isFalse);
  });
}
