import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Refus d'une valeur hors du profil SK-JCS-1 (nombre à virgule, entier trop grand, JSON illisible).
class CanonicalJsonError implements Exception {
  const CanonicalJsonError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Canonicalisation « SK-JCS-1 » du contrat de synchronisation v2 (contrat-v2/README.md §4), identique à la référence
/// serveur `App\Application\CaisseV2\Contrat\Canonicalisation`.
///
/// Sous-ensemble de RFC 8785 (JCS) : objets, tableaux, chaînes, entiers dans ±(2^53 − 1), booléens, null. Aucun nombre
/// à virgule : refusé, jamais arrondi. Clés triées par unités de code UTF-16 (l'ordre de `String.compareTo` en Dart) ;
/// aucun espace ; seuls `"`, `\` et U+0000–U+001F sont échappés. Aucune normalisation Unicode. Pur Dart : partagé par
/// Android et Windows, sans Flutter.
class CanonicalJson {
  CanonicalJson._();

  static const profile = 'SK-JCS-1';
  static const maxInteger = 9007199254740991;

  /// Texte JSON → forme canonique.
  static String fromJson(String json) {
    final Object? value;
    try {
      value = jsonDecode(json);
    } on FormatException catch (e) {
      throw CanonicalJsonError('JSON illisible : ${e.message}');
    }
    return encode(value);
  }

  /// Valeur décodée (Map, List, String, int, bool, null) → forme canonique.
  static String encode(Object? value) {
    final out = StringBuffer();
    _write(value, out);
    return out.toString();
  }

  /// Empreinte SHA-256 (hexadécimal minuscule) des octets UTF-8 de la forme canonique de [value].
  static String sha256Of(Object? value) => sha256.convert(utf8.encode(encode(value))).toString();

  /// Empreinte d'une opération : forme canonique de l'opération SANS son champ `empreinte` (§4).
  static String operationFingerprint(Map<String, dynamic> operation) => sha256Of({...operation}..remove('empreinte'));

  static void _write(Object? value, StringBuffer out) {
    switch (value) {
      case null:
        out.write('null');
      case bool b:
        out.write(b ? 'true' : 'false');
      case int i:
        if (i > maxInteger || i < -maxInteger) throw const CanonicalJsonError('Entier hors de ±(2^53 − 1) : transmettre une chaîne.');
        out.write(i);
      case double _:
        throw const CanonicalJsonError('Nombre à virgule interdit (SK-JCS-1) : montants entiers, quantités en chaînes.');
      case String s:
        _string(s, out);
      case List<Object?> list:
        out.write('[');
        for (var i = 0; i < list.length; i++) {
          if (i > 0) out.write(',');
          _write(list[i], out);
        }
        out.write(']');
      case Map<Object?, Object?> map:
        final keys = [
          for (final k in map.keys)
            if (k is String) k else throw const CanonicalJsonError('Clé d’objet non textuelle.'),
        ]..sort();
        out.write('{');
        for (var i = 0; i < keys.length; i++) {
          if (i > 0) out.write(',');
          _string(keys[i], out);
          out.write(':');
          _write(map[keys[i]], out);
        }
        out.write('}');
      default:
        throw CanonicalJsonError('Valeur non JSON : ${value.runtimeType}.');
    }
  }

  static void _string(String s, StringBuffer out) {
    // Moitié de paire UTF-16 isolée : non représentable en UTF-8 (Dart la remplacerait en silence par U+FFFD, et
    // l'empreinte différerait de celle du serveur, qui refuse une chaîne non UTF-8).
    for (final rune in s.runes) {
      if (rune >= 0xD800 && rune <= 0xDFFF) throw const CanonicalJsonError('Chaîne non UTF-8 (demi-paire UTF-16 isolée).');
    }
    out.write('"');
    for (final unit in s.codeUnits) {
      switch (unit) {
        case 0x22:
          out.write(r'\"');
        case 0x5C:
          out.write(r'\\');
        case 0x08:
          out.write(r'\b');
        case 0x09:
          out.write(r'\t');
        case 0x0A:
          out.write(r'\n');
        case 0x0C:
          out.write(r'\f');
        case 0x0D:
          out.write(r'\r');
        default:
          if (unit < 0x20) {
            out.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
          } else {
            out.writeCharCode(unit);
          }
      }
    }
    out.write('"');
  }
}
