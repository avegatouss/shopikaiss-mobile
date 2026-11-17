import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../offline/money.dart';
import '../passes/pass_rules.dart';
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
          CaisseV2Client.returnCapability,
          CaisseV2Client.lotsCapability,
          CaisseV2Client.ticketModelsCapability,
          CaisseV2Client.passesCapability,
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
    // Forme des données relue ici : un redémarrage hors connexion garde les fonctions du contrat 2.1.
    v2.contract21 = contract21 && (await v2.read(V2Keys.contractRevision) ?? '').startsWith('2.1');
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

  @override
  WholesaleRules? get wholesaleRules {
    final rules = (_shopRules?['gros'] as Map?)?.cast<String, dynamic>();
    return saleExtrasSupported && rules?['actif'] == true ? WholesaleRules(rules!) : null;
  }

  /// Contrôles de la caisse web sur le tarif gros (`SaleService`, `HeldCartService`).
  void _checkWholesale(Operator operator, List<CartLine> lines, SaleExtras extras) {
    final rules = wholesaleRules;
    if (extras.wholesale) {
      if (rules == null || (!rules.manual && extras.sharedCart == null)) throw const OfflineRefusal('La bascule « Tarif gros » du panier n’est pas activée dans cette boutique.');
      if (!hasRight(operator, rules.right)) throw OfflineRefusal('${operator.name} n’a pas le droit d’appliquer le tarif gros.');
    }
    if ((extras.wholesale || lines.any((l) => l.wholesale)) && rules?.cumulates != true && (extras.globalDiscount > 0 || lines.any((l) => l.discount > 0))) {
      throw const OfflineRefusal('Le tarif gros ne se cumule pas avec une remise dans cette boutique : retirez les remises ou revenez au tarif de détail.');
    }
  }

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

  /// Politiques des retours, publiées avec la capacité.
  ({String mode, int max, int days}) _returnRules = (mode: 'en_ligne', max: 0, days: 0);

  @override
  String? returnBlocker(Operator operator) {
    if (!saleExtrasSupported || !_serverOffers(CaisseV2Client.returnCapability)) return 'La boutique ne propose pas les retours hors ligne à ce terminal.';
    if (_returnRules.mode != 'especes') return 'Les retours hors ligne en espèces ne sont pas activés dans les réglages de la boutique.';
    if ((_state?['fonctions_restreintes'] as List?)?.any((f) => (f as Map)['fonction'] == 'retour') ?? true) return 'Les retours sont suspendus sur ce terminal par la boutique.';
    if (!hasRight(operator, 'retour_creer')) return '${operator.name} n’a pas le droit de créer un retour.';
    if (!hasRight(operator, 'retour_rembourser_especes')) return '${operator.name} n’a pas le droit de rembourser en espèces.';
    return null;
  }

  @override
  void checkSaleRules(Operator operator, List<CartLine> lines, SaleExtras extras) => _checkWholesale(operator, lines, extras);

  /// Vente du terminal, parts archivées par ligne, quantités déjà retournées et total déjà rendu. Si la boutique change de
  /// règle entre deux retours d'une vente, le serveur garde la première : écart, donc arbitrage.
  Future<({Map content, Map<String, int> shares, Map<String, int> before, int refunded})> _returnBasis(String saleUuid) async {
    final row = await v2.operation(saleUuid);
    final operation = row?['operation'] as Map?;
    if (operation == null || operation['type'] != 'vente') throw const OfflineRefusal('Seules les ventes de ce terminal se retournent hors ligne.');
    if (row!['etat'] == V2OperationState.rejected || row['etat'] == V2OperationState.arbitration) {
      throw const OfflineRefusal('Cette vente attend un traitement de la boutique : retour impossible pour l’instant.');
    }
    final created = DateTime.parse(operation['cree_le'] as String).toLocal();
    final today = DateTime(now.year, now.month, now.day);
    final age = (today.difference(DateTime(created.year, created.month, created.day)).inHours / 24).round();
    if (age > _returnRules.days) throw OfflineRefusal('Vente trop ancienne pour un retour hors ligne (${_returnRules.days} jour(s) au plus).');
    final content = operation['contenu'] as Map;
    final lines = (content['lignes'] as List).cast<Map>();
    final parts = archivedShares(_saleNet(content), [for (final l in lines) l['total'] as int], _shopRules?['retour_residuel'] as String?);
    if (parts == null) throw const OfflineRefusal('Le montant de ce retour dépend d’une règle d’arrondi de la boutique : faites-le en ligne.');
    final shares = {for (final (i, l) in lines.indexed) l['ligne_uuid'] as String: parts[i]};
    final before = <String, int>{};
    var refunded = 0;
    for (final other in await v2.operationRows()) {
      final past = other['operation'] as Map;
      if (past['type'] != 'retour' || other['etat'] == V2OperationState.rejected) continue;
      final pastContent = past['contenu'] as Map;
      if ((pastContent['vente_ref'] as Map)['operation_uuid'] != saleUuid) continue;
      refunded += pastContent['montant'] as int;
      for (final l in (pastContent['lignes'] as List).cast<Map>()) {
        before.update(l['ligne_uuid'] as String, (v) => v + Decimal6.parse(l['quantite'] as String), ifAbsent: () => Decimal6.parse(l['quantite'] as String));
      }
    }
    return (content: content, shares: shares, before: before, refunded: refunded);
  }

  /// Net archivé : à payer, livraison exclue.
  static int _saleNet(Map content) => ((content['totaux'] as Map)['a_payer'] as int) - (content['livraison'] as int? ?? 0);

  @override
  Future<List<ReturnableLine>> returnableLines(String saleUuid) async {
    final basis = await _returnBasis(saleUuid);
    return [
      for (final l in (basis.content['lignes'] as List).cast<Map>())
        if (Decimal6.parse(l['quantite_base'] as String) - (basis.before[l['ligne_uuid']] ?? 0) case final remaining when remaining > 0)
          ReturnableLine(lineUuid: l['ligne_uuid'] as String, label: l['libelle'] as String, remaining: remaining),
    ];
  }

  int _amountOf(({Map content, Map<String, int> shares, Map<String, int> before, int refunded}) basis, Map<String, int> quantities) {
    final lines = (basis.content['lignes'] as List).cast<Map>();
    var amount = 0;
    for (final e in quantities.entries) {
      final line = lines.where((l) => l['ligne_uuid'] == e.key).firstOrNull ?? (throw const OfflineRefusal('Cette ligne n’appartient pas à la vente.'));
      final sold = Decimal6.parse(line['quantite_base'] as String);
      final before = basis.before[e.key] ?? 0;
      if (e.value <= 0) throw const OfflineRefusal('Quantité invalide.');
      if (before + e.value > sold) throw const OfflineRefusal('La quantité retournée dépasse la quantité vendue restante.');
      amount += returnedAmount(basis.shares[e.key]!, before, e.value, sold);
    }
    return amount;
  }

  @override
  Future<int> returnAmount(String saleUuid, Map<String, int> quantities) async => _amountOf(await _returnBasis(saleUuid), quantities);

  @override
  Future<OfflineOperation> recordReturn(Operator operator, String saleUuid, Map<String, int> quantities, String reason, {String? operationUuid}) => serialized(() async {
    if (operationUuid != null) {
      if (!CaisseEngine.uuidPattern.hasMatch(operationUuid)) throw const OfflineRefusal('Identifiant d’opération invalide (UUID en minuscules attendu).');
      final existing = await v2.operation(operationUuid);
      if (existing != null) return _view(existing);
    }
    if (!returnsOpen(operator)) throw const OfflineRefusal('Retour hors ligne non autorisé sur ce terminal.');
    if (!sessionOpen) throw const OfflineRefusal('Aucune session de caisse ouverte sur ce terminal : ouvrez-la d’abord.');
    final motive = reason.trim();
    if (motive.isEmpty || motive.length > 500) throw const OfflineRefusal('Indiquez le motif du retour (500 caractères au plus).');
    if (quantities.isEmpty) throw const OfflineRefusal('Choisissez au moins une quantité à retourner.');
    final basis = await _returnBasis(saleUuid);
    final amount = _amountOf(basis, quantities);
    if (amount <= 0) throw const OfflineRefusal('Rien à rembourser pour ces quantités.');
    if (amount > _returnRules.max) throw OfflineRefusal('Retour hors ligne limité à ${formatFcfa(_returnRules.max)} : faites-le en ligne.');
    final content = basis.content;
    if (basis.refunded + amount > ((content['totaux'] as Map)['a_payer'] as int)) throw const OfflineRefusal('Le montant cumulé restitué dépasse le montant reçu sur la vente.');
    final lines = (content['lignes'] as List).cast<Map>();
    final stocked = {for (final m in (content['mouvements'] as List).cast<Map>()) m['produit_uuid']};
    final movements = [
      for (final e in quantities.entries)
        if (lines.firstWhere((l) => l['ligne_uuid'] == e.key) case final line when stocked.contains(line['produit_uuid']))
          {'mouvement_uuid': _newUuid(), 'produit_uuid': line['produit_uuid'], 'lot_uuid': line['lot_uuid'], 'variation': Decimal6.format(e.value)},
    ];
    final operation = await _record(operationUuid ?? _newUuid(), 'retour', operator, (_) => {
      'vente_ref': {'operation_uuid': saleUuid},
      'lignes': [for (final e in quantities.entries) {'ligne_uuid': e.key, 'quantite': Decimal6.format(e.value)}],
      'montant': amount,
      'remboursement': 'especes',
      'motif': motive,
      'mouvements': movements,
    });
    await _rebuild();
    await _afterWrite();
    return operation;
  });

  /// Panier repris en ce moment (uuid, opérateur) : sa reprise de 30 minutes est renouvelée à chaque synchronisation.
  (String, int)? _heldCart;

  @override
  bool get sharedCartsSupported => saleExtrasSupported && _serverOffers(CaisseV2Client.sharedCartCapability);

  @override
  Future<List<SharedCart>> sharedCarts() async {
    if (!sharedCartsSupported) return const [];
    final me = _device['terminal_uuid'];
    final carts = <SharedCart>[];
    final deleted = await v2.deletedCarts();
    for (final e in (await v2.entities('panier')).entries) {
      if (!(e.value['terminaux'] as List).contains(me) || deleted.contains(e.key)) continue;
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

  /// Attente d'une écriture intégrée par le journal : le serveur publie par balayage, au cycle suivant.
  static const _publicationDelay = Duration(minutes: 10);

  @override
  Future<String> sharedCartState(String uuid) async {
    if ((await v2.entities('panier')).containsKey(uuid)) return 'publie';
    final row = await v2.operation(uuid);
    if (row?['etat'] != V2OperationState.integrated) return 'local';
    if (await v2.entityDeleted('panier', uuid)) return 'disparu';
    // Intégré, pas encore revenu par le journal : observé sur la démo juste après l'envoi. Passé ce délai, sans suppression
    // reçue (instantané intermédiaire), il a été vendu ou supprimé ailleurs.
    final integrated = DateTime.tryParse('${row!['maj_le']}');
    return integrated != null && now.difference(integrated) < _publicationDelay ? 'local' : 'disparu';
  }

  @override
  Future<SharedCartRef> suspendShared(Operator operator, List<CartLine> lines, SaleExtras extras, {SharedCartRef? previous, String? label}) => serialized(() async {
    if (!sharedCartsSupported) throw const OfflineRefusal('Paniers partagés non disponibles sur ce terminal.');
    if (lines.isEmpty || lines.length > 100) throw const OfflineRefusal('Entre 1 et 100 lignes par panier.');
    if ((lines.any((l) => l.discount > 0) || extras.globalDiscount > 0) && !hasRight(operator, 'remise')) {
      throw OfflineRefusal('${operator.name} n’a pas le droit d’accorder une remise : retirez-la avant de partager ce panier.');
    }
    _checkWholesale(operator, lines, extras);
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
      'tarif': extras.wholesale ? 'gros' : 'detail',
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
      wholesale: content['tarif'] == 'gros',
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
    final cash = (await v2.entities('moyen_paiement')).values.where((m) => m['especes'] == true).map((m) => m['code'] as String).firstOrNull ?? 'especes';
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
        case 'retour':
          expected.update(cash, (v) => v - (content['montant'] as int), ifAbsent: () => -(content['montant'] as int));
        case 'ouverture_session':
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
    final phones = {for (final c in customers) normalizePhone(c.phone)};
    final own = <String>{};
    for (final row in await v2.operationRows()) {
      final operation = row['operation'] as Map;
      if (operation['type'] != 'creation_client' || row['etat'] == V2OperationState.rejected) continue;
      final content = operation['contenu'] as Map;
      own.add(content['client_uuid'] as String);
      if (published.contains(content['client_uuid'])) continue;
      // Intégrée : la fiche arrive par le journal, sous cet uuid ou sous celui de la fiche fusionnée (même téléphone).
      if (row['etat'] == V2OperationState.integrated || row['etat'] == V2OperationState.resolved) {
        final integrated = DateTime.tryParse('${row['maj_le']}');
        final phone = normalizePhone(content['telephone'] as String?);
        if (integrated == null || now.difference(integrated) >= _publicationDelay || (phone != null && phones.contains(phone))) continue;
      }
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
  ({String start, String end})? _imageWindow;

  @override
  bool get imagesSupported => imageDirectory != null;

  @override
  ({String start, String end})? get imageWindow => _imageWindow;

  @override
  Future<void> setImageWindow(({String start, String end})? window) async {
    await v2.write(V2Keys.imageWindow, window == null ? null : '${window.start}-${window.end}');
    _imageWindow = window;
  }

  @override
  ({int cached, int total}) imageCounts() {
    final hashes = {for (final x in snapshot?.products ?? const <Product>[]) ?x.image?.hash};
    return (cached: imageDirectory == null ? 0 : hashes.where((h) => _imageFile(h).existsSync()).length, total: hashes.length);
  }

  bool get _imageWindowOpen {
    final window = _imageWindow;
    if (window == null) return true;
    int minutes(String time) => int.parse(time.substring(0, 2)) * 60 + int.parse(time.substring(3));
    final local = now.toLocal();
    final current = local.hour * 60 + local.minute;
    final start = minutes(window.start);
    final end = minutes(window.end);
    return start < end ? current >= start && current < end : current >= start || current < end;
  }

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
  Future<int> downloadImages({bool Function()? interrupted}) async {
    final directory = imageDirectory;
    final client = _client;
    final s = snapshot;
    if (directory == null || client == null || s == null || !paired) return 0;
    final paused = _imagesPausedUntil;
    if (paused != null && now.isBefore(paused)) return 0;
    if (!_imageWindowOpen) return 0;
    Directory(directory).createSync(recursive: true);
    final wanted = {for (final x in s.products) ?x.image?.hash: ?x.image};
    var added = 0;
    for (final image in wanted.values.where((i) => !_imageFile(i.hash).existsSync()).take(_imagesPerPass)) {
      if (interrupted?.call() == true || !_imageWindowOpen) return added;
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

  @override
  String? get oversellPolicy => _shopRules?['survente'] as String?;

  /// Badge « Nouveau » : produit créé depuis N jours au plus (`regles.nouveau_jours`), null = désactivé.
  @override
  int? get newBadgeDays => _shopRules?['nouveau_jours'] as int?;

  // ---------------------------------------------------------------- passes événement (2.1 lot 8)

  /// Réglages `pass_reglages` de la boutique, relus à chaque reconstruction.
  PassSettings? _passSettings;

  @override
  PassSettings? get passSettings =>
      saleExtrasSupported && _serverOffers(CaisseV2Client.passesCapability) && (_passSettings?.active ?? false) ? _passSettings : null;

  @override
  bool canPayByPass(Operator operator) => passSettings != null && hasRight(operator, 'pass_encaisser');

  /// Jour civil du passage, dans le fuseau publié de la boutique.
  String get _passDay => PassDay.of(now, _shopRules?['fuseau'] as String?);

  static final _passMethod = PaymentMethodInfo({'code': PassRules.method, 'nom': 'Pass événement', 'especes': false, 'reference': 'aucune'});

  int _payableOf(Snapshot s, List<CartLine> lines, SaleExtras extras) {
    try {
      return webTotals(
        lineBases: [for (final l in lines) l.base],
        lineDiscounts: [for (final l in lines) l.discount],
        globalDiscount: extras.globalDiscount,
        vatRate: s.store.vatRate,
        vatIncluded: s.store.vatIncluded,
        delivery: extras.delivery,
      ).payable;
    } on WebRuleRefusal catch (e) {
      throw OfflineRefusal(e.message);
    }
  }

  /// Passages de ce terminal pour [passUuid] que le serveur ne compte pas encore (absents de `compteurs.passages`),
  /// sur la même fenêtre de 7 jours : (aujourd'hui, au total). Une vente rejetée ne compte pas.
  Future<(int, int)> _uncountedPassages(String passUuid, Set<String> counted, String day) async {
    final from = DateTime.utc(int.parse(day.substring(0, 4)), int.parse(day.substring(5, 7)), int.parse(day.substring(8, 10)))
        .subtract(const Duration(days: 6))
        .toIso8601String()
        .substring(0, 10);
    var today = 0;
    var total = 0;
    for (final row in await v2.operationRows()) {
      final operation = row['operation'] as Map;
      if (operation['type'] != 'vente' || row['etat'] == V2OperationState.rejected) continue;
      for (final passage in ((operation['contenu'] as Map)['passages'] as List? ?? const []).cast<Map>()) {
        final jour = passage['jour'] as String;
        if (passage['pass_uuid'] != passUuid || counted.contains(passage['uuid']) || jour.compareTo(from) < 0) continue;
        total++;
        if (jour == day) today++;
      }
    }
    return (today, total);
  }

  /// Décision locale d'ECAS sur les compteurs du serveur et les passages locaux non encore comptés.
  Future<PassDecision> _decideLocally(String passUuid, Map pass, Map event, String day, int amount) async {
    final counters = pass['compteurs'] as Map;
    final (localToday, localTotal) = await _uncountedPassages(passUuid, {...(counters['passages'] as List).cast<String>()}, day);
    final serverToday = (counters['jours'] as List).cast<Map>().where((j) => j['jour'] == day).map((j) => j['passages'] as int).firstOrNull ?? 0;
    final definition = PassDefinition(
      revoked: pass['statut'] != 'actif',
      start: pass['debut'] as String?,
      end: pass['fin'] as String?,
      maxTotal: pass['max_total'] as int?,
      rules: [for (final r in (pass['regles'] as List).cast<Map>()) PassDayRule.fromJson(r)],
      capPerPassage: pass['plafond_par_passage'] as int?,
      eventActive: event['actif'] == true,
      eventStart: event['debut'] as String?,
      eventEnd: event['fin'] as String?,
    );
    return PassRules.decide(definition, day, serverToday + localToday, (counters['total'] as int) + localTotal, amount);
  }

  String? _basketRefusal(Map pass, Map event, List<CartLine> lines) => PassRules.basketRefusal(
    [for (final l in lines) (_productUuids[l.product.id] ?? '', l.label)],
    allProducts: event['tous_produits'] == true,
    eventProducts: {...(event['produits'] as List).cast<String>()},
    menuProducts: pass['menus_produits'] == null ? null : {...(pass['menus_produits'] as List).cast<String>()},
  );

  @override
  Future<PassCheck> verifyPass(Operator operator, String code, List<CartLine> lines, SaleExtras extras, {List<PassCheck> already = const []}) async {
    final settings = passSettings;
    if (settings == null) throw const OfflineRefusal('Les passes événement sont désactivés (Réglages › Passes événement).');
    if (!hasRight(operator, 'pass_encaisser')) throw const OfflineRefusal('Permission refusée : encaisser par pass.');
    final normalized = PassRules.normalize(code);
    if (normalized.isEmpty) throw const OfflineRefusal('Scannez ou saisissez le code du pass.');
    if (already.isNotEmpty && !settings.severalPerSale) throw const OfflineRefusal('Un seul pass par vente : retirez le premier pour en scanner un autre.');
    final s = _requireSelling();
    if (lines.isEmpty) throw const OfflineRefusal('Le panier est vide.');
    final amount = PassRules.split(_payableOf(s, lines, extras), already.length + 1).last;
    final day = _passDay;
    final client = _client;
    if (client == null) return _verifyPassOffline(normalized, lines, already, day, amount);
    final Map<String, dynamic> verdict;
    try {
      verdict = await client.verifyPass({
        'code': normalized.length > 120 ? normalized.substring(0, 120) : normalized,
        'jour': day,
        'lignes': [
          for (final l in lines) {'produit_uuid': _productUuids[l.product.id], 'quantite': Decimal6.format(l.quantity.toInt()), 'montant': l.base - l.discount},
        ],
        'montant': amount,
        'point_passage': null,
        'table_uuid': null,
      });
    } on V2Failure catch (failure) {
      if (failure.kind != V2FailureKind.unavailable) {
        throw OfflineRefusal(failure.status == 429 ? 'Trop de vérifications de pass : réessayez dans un instant.' : failure.message);
      }
      return _verifyPassOffline(normalized, lines, already, day, amount);
    }
    final passUuid = verdict['pass_uuid'] as String?;
    if (passUuid != null && already.any((p) => p.passUuid == passUuid)) throw const OfflineRefusal('Ce pass est déjà sur la vente.');
    if (verdict['verdict'] != 'autorise' || passUuid == null) throw OfflineRefusal(verdict['motif'] as String? ?? 'Pass refusé.');
    return PassCheck(
      passUuid: passUuid,
      holder: verdict['porteur'] as String?,
      leftToday: verdict['restant_jour'] as int?,
      leftTotal: verdict['restant_total'] as int?,
      online: true,
      amount: amount,
    );
  }

  /// Sans réseau : seulement si l'événement l'autorise (`hors_ligne`), par les règles d'ECAS sur les données publiées.
  Future<PassCheck> _verifyPassOffline(String normalized, List<CartLine> lines, List<PassCheck> already, String day, int amount) async {
    final fingerprint = PassRules.fingerprint(normalized);
    final entry = (await v2.entities('pass')).entries.where((e) => e.value['code_empreinte'] == fingerprint).firstOrNull;
    if (entry == null) throw OfflineRefusal("Code inconnu : $normalized. Ce n'est pas un pass enregistré.");
    if (already.any((p) => p.passUuid == entry.key)) throw const OfflineRefusal('Ce pass est déjà sur la vente.');
    final event = (await v2.entities('pass_evenement'))[entry.value['evenement_uuid']];
    if (event == null) throw const OfflineRefusal('Événement du pass introuvable.');
    if (event['hors_ligne'] != 'autoriser') throw const OfflineRefusal('Vérification impossible sans connexion pour cet événement.');
    final decision = await _decideLocally(entry.key, entry.value, event, day, amount);
    if (!decision.allowed) throw OfflineRefusal(decision.refusal!);
    final basket = _basketRefusal(entry.value, event, lines);
    if (basket != null) throw OfflineRefusal(basket);
    return PassCheck(
      passUuid: entry.key,
      holder: entry.value['porteur'] as String?,
      leftToday: decision.leftToday,
      leftTotal: decision.leftTotal,
      online: false,
      amount: amount,
    );
  }

  /// Paiements et passages d'une vente payée par pass, revérifiés sur le panier final (il a pu changer depuis le
  /// scan) : service et menus pour tous, règles complètes pour une décision prise hors connexion.
  Future<(List<CartPayment>, List<Map<String, dynamic>>)> _passPayment(Snapshot s, Operator operator, List<CartLine> lines, SaleExtras extras) async {
    final settings = passSettings;
    if (settings == null) throw const OfflineRefusal('Les passes événement sont désactivés (Réglages › Passes événement).');
    if (!hasRight(operator, 'pass_encaisser')) throw const OfflineRefusal('Permission refusée : encaisser par pass.');
    final uuids = [for (final p in extras.passes) p.passUuid];
    if (uuids.toSet().length != uuids.length) throw const OfflineRefusal('Le même pass est scanné deux fois sur cette vente.');
    if (uuids.length > 1 && !settings.severalPerSale) throw const OfflineRefusal('Un seul pass par vente (réglage « plusieurs passes par vente » éteint).');
    final parts = PassRules.split(_payableOf(s, lines, extras), uuids.length);
    final passes = await v2.entities('pass');
    final events = await v2.entities('pass_evenement');
    final day = _passDay;
    for (var i = 0; i < uuids.length; i++) {
      final pass = passes[uuids[i]];
      final event = pass == null ? null : events[pass['evenement_uuid']];
      if (pass == null || event == null) {
        // Pas encore reçu par ce terminal : le serveur, qui l'a autorisé en ligne, tranche à l'intégration.
        if (extras.passes[i].online) continue;
        throw const OfflineRefusal('Pass introuvable sur ce terminal : scannez-le de nouveau.');
      }
      final basket = _basketRefusal(pass, event, lines);
      if (basket != null) throw OfflineRefusal(basket);
      if (!extras.passes[i].online) {
        final decision = await _decideLocally(uuids[i], pass, event, day, parts[i]);
        if (!decision.allowed) throw OfflineRefusal(decision.refusal!);
      }
    }
    return (
      [for (final part in parts) if (part > 0) CartPayment(method: _passMethod, amount: part)],
      [
        for (var i = 0; i < uuids.length; i++)
          {
            'uuid': _newUuid(),
            'pass_uuid': uuids[i],
            'jour': day,
            'montant': parts[i],
            'point_passage': '',
            'point_consommation': null,
            'table_uuid': null,
            'verifie_en_ligne': extras.passes[i].online,
          },
      ],
    );
  }

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
        var passages = const <Map<String, dynamic>>[];
        if (extras.passes.isNotEmpty) {
          if (payments.isNotEmpty) throw const OfflineRefusal('Une vente payée par pass ne prend aucun autre moyen de paiement.');
          (payments, passages) = await _passPayment(s, operator, lines, extras);
        }
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
        _checkWholesale(operator, lines, extras);
        final allocation = allocateLots(s, lines);
        final cart = [
          for (final l in lines) ..._cartLines(l, allocation[l]),
        ];
        final revision21 = v2.contract21;
        final builder = V2SaleBuilder(products: _products, packagings: _packagings, revisions: _revisions, newUuid: _newUuid);
        final uuid = operationUuid ?? _newUuid();
        // Le contrat exige un UUID de brouillon ; un identifiant d'écran d'une autre forme en donne un, toujours le même
        // (le second encaissement du même panier reste refusé).
        final draft = draftUuid == null ? null : (CaisseEngine.uuidPattern.hasMatch(draftUuid) ? draftUuid : const Uuid().v5(Namespace.url.value, 'brouillon:$draftUuid'));
        final epoch = _device['epoque'];
        await rememberTicketModel(uuid);
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
            passages: passages,
          ),
          draftUuid: draft,
          calculation: revision21 ? '2' : '1',
        );
        if (extras.sharedCart == _heldCart?.$1) _heldCart = null;
        // Reste par lot : la vente suivante ne doit pas puiser dans ce qui vient de partir.
        if (allocation.isNotEmpty) await _rebuild();
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
              for (final p in (content['paiements'] as List).cast<Map>()) {
                'moyen': p['moyen'], 'montant': p['montant'], 'recu': p['recu'], 'reference': p['reference'],
                if (p.containsKey('monnaie')) 'monnaie': p['monnaie'],
                if (p.containsKey('ecart_arrondi')) 'ecart_arrondi': p['ecart_arrondi'],
              },
            ],
            'total': (content['totaux'] as Map)['a_payer'],
            // Totaux figés à l'encaissement : le ticket et son duplicata les impriment tels quels.
            'totaux': content['totaux'],
            'tva': content['tva'],
            'remise_globale': content['remise_globale'] ?? 0,
            'livraison': content['livraison'] ?? 0,
            if (content['note'] != null) 'note': content['note'],
            if (content['client_nom'] != null) 'client_nom': content['client_nom'],
            if (content['tarif'] != null) 'tarif': content['tarif'],
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
    final window = (await v2.read(V2Keys.imageWindow))?.split('-');
    _imageWindow = window == null ? null : (start: window.first, end: window.last);
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
    _returnRules = (
      mode: policies['retours.mode'] as String? ?? 'en_ligne',
      max: policies['retours.max_montant'] as int? ?? 0,
      days: policies['retours.delai_jours'] as int? ?? 0,
    );
    final ids = await v2.localIds([...products.keys, ...packagings.keys]);
    _vat = await v2.shopVat();
    final shop = (await v2.entities('boutique'))[_device['boutique_uuid']];
    _shopRules = (shop?['regles'] as Map?)?.cast<String, dynamic>();
    final passSettings = (await v2.entities('pass_reglages'))[_device['boutique_uuid']];
    _passSettings = passSettings == null ? null : PassSettings(passSettings);
    final categories = await v2.entities('categorie');
    String? categoryOf(Map<String, dynamic> product) {
      final category = categories[product['categorie_uuid']];
      return category != null && category['actif'] == true ? category['nom'] as String : product['categorie'] as String?;
    }

    // Onglets du web : catégories portant un produit actif de la boutique (une catégorie partagée peut n'en porter qu'ailleurs).
    final used = {for (final p in products.values) if (p['actif'] == true) p['categorie_uuid']};
    final orderedCategories = categories.entries.where((c) => c.value['actif'] == true && used.contains(c.key)).map((c) => c.value).toList()
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
    // Index par produit : la reconstruction a lieu à chaque synchronisation et gèle la file des commandes.
    final packagingsOf = <Object?, List<MapEntry<String, Map<String, dynamic>>>>{};
    for (final k in packagings.entries) {
      (packagingsOf[k.value['produit_uuid']] ??= []).add(k);
    }
    final barcodesOf = <Object?, List<Map<String, dynamic>>>{};
    for (final c in barcodes.values) {
      (barcodesOf[c['produit_uuid']] ??= []).add(c);
    }
    final lotsOf = <Object?, List<MapEntry<String, Map<String, dynamic>>>>{};
    for (final l in (await v2.entities('lot')).entries) {
      (lotsOf[l.value['produit_uuid']] ??= []).add(l);
    }
    final estimated = lotsOf.isEmpty ? const <String, int>{} : await v2.estimatedStock();
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
      // Modèle résolu par le serveur pour ce terminal (capacité ticket.modeles) ; null : disposition d'origine.
      'modele_ticket': (await v2.entities('modele_ticket'))[(await v2.entities('ticket_terminal'))[_device['terminal_uuid']]?['modele_uuid']],
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
              'prix_gros': e.value['prix_gros'],
              'gros_quantite_min': e.value['gros_quantite_min'],
              'stock_illimite': e.value['stock_illimite'],
              'stock': (stock[e.key]?['quantite'] as String?) ?? '0',
              if (e.value['gere_par_lots'] == true) ..._lotView(e.key, e.value, lotsOf[e.key] ?? const [], stock, estimated),
              'conditionnements': [
                for (final k in packagingsOf[e.key] ?? const <MapEntry<String, Map<String, dynamic>>>[])
                  if (k.value['actif'] == true)
                    {'id': ids[k.key], 'nom': k.value['nom'], 'coefficient': k.value['coefficient'], 'prix': k.value['prix'], 'prix_gros': k.value['prix_gros'], 'defaut': k.value['defaut']},
              ],
              'codes': [
                for (final c in barcodesOf[e.key] ?? const <Map<String, dynamic>>[]) {'code': c['code'], 'conditionnement_id': c['conditionnement_uuid'] == null ? null : ids[c['conditionnement_uuid']]},
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

  /// Ligne(s) de vente d'une ligne du panier : une par lot pour un produit à lots, remise répartie au prorata.
  List<V2CartLine> _cartLines(CartLine l, List<LotSegment>? segments) {
    final productUuid = _productUuids[l.product.id] ?? (throw OfflineRefusal('« ${l.product.name} » n’est plus au catalogue local.'));
    final packagingUuid = l.packaging == null ? null : (_packagingUuids[l.packaging!.id] ?? (throw OfflineRefusal('Conditionnement de « ${l.label} » retiré.')));
    if (segments == null || segments.length == 1) {
      return [
        V2CartLine(
          productUuid: productUuid,
          packagingUuid: packagingUuid,
          quantityMicros: l.quantity.toInt(),
          discount: l.discount,
          discountEntry: l.discountEntry,
          fixedPrice: segments != null || l.wholesale ? l.unitPrice : l.fixedPrice,
          lotUuid: segments?.single.lot.uuid,
          wholesale: l.wholesale,
        ),
      ];
    }
    const refusal = OfflineRefusal('Quantité à cheval sur plusieurs lots : choisissez un lot ou réduisez la quantité.');
    final million = BigInt.from(Decimal6.scale);
    final coefficient = l.packaging == null ? million : parseMicros(l.packaging!.coefficient) ?? million;
    final total = segments.fold(BigInt.zero, (sum, x) => sum + x.base);
    final out = <V2CartLine>[];
    var discounted = 0;
    var bases = 0;
    for (final (i, x) in segments.indexed) {
      if ((x.base * million).remainder(coefficient) != BigInt.zero) throw refusal;
      final quantity = x.base * million ~/ coefficient;
      final discount = i == segments.length - 1 ? l.discount - discounted : (BigInt.from(l.discount) * x.base ~/ total).toInt();
      discounted += discount;
      bases += lineBase(l.unitPrice, quantity);
      out.add(V2CartLine(
        productUuid: productUuid,
        packagingUuid: packagingUuid,
        quantityMicros: quantity.toInt(),
        discount: discount,
        discountEntry: discount == 0 ? null : DiscountEntry('montant', '$discount'),
        fixedPrice: l.unitPrice,
        lotUuid: x.lot.uuid,
        wholesale: l.wholesale,
      ));
    }
    if (bases != l.base) throw refusal;
    return out;
  }

  /// Vue d'un produit à lots : lots vendables dans l'ordre du mode de la boutique, stock et prix d'après eux.
  ///
  /// Le mode `prix_bas` du web trie sur le prix d'achat, non publié au terminal : ici sur le prix de vente.
  Map<String, dynamic> _lotView(String product, Map<String, dynamic> data, List<MapEntry<String, Map<String, dynamic>>> lots, Map<String, Map<String, dynamic>> stock, Map<String, int> estimated) {
    final mode = (_shopRules?['lots_mode'] ?? 'fifo') as String;
    int entered(MapEntry<String, Map<String, dynamic>> a, MapEntry<String, Map<String, dynamic>> b) {
      final date = (a.value['entree'] as String).compareTo(b.value['entree'] as String);
      return date != 0 ? date : a.key.compareTo(b.key);
    }

    int compare(MapEntry<String, Map<String, dynamic>> a, MapEntry<String, Map<String, dynamic>> b) {
      final order = switch (mode) {
        'dernier_achat' => entered(b, a),
        'prix_bas' => (a.value['prix_vente'] as int).compareTo(b.value['prix_vente'] as int),
        'fefo' => ((a.value['peremption'] ?? '9999-12-31') as String).compareTo((b.value['peremption'] ?? '9999-12-31') as String),
        _ => 0,
      };
      return order != 0 ? order : entered(a, b);
    }

    final ordered = lots.where((e) => e.value['actif'] == true).toList()..sort(compare);
    int price(Map<String, dynamic> lot) => mode == 'prix_unique' ? data['prix'] as int : lot['prix_vente'] as int;
    var total = 0;
    Object? firstPrice;
    final views = <Map<String, dynamic>>[];
    for (final e in ordered) {
      final key = '$product:${e.key}';
      total += Decimal6.parseSigned((stock[key]?['quantite'] ?? '0.000000') as String);
      final left = estimated[key] ?? 0;
      if (left > 0) firstPrice ??= price(e.value);
      views.add({'uuid': e.key, 'reference': e.value['reference'], 'entree': e.value['entree'], 'peremption': e.value['peremption'], 'prix': price(e.value), 'reste': Decimal6.format(left < 0 ? 0 : left)});
    }
    return {'gere_par_lots': true, 'lots_mode': mode, 'lots': views, 'stock': Decimal6.format(total < 0 ? 0 : total), 'prix': firstPrice ?? data['prix'], 'prix_catalogue': data['prix']};
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
    // Intégrée, pas encore revenue par le journal : reste ouverte ici, sinon la vente suivante serait refusée.
    final integrated = state == V2OperationState.integrated ? DateTime.tryParse('${opening!['maj_le']}') : null;
    final awaited = integrated != null && server?['session_uuid'] != local && now.difference(integrated) < _publicationDelay;
    if (!awaited && (opening == null || state == V2OperationState.integrated || state == V2OperationState.resolved || state == V2OperationState.rejected)) {
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
