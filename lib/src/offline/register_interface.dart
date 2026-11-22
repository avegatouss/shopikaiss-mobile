/// Interface réglable de la caisse (contrat 2.1 lot 13, capacité `caisse.interface`, note A
/// `LOT-13-INTERFACE-POUR-B-ET-C.md`) : éléments visibles et ordre, tailles des tuiles, texte du mode compact, hauteur
/// du bouton Payer, verrou du responsable. Partagé par Android et Windows.
library;

import 'dart:convert';

/// Interface résolue pour ce poste : entité publiée `interface_caisse` (clé = uuid du terminal), ou réglage local quand
/// le responsable ne l'a pas verrouillée, ou défauts (écran d'avant le lot 13).
class RegisterInterface {
  const RegisterInterface({
    this.origin = 'defaut',
    this.locked = false,
    this.elements = const {},
    this.categoryTile = 'm',
    this.productTile = 'm',
    this.compactFont = 'm',
    this.payButton = 'm',
  });

  /// Forme publiée (ou locale, même forme sans `origine`). Une clé ou une taille inconnue : valeur par défaut.
  factory RegisterInterface.fromJson(Map json, {String? origin}) {
    String size(Object? v) => sizes.contains(v) ? v as String : 'm';
    final elements = <String, (bool, int)>{};
    for (final e in ((json['elements'] as List?) ?? const []).whereType<Map>()) {
      final key = e['cle'];
      if (key is String && e['visible'] is bool) elements[key] = (e['visible'] as bool, (e['ordre'] as num?)?.toInt() ?? 999);
    }
    return RegisterInterface(
      origin: origin ?? (json['origine'] as String? ?? 'local'),
      locked: json['verrouille'] == true,
      elements: elements,
      categoryTile: size(json['tuile_categorie']),
      productTile: size(json['tuile_produit']),
      compactFont: size(json['police_compacte']),
      payButton: size(json['bouton_payer']),
    );
  }

  static const defaults = RegisterInterface();
  static const sizes = ['s', 'm', 'l', 'xl'];
  static const sizeLabels = {'s': 'Petite', 'm': 'Normale', 'l': 'Grande', 'xl': 'Très grande'};

  /// Échelle de la caisse web : s = 0,85 ; m = 1 ; l = 1,2 ; xl = 1,45.
  static double scaleOf(String size) => switch (size) {
    's' => .85,
    'l' => 1.2,
    'xl' => 1.45,
    _ => 1,
  };

  /// Éléments réglables connus des postes, avec leur libellé (ordre par défaut).
  static const known = <String, String>{
    'scanner': 'Zone de scan',
    'recherche': 'Recherche de produit',
    'favoris': 'Favoris',
    'categories': 'Catégories',
    'marques': 'Filtre marque',
    'fournisseurs': 'Filtre fournisseur',
    'vue': 'Vue Visuelle / Compacte',
    'ventes_recentes': 'Ventes récentes',
    'livre_caisse': 'Livre de caisse',
    'prevente': 'Préventes',
    'prevente_nouvelle': 'Mettre en prévente',
    'recu': 'Reçu',
    'note': 'Note',
    'session': 'Session de caisse',
    'calculatrice': 'Calculatrice',
    'salle_tables': 'Salle et tables',
    'clavier': 'Clavier',
    'back_office': 'Back-office web',
    'retour_web': 'Caisse web / Reconnecter',
  };

  /// `defaut`, `boutique`, `terminal` (publiée) ou `local` (réglage du poste).
  final String origin;
  final bool locked;

  /// Clé → (visible, ordre). Absente : visible, à sa place habituelle.
  final Map<String, (bool, int)> elements;
  final String categoryTile;
  final String productTile;
  final String compactFont;
  final String payButton;

  bool visible(String key) => elements[key]?.$1 ?? true;

  /// Ordre d'un élément ; absent : après les éléments ordonnés, dans l'ordre habituel ([fallback]).
  int order(String key, int fallback) => elements[key]?.$2 ?? 1000 + fallback;

  /// [keys] triées selon le réglage (ordre stable pour les éléments non réglés).
  List<String> sorted(List<String> keys) {
    final indexed = [for (final (i, k) in keys.indexed) (k, order(k, i), i)];
    indexed.sort((a, b) => a.$2 != b.$2 ? a.$2.compareTo(b.$2) : a.$3.compareTo(b.$3));
    return [for (final e in indexed) e.$1];
  }

  double get categoryScale => scaleOf(categoryTile);
  double get productScale => scaleOf(productTile);
  double get compactScale => scaleOf(compactFont);
  double get payScale => scaleOf(payButton);

  /// Forme publiée (pour le réglage local enregistré sur le poste).
  Map<String, dynamic> toJson() => {
    'origine': origin,
    'verrouille': locked,
    'elements': [
      for (final (i, key) in sorted(known.keys.toList()).indexed) {'cle': key, 'visible': visible(key), 'ordre': i + 1},
    ],
    'tuile_categorie': categoryTile,
    'tuile_produit': productTile,
    'police_compacte': compactFont,
    'bouton_payer': payButton,
  };

  String encode() => jsonEncode(toJson());

  RegisterInterface copyWith({Map<String, (bool, int)>? elements, String? categoryTile, String? productTile, String? compactFont, String? payButton}) =>
      RegisterInterface(
        origin: 'local',
        elements: elements ?? this.elements,
        categoryTile: categoryTile ?? this.categoryTile,
        productTile: productTile ?? this.productTile,
        compactFont: compactFont ?? this.compactFont,
        payButton: payButton ?? this.payButton,
      );

  /// Interface appliquée : la publiée si elle est verrouillée ; sinon le réglage local du poste s'il existe ; sinon la
  /// publiée (ou les défauts).
  static RegisterInterface effective(RegisterInterface published, RegisterInterface? local) => published.locked || local == null ? published : local;
}

/// Couleur stable d'un opérateur pour les tuiles de connexion (lot 13, hors contrat) : calculée depuis son identifiant,
/// palette sombre au contraste AA avec un texte blanc. Entier ARGB (`Color(operatorArgb(id))` côté écran) : ce fichier
/// est importé par le moteur, compilé pour l'hôte Windows sans Flutter (pas de `dart:ui`).
int operatorArgb(int operatorId) => operatorPalette[operatorId.abs() % operatorPalette.length];

const operatorPalette = <int>[
  0xFF1565C0, // bleu
  0xFF2E7D32, // vert
  0xFF6A1B9A, // violet
  0xFFC62828, // rouge
  0xFF00695C, // sarcelle
  0xFFAD1457, // framboise
  0xFF4E342E, // brun
  0xFF283593, // indigo
  0xFFBF360C, // orange brûlé
  0xFF37474F, // ardoise
];

/// Initiales d'un nom (« Awa Koné » → « AK »), pour les tuiles de connexion.
String operatorInitials(String name) {
  final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return '?';
  if (words.length == 1) return words.first.substring(0, words.first.length >= 2 ? 2 : 1).toUpperCase();
  return (words.first[0] + words.last[0]).toUpperCase();
}
