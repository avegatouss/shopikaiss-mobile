import '../passes/pass_rules.dart';
import '../sync_v2/decimal6.dart';

/// Promotion publiée (`restaurant.promotion`, RESTAURANT-1 §3.12, lot R-5), lue pour le TARIF DU PERSONNEL (catégorie
/// `staff`) : mêmes règles que PromotionEngine du web (fenêtre horaire dans le fuseau de la boutique, y compris après
/// minuit ; jours ISO ; période ; canaux ; salles ; cibles produit ou catégorie, ou sa catégorie parente restaurant ;
/// remise arrondie vers le bas). Le moteur des promotions et du happy hour (lot R-5, autre chantier) peut reprendre cette
/// classe : seul le choix de la catégorie diffère.
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
    this.days = const [],
    this.start,
    this.end,
    this.from,
    this.to,
    this.channels = const [],
    this.rooms = const [],
    this.products = const [],
    this.categories = const [],
    this.maxPerStaff,
    this.rank = 0,
  });

  /// [rank] : ordre de publication (la « plus ancienne » à égalité, faute d'identifiant serveur publié).
  factory RestoPromotion.fromJson(String uuid, Map m, {int rank = 0}) => RestoPromotion(
    uuid: uuid,
    name: m['nom'] as String,
    category: m['categorie'] as String,
    type: m['type'] as String,
    percent: m['pourcentage'] == null ? null : Decimal6.parse(m['pourcentage'] as String),
    amount: m['montant'] as int?,
    buy: m['achetes'] as int?,
    free: m['offerts'] as int?,
    priority: m['priorite'] as int? ?? 0,
    days: [...((m['jours'] as List?) ?? const []).cast<int>()],
    start: m['heure_debut'] as String?,
    end: m['heure_fin'] as String?,
    from: m['du'] as String?,
    to: m['au'] as String?,
    channels: [...((m['canaux'] as List?) ?? const []).cast<String>()],
    rooms: [...((m['salles'] as List?) ?? const []).cast<String>()],
    products: [...((m['produits'] as List?) ?? const []).cast<String>()],
    categories: [...((m['categories'] as List?) ?? const []).cast<String>()],
    maxPerStaff: m['max_par_personnel'] == null ? null : Decimal6.parse(m['max_par_personnel'] as String),
    rank: rank,
  );

  final String uuid;
  final String name;

  /// `promotion`, `happy_hour` ou `staff`.
  final String category;

  /// `pourcentage`, `montant`, `prix_special` ou `x_achetes_y_offerts`.
  final String type;

  /// Taux en millionièmes (`"50.000000"` → 50 000 000).
  final int? percent;

  /// Montant ou prix spécial par article.
  final int? amount;
  final int? buy;
  final int? free;
  final int priority;
  final List<int> days;
  final String? start;
  final String? end;
  final String? from;
  final String? to;
  final List<String> channels;
  final List<String> rooms;
  final List<String> products;
  final List<String> categories;

  /// Articles (unité de base, millionièmes) par employé et par jour : un contrôle noté par le serveur, jamais un refus.
  final int? maxPerStaff;
  final int rank;

  /// Heure murale de la boutique : fuseau publié à décalage fixe, sinon l'heure locale du terminal (règle de `date_metier`).
  static DateTime wallClock(DateTime now, String? zone) {
    final offset = PassDay.fixedOffsets[zone];
    final local = offset == null ? now.toLocal() : now.toUtc().add(Duration(hours: offset));
    return DateTime.utc(local.year, local.month, local.day, local.hour, local.minute, local.second);
  }

  /// `isActiveAt` du web : [at] est l'heure murale de la boutique ([wallClock]).
  bool activeAt(DateTime at) {
    String two(int v) => v.toString().padLeft(2, '0');
    final time = '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
    var day = DateTime.utc(at.year, at.month, at.day);
    final start = this.start, end = this.end;
    if (start != null && end != null) {
      if (start.compareTo(end) <= 0) {
        if (time.compareTo(start) < 0 || time.compareTo(end) > 0) return false;
      } else if (time.compareTo(end) <= 0) {
        // Après minuit, dans une fenêtre ouverte la veille : le calendrier est celui de la veille.
        day = day.subtract(const Duration(days: 1));
      } else if (time.compareTo(start) < 0) {
        return false;
      }
    } else if (start != null && time.compareTo(start) < 0) {
      return false;
    } else if (end != null && time.compareTo(end) > 0) {
      return false;
    }
    if (days.isNotEmpty && !days.contains(day.weekday)) return false;
    final date = '${day.year.toString().padLeft(4, '0')}-${two(day.month)}-${two(day.day)}';
    if (from != null && date.compareTo(from!) < 0) return false;
    if (to != null && date.compareTo(to!) > 0) return false;
    return true;
  }

  /// Lieu de la commande : canal (code) et salle de sa table ; une commande sans table n'est pas visée par des salles.
  bool placed({String? channel, String? room}) =>
      (channels.isEmpty || (channel != null && channels.contains(channel))) && (rooms.isEmpty || (room != null && rooms.contains(room)));

  /// Cibles : aucune = tous les articles ; sinon le produit, sa catégorie ou la catégorie parente restaurant de celle-ci.
  bool targets(String productUuid, {String? category, String? parentCategory}) {
    if (products.isEmpty && categories.isEmpty) return true;
    if (products.contains(productUuid)) return true;
    return (category != null && categories.contains(category)) || (parentCategory != null && categories.contains(parentCategory));
  }

  /// Remise de la ligne (`discountFor`) : [quantity] et [coefficient] en millionièmes ; « X achetés, Y offerts » : aucune
  /// sur la ligne achetée (l'offert est une ligne liée).
  int discountFor(int unitPrice, int quantity, {int coefficient = Decimal6.scale}) {
    final gross = Decimal6.amount(unitPrice, quantity);
    final articles = BigInt.from(quantity) * BigInt.from(coefficient); // millionièmes²
    final micro2 = BigInt.from(Decimal6.scale) * BigInt.from(Decimal6.scale);
    switch (type) {
      case 'pourcentage':
        return (BigInt.from(gross) * BigInt.from(percent ?? 0) ~/ (BigInt.from(100) * BigInt.from(Decimal6.scale))).toInt();
      case 'montant':
        final value = (BigInt.from(amount ?? 0) * articles ~/ micro2).toInt();
        return value < gross ? value : gross;
      case 'prix_special':
        final n = BigInt.from(amount ?? 0) * articles;
        final q = n ~/ micro2, r = n.remainder(micro2);
        final special = (r * BigInt.two >= micro2 ? q + BigInt.one : q).toInt();
        return gross - special > 0 ? gross - special : 0;
      default:
        return 0;
    }
  }
}

/// Tarif du personnel d'un article (`PromotionEngine::applyToNewLine`, catégorie `staff`) : parmi les promotions du
/// personnel qui valent à [at] (heure murale) au lieu de la commande et visent l'article, la priorité la plus haute, puis
/// la plus forte remise, puis la plus ancienne ; null : le tarif du personnel ne s'applique pas à cet article maintenant.
({RestoPromotion promotion, int discount})? restoStaffPrice(
  Iterable<RestoPromotion> promotions, {
  required DateTime at,
  required String productUuid,
  String? category,
  String? parentCategory,
  String? channel,
  String? room,
  required int unitPrice,
  required int quantity,
  int coefficient = Decimal6.scale,
}) {
  final candidates = [
    for (final p in promotions)
      if (p.category == 'staff' && p.activeAt(at) && p.placed(channel: channel, room: room) && p.targets(productUuid, category: category, parentCategory: parentCategory))
        (promotion: p, discount: p.discountFor(unitPrice, quantity, coefficient: coefficient)),
  ];
  if (candidates.isEmpty) return null;
  candidates.sort((a, b) {
    if (a.promotion.priority != b.promotion.priority) return b.promotion.priority.compareTo(a.promotion.priority);
    if (a.discount != b.discount) return b.discount.compareTo(a.discount);
    return a.promotion.rank.compareTo(b.promotion.rank);
  });
  return candidates.first;
}
