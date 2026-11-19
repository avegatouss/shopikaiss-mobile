import '../passes/pass_rules.dart';
import '../sync_v2/decimal6.dart';

/// Promotions, happy hour et tarif du personnel de la caisse maîtresse (contrat v2, RESTAURANT-1 §3.12, lot R-5).
///
/// Reprise pure et déterministe de `PromotionEngine` du web, qui fait référence et recontrôle chaque ligne à
/// l'intégration (`PromotionEngine::bestAt`, évalué à `cree_le` dans le fuseau de la boutique) :
/// - `isActiveAt` : fenêtre horaire en heure locale du fuseau publié (`restaurant.reglages.fuseau`), une fenêtre qui
///   passe minuit comptant pour le jour où elle a commencé ; jours ISO ; période `du`–`au` ; canaux (code du canal de la
///   commande) ; salles (salle de sa table, liste vide = toutes) ;
/// - cibles : produit, ou catégorie du produit, ou sa catégorie parente restaurant ; aucune cible = tous les articles ;
/// - `discountFor` : pourcentage du brut arrondi vers le bas, montant par article au plus le brut, prix spécial par
///   article (arrondi au plus proche, jamais négatif), « X achetés, Y offerts » (valeur des articles offerts) ;
/// - choix : priorité la plus haute, puis la plus forte remise, puis la plus ancienne.
///
/// Profil Restaurant seulement (le Service de table du web n'a pas de promotions). Quantités en millionièmes, montants en
/// francs entiers.
class RestoPromotion {
  const RestoPromotion({
    required this.uuid,
    required this.name,
    required this.category,
    required this.type,
    this.percent,
    this.amount,
    this.buy,
    this.free,
    this.priority = 0,
    this.weekdays = const [],
    this.start,
    this.end,
    this.from,
    this.to,
    this.channels = const {},
    this.rooms = const {},
    this.products = const {},
    this.categories = const {},
    this.maxPerStaff,
    this.rank,
  });

  /// Entité publiée `restaurant.promotion` (clé = uuid). [rank] : révision de l'entité, seule trace d'ancienneté que la
  /// caisse reçoit (l'identifiant du web n'est pas publié).
  factory RestoPromotion.fromJson(String uuid, Map m, {BigInt? rank}) => RestoPromotion(
    uuid: uuid,
    name: m['nom'] as String,
    category: m['categorie'] as String,
    type: m['type'] as String,
    percent: m['pourcentage'] == null ? null : Decimal6.parse(m['pourcentage'] as String),
    amount: m['montant'] as int?,
    buy: m['achetes'] as int?,
    free: m['offerts'] as int?,
    priority: m['priorite'] as int? ?? 0,
    weekdays: [for (final d in (m['jours'] as List? ?? const [])) d as int],
    start: m['heure_debut'] as String?,
    end: m['heure_fin'] as String?,
    from: m['du'] as String?,
    to: m['au'] as String?,
    channels: {...(m['canaux'] as List? ?? const []).cast<String>()},
    rooms: {...(m['salles'] as List? ?? const []).cast<String>()},
    products: {...(m['produits'] as List? ?? const []).cast<String>()},
    categories: {...(m['categories'] as List? ?? const []).cast<String>()},
    maxPerStaff: m['max_par_personnel'] as String?,
    rank: rank,
  );

  final String uuid;
  final String name;

  /// `promotion`, `happy_hour` ou `staff` : c'est aussi le `tarif` de la ligne remisée.
  final String category;

  /// `pourcentage`, `montant`, `prix_special` ou `x_achetes_y_offerts`.
  final String type;

  /// Taux en millionièmes de point (`"20.000000"` → 20000000).
  final int? percent;

  /// Montant ou prix spécial par article.
  final int? amount;
  final int? buy;
  final int? free;
  final int priority;

  /// Jours ISO (1 = lundi) ; vide = tous.
  final List<int> weekdays;

  /// `HH:MM:SS` en heure locale de la boutique, ou null.
  final String? start;
  final String? end;

  /// Période `AAAA-MM-JJ`, bornes comprises, ou null.
  final String? from;
  final String? to;
  final Set<String> channels;
  final Set<String> rooms;
  final Set<String> products;
  final Set<String> categories;
  final String? maxPerStaff;

  /// Ancienneté (révision de publication) ; null = inconnue, classée après les autres.
  final BigInt? rank;

  bool get buyXGetY => type == 'x_achetes_y_offerts';

  /// Forme du contrat (`donnees-restaurant-1.json#/$defs/restaurant.promotion`) : conditions figées d'une ligne.
  Map<String, dynamic> toJson() => {
    'nom': name,
    'categorie': category,
    'type': type,
    'pourcentage': percent == null ? null : Decimal6.format(percent!),
    'montant': amount,
    'achetes': buy,
    'offerts': free,
    'priorite': priority,
    'jours': weekdays,
    'heure_debut': start,
    'heure_fin': end,
    'du': from,
    'au': to,
    'canaux': [...channels],
    'salles': [...rooms],
    'produits': [...products],
    'categories': [...categories],
    'max_par_personnel': maxPerStaff,
  };

  /// Calendrier et fenêtre horaire à l'heure locale [local] de la boutique (`isActiveAt` sans le lieu).
  bool activeAt(DateTime local) {
    String two(int v) => v.toString().padLeft(2, '0');
    final time = '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
    var day = DateTime.utc(local.year, local.month, local.day);
    final s = start, e = end;
    if (s != null && e != null) {
      if (s.compareTo(e) <= 0) {
        if (time.compareTo(s) < 0 || time.compareTo(e) > 0) return false;
      } else if (time.compareTo(e) <= 0) {
        // Après minuit dans une fenêtre ouverte la veille : le calendrier est celui de la veille.
        day = day.subtract(const Duration(days: 1));
      } else if (time.compareTo(s) < 0) {
        return false;
      }
    } else if (s != null && time.compareTo(s) < 0) {
      return false;
    } else if (e != null && time.compareTo(e) > 0) {
      return false;
    }
    if (weekdays.isNotEmpty && !weekdays.contains(day.weekday)) return false;
    final date = '${day.year.toString().padLeft(4, '0')}-${two(day.month)}-${two(day.day)}';
    if (from != null && date.compareTo(from!) < 0) return false;
    if (to != null && date.compareTo(to!) > 0) return false;
    return true;
  }

  /// Lieu de la commande : canal (code) et salle de sa table ; une liste vide vaut pour tous.
  bool placeMatches({String? channel, String? room}) =>
      (channels.isEmpty || (channel != null && channels.contains(channel))) && (rooms.isEmpty || (room != null && rooms.contains(room)));

  /// Article visé : sans cible, tous ; sinon le produit, ou sa catégorie, ou la catégorie parente restaurant de celle-ci.
  bool targets(String productUuid, {String? categoryUuid, String? parentCategoryUuid}) {
    if (products.isEmpty && categories.isEmpty) return true;
    if (products.contains(productUuid)) return true;
    if (categoryUuid == null) return false;
    return categories.contains(categoryUuid) || (parentCategoryUuid != null && categories.contains(parentCategoryUuid));
  }

  /// Remise que la promotion donne sur toute la ligne (« X achetés, Y offerts » : valeur des articles offerts).
  /// [coefficient] convertit l'unité commandée en articles : montants et prix spéciaux sont par article.
  int discountFor(int unitPrice, int quantity, {int coefficient = Decimal6.scale}) {
    final gross = Decimal6.amount(unitPrice, quantity);
    // Prix × quantité × coefficient, en millionièmes au carré.
    final perArticles = BigInt.from(amount ?? 0) * BigInt.from(quantity) * BigInt.from(coefficient);
    final square = BigInt.from(Decimal6.scale) * BigInt.from(Decimal6.scale);
    switch (type) {
      case 'pourcentage':
        return (BigInt.from(gross) * BigInt.from(percent ?? 0) ~/ (BigInt.from(100) * BigInt.from(Decimal6.scale))).toInt();
      case 'montant':
        final off = (perArticles ~/ square).toInt();
        return off < gross ? off : gross;
      case 'prix_special':
        final price = ((perArticles * BigInt.two + square) ~/ (square * BigInt.two)).toInt();
        return gross - price > 0 ? gross - price : 0;
      case 'x_achetes_y_offerts':
        return Decimal6.amount(unitPrice, freeQuantity(quantity));
      default:
        return 0;
    }
  }

  /// Remise portée par la ligne achetée elle-même (un « X achetés, Y offerts » n'en porte aucune : l'offert est lié).
  int lineDiscount(int unitPrice, int quantity, {int coefficient = Decimal6.scale}) =>
      buyXGetY ? 0 : discountFor(unitPrice, quantity, coefficient: coefficient);

  /// Quantité offerte pour une quantité achetée : floor(achetés / X) × Y, en millionièmes.
  int freeQuantity(int quantity) {
    final x = (buy ?? 0) < 1 ? 1 : buy!;
    final y = (free ?? 0) < 0 ? 0 : (free ?? 0);
    return quantity ~/ (x * Decimal6.scale) * y * Decimal6.scale;
  }
}

/// Article candidat à une promotion : ce que la caisse sait de la ligne et de sa commande à la saisie.
class RestoPromotionLine {
  const RestoPromotionLine({
    required this.productUuid,
    this.categoryUuid,
    required this.unitPrice,
    required this.quantity,
    this.coefficient = Decimal6.scale,
    this.channel,
    this.tableUuid,
  });

  final String productUuid;
  final String? categoryUuid;
  final int unitPrice;
  final int quantity;
  final int coefficient;

  /// Code du canal de la commande.
  final String? channel;

  /// Table de la commande (sa salle compte pour `salles`).
  final String? tableUuid;
}

/// Promotions publiées (`restaurant.promotion`, actives) et ce qu'il faut pour les appliquer : fuseau de la boutique,
/// catégories parentes, salles des tables, conditions figées à la saisie des lignes déjà promues.
class RestoPromotions {
  RestoPromotions({
    this.promotions = const [],
    this.timezone,
    this.categoryParents = const {},
    this.tableRooms = const {},
    Map<String, RestoPromotion>? entryTerms,
  }) : entryTerms = entryTerms ?? {};

  /// Promotions actives publiées. Vide : aucune promotion (fonction restreinte, serveur antérieur au lot R-5…).
  final List<RestoPromotion> promotions;

  /// `restaurant.reglages.fuseau`.
  final String? timezone;

  /// Catégorie parente restaurant de chaque catégorie (`restaurant.categorie.parent_uuid`).
  final Map<String, String?> categoryParents;

  /// Salle de chaque table (`restaurant.table.salle_uuid`).
  final Map<String, String?> tableRooms;

  /// Conditions figées à la saisie, par ligne (`refreshLine` du web : un changement de quantité les garde).
  final Map<String, RestoPromotion> entryTerms;

  bool get isEmpty => promotions.isEmpty;

  /// Heure locale de la boutique : fuseau publié quand son décalage est fixe et connu, sinon l'heure du terminal (même
  /// règle que la date métier).
  static DateTime localTime(DateTime at, String? zone) {
    final offset = PassDay.fixedOffsets[zone];
    return offset == null ? at.toLocal() : at.toUtc().add(Duration(hours: offset));
  }

  RestoPromotion? byUuid(String? uuid) => promotions.where((p) => p.uuid == uuid).firstOrNull;

  /// Conditions d'une ligne promue : celles figées à sa saisie, sinon la promotion publiée (comme `entryTerms` du web).
  RestoPromotion? termsOf(String lineUuid, String? promotionUuid) => entryTerms[lineUuid] ?? byUuid(promotionUuid);

  /// Promotions qui valent pour [line] à l'instant [at] (`applicable` du web) ; [categories] : `['staff']` pour une
  /// ligne au tarif du personnel, sinon `promotion` et `happy_hour`.
  List<RestoPromotion> applicable(RestoPromotionLine line, DateTime at, {List<String> categories = const ['promotion', 'happy_hour']}) {
    final local = localTime(at, timezone);
    final room = line.tableUuid == null ? null : tableRooms[line.tableUuid];
    final parent = line.categoryUuid == null ? null : categoryParents[line.categoryUuid];
    return [
      for (final p in promotions)
        if (categories.contains(p.category) &&
            p.activeAt(local) &&
            p.placeMatches(channel: line.channel, room: room) &&
            p.targets(line.productUuid, categoryUuid: line.categoryUuid, parentCategoryUuid: parent) &&
            (p.category == 'staff' || p.buyXGetY || p.lineDiscount(line.unitPrice, line.quantity, coefficient: line.coefficient) > 0))
          p,
    ];
  }

  /// Promotion de la ligne (`bestAt` du web) : priorité la plus haute, puis la plus forte remise, puis la plus ancienne ;
  /// null si aucune.
  RestoPromotion? best(RestoPromotionLine line, DateTime at, {List<String> categories = const ['promotion', 'happy_hour']}) {
    final candidates = applicable(line, at, categories: categories);
    if (candidates.isEmpty) return null;
    int value(RestoPromotion p) => p.discountFor(line.unitPrice, line.quantity, coefficient: line.coefficient);
    candidates.sort((a, b) {
      if (a.priority != b.priority) return b.priority.compareTo(a.priority);
      final va = value(a), vb = value(b);
      if (va != vb) return vb.compareTo(va);
      if (a.rank != b.rank) {
        if (a.rank == null) return 1;
        if (b.rank == null) return -1;
        return a.rank!.compareTo(b.rank!);
      }
      return a.uuid.compareTo(b.uuid);
    });
    return candidates.first;
  }
}
