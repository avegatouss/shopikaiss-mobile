/// Quantités du contrat v2 : chaînes à six décimales exactement, manipulées en micro-unités entières (aucun nombre à
/// virgule). Arrondis au demi supérieur, comme la référence serveur (`CoherenceVente`, Brick\Math HalfUp).
class Decimal6 {
  static const scale = 1000000;

  static final _unsigned = RegExp(r'^(0|[1-9][0-9]{0,8})\.([0-9]{6})$');
  static final _signed = RegExp(r'^(-?)(0|[1-9][0-9]{0,8})\.([0-9]{6})$');
  static final _loose = RegExp(r'^(\d{1,9})(?:[.,](\d{1,6}))?$');

  /// `"2.500000"` → 2500000 ; lève [FormatException] hors du format du contrat.
  static int parse(String value) {
    final m = _unsigned.firstMatch(value) ?? (throw FormatException('Quantité hors contrat : $value'));
    return int.parse(m.group(1)!) * scale + int.parse(m.group(2)!);
  }

  static int parseSigned(String value) {
    final m = _signed.firstMatch(value) ?? (throw FormatException('Variation hors contrat : $value'));
    final micros = int.parse(m.group(2)!) * scale + int.parse(m.group(3)!);
    return m.group(1) == '-' ? -micros : micros;
  }

  /// Saisie de l'écran (`"2"`, `"0,5"`, `"1.25"`) → micro-unités ; null si illisible ou plus de six décimales.
  static int? parseInput(String value) {
    final m = _loose.firstMatch(value.trim());
    if (m == null) return null;
    return int.parse(m.group(1)!) * scale + int.parse((m.group(2) ?? '').padRight(6, '0'));
  }

  /// 2500000 → `"2.500000"` ; négatif → `"-2.500000"` (jamais `"-0.000000"`).
  static String format(int micros) {
    final sign = micros < 0 ? '-' : '';
    final abs = micros.abs();
    return '$sign${abs ~/ scale}.${(abs % scale).toString().padLeft(6, '0')}';
  }

  /// Libellé court (`"2"`, `"0,5"`).
  static String label(int micros) {
    final text = format(micros).replaceFirst(RegExp(r'\.?0+$'), '');
    return text.replaceAll('.', ',');
  }

  /// Produit de deux quantités, ramené à six décimales (demi supérieur).
  static int multiply(int a, int b) => _divRound(BigInt.from(a) * BigInt.from(b), BigInt.from(scale));

  /// Montant entier = prix × quantité, arrondi au demi supérieur.
  static int amount(int unitPrice, int quantityMicros) => _divRound(BigInt.from(unitPrice) * BigInt.from(quantityMicros), BigInt.from(scale));

  /// Division arrondie au demi supérieur (loin de zéro pour les négatifs, comme HalfUp).
  static int _divRound(BigInt n, BigInt d) {
    final negative = n.isNegative != d.isNegative;
    final q = n.abs() ~/ d.abs();
    final r = n.abs().remainder(d.abs());
    final rounded = r * BigInt.two >= d.abs() ? q + BigInt.one : q;
    return (negative ? -rounded : rounded).toInt();
  }
}
