import 'dart:convert';

import 'engine.dart';
import 'models.dart';

/// Prix mémorisés localement (demande utilisateur du 21/11, livrée par C en e8354be) : un prix saisi sur une ligne
/// est repris au prochain ajout du même produit sur ce terminal. Rien n'est envoyé au serveur : chaque vente
/// reste une vente à prix saisi (contrat 2.1 lot 9), revérifiée par le moteur à l'ajout et à l'encaissement.
/// Partagé par l'adaptateur Windows et la caisse Android : même clé durable par boutique.
class LocalPrices {
  const LocalPrices({required this.enabled, required this.prices});

  static const empty = LocalPrices(enabled: false, prices: {});

  final bool enabled;

  /// Identifiant produit (texte) → prix en francs.
  final Map<String, int> prices;

  static String key(Snapshot snapshot) => 'local-prices-v1:${(snapshot.raw['boutique'] as Map?)?['uuid'] ?? snapshot.store.name}';

  static Future<LocalPrices> read(CaisseEngine engine) async {
    final snapshot = engine.snapshot;
    if (snapshot == null) return empty;
    final raw = await engine.store.read(key(snapshot));
    if (raw == null) return empty;
    try {
      final m = jsonDecode(raw) as Map;
      return LocalPrices(
        enabled: m['enabled'] == true,
        prices: {
          for (final e in ((m['prices'] as Map?) ?? const {}).entries)
            if (e.value is int) '${e.key}': e.value as int,
        },
      );
    } on FormatException {
      return empty;
    }
  }

  Map<String, dynamic> toJson() => {'enabled': enabled, 'prices': prices};

  /// Prix mémorisé applicable à [line] pour [operator], ou null (désactivé, absent, hors bornes ou refusé par le moteur).
  int? priceFor(CaisseEngine engine, Operator? operator, CartLine line) {
    if (!enabled) return null;
    final price = prices['${line.product.id}'];
    if (price == null || price < 0 || price > CaisseEngine.maxEnteredPrice) return null;
    return engine.enteredPriceBlocker(operator, line) == null ? price : null;
  }

  /// Active ou désactive ; la désactivation efface la mémoire sans toucher aux paniers.
  static Future<LocalPrices> setEnabled(CaisseEngine engine, Operator? operator, bool enabled) async {
    final snapshot = engine.snapshot;
    if (snapshot == null || operator == null || !engine.editablePriceSupported || !engine.hasRight(operator, 'prix_vente_modifier')) {
      throw StateError('Le droit de modifier les prix est requis.');
    }
    final current = await read(engine);
    final next = LocalPrices(enabled: enabled, prices: enabled ? current.prices : const {});
    await engine.store.write(key(snapshot), jsonEncode(next.toJson()));
    return next;
  }

  /// Mémorise (ou oublie, [price] null) le prix d'un produit si la mémoire est active. Renvoie vrai si elle a changé.
  static Future<bool> remember(CaisseEngine engine, int productId, int? price) async {
    final snapshot = engine.snapshot;
    if (snapshot == null) return false;
    final current = await read(engine);
    if (!current.enabled) return false;
    final prices = Map<String, int>.from(current.prices);
    if (price == null) {
      prices.remove('$productId');
    } else {
      prices['$productId'] = price;
    }
    await engine.store.write(key(snapshot), jsonEncode(LocalPrices(enabled: true, prices: prices).toJson()));
    return true;
  }
}
