import '../app_settings.dart';

/// Repli de la route de démarrage (2026-11-21) : un serveur ancien (avant `/caisse/demarrer`, ex. production sur 903abe6d)
/// répond 404 (ou 405) sur cette route. La caisse web recharge alors `<origine>/caisse` une seule fois par chargement, sans
/// toucher à l'adresse enregistrée, et retient l'absence de la route pour cette origine pendant 24 h (le serveur peut être
/// mis à jour entre-temps). Logique pure, testée sans vue web.

/// Durée pendant laquelle l'absence de la route est tenue pour acquise.
const startRouteMemoryTtl = Duration(hours: 24);

/// Chemin de repli : la caisse boutique, présente sur tous les serveurs.
const shopRegisterPath = '/caisse';

/// Souvenir « la route de démarrage est absente de [origin] », noté à [at].
class StartRouteMemory {
  const StartRouteMemory(this.origin, this.at);

  final String origin;
  final DateTime at;

  /// Valable pour [shopUrl] : même origine et moins de 24 h.
  bool appliesTo(String shopUrl, DateTime now) {
    final age = now.difference(at);
    return originOf(shopUrl) == origin && !age.isNegative && age < startRouteMemoryTtl;
  }

  Map<String, dynamic> toJson() => {'origin': origin, 'at': at.toUtc().toIso8601String()};

  /// Lecture tolérante : null si absent ou illisible.
  static StartRouteMemory? fromJson(Object? json) {
    if (json is! Map) return null;
    final origin = json['origin'];
    final at = DateTime.tryParse('${json['at']}');
    return origin is String && origin.isNotEmpty && at != null ? StartRouteMemory(origin, at) : null;
  }
}

/// [url] désigne-t-elle la route de démarrage (`/caisse/demarrer`, barre finale tolérée) ?
bool isStartRoute(String url) {
  final uri = Uri.tryParse(url);
  return uri != null && (uri.path == shopStartPath || uri.path == '$shopStartPath/');
}

/// Adresse de repli de [url] : même origine, même requête, chemin `/caisse`.
String registerUrlFor(String url) => Uri.parse(url).replace(path: shopRegisterPath).toString();

/// Adresse à charger pour ouvrir la caisse : l'adresse enregistrée, sauf si c'est la route de démarrage et que [memory]
/// dit qu'elle manque sur cette origine (alors `/caisse` directement).
String startUrlFor(String shopUrl, StartRouteMemory? memory, DateTime now) {
  if (shopUrl.isEmpty || !isStartRoute(shopUrl)) return shopUrl;
  return memory != null && memory.appliesTo(shopUrl, now) ? registerUrlFor(shopUrl) : shopUrl;
}

/// Après une réponse HTTP en erreur : adresse de repli à charger, ou null (rien à faire). Seulement pour le cadre
/// principal, la route de démarrage de l'origine enregistrée, un 404 ou un 405, et une seule tentative par chargement.
String? fallbackUrlFor({
  required String shopUrl,
  required String? failedUrl,
  required int? statusCode,
  required bool isMainFrame,
  required bool alreadyTried,
}) {
  if (!isMainFrame || alreadyTried || failedUrl == null || (statusCode != 404 && statusCode != 405)) return null;
  final origin = originOf(shopUrl);
  if (origin == null || originOf(failedUrl) != origin || !isStartRoute(failedUrl)) return null;
  return registerUrlFor(failedUrl);
}
