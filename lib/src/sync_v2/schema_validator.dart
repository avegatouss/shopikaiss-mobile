import 'dart:convert';

import 'canonical_json.dart';

/// Schéma hors du profil SK-SCHEMA-1 ou introuvable : erreur du contrat, jamais une donnée « valide par défaut ».
class SchemaProfileError implements Exception {
  const SchemaProfileError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Validateur du profil de schémas « SK-SCHEMA-1 » du contrat v2 (contrat-v2/README.md §5), identique à la référence
/// serveur `App\Application\CaisseV2\Contrat\ValidateurSchema` : mêmes mots-clés, mêmes messages (les fixtures
/// invalides en vérifient un extrait).
///
/// Mots-clés reconnus : type, properties, required, additionalProperties: false, items, minItems, maxItems, uniqueItems,
/// enum, const, pattern, minLength, maxLength, minimum, maximum, oneOf, $ref, $defs. Ignorés : $schema, $id, title,
/// description, examples, $comment. Tout autre mot-clé lève [SchemaProfileError].
class SchemaValidator {
  /// [loadSchema] rend le texte d'un fichier de schéma (`operation.json`…) ; les fichiers sont lus une fois.
  SchemaValidator(this._loadSchema);

  final String Function(String file) _loadSchema;
  final Map<String, Map<String, dynamic>> _files = {};

  static const _ignored = {r'$schema', r'$id', 'title', 'description', 'examples', r'$comment', r'$defs'};
  static const _known = {
    'type', 'properties', 'required', 'additionalProperties', 'items', 'minItems', 'maxItems', 'uniqueItems', //
    'enum', 'const', 'pattern', 'minLength', 'maxLength', 'minimum', 'maximum', 'oneOf', r'$ref',
  };

  /// Erreurs « chemin : motif » de [data] contre [schema] (`fichier.json` ou `fichier.json#/$defs/x`) ; vide si valide.
  List<String> validate(Object? data, String schema) {
    final errors = <String>[];
    final parts = schema.split('#');
    final file = parts.first;
    final node = parts.length == 1 || parts[1].isEmpty ? _file(file) : <String, dynamic>{r'$ref': schema};
    _node(data, node, file, r'$', errors);
    return errors;
  }

  Map<String, dynamic> _file(String name) => _files.putIfAbsent(name, () {
    try {
      return Map<String, dynamic>.from(jsonDecode(_loadSchema(name)) as Map);
    } catch (e) {
      throw SchemaProfileError('Schéma introuvable : $name ($e)');
    }
  });

  void _node(Object? data, Map<String, dynamic> schema, String file, String path, List<String> errors) {
    for (final keyword in schema.keys) {
      if (!_ignored.contains(keyword) && !_known.contains(keyword)) {
        throw SchemaProfileError('Mot-clé hors profil SK-SCHEMA-1 « $keyword » dans $file');
      }
    }
    final ref = schema[r'$ref'];
    if (ref is String) {
      final parts = ref.split('#');
      final target = parts.first.isEmpty ? file : parts.first;
      Object? sub = _file(target);
      for (final segment in (parts.length > 1 ? parts[1] : '').split('/').where((s) => s.isNotEmpty)) {
        sub = sub is Map ? sub[segment] : null;
        if (sub == null) throw SchemaProfileError('Référence introuvable : $ref');
      }
      _node(data, Map<String, dynamic>.from(sub as Map), target, path, errors);
    }
    if (schema.containsKey('type')) {
      final types = schema['type'] is List ? [for (final t in schema['type'] as List) '$t'] : ['${schema['type']}'];
      if (!types.any((t) => _accepts(data, t))) {
        errors.add('$path : type attendu ${types.join('|')}, reçu ${_typeOf(data)}');
        return;
      }
    }
    if (schema.containsKey('const') && !_same(data, schema['const'])) {
      errors.add('$path : valeur attendue ${_display(schema['const'])}');
    }
    if (schema['enum'] is List && !(schema['enum'] as List).any((v) => _same(data, v))) {
      errors.add('$path : valeur hors liste (${(schema['enum'] as List).map(_display).join(', ')})');
    }
    if (data is String) {
      final length = data.runes.length;
      if (schema['minLength'] is int && length < (schema['minLength'] as int)) errors.add('$path : au moins ${schema['minLength']} caractère(s)');
      if (schema['maxLength'] is int && length > (schema['maxLength'] as int)) errors.add('$path : au plus ${schema['maxLength']} caractère(s)');
      if (schema['pattern'] is String && !RegExp(schema['pattern'] as String, unicode: true).hasMatch(data)) {
        errors.add('$path : format invalide');
      }
    }
    if (data is int) {
      if (schema['minimum'] is int && data < (schema['minimum'] as int)) errors.add('$path : minimum ${schema['minimum']}');
      if (schema['maximum'] is int && data > (schema['maximum'] as int)) errors.add('$path : maximum ${schema['maximum']}');
    }
    if (data is List) _list(data, schema, file, path, errors);
    if (data is Map) _object(data, schema, file, path, errors);
    if (schema['oneOf'] is List) {
      var valid = 0;
      final details = <List<String>>[];
      for (final variant in schema['oneOf'] as List) {
        final sub = <String>[];
        _node(data, Map<String, dynamic>.from(variant as Map), file, path, sub);
        sub.isEmpty ? valid++ : details.add(sub);
      }
      if (valid != 1) {
        errors.add('$path : doit correspondre à exactement une variante ($valid trouvée(s))');
        if (valid == 0 && details.isNotEmpty) {
          // L'erreur la plus courte désigne en général la variante visée (même règle que le serveur).
          details.sort((a, b) => a.length.compareTo(b.length));
          errors.addAll(details.first);
        }
      }
    }
  }

  void _list(List<Object?> data, Map<String, dynamic> schema, String file, String path, List<String> errors) {
    if (schema['minItems'] is int && data.length < (schema['minItems'] as int)) errors.add('$path : au moins ${schema['minItems']} élément(s)');
    if (schema['maxItems'] is int && data.length > (schema['maxItems'] as int)) errors.add('$path : au plus ${schema['maxItems']} élément(s)');
    if (schema['uniqueItems'] == true) {
      final seen = data.map(CanonicalJson.encode).toList();
      if (seen.toSet().length != seen.length) errors.add('$path : éléments en double');
    }
    if (schema['items'] is Map) {
      for (var i = 0; i < data.length; i++) {
        _node(data[i], Map<String, dynamic>.from(schema['items'] as Map), file, '$path[$i]', errors);
      }
    }
  }

  void _object(Map<Object?, Object?> data, Map<String, dynamic> schema, String file, String path, List<String> errors) {
    for (final required in (schema['required'] as List? ?? const [])) {
      if (!data.containsKey(required)) errors.add('$path.$required : obligatoire');
    }
    // `"properties": []` = objet vide encodé par PHP (contrat restaurant-1 R-4/R-5) : aucune propriété déclarée.
    final raw = schema['properties'];
    if (raw is List && raw.isNotEmpty) throw SchemaProfileError('properties doit être un objet dans $file');
    final properties = raw is Map ? raw : const {};
    for (final entry in data.entries) {
      final property = properties[entry.key];
      if (property is Map) {
        _node(entry.value, Map<String, dynamic>.from(property), file, '$path.${entry.key}', errors);
      } else if (schema['additionalProperties'] == false) {
        errors.add('$path.${entry.key} : propriété inconnue');
      }
    }
  }

  static bool _accepts(Object? data, String type) => switch (type) {
    'null' => data == null,
    'boolean' => data is bool,
    'integer' => data is int,
    'string' => data is String,
    'array' => data is List,
    'object' => data is Map,
    _ => throw SchemaProfileError('Type hors profil : $type'),
  };

  static String _typeOf(Object? data) => switch (data) {
    null => 'null',
    bool _ => 'boolean',
    int _ => 'integer',
    double _ => 'nombre à virgule',
    String _ => 'string',
    List _ => 'array',
    _ => 'object',
  };

  /// Égalité stricte comme le serveur (`===` / `in_array(..., true)`) : même type, même valeur.
  static bool _same(Object? a, Object? b) {
    if (a is double || b is double) return false;
    try {
      return CanonicalJson.encode(a) == CanonicalJson.encode(b);
    } on CanonicalJsonError {
      return false;
    }
  }

  /// Affichage d'une valeur comme `json_encode(..., JSON_UNESCAPED_UNICODE)` (les messages des fixtures en dépendent).
  static String _display(Object? value) => jsonEncode(value);
}
