import 'money.dart';
import 'web_rules.dart';

/// Référentiel de la caisse hors ligne reçu du serveur (`GET /api/caisse/v1/referentiel`, contrat ADR-421).
class Snapshot {
  Snapshot(this.raw)
    : available = raw['disponible'] == true,
      reason = raw['raison'] as String?,
      store = StoreInfo(Map<String, dynamic>.from(raw['boutique'] as Map? ?? const {})),
      terminal = TerminalRef(Map<String, dynamic>.from(raw['terminal'] as Map? ?? const {})),
      rules = OfflineRules(Map<String, dynamic>.from(raw['reglages'] as Map? ?? const {})),
      lastSequence = ((raw['appareil'] as Map?)?['derniere_sequence'] as num?)?.toInt() ?? 0,
      session = raw['session'] == null ? null : Map<String, dynamic>.from(raw['session'] as Map),
      lastOperatorId = (raw['dernier_caissier_id'] as num?)?.toInt(),
      licenceExpiresAt = DateTime.tryParse((raw['licence_expire_le'] ?? '') as String),
      generatedAt = DateTime.tryParse((raw['genere_le'] ?? '') as String) ?? DateTime.fromMillisecondsSinceEpoch(0),
      fingerprint = (raw['empreinte'] ?? '') as String,
      methods = [for (final m in (raw['moyens'] as List? ?? const [])) PaymentMethodInfo(Map<String, dynamic>.from(m as Map))],
      operators = [for (final o in (raw['caissiers'] as List? ?? const [])) Operator(Map<String, dynamic>.from(o as Map))],
      products = [for (final p in (raw['produits'] as List? ?? const [])) Product(Map<String, dynamic>.from(p as Map))],
      coverage = raw['couverture_stock'] is Map ? StockCoverage(Map<String, dynamic>.from(raw['couverture_stock'] as Map)) : null {
    for (final product in products) {
      for (final code in product.codes) {
        _byCode[code.code] = (product, code.packagingId);
      }
      _byId[product.id] = product;
    }
  }

  final Map<String, dynamic> raw;

  /// Couverture du stock transmise avec ce référentiel (B-REQ-002), ou null pour un serveur qui ne la fournit pas.
  final StockCoverage? coverage;
  final bool available;
  final String? reason;
  final StoreInfo store;
  final TerminalRef terminal;
  final OfflineRules rules;
  final int lastSequence;
  final Map<String, dynamic>? session;
  final int? lastOperatorId;
  final DateTime? licenceExpiresAt;
  final DateTime generatedAt;
  final String fingerprint;
  final List<PaymentMethodInfo> methods;
  final List<Operator> operators;
  final List<Product> products;
  final Map<String, (Product, int?)> _byCode = {};
  final Map<int, Product> _byId = {};

  bool get sessionOpen => session != null;

  /// Produit (et conditionnement) d'un code-barres scanné.
  (Product, int?)? byCode(String code) => _byCode[code.trim()];

  Product? byId(int id) => _byId[id];

  /// Recherche par nom, référence ou code (insensible aux accents et à la casse) sur tout le catalogue, restreinte à
  /// [category], [brand] et [supplier] si donnés ; [limit] null = tous les résultats.
  List<Product> search(String query, {int? limit = 60, String? category, String? brand, String? supplier}) {
    final q = fold(query.trim());
    final hits = products
        .where((p) => category == null || p.category == category)
        .where((p) => brand == null || p.brand == brand)
        .where((p) => supplier == null || p.supplier == supplier)
        .where(
          (p) =>
              q.isEmpty ||
              fold(p.name).contains(q) ||
              fold(p.reference ?? '').contains(q) ||
              fold(p.brand ?? '').contains(q) ||
              p.codes.any((c) => c.code.contains(query.trim())),
        );
    return (limit == null ? hits : hits.take(limit)).toList();
  }

  /// Marques du catalogue complet, par ordre alphabétique (sans accents ni casse).
  List<String> get brands => _sortedValues((p) => p.brand);

  /// Fournisseurs du catalogue complet, par ordre alphabétique (sans accents ni casse).
  List<String> get suppliers => _sortedValues((p) => p.supplier);

  List<String> _sortedValues(String? Function(Product) of) {
    final values = {for (final p in products) if (of(p) case final v? when v.isNotEmpty) v}.toList();
    return values..sort((a, b) => fold(a).compareTo(fold(b)));
  }

  /// Catégories du catalogue : ordre de la boutique (contrat 2.1), sinon ordre alphabétique (sans accents ni casse).
  List<String> get categories {
    final names = {for (final p in products) if (p.category != null && p.category!.isNotEmpty) p.category!};
    final ordered = [for (final c in (raw['categories'] as List? ?? const [])) if (names.contains(c)) c as String];
    final rest = names.where((n) => !ordered.contains(n)).toList()..sort((a, b) => fold(a).compareTo(fold(b)));
    return [...ordered, ...rest];
  }

  Operator? operatorById(int? id) {
    for (final operator in operators) {
      if (operator.id == id) return operator;
    }
    return null;
  }
}

class StoreInfo {
  StoreInfo(Map<String, dynamic> m)
    : name = (m['nom'] ?? '') as String,
      legalName = (m['raison_sociale'] ?? m['nom'] ?? '') as String,
      address = m['adresse'] as String?,
      phone = m['telephone'] as String?,
      taxId = m['identifiant_fiscal'] as String?,
      header = m['entete'] as String?,
      footer = m['pied'] as String?,
      currency = (m['devise'] ?? 'FCFA') as String,
      vatRate = (m['tva_taux'] ?? '0') as String,
      vatIncluded = m['tva_incluse'] != false;

  final String name;
  final String legalName;
  final String? address;
  final String? phone;
  final String? taxId;
  final String? header;
  final String? footer;
  final String currency;
  final String vatRate;
  final bool vatIncluded;

  bool get hasVat => (parseMicros(vatRate) ?? BigInt.zero) > BigInt.zero;
}

class TerminalRef {
  TerminalRef(Map<String, dynamic> m)
    : id = (m['id'] as num?)?.toInt() ?? 0,
      name = (m['nom'] ?? '') as String,
      ticketPrefix = (m['prefixe_tickets'] ?? 'HL') as String;

  final int id;
  final String name;
  final String ticketPrefix;
}

/// Arbitrages de la boutique pour la vente hors ligne (Paramètres › Caisse hors ligne).
class OfflineRules {
  OfflineRules(Map<String, dynamic> m)
    : maxHours = (m['duree_max_heures'] as num?)?.toInt() ?? 72,
      maxSales = (m['ventes_max'] as num?)?.toInt() ?? 500,
      maxSaleAmount = (m['montant_max_vente'] as num?)?.toInt(),
      maxLineDiscountPercent = (m['remise_ligne_max_pourcent'] as num?)?.toInt() ?? 0,
      maxGlobalDiscountPercent = (m['remise_globale_max_pourcent'] as num?)?.toInt() ?? 0,
      sessionOpening = m['ouverture_session'] != false,
      operatorMode = (m['mode_caissier'] ?? 'pin') as String,
      refreshMinutes = (m['rafraichissement_minutes'] as num?)?.toInt() ?? 30,
      probeSeconds = (m['sondage_secondes'] as num?)?.toInt() ?? 20,
      automaticSwitch = (m['bascule'] ?? 'automatique') == 'automatique',
      exclusivity = (m['exclusivite'] ?? 'session') as String,
      permanentLocal = m['vente_locale_permanente'] == true;

  final int maxHours;
  final int maxSales;
  final int? maxSaleAmount;
  final int maxLineDiscountPercent;

  /// Politique `remises.globale_max_pourcent` (0 : aucune remise globale hors ligne).
  final int maxGlobalDiscountPercent;
  final bool sessionOpening;
  final String operatorMode;
  final int refreshMinutes;
  final int probeSeconds;
  final bool automaticSwitch;
  final String exclusivity;

  /// Terminal pilote de la vente locale permanente (palier « vente locale v1 ») : la caisse vend localement même
  /// connectée et synchronise en arrière-plan. Faux par défaut, et pour un serveur qui ne connaît pas ce réglage.
  final bool permanentLocal;

  bool get pinRequired => operatorMode == 'pin';
}

class PaymentMethodInfo {
  PaymentMethodInfo(Map<String, dynamic> m)
    : code = (m['code'] ?? '') as String,
      name = (m['nom'] ?? '') as String,
      isCash = m['especes'] == true,
      referenceMode = (m['reference'] as String?) ?? (m['especes'] == true ? 'aucune' : 'facultative');

  final String code;
  final String name;
  final bool isCash;

  /// Référence de transaction : `aucune`, `facultative` ou `obligatoire` (contrat 2.1, réglage Trésorerie du web).
  final String referenceMode;
}

class Operator {
  Operator(Map<String, dynamic> m)
    : id = (m['id'] as num).toInt(),
      name = (m['nom'] ?? '') as String,
      pinHash = m['pin'] as String?,
      approver = m['approbateur'] == true,
      approvalCodeHash = m['code_autorisation'] as String?;

  final int id;
  final String name;
  final String? pinHash;

  /// Peut autoriser une remise au-delà du seuil d'un autre opérateur (contrat 2.1 `approbateur_remise`).
  final bool approver;

  /// Empreinte de son code d'autorisation de 8 chiffres ; null = autorisation hors ligne impossible pour lui.
  final String? approvalCodeHash;
}

/// Client de la boutique (contrat 2.1, aucun solde) ; [pending] = créé sur ce terminal, pas encore reçu du serveur.
class Customer {
  const Customer({required this.uuid, required this.name, this.phone, this.pending = false});

  final String uuid;
  final String name;
  final String? phone;
  final bool pending;
}

/// Ligne d'une vente du terminal encore retournable ; quantités en unité de base, en millionièmes.
class ReturnableLine {
  const ReturnableLine({required this.lineUuid, required this.label, required this.remaining});

  final String lineUuid;
  final String label;
  final int remaining;
}

/// Panier partagé lié au panier courant ; [claimed] = reprise exclusive obtenue du serveur.
class SharedCartRef {
  const SharedCartRef(this.uuid, {this.claimed = false});

  final String uuid;
  final bool claimed;

  Map<String, dynamic> toJson() => {'uuid': uuid, 'repris': claimed};

  static SharedCartRef? fromJson(Object? raw) => raw is Map ? SharedCartRef(raw['uuid'] as String, claimed: raw['repris'] == true) : null;
}

/// Panier partagé publié par le serveur, visible depuis ce terminal.
class SharedCart {
  const SharedCart({required this.uuid, required this.label, required this.linesCount, required this.takenElsewhere, required this.modifiedAt});

  final String uuid;
  final String label;
  final int linesCount;
  final bool takenElsewhere;
  final String modifiedAt;
}

/// Panier partagé repris : prix figés dans [lines], remise globale en montant (le web ne garde pas le pourcentage).
class TakenCart {
  const TakenCart({required this.ref, required this.lines, required this.globalDiscount, required this.delivery, this.note, this.customer, this.wholesale = false});

  final SharedCartRef ref;
  final List<CartLine> lines;
  final int globalDiscount;
  final int delivery;
  final String? note;
  final Customer? customer;

  /// Panier suspendu au tarif gros : mode figé, repris tel quel à la vente.
  final bool wholesale;
}

/// Montant compté à la clôture pour un moyen autre que les espèces.
class SessionCount {
  const SessionCount({required this.method, required this.amount, this.justification});

  final String method;
  final int amount;
  final String? justification;

  Map<String, dynamic> toJson() => {'moyen': method, 'montant': amount, 'justification': justification};
}

/// Écarts constatés par le terminal à la clôture, sans montant : le comptage reste à l'aveugle.
class ClosingGaps {
  const ClosingGaps({this.cash = false, this.methods = const {}});

  final bool cash;
  final Set<String> methods;
}

/// Client d'un panier conservé (clé `client`), ou null.
Customer? customerFromDraft(Object? raw) => raw is Map ? Customer(uuid: raw['uuid'] as String, name: raw['nom'] as String) : null;

/// Autorisation d'une remise par un responsable, code vérifié sur le terminal. Jamais le code ni son empreinte.
class SaleApproval {
  const SaleApproval({required this.approverId, required this.reason, required this.verifiedAt});

  final int approverId;
  final String reason;
  final String verifiedAt;

  Map<String, dynamic> toJson() => {'type': 'remise', 'approbateur_id': '$approverId', 'motif': reason, 'preuve': 'code_local|$verifiedAt'};
}

class Packaging {
  Packaging(Map<String, dynamic> m)
    : id = (m['id'] as num).toInt(),
      name = (m['nom'] ?? '') as String,
      coefficient = (m['coefficient'] ?? '1') as String,
      price = (m['prix'] as num?)?.toInt() ?? 0,
      wholesalePrice = (m['prix_gros'] as num?)?.toInt(),
      isDefault = m['defaut'] == true;

  final int id;
  final String name;
  final String coefficient;
  final int price;
  final int? wholesalePrice;
  final bool isDefault;
}

class ProductCode {
  ProductCode(Map<String, dynamic> m) : code = (m['code'] ?? '') as String, packagingId = (m['conditionnement_id'] as num?)?.toInt();

  final String code;
  final int? packagingId;
}

/// Bon affiché en badge « Promotion » : [activeOn] compare des dates AAAA-MM-JJ, bornes comprises.
class Promotion {
  Promotion(Map<String, dynamic> m)
    : label = m['libelle'] as String,
      from = m['du'] as String?,
      to = m['au'] as String,
      exclusions = [for (final x in m['exclusions'] as List) (x['du'] as String, x['au'] as String)];

  final String label;
  final String? from;
  final String to;
  final List<(String, String)> exclusions;

  bool activeOn(String day) =>
      (from == null || from!.compareTo(day) <= 0) && to.compareTo(day) >= 0 && !exclusions.any((x) => x.$1.compareTo(day) <= 0 && x.$2.compareTo(day) >= 0);
}

/// Lot d'un produit (capacité `lots.vente`) : [remaining] = stock estimé du lot, ventes locales non couvertes déduites.
class ProductLot {
  ProductLot(Map<String, dynamic> m)
    : uuid = m['uuid'] as String,
      reference = m['reference'] as String?,
      enteredAt = DateTime.tryParse('${m['entree'] ?? ''}'),
      expiresOn = m['peremption'] as String?,
      price = (m['prix'] as num).toInt(),
      remaining = parseMicros(m['reste'] as String) ?? BigInt.zero;

  final String uuid;
  final String? reference;
  final DateTime? enteredAt;

  /// Péremption AAAA-MM-JJ, ou null.
  final String? expiresOn;
  final int price;
  final BigInt remaining;

  /// Le web ne bloque pas un lot périmé : la caisse le signale.
  bool expiredOn(String day) => expiresOn != null && expiresOn!.compareTo(day) < 0;

  /// Libellé de la caisse web : référence, sinon date d'entrée.
  String get label {
    final ref = reference;
    if (ref != null && ref.isNotEmpty) return ref;
    final d = enteredAt?.toLocal();
    if (d == null) return 'Lot';
    String two(int v) => v.toString().padLeft(2, '0');
    return 'Lot du ${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
  }
}

/// Image principale d'un produit (contrat 2.1) ; [hash] change quand elle doit être retéléchargée.
class ProductImage {
  ProductImage(Map<String, dynamic> m)
    : uuid = m['uuid'] as String,
      hash = m['empreinte'] as String,
      width = m['largeur'] as int,
      height = m['hauteur'] as int;

  final String uuid;
  final String hash;
  final int width;
  final int height;
}

class Product {
  Product(Map<String, dynamic> m)
    : id = (m['id'] as num).toInt(),
      name = (m['nom'] ?? '') as String,
      reference = m['reference'] as String?,
      category = m['categorie'] as String?,
      brand = m['marque'] as String?,
      supplier = m['fournisseur'] as String?,
      unit = m['unite'] as String?,
      favorite = m['favori'] == true,
      promotions = [for (final x in (m['promotions'] as List? ?? const [])) Promotion(Map<String, dynamic>.from(x as Map))],
      image = m['image'] == null ? null : ProductImage(Map<String, dynamic>.from(m['image'] as Map)),
      createdAt = m['cree_le'] == null ? null : DateTime.tryParse(m['cree_le'] as String),
      alertThreshold = m['seuil_alerte'] == null ? null : parseMicros(m['seuil_alerte'] as String),
      price = (m['prix'] as num?)?.toInt() ?? 0,
      wholesalePrice = (m['prix_gros'] as num?)?.toInt(),
      wholesaleMinimum = m['gros_quantite_min'] == null ? null : parseMicros(m['gros_quantite_min'] as String),
      unlimitedStock = m['stock_illimite'] == true,
      stockMicros = parseMicros(((m['stock'] ?? '0') as String).replaceFirst('-', '')) ?? BigInt.zero,
      negativeStock = ((m['stock'] ?? '0') as String).startsWith('-'),
      managedByLots = m['gere_par_lots'] == true,
      lotMode = (m['lots_mode'] ?? 'fifo') as String,
      lots = [for (final l in (m['lots'] as List? ?? const [])) ProductLot(Map<String, dynamic>.from(l as Map))],
      packagings = [for (final p in (m['conditionnements'] as List? ?? const [])) Packaging(Map<String, dynamic>.from(p as Map))],
      codes = [for (final c in (m['codes'] as List? ?? const [])) ProductCode(Map<String, dynamic>.from(c as Map))];

  final int id;
  final String name;
  final String? reference;
  final String? category;

  /// Prix de gros et seuil propre au produit (`boutique.regles.gros`).
  final int? wholesalePrice;
  final BigInt? wholesaleMinimum;

  /// Produit vendu par lots (capacité `lots.vente`) ; [lots] dans l'ordre d'allocation de [lotMode].
  final bool managedByLots;
  final String lotMode;
  final List<ProductLot> lots;
  final String? brand;
  final String? supplier;

  /// Nom de l'unité de vente (contrat 2.1), ou null.
  final String? unit;

  /// Favori de caisse (contrat 2.1).
  final bool favorite;

  /// Bons affichés en badge, par priorité : présentation seule, aucun prix ne change (contrat 2.1).
  final List<Promotion> promotions;
  final ProductImage? image;
  final DateTime? createdAt;

  /// Seuil de stock faible (contrat 2.1), ou null.
  final BigInt? alertThreshold;

  /// Libellé du badge « Promotion » à la date [day] (AAAA-MM-JJ), ou null.
  String? promotionLabel(String day) => promotions.where((x) => x.activeOn(day)).firstOrNull?.label;

  /// Badge « Nouveau » : créé depuis [days] jours au plus à [now].
  bool isNew(int? days, DateTime now) => days != null && createdAt != null && now.difference(createdAt!).inDays <= days;
  final int price;
  final bool unlimitedStock;
  final BigInt stockMicros;
  final bool negativeStock;
  final List<Packaging> packagings;
  final List<ProductCode> codes;

  Packaging? packaging(int? id) {
    if (id == null) return null;
    for (final p in packagings) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Stock indicatif reçu avec le référentiel (plusieurs terminaux vendent le même stock).
  BigInt get signedStock => negativeStock ? -stockMicros : stockMicros;
}

/// Remise telle que saisie (contrat 2.1 `remise_saisie`) : `montant` ou `pourcentage`, valeur normalisée.
class DiscountEntry {
  const DiscountEntry(this.type, this.value);

  DiscountEntry.fromJson(Map m) : type = m['type'] as String, value = m['valeur'] as String;

  final String type;
  final String value;

  bool get isPercent => type == 'pourcentage';

  Map<String, String> toJson() => {'type': type, 'valeur': value};
}

/// Éléments de vente du contrat 2.1 hors lignes et paiements : remise globale, livraison, note.
/// Tarif gros de la boutique (`boutique.regles.gros`, `WholesaleRules` du web).
class WholesaleRules {
  WholesaleRules(Map<String, dynamic> m)
    : mode = m['mode'] as String,
      minimum = m['quantite_min'] == null ? null : parseMicros(m['quantite_min'] as String),
      right = (m['droit'] ?? 'remise') as String,
      cumulates = m['remises'] == 'allow';

  final String mode;
  final BigInt? minimum;
  final String right;

  /// Remises, bons et points permis en plus du prix de gros.
  final bool cumulates;

  /// Le bouton « Tarif gros » bascule le panier entier.
  bool get manual => mode != 'quantity';

  /// Seuil du produit, sinon celui de la boutique, en unités de base (un carton de 12 compte pour 12).
  bool reaches(BigInt? productMinimum, BigInt quantity) {
    final threshold = productMinimum ?? minimum;
    return mode != 'cart' && threshold != null && threshold > BigInt.zero && quantity >= threshold;
  }
}

/// Mode tarifaire d'un panier, partagé par ses lignes : un changement vaut pour toutes.
class CartTier {
  CartTier({this.rules, this.cart = false});

  /// Null si la boutique n'a pas de tarif gros.
  WholesaleRules? rules;

  /// Panier entier au tarif gros (bascule manuelle).
  bool cart;
}

class SaleExtras {
  const SaleExtras({this.globalDiscount = 0, this.globalEntry, this.delivery = 0, this.note, this.approval, this.customer, this.sharedCart, this.wholesale = false});

  final int globalDiscount;
  final DiscountEntry? globalEntry;
  final int delivery;
  final String? note;

  /// Autorisation d'un responsable : remise au-delà du seuil du caissier, jamais du plafond de la boutique.
  final SaleApproval? approval;

  /// Client de la vente ; null = client de passage.
  final Customer? customer;

  /// Panier partagé consommé par la vente.
  final String? sharedCart;

  /// Panier entier au tarif gros.
  final bool wholesale;

  bool get isEmpty =>
      globalDiscount == 0 && delivery == 0 && (note == null || note!.isEmpty) && approval == null && customer == null && sharedCart == null && !wholesale;
}

/// Ligne du panier hors ligne. Le prix est celui du référentiel au moment de l'ajout : c'est lui qui est encaissé.
class CartLine {
  CartLine({required this.product, this.packaging, BigInt? quantity, this.discount = 0, this.fixedPrice, this.discountEntry, this.lot, this.tier})
    : quantity = quantity ?? BigInt.from(1000000);

  /// Saisie de la remise (montant ou pourcentage), figée dans la vente 2.1 ; [discount] en est le montant.
  DiscountEntry? discountEntry;

  final Product product;
  final Packaging? packaging;
  BigInt quantity;
  int discount;

  /// Lot choisi par le caissier ; null = choix automatique selon la règle de la boutique.
  ProductLot? lot;

  /// Prix déjà encaissé (réimpression d'une vente enregistrée) ; null = prix du catalogue.
  final int? fixedPrice;

  /// Mode tarifaire du panier ; null = détail.
  CartTier? tier;

  /// Tarif gros demandé pour cette ligne : panier entier, ou seuil de quantité atteint.
  bool get _wholesaleDue {
    final rules = tier?.rules;
    return rules != null && (tier!.cart || rules.reaches(product.wholesaleMinimum, baseQuantity(quantity, packaging?.coefficient)));
  }

  int? get _wholesalePrice => packaging == null ? product.wholesalePrice : packaging!.wholesalePrice;

  /// Prix de gros de la ligne. Le contrat ne couvre pas le tarif gros sur lot : ces produits restent au détail.
  int? get _appliedWholesale => fixedPrice == null && !product.managedByLots && _wholesaleDue ? _wholesalePrice : null;

  int get _retailPrice => packaging?.price ?? lot?.price ?? product.price;

  /// La ligne est vendue à un autre prix que le détail, au titre du tarif gros.
  bool get wholesale => _appliedWholesale != null && _appliedWholesale != _retailPrice;

  /// Prix de gros dû mais non appliqué : produit à lots.
  bool get wholesaleSkipped => fixedPrice == null && product.managedByLots && _wholesaleDue && _wholesalePrice != null;

  int get unitPrice => fixedPrice ?? _appliedWholesale ?? _retailPrice;
  String get label => packaging == null ? product.name : '${product.name} (${packaging!.name})';
  int get base => lineBase(unitPrice, quantity);
  int get total => lineTotal(unitPrice, quantity, discount);

  Map<String, dynamic> toPayload() => {
    'produit_id': product.id,
    'conditionnement_id': packaging?.id,
    'quantite': formatMicros(quantity),
    'prix_unitaire': unitPrice,
    'remise': discount,
  };
}

class CartPayment {
  CartPayment({required this.method, required this.amount, this.received, this.reference, int? cashDue}) : cashDue = cashDue ?? amount;

  final PaymentMethodInfo method;
  final int amount;

  /// Espèces seulement : montant remis par le client (monnaie = reçu − montant).
  final int? received;

  /// Espèces : montant dû au tiroir après arrondi de caisse ; la monnaie se calcule sur lui.
  final int cashDue;

  /// Moyen déclaré (hors espèces) : référence saisie par le caissier, recopiée telle quelle dans la vente v2.
  final String? reference;

  int get change => method.isCash && received != null && received! > cashDue ? received! - cashDue : 0;

  Map<String, dynamic> toPayload() => {'moyen': method.code, 'montant': amount, if (method.isCash) 'recu': received ?? amount};
}

/// États d'une opération dans la file locale du terminal.
class OperationStatus {
  static const pending = 'en_attente';
  static const sent = 'transmise';
  static const refused = 'refusee';
}

/// Mouvement de stock local d'une opération, en unité de base du produit (millionièmes, négatif pour une vente).
///
/// La conversion du conditionnement est figée à l'encaissement : un coefficient modifié ensuite au catalogue ne change
/// pas ce mouvement. Il reste « non couvert » tant qu'aucun catalogue reçu du serveur ne le reflète ; le stock estimé
/// est le stock du catalogue plus les mouvements non couverts.
class StockMovement {
  const StockMovement({required this.uuid, required this.operationUuid, required this.productId, required this.quantityMicros, this.coveredAt});

  final String uuid;
  final String operationUuid;
  final int productId;
  final int quantityMicros;
  final DateTime? coveredAt;
}

/// Ventes de ce terminal classées par le serveur dans la même transaction que le stock du référentiel (B-REQ-002).
///
/// Une vente de [integrated] est déjà déduite du stock transmis ; une vente de [arbitration] ou absente des listes ne
/// l'est pas. [dismissed] : écartée par la boutique, sans mouvement serveur.
class StockCoverage {
  StockCoverage(Map<String, dynamic> m)
    : sinceSequence = (m['depuis_sequence'] as num?)?.toInt(),
      integrated = {for (final u in (m['integrees'] as List? ?? const [])) '$u'},
      arbitration = {for (final u in (m['a_arbitrer'] as List? ?? const [])) '$u'},
      dismissed = {for (final u in (m['ecartees'] as List? ?? const [])) '$u'},
      truncated = m['tronque'] == true;

  final int? sinceSequence;
  final Set<String> integrated;
  final Set<String> arbitration;
  final Set<String> dismissed;
  final bool truncated;
}

/// Compteurs de la file, lus sans charger les opérations.
class QueueCounts {
  const QueueCounts({this.pending = 0, this.pendingSales = 0, this.refused = 0, this.arbitration = 0});

  final int pending;
  final int pendingSales;
  final int refused;

  /// Reçues par le serveur mais à arbitrer par la boutique (dernier état connu du terminal).
  final int arbitration;
}

/// Une opération porte déjà cet identifiant : l'encaissement a déjà eu lieu (reprise après réponse perdue).
class OperationAlreadyRecorded implements Exception {
  const OperationAlreadyRecorded(this.operation);

  final OfflineOperation operation;

  @override
  String toString() => 'Opération ${operation.uuid} déjà enregistrée.';
}

/// Panier en cours conservé sur le terminal (redémarrage, coupure, écran fermé), tant qu'il n'est ni encaissé ni vidé.
class StoredDraft {
  const StoredDraft({required this.uuid, required this.revision, required this.content, required this.updatedAt});

  final String uuid;

  /// Révision croissante : une écriture plus ancienne ne remplace jamais une plus récente.
  final int revision;
  final Map<String, dynamic> content;
  final DateTime updatedAt;
}

/// Le brouillon (panier) a déjà donné lieu à une vente : un second encaissement du même panier est refusé.
class DraftAlreadyConsumed implements Exception {
  const DraftAlreadyConsumed(this.operationUuid);

  final String operationUuid;

  @override
  String toString() => 'Ce panier a déjà été encaissé (opération $operationUuid).';
}

/// Opération faite hors ligne, conservée sur le terminal jusqu'à sa réception par le serveur.
class OfflineOperation {
  OfflineOperation({
    required this.uuid,
    required this.sequence,
    required this.type,
    required this.number,
    required this.date,
    required this.operatorId,
    required this.content,
    this.status = OperationStatus.pending,
    this.serverStatus,
    this.serverNumber,
    this.message,
    this.resolvedAt,
  });

  final String uuid;
  final int sequence;

  /// `vente` ou `ouverture_session`.
  final String type;
  final String? number;
  final DateTime date;
  final int operatorId;
  final Map<String, dynamic> content;
  String status;

  /// Statut côté serveur après transmission : `integree`, `a_arbitrer`, `ecartee`.
  String? serverStatus;
  String? serverNumber;
  String? message;

  /// Moment où le serveur a donné à l'opération un sort définitif (`integree` ou `ecartee`). Le stock d'un catalogue
  /// demandé APRÈS ce moment reflète l'opération : sa consommation locale est alors couverte.
  DateTime? resolvedAt;

  bool get isSale => type == 'vente';

  /// Sort définitif côté serveur : plus rien à attendre de la boutique pour cette opération.
  static bool isFinalServerStatus(String? status) => status == 'integree' || status == 'ecartee';
  int get total => (content['total'] as num?)?.toInt() ?? 0;

  Map<String, dynamic> toPayload() => {
    'uuid': uuid,
    'type': type,
    'sequence': sequence,
    'numero': number,
    'date': isoWithOffset(date),
    'caissier_id': operatorId,
    'contenu': content,
  };
}

/// Date ISO 8601 avec le décalage du terminal (`2026-10-18T10:15:00+00:00`), lue telle quelle par le serveur.
String isoWithOffset(DateTime date) {
  final local = date.toLocal();
  final offset = local.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final hours = offset.inHours.abs().toString().padLeft(2, '0');
  final minutes = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
  String two(int v) => v.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)}T${two(local.hour)}:${two(local.minute)}:${two(local.second)}$sign$hours:$minutes';
}

/// Texte sans accents (casse conservée), pour l'imprimante en police ASCII.
String stripAccents(String text) {
  const map = {
    'à': 'a',
    'â': 'a',
    'ä': 'a',
    'á': 'a',
    'ã': 'a',
    'å': 'a',
    'ç': 'c',
    'é': 'e',
    'è': 'e',
    'ê': 'e',
    'ë': 'e',
    'í': 'i',
    'ì': 'i',
    'î': 'i',
    'ï': 'i',
    'ñ': 'n',
    'ó': 'o',
    'ò': 'o',
    'ô': 'o',
    'ö': 'o',
    'õ': 'o',
    'ú': 'u',
    'ù': 'u',
    'û': 'u',
    'ü': 'u',
    'ý': 'y',
    'ÿ': 'y',
    'œ': 'oe',
    'æ': 'ae',
    'À': 'A',
    'Â': 'A',
    'Ä': 'A',
    'Á': 'A',
    'Ã': 'A',
    'Å': 'A',
    'Ç': 'C',
    'É': 'E',
    'È': 'E',
    'Ê': 'E',
    'Ë': 'E',
    'Í': 'I',
    'Ì': 'I',
    'Î': 'I',
    'Ï': 'I',
    'Ñ': 'N',
    'Ó': 'O',
    'Ò': 'O',
    'Ô': 'O',
    'Ö': 'O',
    'Õ': 'O',
    'Ú': 'U',
    'Ù': 'U',
    'Û': 'U',
    'Ü': 'U',
    'Ý': 'Y',
    'Œ': 'OE',
    'Æ': 'AE',
    '’': "'",
    '‘': "'",
    '«': '"',
    '»': '"',
    '–': '-',
    '—': '-',
    ' ': ' ',
    ' ': ' ',
    '€': 'EUR',
  };
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    buffer.write(map[char] ?? char);
  }
  return buffer.toString();
}

/// Minuscules sans accents, pour la recherche.
String fold(String text) => stripAccents(text).toLowerCase();
