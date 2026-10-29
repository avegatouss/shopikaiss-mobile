import '../offline/money.dart';
import 'decimal6.dart';

/// Ligne d'un panier v2, telle que choisie à l'écran (catalogue de la projection v2).
class V2CartLine {
  const V2CartLine({required this.productUuid, this.packagingUuid, required this.quantityMicros, this.discount = 0});

  final String productUuid;
  final String? packagingUuid;
  final int quantityMicros;
  final int discount;
}

/// Paiement unique de la révision 2.0 (`vente.especes`) ; [received] = somme remise par le client (espèces).
class V2Payment {
  const V2Payment({required this.method, required this.amount, this.received, this.reference});

  final String method;
  final int amount;
  final int? received;
  final String? reference;
}

/// TVA de la boutique, figée dans la vente : entité `boutique` du journal v2 (contrat 2.0.1, [V2Store.shopVat]).
class V2Vat {
  const V2Vat({this.rate = '0.000000', this.included = true});

  /// Taux à six décimales (`"18.000000"`).
  final String rate;
  final bool included;
}

/// Construction d'une vente v2 figée (operation.json#/$defs/vente) à partir de la projection : libellés, prix,
/// conversions et révisions de prix sont lus UNE fois et recopiés dans l'opération ; montants calculés par la règle
/// unique du moteur (money.dart, identique au serveur) et recoupés comme `CoherenceVente`.
class V2SaleBuilder {
  V2SaleBuilder({
    required this.products,
    required this.packagings,
    required this.revisions,
    required this.newUuid,
  });

  /// Entités `produit` et `conditionnement` de la projection, indexées par UUID.
  final Map<String, Map<String, dynamic>> products;
  final Map<String, Map<String, dynamic>> packagings;

  /// Révision appliquée de l'entité qui porte le prix (`produit` ou `conditionnement`), par UUID.
  final Map<String, String> revisions;
  final String Function() newUuid;

  /// Contenu de vente prêt à figer ; lève [V2SaleInvalid] sans rien écrire si le panier n'est pas vendable localement.
  Map<String, dynamic> content({
    required String numberLocal,
    required String draftUuid,
    required String sessionUuid,
    required List<V2CartLine> cart,
    required V2Payment payment,
    V2Vat vat = const V2Vat(),
  }) {
    if (cart.isEmpty) throw const V2SaleInvalid('Panier vide.');
    final lines = <Map<String, dynamic>>[];
    final movements = <Map<String, dynamic>>[];
    final lineTotals = <int>[];
    var gross = 0, discounts = 0;
    for (final item in cart) {
      final product = products[item.productUuid] ?? (throw const V2SaleInvalid('Produit absent du catalogue local.'));
      if (product['actif'] != true || product['vente_locale'] != true) {
        throw V2SaleInvalid('« ${product['nom']} » ne se vend qu’en ligne.');
      }
      if (item.quantityMicros <= 0) throw const V2SaleInvalid('Quantité invalide.');
      final pack = item.packagingUuid == null ? null : packagings[item.packagingUuid];
      if (item.packagingUuid != null && (pack == null || pack['actif'] != true || pack['produit_uuid'] != item.productUuid)) {
        throw const V2SaleInvalid('Conditionnement absent ou inactif.');
      }
      final price = (pack?['prix'] ?? product['prix']) as int;
      final coefficient = pack == null ? Decimal6.scale : Decimal6.parse(pack['coefficient'] as String);
      final base = Decimal6.amount(price, item.quantityMicros);
      if (item.discount < 0 || item.discount > base) throw const V2SaleInvalid('Remise supérieure au montant de la ligne.');
      final baseQuantity = Decimal6.multiply(item.quantityMicros, coefficient);
      final label = pack == null ? product['nom'] as String : '${product['nom']} (${pack['nom']})';
      lines.add({
        'ligne_uuid': newUuid(),
        'produit_uuid': item.productUuid,
        'conditionnement_uuid': item.packagingUuid,
        'libelle': label.length > 200 ? label.substring(0, 200) : label,
        'quantite': Decimal6.format(item.quantityMicros),
        'coefficient': Decimal6.format(coefficient),
        'quantite_base': Decimal6.format(baseQuantity),
        'prix_unitaire': price,
        'remise': item.discount,
        'total': base - item.discount,
        'revision_prix': revisions[item.packagingUuid ?? item.productUuid] ?? '0',
      });
      if (product['stock_illimite'] != true) {
        movements.add({'mouvement_uuid': newUuid(), 'produit_uuid': item.productUuid, 'lot_uuid': null, 'variation': Decimal6.format(-baseQuantity)});
      }
      gross += base;
      discounts += item.discount;
      lineTotals.add(base - item.discount);
    }
    final totals = saleTotals(lineTotals, vat.rate, vat.included);
    if (payment.amount != totals.payable) {
      throw V2SaleInvalid('Paiement ${formatFcfa(payment.amount)} différent du total ${formatFcfa(totals.payable)}.');
    }
    if (payment.received != null && payment.received! < payment.amount) throw const V2SaleInvalid('Somme reçue insuffisante.');
    return {
      'numero_local': numberLocal,
      'brouillon_uuid': draftUuid,
      'session_uuid': sessionUuid,
      'client_uuid': null,
      'tva': {'taux': vat.rate, 'incluse': vat.included},
      'lignes': lines,
      'remise_globale': 0,
      'livraison': 0,
      'totaux': {'brut': gross, 'remises': discounts, 'base_ht': totals.baseHt, 'tva': totals.vat, 'a_payer': totals.payable},
      'paiements': [
        {'tentative_uuid': newUuid(), 'moyen': payment.method, 'montant': payment.amount, 'recu': payment.received, 'reference': payment.reference},
      ],
      'mouvements': movements,
      'autorisations': <Map<String, dynamic>>[],
    };
  }

  /// Total à payer d'un panier (affichage avant paiement), par la même règle.
  int payable(List<V2CartLine> cart, {V2Vat vat = const V2Vat()}) {
    final totals = <int>[];
    for (final item in cart) {
      final pack = item.packagingUuid == null ? null : packagings[item.packagingUuid];
      final price = (pack?['prix'] ?? products[item.productUuid]?['prix'] ?? 0) as int;
      totals.add(Decimal6.amount(price, item.quantityMicros) - item.discount);
    }
    return saleTotals(totals, vat.rate, vat.included).payable;
  }
}

/// Opération v2 complète sans empreinte (calculée par le stockage sur la séquence réservée).
Map<String, dynamic> v2Operation({
  required String uuid,
  required String type,
  required String deviceUuid,
  required int epoch,
  required int sequence,
  required DateTime createdAt,
  required String operatorId,
  required String policiesVersion,
  required String? catalogueCursor,
  required Map<String, dynamic> content,
}) => {
  'uuid': uuid,
  'type': type,
  'appareil': {'uuid': deviceUuid, 'epoque': epoch},
  'sequence': sequence,
  'cree_le': '${createdAt.toUtc().toIso8601String().substring(0, 19)}Z',
  'operateur_id': operatorId,
  'versions': {'politiques': policiesVersion, 'calcul': '1', 'curseur_catalogue': catalogueCursor},
  'contenu': content,
};

class V2SaleInvalid implements Exception {
  const V2SaleInvalid(this.message);

  final String message;

  @override
  String toString() => message;
}
