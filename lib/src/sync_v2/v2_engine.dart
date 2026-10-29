import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../offline/api.dart';
import '../offline/engine.dart';
import '../offline/models.dart';
import '../offline/store.dart';
import 'contract_schemas.dart';
import 'schema_validator.dart';
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
  }) : _newUuid = newUuid ?? (() => const Uuid().v4());

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
    _client = CaisseV2Client(apiBase: apiBase!, transport: transport, appVersion: appVersion, localSchema: offlineSchemaVersion);
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
      await sync.pair(code, platform: platform, model: model, newUuid: _newUuid);
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
    if (!(_rights[operator.id] ?? const []).contains(right)) throw OfflineRefusal('${operator.name} n’a pas le droit de $label.');
  }

  @override
  Future<OfflineOperation> openSession(int float, Operator operator) => serialized(() async {
    final s = _requireSelling(allowWithoutSession: true);
    if (!s.rules.sessionOpening) throw const OfflineRefusal('L’ouverture de session locale n’est pas autorisée : ouvrez-la en ligne.');
    if (sessionOpen) throw const OfflineRefusal('Une session est déjà ouverte sur ce terminal.');
    if (float < 0) throw const OfflineRefusal('Fond de caisse invalide.');
    _requireRight(operator, 'ouverture_session', 'ouvrir une session');
    final uuid = _newUuid();
    final operation = await _record(uuid, 'ouverture_session', operator, (_) => {'fond': float});
    await v2.write(V2Keys.localSession, uuid);
    await _rebuild();
    await _afterWrite();
    return operation;
  });

  @override
  Future<OfflineOperation> recordSale(List<CartLine> lines, List<CartPayment> payments, Operator operator, {String? draftUuid, String? operationUuid}) =>
      serialized(() async {
        if (operationUuid != null) {
          if (!CaisseEngine.uuidPattern.hasMatch(operationUuid)) throw const OfflineRefusal('Identifiant de vente invalide (UUID en minuscules attendu).');
          final existing = await v2.operation(operationUuid);
          if (existing != null) return sameSale(await _view(existing));
        }
        final s = _requireSelling();
        final payable = checkSale(s, lines, payments);
        _requireRight(operator, 'vente', 'vendre');
        if (payments.length != 1 || !payments.single.method.isCash) {
          throw const OfflineRefusal('Vente locale : un seul paiement, en espèces.');
        }
        final cart = [
          for (final l in lines)
            V2CartLine(
              productUuid: _productUuids[l.product.id] ?? (throw OfflineRefusal('« ${l.product.name} » n’est plus au catalogue local.')),
              packagingUuid: l.packaging == null ? null : (_packagingUuids[l.packaging!.id] ?? (throw OfflineRefusal('Conditionnement de « ${l.label} » retiré.'))),
              quantityMicros: l.quantity.toInt(),
              discount: l.discount,
            ),
        ];
        final builder = V2SaleBuilder(products: _products, packagings: _packagings, revisions: _revisions, newUuid: _newUuid);
        final payment = payments.single;
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
            payment: V2Payment(method: payment.method.code, amount: payable, received: payment.received ?? payable),
            vat: _vat!,
          ),
          draftUuid: draft,
        );
        await _afterWrite();
        return operation;
      });

  Future<OfflineOperation> _record(
    String uuid,
    String type,
    Operator operator,
    Map<String, dynamic> Function(int sequence) content, {
    String? draftUuid,
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
              for (final p in (content['paiements'] as List).cast<Map>()) {'moyen': p['moyen'], 'montant': p['montant'], 'recu': p['recu']},
            ],
            'total': (content['totaux'] as Map)['a_payer'],
          }
        : content;
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
    final localMethods = (policies['paiements.moyens_locaux'] as List?)?.cast<String>() ?? const <String>[];
    final methods = [
      for (final m in (await v2.entities('moyen_paiement')).values)
        if (m['local'] == true && m['especes'] == true && localMethods.contains(m['code'])) {'code': m['code'], 'nom': m['nom'], 'especes': true},
    ];
    final rights = <int, List<String>>{};
    final operators = <Map<String, dynamic>>[];
    for (final o in (await v2.entities('operateur')).values) {
      final id = int.tryParse('${o['operateur_id']}');
      if (id == null) continue;
      rights[id] = (o['droits'] as List).cast<String>();
      if (rights[id]!.contains('vente')) operators.add({'id': id, 'nom': o['nom'], 'pin': o['pin_empreinte']});
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
      'produits': [
        for (final e in products.entries)
          if (e.value['actif'] == true && e.value['vente_locale'] == true)
            {
              'id': ids[e.key],
              'nom': e.value['nom'],
              'reference': e.value['reference'],
              'categorie': e.value['categorie'],
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
    _sessionUuid = session?['session_uuid'] as String?;
    snapshot = Snapshot(raw);
  }

  /// Session du terminal : celle du serveur si elle est ouverte ; sinon l'ouverture locale tant que le serveur ne l'a
  /// pas intégrée (une fois intégrée ou résolue, le serveur fait foi, y compris pour sa clôture).
  Future<Map<String, dynamic>?> _ownSession() async {
    final server = (await v2.entities('session'))['session:${_device['terminal_uuid']}'];
    if (server?['ouverte'] == true) return {'session_uuid': server!['session_uuid'], 'operateur_id': server['operateur_id']};
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
