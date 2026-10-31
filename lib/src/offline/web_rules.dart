/// Règles de calcul de la caisse web reprises au franc près (référentiel de parité de A, PARITE-CAISSE-WEB.md §3,
/// contrat v2 2.1) : remise saisie en pourcentage, remise globale, TVA sur le panier, livraison, arrondi espèces.
///
/// Les montants restent entiers (FCFA) ; les pourcentages saisis ont deux décimales au plus et sont calculés en
/// centièmes, sans nombre à virgule. Exemples de référence : PARITE-CAISSE-WEB.md §3.15 (E1 à E11), repris par
/// test/web_rules_test.dart.
library;

import 'money.dart';

/// Refus d'une saisie ou d'un calcul, avec le texte de la caisse web.
class WebRuleRefusal implements Exception {
  const WebRuleRefusal(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Pourcentage saisi (`12,50`, `12.5`, `100`) en centièmes (1250), selon `ManualDiscount` : virgule ou point, trois
/// chiffres et deux décimales au plus, de 0,01 à 100.
int parsePercent(String input) {
  final match = RegExp(r'^(\d{1,3})(?:[.,](\d{1,2}))?$').firstMatch(input.trim());
  final hundredths = match == null ? 0 : int.parse(match.group(1)!) * 100 + int.parse((match.group(2) ?? '').padRight(2, '0'));
  if (hundredths <= 0 || hundredths > 10000) {
    throw const WebRuleRefusal('Pourcentage de remise invalide : de 0,01 à 100, deux décimales au plus.');
  }
  return hundredths;
}

/// Écriture normalisée d'un pourcentage, sans zéros finaux (« 12,50 » → « 12.5 »), figée dans `remise_saisie`.
String formatPercent(int hundredths) {
  final whole = hundredths ~/ 100;
  final fraction = (hundredths % 100).toString().padLeft(2, '0').replaceFirst(RegExp(r'0+$'), '');
  return fraction.isEmpty ? '$whole' : '$whole.$fraction';
}

/// Montant d'une remise en pourcentage : `min(base, arrondi(base × p / 100))`, arrondi selon la règle de la boutique
/// (`remise_pourcentage_arrondi`) : `down` = franc inférieur (défaut), `nearest` = moitié vers le haut.
int percentDiscount(int base, int hundredths, {required String rounding}) {
  final numerator = BigInt.from(base) * BigInt.from(hundredths);
  final denominator = BigInt.from(10000);
  final amount = (rounding == 'nearest' ? divideHalfUp(numerator, denominator) : numerator ~/ denominator).toInt();
  return amount > base ? base : amount;
}

/// Remise saisie en montant ou en pourcentage, contrôlée contre sa base (texte du web pour un dépassement).
int enteredDiscount({required String type, required String value, required int base, required String rounding, String? label}) {
  if (type == 'pourcentage') return percentDiscount(base, parsePercent(value), rounding: rounding);
  final amount = int.tryParse(value.trim());
  if (amount == null || amount <= 0) throw const WebRuleRefusal('Remise invalide : montant entier positif.');
  if (amount > base) {
    throw WebRuleRefusal('La remise${label == null ? '' : ' sur « $label »'} (${formatFcfa(amount)}) dépasse sa base de calcul (${formatFcfa(base)}).');
  }
  return amount;
}

BigInt _halfUp(BigInt numerator, BigInt denominator) => (numerator * BigInt.two + denominator) ~/ (denominator * BigInt.two);

/// Part archivée d'une ligne : `arrondi(net × total_ligne / brut)`, demi vers le haut (référentiel §3.13).
int archivedShare(int net, int lineTotal, int gross) => gross == 0 ? 0 : _halfUp(BigInt.from(net) * BigInt.from(lineTotal), BigInt.from(gross)).toInt();

/// Parts archivées de toutes les lignes selon `retour_residuel` (`ReturnService::archivedShares`), ou null si le retour ne se
/// chiffre pas ici : règle inconnue et parts inexactes, règle `refuse`, reste impossible à répartir.
List<int>? archivedShares(int net, List<int> totals, String? rule) {
  final gross = totals.fold<int>(0, (sum, t) => sum + t);
  final shares = [for (final t in totals) archivedShare(net, t, gross)];
  final allocated = shares.fold<int>(0, (sum, s) => sum + s);
  if (allocated == net) return shares;
  if (rule == null) return null;
  if (rule == 'largest_fraction') return _largestFractionShares(net, totals, gross);
  if (allocated < net) return shares;
  if (rule == 'refuse') return null;
  final floors = [for (final t in totals) gross == 0 ? 0 : net * t ~/ gross];
  var target = totals.length - 1;
  if (rule == 'largest_share') {
    for (var i = 0; i < totals.length; i++) {
      if (totals[i] > totals[target] || (totals[i] == totals[target] && i < target)) target = i;
    }
  }
  floors[target] += net - floors.fold<int>(0, (sum, f) => sum + f);
  return floors;
}

/// Plus forts restes, un franc par ligne, à fraction égale la première ligne du ticket (ADR-185).
List<int>? _largestFractionShares(int net, List<int> totals, int gross) {
  if (gross == 0) return List.filled(totals.length, 0);
  final shares = [for (final t in totals) net * t ~/ gross];
  final candidates = [
    for (var i = 0; i < totals.length; i++)
      if ((net * totals[i]).remainder(gross) > 0) i,
  ]..sort((a, b) => (net * totals[b]).remainder(gross).compareTo((net * totals[a]).remainder(gross)) != 0
      ? (net * totals[b]).remainder(gross).compareTo((net * totals[a]).remainder(gross))
      : a.compareTo(b));
  final residual = net - shares.fold<int>(0, (sum, s) => sum + s);
  if (residual < 0 || residual > candidates.length) return null;
  for (final i in candidates.take(residual)) {
    shares[i]++;
  }
  return shares;
}

/// Montant rendu pour [quantity] après [before] déjà retournés sur une ligne de quantité [sold], en millionièmes.
int returnedAmount(int share, int before, int quantity, int sold) {
  int cumulated(int q) => _halfUp(BigInt.from(share) * BigInt.from(q), BigInt.from(sold)).toInt();
  return cumulated(before + quantity) - cumulated(before);
}

/// Téléphone au format E.164, indicatif 225 par défaut, ou null s'il est illisible (`ClientsCaisse::telephone` du serveur).
String? normalizePhone(String? entered) {
  final text = (entered ?? '').trim();
  final digits = text.replaceAll(RegExp(r'\D'), '');
  final full = text.startsWith('+')
      ? digits
      : digits.startsWith('00')
      ? digits.substring(2)
      : digits.startsWith('225') && digits.length > 10
      ? digits
      : '225$digits';
  return digits.length >= 8 && RegExp(r'^[1-9]\d{7,14}$').hasMatch(full) ? '+$full' : null;
}

/// Seuil d'un rôle (`remise_max_pourcent`, millionièmes de pourcent) : dépassé si `remise × 100 > base × seuil`
/// (comparaison exacte du web, E11).
bool exceedsPercent(int discount, int base, BigInt percentMicros) =>
    BigInt.from(discount) * BigInt.from(100) * BigInt.from(1000000) > BigInt.from(base) * percentMicros;

/// Totaux d'une vente selon le web (§3.5 à §3.7).
class WebTotals {
  const WebTotals({
    required this.gross,
    required this.lineDiscounts,
    required this.subtotal,
    required this.globalDiscount,
    required this.vat,
    required this.net,
    required this.baseHt,
    required this.delivery,
  });

  /// Brut du contrat (`totaux.brut`) : avant remises de ligne.
  final int gross;
  final int lineDiscounts;

  /// « Sous-total » du web : brut − remises de ligne, base de la remise globale.
  final int subtotal;
  final int globalDiscount;
  final int vat;

  /// Après remise globale et TVA, hors livraison (base des parts de retour).
  final int net;
  final int baseHt;

  /// Livraison, hors TVA.
  final int delivery;

  int get payable => net + delivery;

  /// Remises du contrat (`totaux.remises`) : lignes et remise globale.
  int get discounts => lineDiscounts + globalDiscount;
}

/// Totaux du panier : [lineBases] = arrondi(prix × quantité) par ligne, [lineDiscounts] alignées. Une remise globale
/// supérieure au sous-total est refusée, comme à la vente web (E10).
WebTotals webTotals({
  required List<int> lineBases,
  required List<int> lineDiscounts,
  int globalDiscount = 0,
  required String vatRate,
  required bool vatIncluded,
  int delivery = 0,
}) {
  final gross = lineBases.fold<int>(0, (sum, v) => sum + v);
  final discounts = lineDiscounts.fold<int>(0, (sum, v) => sum + v);
  final subtotal = gross - discounts;
  if (globalDiscount < 0) throw const WebRuleRefusal('Remise globale invalide.');
  if (globalDiscount > subtotal) throw const WebRuleRefusal('La remise globale dépasse le montant du panier.');
  final totals = saleTotals([subtotal - globalDiscount], vatRate, vatIncluded);
  return WebTotals(
    gross: gross,
    lineDiscounts: discounts,
    subtotal: subtotal,
    globalDiscount: globalDiscount,
    vat: totals.vat,
    net: totals.net,
    baseHt: totals.baseHt,
    delivery: delivery,
  );
}

/// Arrondi de caisse (`CashRounding`) : `r = montant mod pas` ; `down` : vers le bas ; `up` : vers le haut ;
/// `nearest` : vers le haut si `2r > pas`, sinon vers le bas (égalité vers le bas, en faveur du client).
int cashRound(int amount, {required int step, required String mode}) {
  if (step <= 1) return amount;
  final r = amount % step;
  if (r == 0) return amount;
  return switch (mode) {
    'up' => amount - r + step,
    'nearest' => 2 * r > step ? amount - r + step : amount - r,
    _ => amount - r,
  };
}

/// Ligne d'espèces selon le web et le contrat 2.1 (§7.7) : le montant reste la part exacte de la vente ; le tiroir
/// reçoit `montant + ecart_arrondi` ; la monnaie se calcule sur ce montant arrondi.
class CashLine {
  const CashLine({required this.amount, required this.roundingGap, required this.received});

  final int amount;
  final int roundingGap;
  final int received;

  int get due => amount + roundingGap;
  int get change => received - due;
}

/// Ligne d'espèces de [amount] avec l'arrondi de la boutique (`null` = sans arrondi) ; [received] absent = montant dû.
CashLine cashLine(int amount, {({int step, String mode})? rounding, int? received}) {
  final due = rounding == null ? amount : cashRound(amount, step: rounding.step, mode: rounding.mode);
  final paid = received ?? due;
  if (paid < due) throw const WebRuleRefusal('Le montant reçu est inférieur au montant à régler.');
  return CashLine(amount: amount, roundingGap: due - amount, received: paid);
}
