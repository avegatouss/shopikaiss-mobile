import '../offline/models.dart';
import '../offline/money.dart';
import '../offline/web_rules.dart';
import 'decimal6.dart';

/// Ligne d'un panier v2, telle que choisie à l'écran (catalogue de la projection v2).
class V2CartLine {
  const V2CartLine({required this.productUuid, this.packagingUuid, required this.quantityMicros, this.discount = 0, this.discountEntry, this.fixedPrice, this.lotUuid});

  final String productUuid;
  final String? packagingUuid;
  final int quantityMicros;
  final int discount;

  /// Saisie de la remise (forme 2.1 `remise_saisie`).
  final DiscountEntry? discountEntry;

  /// Prix figé d'un panier partagé ; null = prix du catalogue.
  final int? fixedPrice;

  /// Lot vendu, obligatoire pour un produit à lots (une ligne par lot).
  final String? lotUuid;
}

/// Paiement d'une vente (au plus 10) ; [received] = somme remise par le client (espèces seulement), [reference] =
/// référence d'un moyen déclaré (jamais une confirmation de prestataire).
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
    required List<V2Payment> payments,
    V2Vat vat = const V2Vat(),
    SaleExtras extras = const SaleExtras(),
    ({int step, String mode})? cashRounding,
    bool revision21 = false,
    SaleApproval? approval,
  }) {
    if (!revision21 && !extras.isEmpty) throw const V2SaleInvalid('Remise globale, livraison et note : contrat 2.1 requis.');
    if (cart.isEmpty) throw const V2SaleInvalid('Panier vide.');
    final lines = <Map<String, dynamic>>[];
    final movements = <Map<String, dynamic>>[];
    final bases = <int>[];
    final lineDiscounts = <int>[];
    for (final item in cart) {
      final product = products[item.productUuid] ?? (throw const V2SaleInvalid('Produit absent du catalogue local.'));
      if (product['actif'] != true || product['vente_locale'] != true) {
        throw V2SaleInvalid('« ${product['nom']} » ne se vend qu’en ligne.');
      }
      if (item.quantityMicros <= 0) throw const V2SaleInvalid('Quantité invalide.');
      if (product['gere_par_lots'] == true && item.lotUuid == null) throw V2SaleInvalid('« ${product['nom']} » : lot manquant.');
      final pack = item.packagingUuid == null ? null : packagings[item.packagingUuid];
      if (item.packagingUuid != null && (pack == null || pack['actif'] != true || pack['produit_uuid'] != item.productUuid)) {
        throw const V2SaleInvalid('Conditionnement absent ou inactif.');
      }
      final price = item.fixedPrice ?? (pack?['prix'] ?? product['prix']) as int;
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
        if (revision21) 'remise_saisie': item.discountEntry?.toJson(),
        if (item.lotUuid != null) 'lot_uuid': item.lotUuid,
      });
      if (product['stock_illimite'] != true || item.lotUuid != null) {
        movements.add({'mouvement_uuid': newUuid(), 'produit_uuid': item.productUuid, 'lot_uuid': item.lotUuid, 'variation': Decimal6.format(-baseQuantity)});
      }
      bases.add(base);
      lineDiscounts.add(item.discount);
    }
    final WebTotals totals;
    try {
      totals = webTotals(
        lineBases: bases,
        lineDiscounts: lineDiscounts,
        globalDiscount: extras.globalDiscount,
        vatRate: vat.rate,
        vatIncluded: vat.included,
        delivery: extras.delivery,
      );
    } on WebRuleRefusal catch (e) {
      throw V2SaleInvalid(e.message);
    }
    if ((payments.isEmpty && totals.payable > 0) || payments.length > 10) throw const V2SaleInvalid('Entre 1 et 10 paiements par vente.');
    // Espèces (reçu renseigné) : le tiroir reçoit le montant arrondi ; montant = part exacte de la vente.
    int due(V2Payment p) => p.received == null || cashRounding == null ? p.amount : cashRound(p.amount, step: cashRounding.step, mode: cashRounding.mode);
    var paid = 0;
    for (final payment in payments) {
      if (payment.amount <= 0) throw const V2SaleInvalid('Chaque paiement doit être positif.');
      if (payment.received != null && payment.received! < due(payment)) throw const V2SaleInvalid('Somme reçue insuffisante.');
      if ((payment.reference?.length ?? 0) > 100) throw const V2SaleInvalid('Référence de paiement trop longue (100 caractères au plus).');
      paid += payment.amount;
    }
    if (paid != totals.payable) {
      throw V2SaleInvalid('Paiements ${formatFcfa(paid)} différents du total ${formatFcfa(totals.payable)}.');
    }
    return {
      'numero_local': numberLocal,
      'brouillon_uuid': draftUuid,
      'session_uuid': sessionUuid,
      'client_uuid': extras.customer?.uuid,
      'tva': {'taux': vat.rate, 'incluse': vat.included},
      'lignes': lines,
      'remise_globale': extras.globalDiscount,
      'livraison': extras.delivery,
      'totaux': {'brut': totals.gross, 'remises': totals.discounts, 'base_ht': totals.baseHt, 'tva': totals.vat, 'a_payer': totals.payable},
      'paiements': [
        for (final p in payments)
          {
            'tentative_uuid': newUuid(),
            'moyen': p.method,
            'montant': p.amount,
            'recu': p.received,
            'reference': p.reference,
            if (revision21) 'monnaie': p.received == null ? null : p.received! - due(p),
            if (revision21) 'ecart_arrondi': due(p) - p.amount,
          },
      ],
      if (revision21) 'remise_globale_saisie': extras.globalDiscount == 0 ? null : extras.globalEntry?.toJson(),
      if (revision21) 'note': extras.note == null || extras.note!.isEmpty ? null : extras.note,
      if (revision21) 'client_nom': extras.customer?.name,
      if (extras.sharedCart != null) 'panier_uuid': extras.sharedCart,
      'mouvements': movements,
      'autorisations': <Map<String, dynamic>>[if (approval != null) approval.toJson()],
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
  String calculation = '1',
}) => {
  'uuid': uuid,
  'type': type,
  'appareil': {'uuid': deviceUuid, 'epoque': epoch},
  'sequence': sequence,
  'cree_le': '${createdAt.toUtc().toIso8601String().substring(0, 19)}Z',
  'operateur_id': operatorId,
  'versions': {'politiques': policiesVersion, 'calcul': calculation, 'curseur_catalogue': catalogueCursor},
  'contenu': content,
};

class V2SaleInvalid implements Exception {
  const V2SaleInvalid(this.message);

  final String message;

  @override
  String toString() => message;
}
