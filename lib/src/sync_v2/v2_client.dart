import 'dart:math';

import 'canonical_json.dart';
import 'contract_schemas.dart';
import 'schema_validator.dart';
import 'v2_transport.dart';

/// Conduite à tenir après une erreur de requête entière (contrat-v2/README.md §8).
enum V2FailureKind {
  /// 401 : appareil non reconnu ou révoqué — plus de nouvelle vente locale ; la file est conservée.
  unauthorized,

  /// 403 `politique_refusee` : motif métier, jamais de reprise rapide.
  policy,

  /// 410 `curseur_expire` / `instantane_expire` : nouvel instantané, sans effacer les opérations locales.
  expired,

  /// 413 : couper le lot.
  tooLarge,

  /// 422 : requête mal formée — défaut du client, pas une donnée à réessayer telle quelle.
  invalid,

  /// 426 : protocole non pris en charge — mise à jour du client ; la file reste en place.
  protocol,

  /// 429 : attendre [V2Failure.retryAfter] (avec aléa).
  throttled,

  /// 5xx, délai, corps tronqué ou réponse non conforme au contrat : résultat INCONNU, reprise bornée.
  unavailable,
}

class V2Failure implements Exception {
  const V2Failure(this.kind, this.code, this.message, {this.status = 0, this.retryAfter, this.details});

  final V2FailureKind kind;

  /// `erreur.code` du serveur, ou un code local (`reseau`, `reponse_non_conforme`).
  final String code;
  final String message;
  final int status;
  final Duration? retryAfter;
  final Object? details;

  /// Vrai quand le serveur a pu traiter la requête sans que le client en connaisse le résultat.
  bool get outcomeUnknown => kind == V2FailureKind.unavailable;

  @override
  String toString() => 'V2Failure($code, $status) $message';
}

/// Identité rendue par l'appairage v2 ; le jeton se range dans le coffre de la plateforme.
class V2Pairing {
  const V2Pairing({required this.token, required this.epoch, required this.device, required this.capabilities, this.webKey});

  final String token;

  /// Clé web de l'appareil (révision 2.0.2, B-REQ-006), à poser en cookie `sk_appareil` ; absente d'un serveur 2.0.1.
  final String? webKey;
  final int epoch;

  /// `appareil` tel que rendu (uuid, nom, terminal_uuid, terminal_nom, boutique_uuid, boutique_nom, derniere_sequence).
  final Map<String, dynamic> device;
  final List<String> capabilities;

  String get deviceUuid => device['uuid'] as String;
  String get terminalUuid => device['terminal_uuid'] as String;
  int get lastSequence => device['derniere_sequence'] as int;
}

/// Client de l'API `/api/caisse/v2`, révision 2.0.2 : en-têtes obligatoires, erreurs typées, réponses validées contre
/// les schémas embarqués (une réponse non conforme n'est jamais appliquée : elle vaut « résultat inconnu »).
class CaisseV2Client {
  CaisseV2Client({
    required this.apiBase,
    required this.transport,
    required this.appVersion,
    required this.localSchema,
    this.capabilities = defaultCapabilities,
    SchemaValidator? validator,
  }) : validator = validator ?? SchemaValidator((file) => contractV2Schemas[file] ?? (throw SchemaProfileError('Schéma inconnu : $file')));

  static const protocol = 2;

  /// Capacités de ce client en révision 2.0 (README §2). `vente.paiement_declare` s'y ajoute seulement quand le moteur
  /// l'active (voir `V2Engine.declaredPayments`).
  static const defaultCapabilities = ['vente.especes', 'stock.couverture', 'instantane.v1'];

  /// Moyens « paiement externe déclaré » (03 `paiements.externe_declare`) : référence saisie, jamais une confirmation.
  static const declaredPaymentCapability = 'vente.paiement_declare';

  /// Formes 2.1 des données (REVISION-2.1 §7.1) : rendues seulement si le client l'annonce ET que le serveur la rend.
  static const contract21Capability = 'contrat.2_1';

  /// Clients publiés et création hors ligne (2.1, lot 2).
  static const customerReadCapability = 'client.lecture';
  static const customerCreateCapability = 'client.creation';

  /// Clôture de session hors ligne (2.1, lot 3).
  static const sessionCloseCapability = 'session.cloture';

  /// Paniers partagés (2.1, lot 4).
  static const sharedCartCapability = 'panier.partage';

  /// Retours limités en espèces (2.1, lot 5).
  static const returnCapability = 'retour.especes';

  /// Vente des produits à lots (2.1 lot 6).
  static const lotsCapability = 'lots.vente';

  /// Modèles de ticket (2.1 lot 7) : types `modele_ticket` et `ticket_terminal`.
  static const ticketModelsCapability = 'ticket.modeles';

  /// Passes événement (2.1 lot 8) : types `pass_reglages`, `pass_evenement`, `pass`, `POST /passes/verifier`,
  /// `vente.passages[]`, droit `pass_encaisser`.
  static const passesCapability = 'passes.evenement';

  /// Restaurant hors connexion (révision restaurant-1, lots R-1 et R-2) : caisse maîtresse, salles, tables, menus,
  /// `resto_commande` et vente avec `commande`. Accordée seulement avec `contrat.2_1` et `session.cloture`.
  static const restaurantCapability = 'restaurant.v1';

  /// Lot « Z local » (README §12) : types `z.session` et `z.journee`, `cloture_session.contenu.detail`, opérations
  /// `edition_pre_x` et `edition_pre_z`. Accordée seulement avec `contrat.2_1`.
  static const zLocalCapability = 'z.local';

  /// Prix modifiable à la vente (2.1 lot 9) : `produit.prix_modifiable`, droit `prix_vente_modifier`, prix saisi rejoué
  /// en `prix_vente_modifie`. Accordée seulement avec `contrat.2_1`.
  static const editablePriceCapability = 'prix.modifiable';

  /// Catalogue hors connexion (2.1 lot 10) : opérations `creation_produit` et `modification_produit`, droits
  /// `produits_creer` et `produits_modifier`. Chacune accordée seulement avec `contrat.2_1`.
  static const productCreateCapability = 'produit.creation';
  static const productEditCapability = 'produit.modification';

  /// Modifier un ticket après encaissement (2.1 lot 11) : opération critique `vente_modification`, option
  /// `boutique.regles.modification_ticket`, `operateur.approbateur_modification`. Accordée seulement avec `contrat.2_1`.
  static const saleEditCapability = 'vente.modification';

  /// Sessions locales séparées (2.1 lot 12) : ouverture malgré une clôture à arbitrer, plafond
  /// `boutique.regles.sessions_locales`, opération `cloture_journee`. Accordée seulement avec `contrat.2_1`.
  static const multipleSessionsCapability = 'session.multiple';

  /// Bornes du contrat pour `POST /operations`.
  static const maxBatch = 50;
  static const maxBodyBytes = 524288;
  static const maxStateUuids = 200;

  /// `https://boutique/api/caisse/v2`.
  final String apiBase;
  final V2Transport transport;
  final String appVersion;
  final int localSchema;
  final List<String> capabilities;
  final SchemaValidator validator;

  String? token;

  Map<String, String> get _headers => {
    if (token != null) 'Authorization': 'Bearer $token',
    'X-Caisse-Protocole': '$protocol',
    'X-Caisse-Application': appVersion.isEmpty ? 'inconnue' : appVersion,
    'X-Caisse-Schema-Local': '$localSchema',
  };

  Future<V2Pairing> pair({required String code, required String installationUuid, required String platform, String? model}) async {
    final body = {
      'code': code.trim(),
      'installation_uuid': installationUuid,
      'plateforme': platform,
      'modele': model,
      'version_application': appVersion.isEmpty ? 'inconnue' : appVersion,
      'schema_local': '$localSchema',
      'capacites': capabilities,
    };
    _requireValid(body, 'appairage.json#/\$defs/demande');
    final json = await _call('POST', '/appairage', body: body, schema: 'appairage.json#/\$defs/reponse', withAuth: false) as Map;
    final pairing = V2Pairing(
      token: json['jeton'] as String,
      epoch: json['epoque'] as int,
      device: Map<String, dynamic>.from(json['appareil'] as Map),
      capabilities: List<String>.from(json['capacites_serveur'] as List),
      webKey: json['cle_web'] as String?,
    );
    token = pairing.token;
    return pairing;
  }

  Future<Map<String, dynamic>> state() async => Map<String, dynamic>.from(
    await _call('GET', '/etat', headers: {'X-Caisse-Capacites': capabilities.join(',')}, schema: 'etat.json', timeout: const Duration(seconds: 8)) as Map,
  );

  Future<Map<String, dynamic>> createSnapshot(String reason) async =>
      Map<String, dynamic>.from(await _call('POST', '/instantanes', body: {'raison': reason}, schema: 'instantanes.json#/\$defs/manifeste') as Map);

  /// Page d'instantané, empreinte vérifiée (SHA-256 SK-JCS-1 du tableau `entites`) contre celle du manifeste.
  Future<List<Map<String, dynamic>>> snapshotPage(String uuid, int page, String expectedFingerprint) async {
    final json = await _call('GET', '/instantanes/$uuid/pages/$page', schema: 'instantanes.json#/\$defs/page') as Map;
    final entities = json['entites'] as List;
    final fingerprint = CanonicalJson.sha256Of(entities);
    if (json['instantane_uuid'] != uuid || json['page'] != page || json['empreinte'] != expectedFingerprint || fingerprint != expectedFingerprint) {
      throw V2Failure(V2FailureKind.unavailable, 'empreinte_page', 'Page $page de l’instantané altérée ou incomplète : préparation à refaire.');
    }
    return [for (final e in entities) Map<String, dynamic>.from(e as Map)];
  }

  Future<Map<String, dynamic>> changes(String cursor, {int limit = 200}) async => Map<String, dynamic>.from(
    await _call('GET', '/changements?curseur=${Uri.encodeQueryComponent(cursor)}&limite=$limit', schema: 'changements.json#/\$defs/page') as Map,
  );

  /// Résultats individuels, dans l'ordre envoyé ; chaque UUID envoyé doit y figurer une fois.
  Future<List<Map<String, dynamic>>> submit(List<Map<String, dynamic>> operations) async {
    final json = await _call('POST', '/operations', body: {'operations': operations}, schema: 'operations.json#/\$defs/reponse') as Map;
    final results = [for (final r in json['resultats'] as List) Map<String, dynamic>.from(r as Map)];
    final sent = [for (final o in operations) o['uuid']];
    if (results.length != sent.length || {for (final r in results) r['uuid']}.difference(sent.toSet()).isNotEmpty) {
      throw const V2Failure(V2FailureKind.unavailable, 'reponse_non_conforme', 'Résultats du lot incomplets : état à vérifier.');
    }
    return results;
  }

  Future<List<Map<String, dynamic>>> operationStates(List<String> uuids) async {
    final json = await _call('POST', '/operations/etats', body: {'uuids': uuids}, schema: 'operations.json#/\$defs/reponse_etats') as Map;
    return [for (final r in json['etats'] as List) Map<String, dynamic>.from(r as Map)];
  }

  Future<void> acknowledge(Map<String, dynamic> body) async {
    _requireValid(body, 'accuses.json#/\$defs/demande');
    await _call('POST', '/accuses', body: body);
  }

  void _requireValid(Object? data, String schema) {
    final errors = validator.validate(data, schema);
    if (errors.isNotEmpty) throw V2Failure(V2FailureKind.invalid, 'requete_non_conforme', 'Requête non conforme au contrat v2 : ${errors.first}');
  }

  /// Image d'un produit (`GET /images/{uuid}`, révision 2.1) ; réponse brute, l'appelant gère 404 et 429.
  Future<V2Response> image(String uuid) => transport.fetchBytes(apiBase, '/images/$uuid', headers: _headers);

  Future<Object?> _call(
    String method,
    String path, {
    Object? body,
    String? schema,
    Map<String, String> headers = const {},
    bool withAuth = true,
    Duration? timeout,
  }) async {
    final response = await transport.send(method, apiBase, path, headers: {if (withAuth) ..._headers, ...headers}, body: body, timeout: timeout);
    if (response.status == 0) {
      throw const V2Failure(V2FailureKind.unavailable, 'reseau', 'Boutique injoignable ou réponse interrompue : résultat inconnu.');
    }
    if (!response.ok) throw _failure(response);
    if (schema != null) {
      final errors = validator.validate(response.body, schema);
      if (errors.isNotEmpty) {
        throw V2Failure(V2FailureKind.unavailable, 'reponse_non_conforme', 'Réponse du serveur non conforme au contrat v2 : ${errors.first}',
            status: response.status, details: errors.take(5).toList());
      }
    }
    return response.body;
  }

  /// Vérification d'un pass avant passage (passes.json) : verdict sans réservation. Seul envoi du code en clair.
  Future<Map<String, dynamic>> verifyPass(Map<String, dynamic> request) async {
    _requireValid(request, 'passes.json#/\$defs/demande');
    return Map<String, dynamic>.from(
      await _call('POST', '/passes/verifier', body: request, schema: 'passes.json#/\$defs/reponse', timeout: const Duration(seconds: 10)) as Map,
    );
  }

  /// Reprise exclusive d'un panier partagé, ou renouvellement par son détenteur.
  Future<Map<String, dynamic>> takeCart(String uuid, String operatorId) async => Map<String, dynamic>.from(
    await _call('POST', '/paniers/$uuid/reprise', body: {'operateur_id': operatorId}, schema: 'paniers.json#/\$defs/reprise') as Map,
  );

  Future<void> releaseCart(String uuid, String operatorId) async {
    await _call('POST', '/paniers/$uuid/liberation', body: {'operateur_id': operatorId});
  }

  V2Failure _failure(V2Response response) {
    final error = response.body is Map ? (response.body as Map)['erreur'] : null;
    final code = error is Map && error['code'] is String ? error['code'] as String : 'http_${response.status}';
    final message = error is Map && error['message'] is String ? error['message'] as String : 'Réponse inattendue du serveur (${response.status}).';
    final seconds = response.retryAfter ?? (error is Map ? error['reessayer_apres_secondes'] as int? : null);
    final kind = switch (response.status) {
      401 => V2FailureKind.unauthorized,
      403 => V2FailureKind.policy,
      410 => V2FailureKind.expired,
      413 => V2FailureKind.tooLarge,
      422 || 404 => V2FailureKind.invalid,
      426 => V2FailureKind.protocol,
      429 => V2FailureKind.throttled,
      _ => V2FailureKind.unavailable,
    };
    return V2Failure(kind, code, message, status: response.status, retryAfter: seconds == null ? null : Duration(seconds: seconds),
        details: error is Map ? error['details'] : null);
  }

  /// Délai de reprise avec aléa (429, 5xx), borné par `delais.reprise_max_secondes`.
  static Duration backoff(int attempt, {Duration? retryAfter, int maxSeconds = 60, Random? random}) {
    final base = retryAfter?.inSeconds ?? min(maxSeconds, 2 << min(attempt, 5));
    final jitter = (random ?? Random()).nextInt(max(1, base ~/ 2) + 1);
    return Duration(seconds: min(maxSeconds, base) + jitter);
  }
}
