import 'money.dart';

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
      products = [for (final p in (raw['produits'] as List? ?? const [])) Product(Map<String, dynamic>.from(p as Map))] {
    for (final product in products) {
      for (final code in product.codes) {
        _byCode[code.code] = (product, code.packagingId);
      }
    }
  }

  final Map<String, dynamic> raw;
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

  bool get sessionOpen => session != null;

  /// Produit (et conditionnement) d'un code-barres scanné.
  (Product, int?)? byCode(String code) => _byCode[code.trim()];

  /// Recherche par nom, référence ou code (insensible aux accents et à la casse).
  List<Product> search(String query, {int limit = 60}) {
    final q = fold(query.trim());
    if (q.isEmpty) return products.take(limit).toList();
    return products
        .where((p) => fold(p.name).contains(q) || fold(p.reference ?? '').contains(q) || p.codes.any((c) => c.code.contains(query.trim())))
        .take(limit)
        .toList();
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
      sessionOpening = m['ouverture_session'] != false,
      operatorMode = (m['mode_caissier'] ?? 'pin') as String,
      refreshMinutes = (m['rafraichissement_minutes'] as num?)?.toInt() ?? 30,
      probeSeconds = (m['sondage_secondes'] as num?)?.toInt() ?? 20,
      automaticSwitch = (m['bascule'] ?? 'automatique') == 'automatique',
      exclusivity = (m['exclusivite'] ?? 'session') as String;

  final int maxHours;
  final int maxSales;
  final int? maxSaleAmount;
  final int maxLineDiscountPercent;
  final bool sessionOpening;
  final String operatorMode;
  final int refreshMinutes;
  final int probeSeconds;
  final bool automaticSwitch;
  final String exclusivity;

  bool get pinRequired => operatorMode == 'pin';
}

class PaymentMethodInfo {
  PaymentMethodInfo(Map<String, dynamic> m) : code = (m['code'] ?? '') as String, name = (m['nom'] ?? '') as String, isCash = m['especes'] == true;

  final String code;
  final String name;
  final bool isCash;
}

class Operator {
  Operator(Map<String, dynamic> m) : id = (m['id'] as num).toInt(), name = (m['nom'] ?? '') as String, pinHash = m['pin'] as String?;

  final int id;
  final String name;
  final String? pinHash;
}

class Packaging {
  Packaging(Map<String, dynamic> m)
    : id = (m['id'] as num).toInt(),
      name = (m['nom'] ?? '') as String,
      coefficient = (m['coefficient'] ?? '1') as String,
      price = (m['prix'] as num?)?.toInt() ?? 0,
      isDefault = m['defaut'] == true;

  final int id;
  final String name;
  final String coefficient;
  final int price;
  final bool isDefault;
}

class ProductCode {
  ProductCode(Map<String, dynamic> m) : code = (m['code'] ?? '') as String, packagingId = (m['conditionnement_id'] as num?)?.toInt();

  final String code;
  final int? packagingId;
}

class Product {
  Product(Map<String, dynamic> m)
    : id = (m['id'] as num).toInt(),
      name = (m['nom'] ?? '') as String,
      reference = m['reference'] as String?,
      category = m['categorie'] as String?,
      price = (m['prix'] as num?)?.toInt() ?? 0,
      unlimitedStock = m['stock_illimite'] == true,
      stockMicros = parseMicros(((m['stock'] ?? '0') as String).replaceFirst('-', '')) ?? BigInt.zero,
      negativeStock = ((m['stock'] ?? '0') as String).startsWith('-'),
      packagings = [for (final p in (m['conditionnements'] as List? ?? const [])) Packaging(Map<String, dynamic>.from(p as Map))],
      codes = [for (final c in (m['codes'] as List? ?? const [])) ProductCode(Map<String, dynamic>.from(c as Map))];

  final int id;
  final String name;
  final String? reference;
  final String? category;
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

/// Ligne du panier hors ligne. Le prix est celui du référentiel au moment de l'ajout : c'est lui qui est encaissé.
class CartLine {
  CartLine({required this.product, this.packaging, BigInt? quantity, this.discount = 0}) : quantity = quantity ?? BigInt.from(1000000);

  final Product product;
  final Packaging? packaging;
  BigInt quantity;
  int discount;

  int get unitPrice => packaging?.price ?? product.price;
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
  CartPayment({required this.method, required this.amount, this.received});

  final PaymentMethodInfo method;
  final int amount;

  /// Espèces seulement : montant remis par le client (monnaie = reçu − montant).
  final int? received;

  int get change => method.isCash && received != null && received! > amount ? received! - amount : 0;

  Map<String, dynamic> toPayload() => {'moyen': method.code, 'montant': amount, if (method.isCash) 'recu': received ?? amount};
}

/// États d'une opération dans la file locale du terminal.
class OperationStatus {
  static const pending = 'en_attente';
  static const sent = 'transmise';
  static const refused = 'refusee';
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

  bool get isSale => type == 'vente';
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
