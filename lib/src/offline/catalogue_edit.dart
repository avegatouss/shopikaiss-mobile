import '../sync_v2/decimal6.dart';
import 'caisse_engine.dart';
import 'money.dart';

/// Catalogue hors connexion (contrat 2.1 lot 10, A `c87b57c1`) : types et validation communs au moteur, à l'adaptateur
/// Windows et à la caisse Android. Les bornes sont celles du schéma `operation.json#/$defs/creation_produit`.
class CatalogueLimits {
  static const name = 160;
  static const reference = 80;
  static const barcodes = 5;
  static const barcode = 80;
  static const maxAmount = 1000000000;
  static final barcodePattern = RegExp(r'^[!-~]{1,80}$');
}

/// Champs saisis d'un produit créé sur le terminal.
class NewProduct {
  const NewProduct({
    required this.name,
    this.reference,
    this.barcodes = const [],
    this.categoryUuid,
    required this.price,
    this.purchasePrice,
    this.wholesalePrice,
    this.wholesaleMin,
    this.unlimitedStock = false,
  });

  final String name;
  final String? reference;
  final List<String> barcodes;
  final String? categoryUuid;
  final int price;
  final int? purchasePrice;
  final int? wholesalePrice;

  /// Quantité minimale du tarif de gros, texte décimal saisi (« 10 », « 2,5 ») ; null : aucune.
  final String? wholesaleMin;
  final bool unlimitedStock;
}

/// Champs modifiables d'une fiche (schéma `modification_produit`) : nom, référence, catégorie, prix, gros, seuil.
class ProductFields {
  const ProductFields({
    required this.productId,
    required this.uuid,
    required this.name,
    required this.reference,
    required this.barcodes,
    required this.categoryUuid,
    required this.price,
    required this.wholesalePrice,
    required this.wholesaleMin,
    required this.unlimitedStock,
    required this.localState,
  });

  final int productId;
  final String uuid;
  final String name;
  final String? reference;
  final List<String> barcodes;
  final String? categoryUuid;
  final int price;
  final int? wholesalePrice;

  /// Quantité au format du contrat (`"10.000000"`) ou null.
  final String? wholesaleMin;
  final bool unlimitedStock;
  final String? localState;
}

/// Suivi d'une création ou d'une modification envoyée (ou à envoyer) au serveur.
class CatalogueChange {
  const CatalogueChange({
    required this.operationUuid,
    required this.kind,
    required this.productUuid,
    required this.productId,
    required this.name,
    required this.state,
    required this.reason,
    required this.canonicalUuid,
    required this.decision,
    required this.createdAt,
  });

  final String operationUuid;

  /// `creation` ou `modification`.
  final String kind;
  final String productUuid;
  final int? productId;
  final String name;

  /// `a_synchroniser`, `envoye`, `conflit`, `integre`, `refuse`.
  final String state;
  final String? reason;
  final String? canonicalUuid;
  final String? decision;
  final DateTime? createdAt;

  Map<String, dynamic> toJson() => {
    'operation_id': operationUuid,
    'kind': kind,
    'product_id': productId,
    'product_uuid': productUuid,
    'name': name,
    'state': state,
    'reason': reason,
    'canonical_uuid': canonicalUuid,
    'decision': decision,
    'created_at': createdAt?.toUtc().toIso8601String(),
  };
}

/// Contrôles de saisie communs ; [OfflineRefusal] avec un message prêt à afficher.
class CatalogueValidation {
  /// Codes d'erreur rendus par l'adaptateur.
  static const codeUsed = 'code_deja_utilise';
  static const unknownProduct = 'produit_inconnu';
  static const noChange = 'aucun_changement';

  static String name(String value) {
    final text = value.trim();
    if (text.isEmpty || text.length > CatalogueLimits.name) throw const OfflineRefusal('Indiquez le nom du produit (160 caractères au plus).');
    return text;
  }

  static String? reference(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return null;
    if (text.length > CatalogueLimits.reference) throw const OfflineRefusal('Référence trop longue (80 caractères au plus).');
    return text;
  }

  static List<String> barcodes(List<String> values) {
    final codes = <String>[];
    for (final raw in values) {
      final code = raw.trim();
      if (code.isEmpty) continue;
      if (!CatalogueLimits.barcodePattern.hasMatch(code)) {
        throw OfflineRefusal('Code-barres « $code » invalide : 80 caractères au plus, sans espace ni accent.');
      }
      if (!codes.contains(code)) codes.add(code);
    }
    if (codes.length > CatalogueLimits.barcodes) throw const OfflineRefusal('Cinq codes-barres au plus.');
    return codes;
  }

  static int amount(int? value, String label) {
    if (value == null || value < 0 || value > CatalogueLimits.maxAmount) throw OfflineRefusal('$label invalide (0 à 1 000 000 000 F).');
    return value;
  }

  static int? optionalAmount(int? value, String label) => value == null ? null : amount(value, label);

  /// Quantité saisie (« 10 », « 2,5 ») → format du contrat (`"10.000000"`) ; vide → null.
  static String? quantity(String? value) {
    final text = value?.trim().replaceAll(',', '.') ?? '';
    if (text.isEmpty) return null;
    final micros = parseMicros(text);
    if (micros == null || micros <= BigInt.zero || micros > BigInt.from(999999999) * BigInt.from(1000000)) {
      throw const OfflineRefusal('Quantité minimale de gros invalide (nombre positif, six décimales au plus).');
    }
    return Decimal6.format(micros.toInt());
  }
}
