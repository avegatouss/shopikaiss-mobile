import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Passes événement : règles d'ECAS (`ReglesPassage.kt`) portées mot pour mot, mêmes refus dans le même ordre et mêmes
/// messages (le serveur rend les mêmes textes). Jours civils au format du contrat v2 : `AAAA-MM-JJ`.
///
/// Priorités : une règle datée l'emporte sur le jour de semaine ; sans règle, tous les jours de la fenêtre sans limite
/// par jour ; avec des règles, seuls les jours couverts ; une règle à 0 interdit le jour.
class PassDay {
  PassDay._();

  /// 1 = lundi … 7 = dimanche (ISO).
  static int weekday(String day) => DateTime.utc(int.parse(day.substring(0, 4)), int.parse(day.substring(5, 7)), int.parse(day.substring(8, 10))).weekday;

  /// « JJ/MM/AAAA ».
  static String format(String day) => '${day.substring(8, 10)}/${day.substring(5, 7)}/${day.substring(0, 4)}';

  static const names = ['lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'];

  static String name(int weekday) => weekday >= 1 && weekday <= 7 ? names[weekday - 1] : '?';

  /// Jour civil de la boutique : fuseau publié (`boutique.regles.fuseau`) quand son décalage est fixe et connu, sinon
  /// l'heure locale du terminal (même règle que `date_metier`).
  static String of(DateTime now, String? zone) {
    final offset = fixedOffsets[zone];
    final local = offset == null ? now.toLocal() : now.toUtc().add(Duration(hours: offset));
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year.toString().padLeft(4, '0')}-${two(local.month)}-${two(local.day)}';
  }

  /// Fuseaux sans heure d'été des pays servis, en heures par rapport à UTC.
  static const fixedOffsets = <String, int>{
    'UTC': 0, 'Etc/UTC': 0, 'GMT': 0, 'Africa/Abidjan': 0, 'Africa/Accra': 0, 'Africa/Bamako': 0, 'Africa/Conakry': 0,
    'Africa/Dakar': 0, 'Africa/Lome': 0, 'Africa/Nouakchott': 0, 'Africa/Ouagadougou': 0, 'Africa/Freetown': 0,
    'Africa/Monrovia': 0, 'Africa/Banjul': 0, 'Africa/Bissau': 0, 'Africa/Lagos': 1, 'Africa/Porto-Novo': 1,
    'Africa/Douala': 1, 'Africa/Libreville': 1, 'Africa/Niamey': 1, 'Africa/Ndjamena': 1, 'Africa/Brazzaville': 1,
    'Africa/Kinshasa': 1, 'Africa/Bangui': 1, 'Africa/Malabo': 1, 'Africa/Luanda': 1,
  };
}

/// Une règle de passage : un jour de la semaine OU une date, et le nombre de passages ce jour-là.
class PassDayRule {
  const PassDayRule({this.weekday, this.date, required this.max});

  PassDayRule.fromJson(Map m) : weekday = m['jour_semaine'] as int?, date = m['date'] as String?, max = m['max_passages'] as int;

  final int? weekday;
  final String? date;
  final int max;
}

/// Ce qu'il faut savoir d'un pass pour décider d'un passage.
class PassDefinition {
  const PassDefinition({
    this.revoked = false,
    this.start,
    this.end,
    this.maxTotal,
    this.rules = const [],
    this.capPerPassage,
    this.eventActive = true,
    this.eventStart,
    this.eventEnd,
  });

  final bool revoked;
  final String? start;
  final String? end;
  final int? maxTotal;
  final List<PassDayRule> rules;
  final int? capPerPassage;
  final bool eventActive;
  final String? eventStart;
  final String? eventEnd;
}

/// Décision : refus avec son motif, ou autorisation avec les passages restants APRÈS celui-ci (null = illimité).
class PassDecision {
  const PassDecision.allowed(this.leftToday, this.leftTotal) : refusal = null;
  const PassDecision.refused(String this.refusal) : leftToday = null, leftTotal = null;

  final String? refusal;
  final int? leftToday;
  final int? leftTotal;

  bool get allowed => refusal == null;
}

class PassRules {
  PassRules._();

  /// Quota du jour : null = jour couvert sans limite ; 0 = jour non couvert ou interdit.
  static int? dayQuota(List<PassDayRule> rules, String day) {
    if (rules.isEmpty) return null;
    final dated = rules.where((r) => r.date == day);
    if (dated.isNotEmpty) return dated.map((r) => r.max).reduce((a, b) => a > b ? a : b);
    final weekday = PassDay.weekday(day);
    final weekly = rules.where((r) => r.date == null && r.weekday == weekday);
    if (weekly.isNotEmpty) return weekly.map((r) => r.max).reduce((a, b) => a > b ? a : b);
    return 0;
  }

  static String _plural(int n) => n > 1 ? 's' : '';

  static PassDecision decide(PassDefinition def, String day, int today, int total, int amount) {
    if (def.revoked) return const PassDecision.refused('Ce pass a été révoqué : il ne passe plus.');
    if (!def.eventActive) return const PassDecision.refused("L'événement de ce pass est clos ou désactivé.");
    if (def.eventStart != null && day.compareTo(def.eventStart!) < 0) return PassDecision.refused("L'événement commence le ${PassDay.format(def.eventStart!)}.");
    if (def.eventEnd != null && day.compareTo(def.eventEnd!) > 0) return PassDecision.refused("L'événement s'est terminé le ${PassDay.format(def.eventEnd!)}.");
    if (def.start != null && day.compareTo(def.start!) < 0) return PassDecision.refused("Ce pass n'est valable qu'à partir du ${PassDay.format(def.start!)}.");
    if (def.end != null && day.compareTo(def.end!) > 0) return PassDecision.refused('Ce pass a expiré le ${PassDay.format(def.end!)}.');
    if (amount < 0) return const PassDecision.refused('Montant invalide.');
    final cap = def.capPerPassage;
    if (cap != null && amount > cap) return PassDecision.refused('Le panier ($amount FCFA) dépasse le plafond du pass par passage ($cap FCFA).');
    final leftTotal = def.maxTotal == null ? null : def.maxTotal! - total;
    if (leftTotal != null && leftTotal <= 0) return PassDecision.refused('Ce pass a déjà utilisé ses ${def.maxTotal} passage${_plural(def.maxTotal!)}.');
    final quota = dayQuota(def.rules, day);
    if (quota == 0) {
      final days = allowedDays(def.rules);
      return PassDecision.refused('Ce pass ne passe pas le ${PassDay.name(PassDay.weekday(day))} ${PassDay.format(day)}.${days.isNotEmpty ? ' Jours prévus : $days.' : ''}');
    }
    final leftToday = quota == null ? null : quota - today;
    if (leftToday != null && leftToday <= 0) return PassDecision.refused("Ce pass a déjà fait ses $quota passage${_plural(quota!)} aujourd'hui.");
    return PassDecision.allowed(leftToday == null ? null : leftToday - 1, leftTotal == null ? null : leftTotal - 1);
  }

  /// « lundi (3), mardi (2), 14/11/2026 (1) ».
  static String allowedDays(List<PassDayRule> rules) {
    final kept = rules.where((r) => r.max > 0).toList()
      ..sort((a, b) {
        final byDate = (a.date ?? '').compareTo(b.date ?? '');
        return byDate != 0 ? byDate : (a.weekday ?? 0).compareTo(b.weekday ?? 0);
      });
    return kept.map((r) => '${r.date != null ? PassDay.format(r.date!) : PassDay.name(r.weekday ?? 0)} (${r.max})').join(', ');
  }

  /// Refus du panier (articles hors du service de l'événement ou des menus du pass), ou null. [lines] : (uuid du
  /// produit, nom) ; [eventProducts] et [menuProducts] sont déjà résolus en uuid par le serveur (variantes comprises).
  static String? basketRefusal(List<(String, String)> lines, {required bool allProducts, required Set<String> eventProducts, Set<String>? menuProducts}) {
    if (lines.isEmpty) return 'Le panier est vide.';
    if (eventProducts.isEmpty && !allProducts) {
      return "L'événement n'a aucun produit dans son service : marquez ses catégories, fournisseurs, marques ou produits.";
    }
    final outside = {for (final l in lines) if (!allProducts && !eventProducts.contains(l.$1)) l.$2}.toList();
    if (outside.isNotEmpty) {
      return "Hors du service de l'événement : ${outside.join(', ')}. Retirez-les du panier ou encaissez-les en caisse normale.";
    }
    if (menuProducts != null) {
      final offMenu = {for (final l in lines) if (!menuProducts.contains(l.$1)) l.$2}.toList();
      if (offMenu.isNotEmpty) return 'Hors des menus de ce pass : ${offMenu.join(', ')}.';
    }
    return null;
  }

  /// Répartit [total] entre [n] passes au franc près : le reste va au premier (Σ parts = total).
  static List<int> split(int total, int n) {
    if (n <= 0) throw ArgumentError('Au moins un pass.');
    final base = total ~/ n;
    final rest = total - base * n;
    return List.generate(n, (i) => i == 0 ? base + rest : base);
  }

  /// Normalisation d'ECAS (`CodesPass.normaliser`) : bords retirés, retours chariot retirés, majuscules ; les espaces
  /// intérieurs restent.
  static String normalize(String code) => code.trim().replaceAll('\r', '').replaceAll('\n', '').toUpperCase();

  /// Empreinte publiée par le serveur : SHA-256 hexadécimal minuscule de l'UTF-8 du code normalisé.
  static String fingerprint(String code) => sha256.convert(utf8.encode(normalize(code))).toString();

  /// Moyen de paiement des ventes débitées sur un pass : jamais proposé dans la liste des moyens.
  static const method = 'pass_evenement';
}
