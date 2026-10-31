import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../offline/money.dart';
import '../offline/web_rules.dart';

import '../offline/api.dart';
import '../offline/engine.dart';
import '../offline/models.dart';
import '../offline/store.dart';
import 'contract_schemas.dart';
import 'schema_validator.dart';
import 'decimal6.dart';
import 'v2_client.dart';
import 'v2_sale.dart';
import 'v2_store.dart';
import 'v2_sync.dart';
import 'v2_transport.dart';

/// Caisse locale du terminal sur le protocole v2 (décision du 2026-10-29 : clients v2 seulement).
///
/// Même interface que la caisse v1 pour les écrans Android et l'hôte Windows : le catalogue de la projection v2 est
/// présenté en [Snapshot] (produits et conditionnements désignés par des identifiants entiers locaux, stables), les
/// opérations figées en [OfflineOperation]. Ventes construites et figées par [V2SaleBuilder], file et couverture du
/// stock par [V2Store], échanges par [V2Sync].
///
/// - Autorisation bornée du serveur (`/etat`) : refusée ou expirée, aucune nouvelle vente ; la file reste transmissible.
/// - Politiques effectives reçues du serveur, sans héritage local ; une politique absente vaut restriction.
/// - Paiement unique en espèces (capacité `vente.especes`) ; TVA figée depuis l'entité `boutique`.
/// - Session : celle du terminal (`session:<uuid du terminal>`), ou l'ouverture locale tant que le serveur ne l'a pas
///   intégrée ; une vente porte l'UUID de cette session.
class V2Engine extends CaisseEngine {
  V2Engine({
    required super.store,
    required this.v2,
    required this.transport,
    required this.appVersion,
    required this.platform,
    this.legacyTransport,
    super.clock,
    String Function()? newUuid,
    super.pinVerifier,
    this.declaredPayments = false,
    this.contract21 = false,
    this.imageDirectory,
  }) : _newUuid = newUuid ?? (() => const Uuid().v4());

  /// Dossier du cache d'images (fichiers nommés par empreinte) ; null : aucune image téléchargée.
  final String? imageDirectory;

  /// Annonce `contrat.2_1` : formes 2.1 des données (catégories ordonnées, marque, fournisseur, unité, plafonds de
  /// remise par opérateur, référence de paiement selon le moyen). Sans effet si le serveur ne la rend pas.
  final bool contract21;

  /// Annonce `vente.paiement_declare` : les moyens déclarés (mobile money…) publiés pour la vente locale deviennent
  /// utilisables hors connexion comme les espèces, SI le serveur rend aussi cette capacité (ouverte par A le 29/10,
  /// lot 0 de la 2.1). Activé par Android et l'hôte Windows.
  final bool declaredPayments;

  /// Transport v1, pour vider seulement la file d'une installation 1.1.5 mise à jour (routes v1 gardées par le
  /// serveur) ; aucune nouvelle opération v1. Null : pas d'ancienne file (Windows).
  final RegisterTransport? legacyTransport;

  /// Opérations v1 encore en attente (installation antérieure), comptées dans [pendingCount].
  int legacyPending = 0;

  final V2Store v2;
  final V2Transport transport;
  final String appVersion;

  /// `android` ou `windows` (appairage.json).
  final String platform;
  final String Function() _newUuid;

  CaisseV2Client? _client;
  V2Sync? _sync;
  String? _token;
  bool _syncing = false;
  Map<String, dynamic>? _state;
  Map<String, dynamic> _device = const {};
  String? _blocked;

  // Projection présentée : correspondances entiers ↔ UUID, données brutes pour figer la vente.
  Map<String, Map<String, dynamic>> _products = const {};
  Map<String, Map<String, dynamic>> _packagings = const {};
  Map<String, String> _revisions = const {};
  Map<String, int> _ids = const {};
  Map<int, String> _productUuids = const {};
  Map<int, String> _packagingUuids = const {};
  Map<int, List<String>> _rights = const {};

  /// Plafonds de remise du rôle (contrat 2.1) : pourcentage en millionièmes, montant par vente ; null = sans limite.
  Map<int, (BigInt?, int?)> _discountCaps = const {};
  String? _sessionUuid;
  V2Vat? _vat;

  /// Moteur sur la base du terminal (tables v2 du schéma 4), schémas du contrat embarqués.
  factory V2Engine.onStore(
    SqfliteOfflineStore store, {
    required V2Transport transport,
    required String appVersion,
    required String platform,
    RegisterTransport? legacyTransport,
    DateTime Function()? clock,
    String Function()? newUuid,
    Future<bool> Function(String pin, String hash)? pinVerifier,
    bool declaredPayments = false,
    bool contract21 = false,
    String? imageDirectory,
  }) => V2Engine(
    store: store,
    v2: V2Store(store.database, SchemaValidator((file) => contractV2Schemas[file] ?? (throw SchemaProfileError('Schéma inconnu : $file')))),
    transport: transport,
    appVersion: appVersion,
    platform: platform,
    legacyTransport: legacyTransport,
    clock: clock,
    newUuid: newUuid,
    pinVerifier: pinVerifier,
    declaredPayments: declaredPayments,
    contract21: contract21,
    imageDirectory: imageDirectory,
  );

  static String apiBaseFor(String origin) => '$origin/api/caisse/v2';

  @override
  bool get paired => _token != null;

  /// Terminal autorisé par le serveur à vendre localement : la caisse locale est la caisse principale.
  @override
  bool get permanentLocal => paired && _authorization?['vente_locale'] == true;

  @override
  bool get syncing => _syncing;

  @override
  bool get sessionOpen => snapshot?.sessionOpen ?? false;

  Map<String, dynamic>? get _authorization => (_state?['autorisation'] as Map?)?.cast<String, dynamic>();

  @override
  Future<String?> storedOrigin() => v2.read(V2Keys.origin);

  @override
  Future<void> load(String origin) async {
    final stored = await v2.read(V2Keys.origin);
    final queued = pendingCount > 0 || await _unsentCount() > 0;
    shopMismatch = stored != null && stored != origin && queued;
    final effective = shopMismatch ? stored! : origin;
    if (stored != null && stored != origin && !queued) {
      // Boutique changée, file vide : l'ancien appairage ne vaut plus (la projection est remplacée au prochain).
      await v2.write(V2Keys.token, null);
    }
    apiBase = apiBaseFor(effective);
    _client = CaisseV2Client(
      apiBase: apiBase!,
      transport: transport,
      appVersion: appVersion,
      localSchema: offlineSchemaVersion,
      capabilities: [
        ...CaisseV2Client.defaultCapabilities,
        if (declaredPayments) CaisseV2Client.declaredPaymentCapability,
        if (contract21) ...[
          CaisseV2Client.contract21Capability,
          CaisseV2Client.customerReadCapability,
          CaisseV2Client.customerCreateCapability,
          CaisseV2Client.sessionCloseCapability,
          CaisseV2Client.sharedCartCapability,
        ],
      ],
    );
    _sync = V2Sync(_client!, v2);
    _token = await v2.read(V2Keys.token);
    _client!.token = _token;
    revoked = _token == null && await v2.read(V2Keys.revoked) != null;
    // Clé web d'un appairage v1 antérieur : garde l'accès à la caisse web d'un terminal réservé à l'application.
    webToken = await store.read(StoreKeys.webToken);
    lastContact = DateTime.tryParse(await v2.read(V2Keys.lastContact) ?? '');
    snapshotAt = DateTime.tryParse(await v2.read(V2Keys.snapshotAt) ?? '');
    final state = await v2.read(V2Keys.serverState);
    _state = state == null ? null : Map<String, dynamic>.from(jsonDecode(state) as Map);
    await _rebuild();
    await _count();
    notifyListeners();
  }

  @override
  Future<String?> pair(String code, {required String model, required String appVersion}) async {
    final sync = _sync;
    if (sync == null) return 'Adresse de la boutique absente.';
    if (shopMismatch) {
      return 'Des ventes locales attendent encore l’ancienne boutique : reconnectez-la pour les envoyer avant d’appairer celle-ci.';
    }
    try {
      final pairing = await sync.pair(code, platform: platform, model: model, newUuid: _newUuid);
      // Clé web rendue une seule fois (2.0.2) : même rangement que celle de la v1, lue par la vue web de la caisse.
      webToken = pairing.webKey;
      await store.write(StoreKeys.webToken, webToken);
    } on V2Failure catch (e) {
      return e.code == 'reseau' ? 'Boutique injoignable : l’appairage exige une connexion.' : e.message;
    }
    _token = await v2.read(V2Keys.token);
    revoked = false;
    await v2.write(V2Keys.origin, apiBase!.substring(0, apiBase!.length - apiBaseFor('').length));
    await _contact();
    final error = await refreshSnapshot();
    notifyListeners();
    return error;
  }

  @override
  Future<void> unpair() async {
    _token = null;
    _client?.token = null;
    await v2.write(V2Keys.token, null);
    snapshot = null;
    notifyListeners();
  }

  @override
  Future<bool> probe() async {
    final client = _client;
    if (client == null || !paired) return false;
    var ok = false;
    try {
      _state = await client.state();
      await v2.write(V2Keys.serverState, jsonEncode(_state));
      await _contact();
      ok = true;
      lastUnreachable = false;
    } on V2Failure catch (e) {
      await _failed(e);
    }
    if (reachable != ok) {
      reachable = ok;
      notifyListeners();
    }
    return ok;
  }

  @override
  Future<String?> refreshSnapshot() async {
    if (!paired) return 'Application non appairée.';
    final report = await sync();
    return report.message;
  }

  @override
  Future<SyncReport> sync() async {
    final engine = _sync;
    if (engine == null || !paired || _syncing) return const SyncReport(reachable: false);
    _syncing = true;
    notifyListeners();
    try {
      await _drainLegacy();
      final report = await engine.run();
      final failure = report.failure;
      if (failure == null && _heldCart != null) {
        await _client!.takeCart(_heldCart!.$1, '${_heldCart!.$2}').then<void>((_) {}, onError: (Object _) => _heldCart = null);
      }
      if (failure != null) {
        await _failed(failure);
      } else {
        lastUnreachable = false;
        reachable = true;
        await _contact();
        snapshotAt = now;
        await v2.write(V2Keys.snapshotAt, snapshotAt!.toUtc().toIso8601String());
      }
      final state = await v2.read(V2Keys.serverState);
      if (state != null) _state = Map<String, dynamic>.from(jsonDecode(state) as Map);
      await _rebuild();
      return SyncReport(
        sent: report.sent,
        integrated: report.integrated,
        pending: report.arbitration,
        refused: report.rejected,
        reachable: failure == null || failure.code != 'reseau',
        message: failure?.message ?? (report.blockedBy == null ? null : V2Incompatible(report.blockedBy!).toString()),
      );
    } finally {
      _syncing = false;
      await _count();
      if (pendingCount == 0) offlineSince = null;
      notifyListeners();
    }
  }

  /// Envoie la file v1 laissée par une installation antérieure, avec son propre appairage v1 (jeton conservé), sans
  /// rien y ajouter. Sans appairage v1 valide, la file reste sur le terminal et reste comptée.
  Future<void> _drainLegacy() async {
    final transport = legacyTransport;
    if (transport == null || (await store.counts()).pending == 0) return;
    final origin = await OfflineEngine(store: store, transport: transport).storedOrigin();
    if (origin == null) return;
    final legacy = OfflineEngine(store: store, transport: transport);
    await legacy.load(origin);
    if (legacy.paired) await legacy.sync();
  }

  Future<void> _failed(V2Failure failure) async {
    lastUnreachable = failure.code == 'reseau';
    reachable = false;
    if (lastUnreachable) offlineSince ??= now;
    if (failure.kind == V2FailureKind.unauthorized) {
      revoked = true;
      _token = null;
      _client?.token = null;
      await v2.write(V2Keys.token, null);
      await v2.write(V2Keys.revoked, failure.code);
    }
  }

  @override
  String? get blockReason {
    final s = snapshot;
    if (!paired) {
      return revoked
          ? 'Application révoquée par la boutique : appairez-la de nouveau (Réglages).'
          : 'Application non appairée à un terminal (Réglages › Caisse hors ligne).';
    }
    if (shopMismatch) return 'Ventes en attente pour l’ancienne boutique ($apiBase) : elles doivent être envoyées avant de vendre ici.';
    if (_blocked != null) return 'Donnée du serveur non prise en charge (« $_blocked ») : mettez l’application à jour.';
    if (s == null) return 'Aucun catalogue reçu : connectez le terminal une première fois.';
    final authorization = _authorization;
    if (authorization == null || authorization['vente_locale'] != true) {
      final reason = (authorization?['raison'] as Map?)?['message'] as String?;
      return 'La vente locale n’est pas autorisée sur ce terminal${reason == null ? '' : ' : $reason'}.';
    }
    final expires = DateTime.tryParse('${authorization['expire_le'] ?? ''}');
    if (expires != null && now.isAfter(expires)) return 'Autorisation de vente locale expirée : reconnectez le terminal.';
    if (_vat == null) return 'TVA de la boutique non reçue : le serveur doit être mis à jour (contrat 2.0.1).';
    if (s.methods.isEmpty) return 'Aucun moyen de paiement autorisé localement.';
    final contact = lastContact ?? snapshotAt;
    if (contact != null && now.difference(contact) > Duration(hours: s.rules.maxHours)) {
      return 'Durée hors ligne dépassée (${s.rules.maxHours} h depuis le dernier contact) : reconnectez le terminal.';
    }
    if (pendingSales >= s.rules.maxSales) return 'Nombre maximal de ventes non transmises atteint (${s.rules.maxSales}) : reconnectez le terminal.';
    return null;
  }

  Snapshot _requireSelling({bool allowWithoutSession = false}) {
    final reason = blockReason;
    if (reason != null) throw OfflineRefusal(reason);
    if (!allowWithoutSession && !sessionOpen) throw const OfflineRefusal('Aucune session de caisse ouverte sur ce terminal : ouvrez-la d’abord.');
    return snapshot!;
  }

  void _requireRight(Operator operator, String right, String label) {
    if (!hasRight(operator, right)) throw OfflineRefusal('${operator.name} n’a pas le droit de $label.');
  }

  /// Droits publiés par le serveur pour l'opérateur (`vente`, `ouverture_session`, `remise`) ; absent = refusé.
  @override
  bool hasRight(Operator operator, String right) => (_rights[operator.id] ?? const []).contains(right);

  @override
  int maxLineDiscountFor(Operator operator, int base) => _withRoleCap(operator, base, super.maxLineDiscountFor(operator, base));

  @override
  int maxGlobalDiscountFor(Operator operator, int subtotal) => _withRoleCap(operator, subtotal, super.maxGlobalDiscountFor(operator, subtotal));

  /// Plafond du rôle (`remise_max_pourcent`) appliqué en plus de celui de la boutique : le plus petit des deux.
  int _withRoleCap(Operator operator, int base, int shop) {
    final percent = _discountCaps[operator.id]?.$1;
    if (percent == null) return shop;
    final role = (BigInt.from(base) * percent ~/ BigInt.from(100000000)).toInt();
    return role < shop ? role : shop;
  }

  @override
  int? maxSaleDiscountFor(Operator operator) => _discountCaps[operator.id]?.$2;

  /// Montant d'une remise saisie sur [base], par la règle du web (pourcentage arrondi selon la boutique).
  int _entered(DiscountEntry entry, int base) {
    try {
      return enteredDiscount(type: entry.type, value: entry.value, base: base, rounding: percentRounding);
    } on WebRuleRefusal catch (e) {
      throw OfflineRefusal(e.message);
    }
  }

  @override
  Future<OfflineOperation> openSession(int float, Operator operator) => serialized(() async {
    final s = _requireSelling(allowWithoutSession: true);
    if (!s.rules.sessionOpening) throw const OfflineRefusal('L’ouverture de session locale n’est pas autorisée : ouvrez-la en ligne.');
    if (sessionOpen) throw const OfflineRefusal('Une session est déjà ouverte sur ce terminal.');
    if (float < 0) throw const OfflineRefusal('Fond de caisse invalide.');
    final closing = await v2.read(V2Keys.closingOperation);
    if (closing != null && (await v2.operation(closing))?['etat'] == V2OperationState.arbitration) {
      throw const OfflineRefusal('La clôture précédente attend un arbitrage de la boutique : faites-la traiter avant d’ouvrir une session.');
    }
    _requireRight(operator, 'ouverture_session', 'ouvrir une session');
    final uuid = _newUuid();
    final operation = await _record(uuid, 'ouverture_session', operator, (_) => {'fond': float});
    await v2.write(V2Keys.localSession, uuid);
    await _rebuild();
    await _afterWrite();
    return operation;
  });

  /// Règles commerciales de la boutique (forme 2.1, `boutique.regles`), ou null.
  Map<String, dynamic>? _shopRules;

  @override
  bool get saleExtrasSupported => v2.contract21 && _shopRules != null;

  @override
  String get percentRounding => (_shopRules?['remise_pourcentage_arrondi'] as String?) ?? 'down';

  /// Arrondi de caisse : appliqué seulement en vente 2.1 (le serveur ne l'applique que si la vente le déclare).
  @override
  ({int step, String mode})? get cashRounding {
    final rounding = _shopRules?['arrondi_especes'] as Map?;
    if (!v2.contract21 || rounding == null) return null;
    return (step: rounding['pas'] as int, mode: rounding['mode'] as String);
  }

  @override
  String? get deliveryRight => _shopRules?['livraison_droit'] as String?;

  /// Panier repris en ce moment (uuid, opérateur) : sa reprise de 30 minutes est renouvelée à chaque synchronisation.
  (String, int)? _heldCart;

  @override
  bool get sharedCartsSupported => saleExtrasSupported && _serverOffers(CaisseV2Client.sharedCartCapability);

  @override
  Future<List<SharedCart>> sharedCarts() async {
    if (!sharedCartsSupported) return const [];
    final me = _device['terminal_uuid'];
    final carts = <SharedCart>[];
    for (final e in (await v2.entities('panier')).entries) {
      if (!(e.value['terminaux'] as List).contains(me)) continue;
      final taken = e.value['repris_par'] as Map?;
      carts.add(SharedCart(
        uuid: e.key,
        label: e.value['libelle'] as String,
        linesCount: ((e.value['contenu'] as Map)['lignes'] as List).length,
        takenElsewhere: taken != null && taken['terminal_uuid'] != me,
        modifiedAt: e.value['modifie_le'] as String,
      ));
    }
    return carts..sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
  }

  @override
  Future<String> sharedCartState(String uuid) async {
    if ((await v2.entities('panier')).containsKey(uuid)) return 'publie';
    return (await v2.operation(uuid))?['etat'] == V2OperationState.integrated ? 'disparu' : 'local';
  }

  @override
  Future<SharedCartRef> suspendShared(Operator operator, List<CartLine> lines, SaleExtras extras, {SharedCartRef? previous, String? label}) => serialized(() async {
    if (!sharedCartsSupported) throw const OfflineRefusal('Paniers partagés non disponibles sur ce terminal.');
    if (lines.isEmpty || lines.length > 100) throw const OfflineRefusal('Entre 1 et 100 lignes par panier.');
    if ((lines.any((l) => l.discount > 0) || extras.globalDiscount > 0) && !hasRight(operator, 'remise')) {
      throw OfflineRefusal('${operator.name} n’a pas le droit d’accorder une remise : retirez-la avant de partager ce panier.');
    }
    final name = (label ?? '').trim().isEmpty ? 'Panier ${now.toIso8601String().substring(0, 16).replaceFirst('T', ' ')}' : label!.trim();
    if (name.length > 150) throw const OfflineRefusal('Nom du panier trop long (150 caractères au plus).');
    final content = {
      'lignes': [
        for (final l in lines)
          {
            'produit_uuid': _productUuids[l.product.id] ?? (throw OfflineRefusal('« ${l.product.name} » n’est plus au catalogue local.')),
            'conditionnement_uuid': l.packaging == null ? null : (_packagingUuids[l.packaging!.id] ?? (throw OfflineRefusal('Conditionnement de « ${l.label} » retiré.'))),
            'quantite': Decimal6.format(l.quantity.toInt()),
            'remise': l.discount,
          },
      ],
      'client_uuid': extras.customer?.uuid,
      'remise_globale': extras.globalDiscount,
      'livraison': extras.delivery,
      'note': extras.note,
      'tarif': 'detail',
    };
    // Sans reprise, le serveur ne retire pas l'ancien panier de lui-même : suppression explicite, avant, dans l'ordre.
    if (previous != null && !previous.claimed) {
      await _record(_newUuid(), 'panier_supprimer', operator, (_) => {'panier_uuid': previous.uuid, 'motif': 'Remplacé sur le terminal'});
    }
    final uuid = _newUuid();
    await _record(uuid, 'panier_suspendre', operator, (_) => {
      'panier_uuid': uuid,
      'libelle': name,
      'remplace_uuid': previous?.claimed == true ? previous!.uuid : null,
      'contenu': content,
    });
    if (previous?.uuid == _heldCart?.$1) _heldCart = null;
    await _afterWrite();
    return SharedCartRef(uuid);
  });

  @override
  Future<TakenCart> takeSharedCart(Operator operator, String uuid) async {
    final client = _client;
    if (client == null || !sharedCartsSupported) throw const OfflineRefusal('Paniers partagés non disponibles sur ce terminal.');
    final Map<String, dynamic> taken;
    try {
      taken = await client.takeCart(uuid, '${operator.id}');
    } on V2Failure catch (failure) {
      throw OfflineRefusal(switch (failure) {
        V2Failure(code: 'panier_deja_repris') => 'Ce panier est déjà repris sur une autre caisse.',
        V2Failure(status: 404) => 'Ce panier a été vendu ou supprimé.',
        V2Failure(kind: V2FailureKind.unavailable) => 'Reprise impossible sans réseau : ce panier est partagé.',
        _ => failure.message,
      });
    }
    final content = taken['contenu'] as Map;
    final raw = (content['lignes'] as List).cast<Map>();
    final ids = await v2.localIds([for (final l in raw) ...[l['produit_uuid'] as String, if (l['conditionnement_uuid'] != null) l['conditionnement_uuid'] as String]]);
    final lines = <CartLine>[];
    for (final l in raw) {
      final product = snapshot?.products.where((p) => p.id == ids[l['produit_uuid']]).firstOrNull;
      final packaging = l['conditionnement_uuid'] == null ? null : product?.packaging(ids[l['conditionnement_uuid']]);
      if (product == null || (l['conditionnement_uuid'] != null && packaging == null)) {
        await client.releaseCart(uuid, '${operator.id}').then<void>((_) {}, onError: (Object _) {});
        throw OfflineRefusal('Ce panier contient « ${l['libelle']} », indisponible sur ce terminal : reprenez-le en ligne.');
      }
      lines.add(CartLine(
        product: product,
        packaging: packaging,
        quantity: parseMicros(l['quantite'] as String),
        discount: l['remise'] as int,
        fixedPrice: l['prix_unitaire'] as int,
      ));
    }
    _heldCart = (uuid, operator.id);
    return TakenCart(
      ref: SharedCartRef(uuid, claimed: true),
      lines: lines,
      globalDiscount: content['remise_globale'] as int,
      delivery: content['livraison'] as int,
      note: content['note'] as String?,
      customer: content['client_uuid'] == null ? null : Customer(uuid: content['client_uuid'] as String, name: content['client_nom'] as String? ?? 'Client'),
    );
  }

  @override
  Future<void> releaseSharedCart(Operator operator, String uuid) async {
    if (_heldCart?.$1 == uuid) _heldCart = null;
    await _client?.releaseCart(uuid, '${operator.id}').then<void>((_) {}, onError: (Object _) {});
  }

  @override
  Future<void> deleteSharedCart(Operator operator, String uuid, {String reason = 'Supprimé sur le terminal'}) => serialized(() async {
    if (_heldCart?.$1 == uuid) _heldCart = null;
    await _record(_newUuid(), 'panier_supprimer', operator, (_) => {'panier_uuid': uuid, 'motif': reason});
    await _afterWrite();
  });

  @override
  bool canCloseSession(Operator operator) =>
      saleExtrasSupported && sessionOpen && _serverOffers(CaisseV2Client.sessionCloseCapability) && hasRight(operator, 'caisse_cloturer');

  /// Attendu de la session d'après les opérations du terminal, par moyen de paiement ; null si son ouverture n'y figure pas.
  Future<Map<String, int>?> _expectedCounts() async {
    final expected = <String, int>{};
    for (final row in await v2.operationRows()) {
      if (row['etat'] == V2OperationState.rejected) continue;
      final operation = row['operation'] as Map;
      final content = operation['contenu'] as Map;
      switch (operation['type']) {
        case 'vente':
          for (final p in (content['paiements'] as List).cast<Map>()) {
            final amount = (p['montant'] as int) + (p['ecart_arrondi'] as int? ?? 0);
            expected.update(p['moyen'] as String, (v) => v + amount, ifAbsent: () => amount);
          }
        case 'ouverture_session':
          final cash = (await v2.entities('moyen_paiement')).values.where((m) => m['especes'] == true).map((m) => m['code'] as String).firstOrNull ?? 'especes';
          expected.update(cash, (v) => v + (content['fond'] as int), ifAbsent: () => content['fond'] as int);
          return expected;
        case 'cloture_session':
          return null;
      }
    }
    return null;
  }

  @override
  Future<ClosingGaps> closingGaps(int cash, List<SessionCount> others) async {
    final expected = await _expectedCounts();
    if (expected == null) return const ClosingGaps();
    final cashCodes = {for (final m in snapshot?.methods ?? const <PaymentMethodInfo>[]) if (m.isCash) m.code};
    final cashExpected = expected.entries.where((e) => cashCodes.contains(e.key)).fold<int>(0, (sum, e) => sum + e.value);
    return ClosingGaps(cash: cash != cashExpected, methods: {for (final c in others) if (c.amount != (expected[c.method] ?? 0)) c.method});
  }

  @override
  Future<OfflineOperation> closeSession(Operator operator, {required int cash, String? comment, List<SessionCount> others = const [], String? operationUuid}) => serialized(() async {
    if (operationUuid != null) {
      if (!CaisseEngine.uuidPattern.hasMatch(operationUuid)) throw const OfflineRefusal('Identifiant d’opération invalide (UUID en minuscules attendu).');
      final existing = await v2.operation(operationUuid);
      if (existing != null) return _view(existing);
    }
    if (!sessionOpen || _sessionUuid == null) throw const OfflineRefusal('Aucune session de caisse ouverte sur ce terminal.');
    if (!_serverOffers(CaisseV2Client.sessionCloseCapability) || !saleExtrasSupported) throw const OfflineRefusal('Clôture non disponible sur ce terminal : clôturez en ligne.');
    _requireRight(operator, 'caisse_cloturer', 'clôturer la session');
    if (cash < 0 || others.any((c) => c.amount < 0)) throw const OfflineRefusal('Montant compté invalide.');
    final remark = comment?.trim() ?? '';
    if (remark.length > 500) throw const OfflineRefusal('Commentaire trop long (500 caractères au plus).');
    final known = {for (final m in snapshot!.methods) if (!m.isCash) m.code};
    for (final c in others) {
      if (!known.contains(c.method)) throw OfflineRefusal('Moyen « ${c.method} » non compté sur ce terminal.');
      if ((c.justification?.length ?? 0) > 500) throw const OfflineRefusal('Justification trop longue (500 caractères au plus).');
    }
    final gaps = await closingGaps(cash, others);
    if (gaps.cash && remark.isEmpty) throw const OfflineRefusal('Écart constaté : indiquez un commentaire.');
    for (final c in others) {
      if (gaps.methods.contains(c.method) && (c.justification ?? '').trim().isEmpty) throw OfflineRefusal('Écart constaté sur « ${c.method} » : indiquez une justification.');
    }
    final session = _sessionUuid!;
    final uuid = operationUuid ?? _newUuid();
    final operation = await _record(uuid, 'cloture_session', operator, (_) => {
      'session_uuid': session,
      'compte': cash,
      'comptage': others.isEmpty ? null : [for (final c in others) c.toJson()],
      'commentaire': remark.isEmpty ? null : remark,
    });
    await v2.write(V2Keys.closingOperation, uuid);
    await v2.write(V2Keys.localSession, null);
    await _rebuild();
    await _afterWrite();
    return operation;
  });

  @override
  Future<OfflineOperation?> lastClosure() async {
    final uuid = await v2.read(V2Keys.closingOperation);
    final row = uuid == null ? null : await v2.operation(uuid);
    return row == null ? null : _view(row);
  }

  bool _serverOffers(String capability) => (_state?['capacites_serveur'] as List?)?.contains(capability) ?? false;

  @override
  bool get customersSupported => saleExtrasSupported && _serverOffers(CaisseV2Client.customerReadCapability);

  @override
  bool canCreateCustomer(Operator operator) =>
      customersSupported && _serverOffers(CaisseV2Client.customerCreateCapability) && hasRight(operator, 'clients_creer');

  /// Clients publiés et créations en cours ; rechargés après chaque synchronisation.
  List<Customer>? _customers;

  /// Uuid créés sur ce terminal, encore valables après une fusion : le serveur les garde en alias, sans limite.
  Set<String> _ownCustomers = const {};

  Future<List<Customer>> _loadCustomers() async {
    if (_customers != null) return _customers!;
    final customers = [
      for (final e in (await v2.entities('client')).entries)
        if (e.value['actif'] == true && e.value['type'] != 'passage') Customer(uuid: e.key, name: e.value['nom'] as String, phone: e.value['telephone'] as String?),
    ];
    final published = {for (final c in customers) c.uuid};
    final own = <String>{};
    for (final row in await v2.operationRows()) {
      final operation = row['operation'] as Map;
      if (operation['type'] != 'creation_client' || row['etat'] == V2OperationState.rejected) continue;
      final content = operation['contenu'] as Map;
      own.add(content['client_uuid'] as String);
      // Intégrée : la fiche arrive par le journal, sous cet uuid ou sous celui de la fiche fusionnée.
      if (row['etat'] == V2OperationState.integrated || row['etat'] == V2OperationState.resolved || published.contains(content['client_uuid'])) continue;
      customers.add(Customer(uuid: content['client_uuid'] as String, name: content['nom'] as String, phone: content['telephone'] as String?, pending: true));
    }
    customers.sort((a, b) => fold(a.name).compareTo(fold(b.name)));
    _ownCustomers = own;
    return _customers = customers;
  }

  @override
  Future<List<Customer>> searchCustomers(String query, {int limit = 30}) async {
    if (!customersSupported) return const [];
    final text = fold(query.trim());
    final digits = query.replaceAll(RegExp(r'\D'), '');
    final hits = (await _loadCustomers()).where(
      (c) => text.isEmpty || fold(c.name).contains(text) || (digits.isNotEmpty && (c.phone ?? '').replaceAll(RegExp(r'\D'), '').contains(digits)),
    );
    return hits.take(limit).toList();
  }

  @override
  Future<Customer> createCustomer(Operator operator, {required String name, String? phone, String? operationUuid}) => serialized(() async {
    if (operationUuid != null) {
      if (!CaisseEngine.uuidPattern.hasMatch(operationUuid)) throw const OfflineRefusal('Identifiant d’opération invalide (UUID en minuscules attendu).');
      final existing = await v2.operation(operationUuid);
      if (existing != null) {
        final content = (existing['operation'] as Map)['contenu'] as Map;
        return Customer(uuid: content['client_uuid'] as String, name: content['nom'] as String, phone: content['telephone'] as String?, pending: true);
      }
    }
    _requireSelling(allowWithoutSession: true);
    if (!customersSupported || !_serverOffers(CaisseV2Client.customerCreateCapability)) throw const OfflineRefusal('Création de client non disponible sur ce terminal.');
    _requireRight(operator, 'clients_creer', 'créer un client');
    final nom = name.trim();
    if (nom.isEmpty || nom.length > 160) throw const OfflineRefusal('Indiquez le nom du client (160 caractères au plus).');
    final entered = phone?.trim() ?? '';
    final normalized = normalizePhone(entered);
    if (entered.isNotEmpty && (normalized == null || entered.length > 40)) throw const OfflineRefusal('Numéro de téléphone illisible.');
    if (normalized != null) {
      final same = (await _loadCustomers()).where((c) => normalizePhone(c.phone) == normalized).firstOrNull;
      if (same != null) return same;
    }
    final uuid = _newUuid();
    await _record(operationUuid ?? _newUuid(), 'creation_client', operator, (_) => {
      'client_uuid': uuid,
      'nom': nom,
      'telephone': entered.isEmpty ? null : entered,
      'type': 'particulier',
    });
    _customers = null;
    await _afterWrite();
    return Customer(uuid: uuid, name: nom, phone: entered.isEmpty ? null : entered, pending: true);
  });

  static const _imagesPerPass = 30;
  DateTime? _imagesPausedUntil;

  File _imageFile(String hash) => File(p.join(imageDirectory!, '$hash.jpg'));

  @override
  String? imagePath(ProductImage image) {
    if (imageDirectory == null) return null;
    final file = _imageFile(image.hash);
    return file.existsSync() ? file.path : null;
  }

  /// Le journal sert de manifeste : une nouvelle empreinte = nouveau fichier. S'arrête sur 429 (Retry-After respecté) ou
  /// sans réseau ; un contenu dont l'empreinte diffère n'est jamais gardé ; les fichiers qui ne servent plus sont retirés.
  @override
  Future<int> downloadImages() async {
    final directory = imageDirectory;
    final client = _client;
    final s = snapshot;
    if (directory == null || client == null || s == null || !paired) return 0;
    final paused = _imagesPausedUntil;
    if (paused != null && now.isBefore(paused)) return 0;
    Directory(directory).createSync(recursive: true);
    final wanted = {for (final x in s.products) ?x.image?.hash: ?x.image};
    var added = 0;
    for (final image in wanted.values.where((i) => !_imageFile(i.hash).existsSync()).take(_imagesPerPass)) {
      final response = await client.image(image.uuid);
      if (response.status == 429) {
        _imagesPausedUntil = now.add(Duration(seconds: response.retryAfter ?? 60));
        break;
      }
      if (response.status == 0) break;
      final bytes = response.bytes;
      if (!response.ok || bytes == null || sha256.convert(bytes).toString() != image.hash) continue;
      final temporary = File('${_imageFile(image.hash).path}.tmp');
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(_imageFile(image.hash).path);
      added++;
    }
    for (final file in Directory(directory).listSync().whereType<File>()) {
      if (p.extension(file.path) == '.jpg' && !wanted.containsKey(p.basenameWithoutExtension(file.path))) file.deleteSync();
    }
    return added;
  }

  /// Badge « Nouveau » : produit créé depuis N jours au plus (`regles.nouveau_jours`), null = désactivé.
  @override
  int? get newBadgeDays => _shopRules?['nouveau_jours'] as int?;

  @override
  Future<OfflineOperation> recordSale(
    List<CartLine> lines,
    List<CartPayment> payments,
    Operator operator, {
    String? draftUuid,
    String? operationUuid,
    SaleExtras extras = const SaleExtras(),
  }) => serialized(() async {
        if (operationUuid != null) {
          if (!CaisseEngine.uuidPattern.hasMatch(operationUuid)) throw const OfflineRefusal('Identifiant de vente invalide (UUID en minuscules attendu).');
          final existing = await v2.operation(operationUuid);
          if (existing != null) return sameSale(await _view(existing));
        }
        final s = _requireSelling();
        if (!extras.isEmpty && !saleExtrasSupported) throw const OfflineRefusal('Remise globale, livraison et note : disponibles avec le contrat 2.1.');
        if (extras.customer != null) {
          final uuid = extras.customer!.uuid;
          final known = customersSupported && ((await _loadCustomers()).any((c) => c.uuid == uuid) || _ownCustomers.contains(uuid));
          if (!known) throw OfflineRefusal('Le client « ${extras.customer!.name} » n’est plus disponible : choisissez-en un autre.');
        }
        checkSale(s, lines, payments, extras);
        _requireRight(operator, 'vente', 'vendre');
        if (lines.any((l) => l.discount > 0) || extras.globalDiscount > 0) _requireRight(operator, 'remise', 'accorder une remise');
        for (final l in lines) {
          if (l.discount > enterableLineDiscount(operator, l.base)) throw OfflineRefusal('Remise sur « ${l.label} » au-delà du plafond de ${operator.name}.');
          final entry = l.discountEntry;
          if (entry != null && _entered(entry, l.base) != l.discount) throw OfflineRefusal('Remise sur « ${l.label} » différente de sa saisie.');
        }
        final subtotal = lines.fold<int>(0, (sum, l) => sum + l.base - l.discount);
        if (extras.globalDiscount > enterableGlobalDiscount(operator, subtotal)) {
          throw OfflineRefusal('Remise globale au-delà du maximum autorisé hors ligne pour ${operator.name}.');
        }
        if (extras.globalEntry != null && _entered(extras.globalEntry!, subtotal) != extras.globalDiscount) {
          throw const OfflineRefusal('Remise globale différente de sa saisie.');
        }
        if (extras.delivery > 0 && deliveryRight != null) _requireRight(operator, deliveryRight!, 'ajouter une livraison');
        final saleCap = enterableSaleDiscount(operator);
        if (saleCap != null && lines.fold<int>(0, (sum, l) => sum + l.discount) + extras.globalDiscount > saleCap) {
          throw OfflineRefusal('Remises au-delà du plafond de ${operator.name} par vente (${formatFcfa(saleCap)}).');
        }
        // Une autorisation ne figure dans la vente que si les remises dépassent le seuil du caissier.
        final overLimit = !withinDiscountLimits(operator, lines, extras.globalDiscount);
        if (overLimit) {
          final approval = extras.approval;
          if (approval == null) throw OfflineRefusal('Remise au-delà du seuil de ${operator.name} : autorisation d’un responsable requise.');
          final approvers = approversFor(operator, lines, extras.globalDiscount);
          if (!approvers.any((o) => o.id == approval.approverId)) throw const OfflineRefusal('Ce responsable ne peut pas autoriser cette remise.');
        }
        for (final p in payments) {
          if (p.method.referenceMode == 'obligatoire' && (p.reference == null || p.reference!.trim().isEmpty)) {
            throw OfflineRefusal('Référence obligatoire pour « ${p.method.name} ».');
          }
        }
        // Moyens admis : ceux du catalogue local (politique paiements.moyens_locaux et capacités du serveur), vérifiés
        // par checkSale ; une seule ligne d'espèces (la monnaie se rend sur elle).
        if (payments.where((p) => p.method.isCash).length > 1) throw const OfflineRefusal('Une seule ligne d’espèces par vente.');
        final cart = [
          for (final l in lines)
            V2CartLine(
              productUuid: _productUuids[l.product.id] ?? (throw OfflineRefusal('« ${l.product.name} » n’est plus au catalogue local.')),
              packagingUuid: l.packaging == null ? null : (_packagingUuids[l.packaging!.id] ?? (throw OfflineRefusal('Conditionnement de « ${l.label} » retiré.'))),
              quantityMicros: l.quantity.toInt(),
              discount: l.discount,
              discountEntry: l.discountEntry,
              fixedPrice: l.fixedPrice,
            ),
        ];
        final revision21 = v2.contract21;
        final builder = V2SaleBuilder(products: _products, packagings: _packagings, revisions: _revisions, newUuid: _newUuid);
        final uuid = operationUuid ?? _newUuid();
        // Le contrat exige un UUID de brouillon ; un identifiant d'écran d'une autre forme en donne un, toujours le même
        // (le second encaissement du même panier reste refusé).
        final draft = draftUuid == null ? null : (CaisseEngine.uuidPattern.hasMatch(draftUuid) ? draftUuid : const Uuid().v5(Namespace.url.value, 'brouillon:$draftUuid'));
        final epoch = _device['epoque'];
        final operation = await _record(
          uuid,
          'vente',
          operator,
          (sequence) => builder.content(
            numberLocal: 'HL2-$epoch-${sequence.toString().padLeft(6, '0')}',
            draftUuid: draft ?? _newUuid(),
            sessionUuid: _sessionUuid!,
            cart: cart,
            payments: [
              for (final p in payments)
                V2Payment(
                  method: p.method.code,
                  amount: p.amount,
                  received: p.method.isCash ? (p.received ?? p.amount) : null,
                  reference: p.method.isCash || p.method.referenceMode == 'aucune' || p.reference == null || p.reference!.isEmpty ? null : p.reference,
                ),
            ],
            vat: _vat!,
            extras: extras,
            cashRounding: cashRounding,
            revision21: revision21,
            approval: overLimit ? extras.approval : null,
          ),
          draftUuid: draft,
          calculation: revision21 ? '2' : '1',
        );
        if (extras.sharedCart == _heldCart?.$1) _heldCart = null;
        await _afterWrite();
        return operation;
      });

  Future<OfflineOperation> _record(
    String uuid,
    String type,
    Operator operator,
    Map<String, dynamic> Function(int sequence) content, {
    String? draftUuid,
    String calculation = '1',
  }) async {
    final epoch = int.parse(await v2.read(V2Keys.epoch) ?? (throw const OfflineRefusal('Terminal non appairé.')));
    final policies = await v2.read(V2Keys.policiesVersion) ?? '0';
    final cursor = await v2.read(V2Keys.cursor);
    final createdAt = now;
    try {
      final operation = await v2.recordOperation(
        (sequence) => v2Operation(
          uuid: uuid,
          type: type,
          deviceUuid: _device['uuid'] as String,
          epoch: epoch,
          sequence: sequence,
          createdAt: createdAt,
          operatorId: '${operator.id}',
          policiesVersion: policies,
          catalogueCursor: cursor,
          content: content(sequence),
          calculation: calculation,
        ),
        draftUuid: draftUuid,
      );
      return await _view({'operation': operation, 'etat': V2OperationState.toSend, 'numero_serveur': null, 'raison': null, 'maj_le': null});
    } on V2SaleInvalid catch (e) {
      throw OfflineRefusal(e.message);
    } on V2SaleRefused catch (e) {
      throw OfflineRefusal(e.message);
    }
  }

  Future<void> _afterWrite() async {
    offlineSince ??= now;
    await _count();
    notifyListeners();
  }

  @override
  Future<OfflineOperation?> saleStatus(String operationUuid) => serialized(() async {
    final row = await v2.operation(operationUuid);
    return row == null ? null : _view(row);
  });

  @override
  Future<Map<int, BigInt>> soldSinceSnapshot() async {
    final sold = <int, BigInt>{};
    for (final e in (await v2.uncoveredStock()).entries) {
      final id = _ids[e.key.split(':').first];
      if (id != null) sold[id] = (sold[id] ?? BigInt.zero) - BigInt.from(e.value);
    }
    return sold;
  }

  @override
  Future<List<OfflineOperation>> history() async {
    final rows = await v2.operationRows();
    return [for (final r in rows.reversed) await _view(r)];
  }

  // ---------------------------------------------------------------- présentation

  /// Opération v2 vue comme une opération de la caisse locale (contenu au format des écrans et du ticket).
  Future<OfflineOperation> _view(Map<String, dynamic> row) async {
    final op = Map<String, dynamic>.from(row['operation'] as Map);
    final content = Map<String, dynamic>.from(op['contenu'] as Map);
    final state = row['etat'] as String;
    final isSale = op['type'] == 'vente';
    final ids = isSale
        ? await _idsFor([
            for (final l in (content['lignes'] as List).cast<Map>()) ...[l['produit_uuid'] as String, if (l['conditionnement_uuid'] != null) l['conditionnement_uuid'] as String],
          ])
        : const <String, int>{};
    final view = isSale
        ? {
            'lignes': [
              for (final l in (content['lignes'] as List).cast<Map>())
                {
                  'produit_id': ids[l['produit_uuid']],
                  'conditionnement_id': l['conditionnement_uuid'] == null ? null : ids[l['conditionnement_uuid']],
                  'libelle': l['libelle'],
                  'quantite': l['quantite'],
                  'prix_unitaire': l['prix_unitaire'],
                  'remise': l['remise'],
                },
            ],
            'paiements': [
              for (final p in (content['paiements'] as List).cast<Map>()) {'moyen': p['moyen'], 'montant': p['montant'], 'recu': p['recu'], 'reference': p['reference']},
            ],
            'total': (content['totaux'] as Map)['a_payer'],
            if (content['client_nom'] != null) 'client_nom': content['client_nom'],
          }
        : {...content, if (await v2.read('${V2Keys.zPrefix}${op['uuid']}') case final z?) 'z': jsonDecode(z)};
    final finalState = state == V2OperationState.integrated || state == V2OperationState.resolved;
    return OfflineOperation(
      uuid: op['uuid'] as String,
      sequence: op['sequence'] as int,
      type: op['type'] as String,
      number: isSale ? content['numero_local'] as String : null,
      date: DateTime.parse(op['cree_le'] as String).toLocal(),
      operatorId: int.tryParse('${op['operateur_id']}') ?? 0,
      content: view,
      status: V2OperationState.unsent.contains(state)
          ? OperationStatus.pending
          : (state == V2OperationState.rejected ? OperationStatus.refused : OperationStatus.sent),
      serverStatus: V2OperationState.unsent.contains(state) ? null : state,
      serverNumber: row['numero_serveur'] as String?,
      message: (row['raison'] as Map?)?['message'] as String?,
      resolvedAt: finalState ? DateTime.tryParse('${row['maj_le'] ?? ''}') : null,
    );
  }

  Future<Map<String, int>> _idsFor(List<String> uuids) async {
    if (uuids.every(_ids.containsKey)) return _ids;
    _ids = await v2.localIds(uuids);
    return _ids;
  }

  /// Catalogue présenté, reconstruit depuis la projection (après chaque synchronisation et au chargement).
  Future<void> _rebuild() async {
    _customers = null;
    _blocked = await v2.read(V2Keys.blocked);
    final device = await v2.read(V2Keys.device);
    _device = device == null ? const {} : {...Map<String, dynamic>.from(jsonDecode(device) as Map), 'epoque': int.tryParse(await v2.read(V2Keys.epoch) ?? '')};
    deviceName = device == null ? null : '${_device['nom'] ?? ''} — ${_device['terminal_nom'] ?? ''}';
    final cursor = await v2.read(V2Keys.cursor);
    if (cursor == null || device == null) {
      snapshot = null;
      return;
    }
    final products = await v2.entities('produit');
    final packagings = await v2.entities('conditionnement');
    final barcodes = await v2.entities('code_barre');
    final stock = await v2.entities('stock.projection');
    final policies = {for (final p in (await v2.entities('politique')).values) p['cle_politique'] as String: p['valeur']};
    final ids = await v2.localIds([...products.keys, ...packagings.keys]);
    _vat = await v2.shopVat();
    final shop = (await v2.entities('boutique'))[_device['boutique_uuid']];
    _shopRules = (shop?['regles'] as Map?)?.cast<String, dynamic>();
    final categories = await v2.entities('categorie');
    String? categoryOf(Map<String, dynamic> product) {
      final category = categories[product['categorie_uuid']];
      return category != null && category['actif'] == true ? category['nom'] as String : product['categorie'] as String?;
    }

    final orderedCategories = categories.values.where((c) => c['actif'] == true).toList()
      ..sort((a, b) => (a['ordre'] as int).compareTo(b['ordre'] as int));
    final localMethods = (policies['paiements.moyens_locaux'] as List?)?.cast<String>() ?? const <String>[];
    // Espèces, et moyens déclarés quand les deux côtés ont la capacité ; toujours dans la politique de la boutique.
    final declared = declaredPayments && ((_state?['capacites_serveur'] as List?)?.contains(CaisseV2Client.declaredPaymentCapability) ?? false);
    final methods = [
      for (final m in (await v2.entities('moyen_paiement')).values)
        if (m['local'] == true && (m['especes'] == true || declared) && localMethods.contains(m['code']))
          {'code': m['code'], 'nom': m['nom'], 'especes': m['especes'] == true, 'reference': m['reference']},
    ];
    final rights = <int, List<String>>{};
    final caps = <int, (BigInt?, int?)>{};
    final operators = <Map<String, dynamic>>[];
    for (final o in (await v2.entities('operateur')).values) {
      final id = int.tryParse('${o['operateur_id']}');
      if (id == null) continue;
      rights[id] = (o['droits'] as List).cast<String>();
      if (o['remise_max_pourcent'] != null || o['remise_max_montant'] != null) {
        caps[id] = (o['remise_max_pourcent'] == null ? null : parseMicros(o['remise_max_pourcent'] as String), o['remise_max_montant'] as int?);
      }
      if (rights[id]!.contains('vente')) {
        operators.add({'id': id, 'nom': o['nom'], 'pin': o['pin_empreinte'], 'approbateur': o['approbateur_remise'], 'code_autorisation': o['code_autorisation_empreinte']});
      }
    }
    final session = await _ownSession();
    final changesSeconds = ((_state?['delais'] as Map?)?['changements_secondes'] as int?) ?? 60;
    final raw = <String, dynamic>{
      'disponible': true,
      'boutique': {'nom': shop?['nom'] ?? _device['boutique_nom'] ?? '', 'devise': shop?['devise'] ?? 'FCFA', 'tva_taux': _vat?.rate ?? '0', 'tva_incluse': _vat?.included ?? true},
      'terminal': {'id': 0, 'nom': _device['terminal_nom'] ?? '', 'prefixe_tickets': 'HL2-${_device['epoque']}'},
      'reglages': {
        'duree_max_heures': policies['autonomie.duree_max_heures'] ?? 72,
        'ventes_max': policies['autonomie.ventes_max_non_recues'] ?? 500,
        'montant_max_vente': policies['autonomie.montant_max_vente'],
        'remise_ligne_max_pourcent': policies['remises.ligne_max_pourcent'] ?? 0,
        'remise_globale_max_pourcent': policies['remises.globale_max_pourcent'] ?? 0,
        'ouverture_session': policies['session.ouverture_locale'] == true,
        'mode_caissier': policies['droits.identification'] ?? 'pin',
        'rafraichissement_minutes': (changesSeconds / 60).ceil().clamp(1, 60),
        'vente_locale_permanente': _authorization?['vente_locale'] == true,
      },
      'session': session,
      'genere_le': snapshotAt?.toUtc().toIso8601String(),
      'empreinte': cursor,
      'moyens': methods,
      'caissiers': operators,
      'categories': [for (final c in orderedCategories) c['nom']],
      'produits': [
        for (final e in products.entries)
          if (e.value['actif'] == true && e.value['vente_locale'] == true)
            {
              'id': ids[e.key],
              'nom': e.value['nom'],
              'reference': e.value['reference'],
              'categorie': categoryOf(e.value),
              'marque': e.value['marque'],
              'fournisseur': e.value['fournisseur'],
              'unite': (e.value['unite'] as Map?)?['nom'],
              'favori': e.value['favori'] == true,
              'promotions': e.value['promotions'],
              'image': e.value['image'],
              'cree_le': e.value['cree_le'],
              'seuil_alerte': e.value['seuil_alerte'],
              'prix': e.value['prix'],
              'stock_illimite': e.value['stock_illimite'],
              'stock': (stock[e.key]?['quantite'] as String?) ?? '0',
              'conditionnements': [
                for (final k in packagings.entries)
                  if (k.value['produit_uuid'] == e.key && k.value['actif'] == true)
                    {'id': ids[k.key], 'nom': k.value['nom'], 'coefficient': k.value['coefficient'], 'prix': k.value['prix'], 'defaut': k.value['defaut']},
              ],
              'codes': [
                for (final c in barcodes.values)
                  if (c['produit_uuid'] == e.key) {'code': c['code'], 'conditionnement_id': c['conditionnement_uuid'] == null ? null : ids[c['conditionnement_uuid']]},
              ],
            },
      ],
    };
    final productRevisions = await v2.revisions('produit');
    final packagingRevisions = await v2.revisions('conditionnement');
    _products = products;
    _packagings = packagings;
    _revisions = {...productRevisions, ...packagingRevisions};
    _ids = ids;
    _productUuids = {for (final e in products.keys) ids[e]!: e};
    _packagingUuids = {for (final e in packagings.keys) ids[e]!: e};
    _rights = rights;
    _discountCaps = caps;
    _sessionUuid = session?['session_uuid'] as String?;
    snapshot = Snapshot(raw);
  }

  /// Session du terminal : celle du serveur si elle est ouverte ; sinon l'ouverture locale tant que le serveur ne l'a
  /// pas intégrée (une fois intégrée ou résolue, le serveur fait foi, y compris pour sa clôture).
  Future<Map<String, dynamic>?> _ownSession() async {
    final server = (await v2.entities('session'))['session:${_device['terminal_uuid']}'];
    if (server?['ouverte'] == true && !await _closedLocally(server!['session_uuid'] as String)) {
      return {'session_uuid': server['session_uuid'], 'operateur_id': server['operateur_id']};
    }
    final local = await v2.read(V2Keys.localSession);
    if (local == null) return null;
    final opening = await v2.operation(local);
    final state = opening?['etat'] as String?;
    if (opening == null || state == V2OperationState.integrated || state == V2OperationState.resolved || state == V2OperationState.rejected) {
      await v2.write(V2Keys.localSession, null);
      return null;
    }
    return {'session_uuid': local, 'locale': true};
  }

  /// Clôture émise par ce terminal que le serveur n'a pas encore reflétée : la session ne se rouvre pas d'elle-même.
  Future<bool> _closedLocally(String serverSession) async {
    final uuid = await v2.read(V2Keys.closingOperation);
    final row = uuid == null ? null : await v2.operation(uuid);
    final state = row?['etat'] as String?;
    if (state == null || state == V2OperationState.rejected || state == V2OperationState.resolved) return false;
    return state != V2OperationState.integrated || ((row!['operation'] as Map)['contenu'] as Map)['session_uuid'] == serverSession;
  }

  Future<int> _unsentCount() async {
    final counts = await v2.stateCounts();
    return counts.entries.where((e) => V2OperationState.unsent.contains(e.key.$2)).fold<int>(0, (sum, e) => sum + e.value);
  }

  Future<void> _count() async {
    final counts = await v2.stateCounts();
    int sum(bool Function(String type, String state) test) =>
        counts.entries.where((e) => test(e.key.$1, e.key.$2)).fold<int>(0, (total, e) => total + e.value);
    legacyPending = legacyTransport == null ? 0 : (await store.counts()).pending;
    pendingCount = sum((_, s) => V2OperationState.unsent.contains(s)) + legacyPending;
    pendingSales = sum((t, s) => t == 'vente' && V2OperationState.unsent.contains(s));
    refusedCount = sum((_, s) => s == V2OperationState.rejected);
    localArbitrationCount = sum((_, s) => s == V2OperationState.arbitration);
  }

  Future<void> _contact() async {
    lastContact = now;
    await v2.write(V2Keys.lastContact, lastContact!.toUtc().toIso8601String());
  }
}
