/// Calcul d'une vente hors ligne, à l'identique du serveur (`App\Domain\Sales\SaleCalculator`, politique DECIMAL_EXACT) :
/// montants entiers en FCFA, quantités et taux à six décimales, arrondi « au plus proche, moitié vers le haut ».
///
/// - total de ligne = arrondi(prix × quantité) − remise, jamais négatif ;
/// - TVA incluse : TVA = arrondi(montant × taux / (100 + taux)), net = montant ;
/// - TVA ajoutée : TVA = arrondi(montant × taux / 100), net = montant + TVA.
///
/// Le serveur recalcule chaque vente reçue et refuse (mise en arbitrage) un total différent : ce fichier doit rester
/// identique à la règle du serveur.
library;

final BigInt _million = BigInt.from(1000000);

/// Quantité ou taux décimal (`"2"`, `"0.5"`, `"18.000000"`) en millionièmes. Null si illisible ou plus de 6 décimales.
BigInt? parseMicros(String value) {
  final text = value.trim().replaceAll(',', '.');
  final match = RegExp(r'^(\d{1,14})(?:\.(\d{1,6}))?$').firstMatch(text);
  if (match == null) return null;
  final whole = BigInt.parse(match.group(1)!);
  final fraction = (match.group(2) ?? '').padRight(6, '0');
  return whole * _million + BigInt.parse(fraction.isEmpty ? '0' : fraction);
}

/// Écriture décimale normalisée d'une quantité (`2`, `0.5`, `1.25`) envoyée au serveur.
String formatMicros(BigInt micros) {
  final whole = micros ~/ _million;
  final fraction = (micros % _million).toString().padLeft(6, '0').replaceFirst(RegExp(r'0+$'), '');
  return fraction.isEmpty ? '$whole' : '$whole.$fraction';
}

/// Division entière arrondie au plus proche, moitié vers le haut (valeurs positives ou nulles).
BigInt divideHalfUp(BigInt numerator, BigInt denominator) {
  final quotient = numerator ~/ denominator;
  final remainder = numerator - quotient * denominator;
  return remainder * BigInt.two >= denominator ? quotient + BigInt.one : quotient;
}

/// Montant brut d'une ligne : arrondi(prix × quantité).
int lineBase(int unitPrice, BigInt quantityMicros) => divideHalfUp(BigInt.from(unitPrice) * quantityMicros, _million).toInt();

/// Total d'une ligne après remise, jamais négatif.
int lineTotal(int unitPrice, BigInt quantityMicros, int discount) {
  final total = lineBase(unitPrice, quantityMicros) - discount;
  return total < 0 ? 0 : total;
}

/// Remise maximale d'une ligne pour un pourcentage autorisé : la règle du serveur est `remise × 100 ≤ base × pourcentage`.
int maxLineDiscount(int base, int percent) => percent <= 0 ? 0 : (base * percent) ~/ 100;

class SaleTotals {
  const SaleTotals({required this.gross, required this.vat, required this.net, required this.baseHt});

  final int gross;
  final int vat;
  final int net;
  final int baseHt;

  /// Montant à encaisser (pas de livraison hors ligne).
  int get payable => net;
}

/// Totaux d'un panier : [lineTotals] déjà remisés, taux de TVA décimal de la boutique, TVA incluse ou ajoutée.
SaleTotals saleTotals(List<int> lineTotals, String vatRate, bool vatIncluded) {
  final gross = lineTotals.fold<int>(0, (sum, total) => sum + total);
  final rate = parseMicros(vatRate) ?? BigInt.zero;
  final amount = BigInt.from(gross);
  final vat = rate == BigInt.zero
      ? 0
      : divideHalfUp(amount * rate, vatIncluded ? rate + BigInt.from(100) * _million : BigInt.from(100) * _million).toInt();
  final net = vatIncluded ? gross : gross + vat;
  return SaleTotals(gross: gross, vat: vat, net: net, baseHt: net - vat);
}

/// `12 500 F` : montant lisible (espace fine insécable remplacée par une espace simple pour l'imprimante).
String formatFcfa(int amount, [String currency = 'F']) {
  final digits = amount.abs().toString();
  final buffer = StringBuffer(amount < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(' ');
    buffer.write(digits[i]);
  }
  return '$buffer $currency';
}
