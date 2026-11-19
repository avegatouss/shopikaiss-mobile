part of 'v2_engine.dart';

/// Suivi d'une commande dans la file : dernière version et remontée de ses opérations `resto_commande`.
class _RestoTrack {
  _RestoTrack(this.uuid);

  final String uuid;
  RestoOrder? order;
  int pending = 0;
  String? message;
  bool waiting = false;
  bool blocked = false;
  String? serverNumber;
}

/// Restaurant hors connexion (capacité `restaurant.v1`, RESTAURANT-1 validé, lots R-1 à R-3) : la caisse maîtresse
/// tient ses commandes du Service de table et les fait remonter par `resto_commande` (une version par validation, état
/// complet), envoie les bons aux postes (R-3 : bons immuables dans le fait, livraison locale, états remontés par
/// `resto_bons_etats`), puis règle par une vente v2 avec `commande` (`full`) suivie de la `cloture`.
///
/// La file des opérations fait foi : la commande courante est l'état de sa dernière version enregistrée, rien d'autre
/// n'est stocké. Un fait n'est enregistré que si la caisse est maîtresse (bloc `/etat.restaurant` ET désignation publiée).
extension _V2Restaurant on V2Engine {
  static const _unavailable = 'Restaurant non disponible sur ce terminal.';

  /// Journal local des événements de bons (livraisons, vérifications, duplicatas) : `{e: événement du contrat, g:
  /// génération, o: opérateur, r: remonté, x: résultat local d'un duplicata}`.
  static const _ticketJournalKey = 'v2.resto_bons_journal';
  static const _ticketFlushKey = 'v2.resto_bons_dernier_lot';

  /// Autorisations restaurant données sur ce terminal (plafonds de l'assistant) : `{a: approbateur, j: jour, m: montant}`.
  static const _approvalLedgerKey = 'v2.resto_autorisations';

  /// Adresses locales des imprimantes de poste (`{poste_uuid: "ip:port"}`), jamais reçues du serveur (§3.8).
  static const _printersKey = 'v2.resto_imprimantes';

  Future<RestoContext?> _loadRestaurant() async {
    if (!v2.restaurant || !_serverOffers(CaisseV2Client.restaurantCapability)) return null;
    final block = (_state?['restaurant'] as Map?)?.cast<String, dynamic>();
    if (block == null) return null;
    final pdv = block['point_de_vente_uuid'] as String?;
    final generation = block['generation'] as String;
    final pointOfSale = pdv == null ? null : (await v2.entities('restaurant.point_de_vente'))[pdv];
    final designation = pdv == null ? null : (await v2.entities('restaurant.maitre'))['maitre:$pdv'];
    final settings = pdv == null ? null : (await v2.entities('restaurant.reglages'))['reglages:$pdv'];
    final epoch = int.tryParse(await v2.read(V2Keys.epoch) ?? '');
    final restricted = ((_state?['fonctions_restreintes'] as List?) ?? const []).cast<Map>().where((f) => f['fonction'] == 'restaurant.commande').firstOrNull;
    String? reason;
    if (pdv == null) {
      reason = 'Ce terminal n’est rattaché à aucun point de vente restaurant.';
    } else if (block['maitre'] != true) {
      reason = 'Cette caisse n’est pas la caisse maîtresse du point de vente : commandes en lecture seule.';
    } else if (designation == null ||
        designation['appareil_uuid'] != _device['uuid'] ||
        designation['epoque'] != epoch ||
        designation['generation'] != generation) {
      // Désaccord entre /etat et la désignation publiée : le plus restrictif l'emporte.
      reason = 'Désignation de la caisse maîtresse pas encore reçue sur ce terminal : synchronisez-le.';
    } else if (restricted != null) {
      reason = ((restricted['raison'] as Map?)?['message'] as String?) ?? 'Commandes restaurant suspendues sur ce terminal.';
    }
    final rooms = [
      for (final e in (await v2.entities('restaurant.salle')).entries)
        if (e.value['actif'] == true) RestoRoom(uuid: e.key, code: e.value['code'] as String, name: e.value['nom'] as String, order: e.value['ordre'] as int),
    ]..sort((a, b) => a.order != b.order ? a.order.compareTo(b.order) : a.name.compareTo(b.name));
    final roomUuids = {for (final r in rooms) r.uuid};
    final tables = [
      for (final e in (await v2.entities('restaurant.table')).entries)
        if (e.value['actif'] == true && (e.value['point_de_vente_uuid'] == null || e.value['point_de_vente_uuid'] == pdv) &&
            (e.value['salle_uuid'] == null || roomUuids.contains(e.value['salle_uuid'])))
          RestoTable(
            uuid: e.key,
            roomUuid: e.value['salle_uuid'] as String?,
            name: e.value['nom'] as String,
            code: e.value['code'] as String?,
            capacity: e.value['capacite'] as int?,
            order: e.value['ordre'] as int,
          ),
    ]..sort((a, b) => a.order != b.order ? a.order.compareTo(b.order) : a.name.compareTo(b.name));
    final menus = [
      for (final e in (await v2.entities('restaurant.menu')).entries)
        if (e.value['actif'] == true)
          RestoMenu(
            uuid: e.key,
            name: e.value['nom'] as String,
            products: {...(e.value['produits'] as List).cast<String>()},
            categories: {...(e.value['categories'] as List).cast<String>()},
          ),
    ];
    final lastNumbers = (block['derniers_numeros'] as Map?)?.cast<String, dynamic>();
    final stations = {
      for (final e in (await v2.entities('restaurant.poste')).entries)
        e.key: RestoStation(
          uuid: e.key,
          code: e.value['code'] as String,
          name: e.value['nom'] as String,
          screen: e.value['ecran'] == true,
          paper: e.value['papier'] == true,
          active: e.value['actif'] == true,
          order: e.value['ordre'] as int,
          flow: e.value['flux'] as String,
        ),
    };
    final printers = jsonDecode(await v2.read(_printersKey) ?? '{}') as Map;
    _restoPrinters
      ..clear()
      ..addAll(printers.cast<String, String>());
    return RestoContext(
      pointOfSaleUuid: pdv,
      pointOfSaleName: pointOfSale?['nom'] as String?,
      profile: (pointOfSale?['profil'] ?? block['profil']) as String?,
      master: reason == null,
      generation: generation,
      notMasterReason: reason,
      settings: settings == null ? const RestoSettings() : RestoSettings.fromJson(settings),
      rooms: rooms,
      tables: tables,
      menus: menus,
      hiddenCategories: {
        for (final e in (await v2.entities('restaurant.categorie')).entries)
          if (e.value['visible'] == false) e.key,
      },
      lastOrderNumber: lastNumbers?['commande'] as String?,
      stations: stations,
      routes: {for (final e in (await v2.entities('restaurant.routage')).entries) e.key: e.value['poste_effectif_uuid'] as String?},
      lastTicketNumbers: {
        for (final b in ((lastNumbers?['bons'] as List?) ?? const []).cast<Map>()) b['poste_uuid'] as String: b['numero_jour'] as String,
      },
    );
  }

  String? _restaurantBlocker(Operator operator) {
    final ctx = _resto;
    if (ctx == null) return _unavailable;
    if (ctx.profile == null) return 'Ce point de vente est en mode Boutique : aucune commande à table.';
    if (!ctx.tableService) return 'Profil Restaurant (production) : pas encore disponible hors ligne, utilisez la caisse web.';
    if (!ctx.master) return ctx.notMasterReason;
    if (!hasRight(operator, 'caisse_table')) return '${operator.name} n’a pas le droit de prendre des commandes.';
    return blockReason;
  }

  RestoContext _requireResto(Operator operator) {
    final reason = _restaurantBlocker(operator);
    if (reason != null) throw OfflineRefusal(reason);
    return _resto!;
  }

  RestoVat get _restoVat => RestoVat(rate: _vat?.rate ?? '0.000000', included: _vat?.included ?? true);

  /// Commandes de la file, groupées par uuid, dernière version de chacune.
  Future<Map<String, _RestoTrack>> _restoTracks() async {
    final tracks = <String, _RestoTrack>{};
    final rows = await v2.operationsOfType('resto_commande');
    for (final row in rows) {
      final operation = row['operation'] as Map;
      final content = operation['contenu'] as Map;
      final uuid = content['commande_uuid'] as String;
      final track = tracks[uuid] ??= _RestoTrack(uuid);
      final version = content['version'] as int;
      if (track.order == null || version > track.order!.version) {
        track.order = RestoOrder.fromState(uuid, version, content['etat'] as Map);
      }
      final state = row['etat'] as String;
      if (V2OperationState.unsent.contains(state)) track.pending++;
      final reason = row['raison'] as Map?;
      if (state != V2OperationState.integrated && state != V2OperationState.resolved && reason != null) {
        track.message = reason['message'] as String?;
        if (reason['code'] == 'restaurant.attente_version') track.waiting = true;
      }
      if (state == V2OperationState.rejected || state == V2OperationState.arbitration) track.blocked = true;
      if (version == 1 && row['numero_serveur'] != null) track.serverNumber = row['numero_serveur'] as String;
    }
    _restoReceiveMoves(tracks, rows);
    return tracks;
  }

  /// Q9 (R-4) : un déplacement ou une fusion est une opération de la SOURCE ; la cible ne consomme pas de version. Tant que
  /// la cible est à `version_cible`, son état courant est celui de sa dernière version plus les lignes reçues (et, pour
  /// une fusion, couverts, remises et client) ; sa version suivante, enregistrée depuis cet état, les porte.
  void _restoReceiveMoves(Map<String, _RestoTrack> tracks, List<Map<String, dynamic>> rows) {
    final states = <String, Map<int, Map>>{};
    final moves = <String, List<(String, int, String, Map)>>{};
    for (final row in rows) {
      final content = (row['operation'] as Map)['contenu'] as Map;
      final uuid = content['commande_uuid'] as String;
      final version = content['version'] as int;
      (states[uuid] ??= {})[version] = content['etat'] as Map;
      final action = content['action'] as String;
      if (action == 'deplacement_lignes' || action == 'fusion') {
        final fact = content['fait'] as Map;
        (moves[fact['vers_commande_uuid'] as String] ??= []).add((uuid, version, action, fact));
      }
    }
    if (moves.isEmpty) return;
    final memo = <String, RestoOrder?>{};
    // État d'une commande à une version, lignes reçues comprises ; la source est relue juste avant son geste (récursion
    // vers des opérations toujours plus anciennes de la file).
    RestoOrder? at(String uuid, int version) {
      final key = '$uuid|$version';
      if (memo.containsKey(key)) return memo[key];
      final state = states[uuid]?[version];
      if (state == null) return memo[key] = null;
      var order = RestoOrder.fromState(uuid, version, state);
      for (final (source, sourceVersion, action, fact) in moves[uuid] ?? const <(String, int, String, Map)>[]) {
        if (fact['version_cible'] != version) continue;
        final before = at(source, sourceVersion - 1);
        if (before != null) order = RestoEngine.receive(order, before, action, fact);
      }
      return memo[key] = order;
    }

    for (final track in tracks.values) {
      if (moves.containsKey(track.uuid)) track.order = at(track.uuid, track.order!.version) ?? track.order;
    }
  }

  /// Ventes de ce terminal qui règlent une commande (hors quarantaine).
  Future<Set<String>> _paidOrders() async => {
    for (final row in await v2.operationsOfType('vente'))
      if (row['etat'] != V2OperationState.rejected)
        if (((row['operation'] as Map)['contenu'] as Map)['commande'] case final Map order) order['commande_uuid'] as String,
  };

  RestoOrderView _restoView(_RestoTrack track, Set<String> paid, {List<RestoTicket> tickets = const [], int toCheck = 0}) => RestoOrderView(
    order: track.order!,
    payable: track.order!.totals(_restoVat).payable,
    paid: paid.contains(track.uuid) && track.order!.isOpen,
    pendingVersions: track.pending,
    serverMessage: track.message,
    waiting: track.waiting,
    serverNumber: track.serverNumber,
    tickets: tickets,
    ticketsToCheck: toCheck,
  );

  Future<List<RestoOrderView>> _restaurantOrders({bool all = false}) async {
    if (_resto == null) return const [];
    final tracks = await _restoTracks();
    final paid = await _paidOrders();
    final toCheck = <String, int>{};
    for (final t in await _restoTicketViews()) {
      if (t.state == RestoDeliveryState.toCheck || t.state == RestoDeliveryState.failed) toCheck[t.ticket.orderUuid] = (toCheck[t.ticket.orderUuid] ?? 0) + 1;
    }
    return [
      for (final t in tracks.values)
        if (all || t.order!.isOpen) _restoView(t, paid, toCheck: toCheck[t.uuid] ?? 0),
    ];
  }

  Future<RestoOrder> _restoOrder(String uuid) async {
    final track = (await _restoTracks())[uuid];
    if (track == null) throw const OfflineRefusal('Commande introuvable sur ce terminal.');
    return track.order!;
  }

  /// Bons portés par un fait de commande de la file (`envoi`, `annulation_ligne`, `annulation`).
  static List<Map> _ticketsOf(Map content) => ((content['fait'] as Map?)?['bons'] as List? ?? const []).cast<Map>();

  /// Moteur pur, avec les compteurs repris de la file et des derniers numéros reçus par le serveur (jamais réutilisés) :
  /// numéro local des commandes, numéro des bons par (commande, poste), numéro du jour par poste.
  Future<RestoEngine> _restoEngine(RestoContext ctx) async {
    final counters = RestoCounters();
    void atLeast(String key, int value) {
      if ((counters.values[key] ?? 0) < value) counters.values[key] = value;
    }

    void seen(String? number) {
      final parsed = RestoEngine.parseLocalNumber(number);
      if (parsed != null) atLeast('commande|${parsed.$1}', parsed.$2);
    }

    void seenDay(String station, String? dayNumber) {
      final m = RegExp(r'-([0-9]{8})-([0-9]{4,6})$').firstMatch(dayNumber ?? '');
      if (m != null) atLeast('jour|$station|${m.group(1)}', int.parse(m.group(2)!));
    }

    for (final row in await v2.operationsOfType('resto_commande')) {
      final content = (row['operation'] as Map)['contenu'] as Map;
      seen((content['etat'] as Map)['numero_local'] as String?);
      for (final b in _ticketsOf(content)) {
        atLeast('bon|${content['commande_uuid']}|${b['poste_uuid']}', b['numero'] as int);
        seenDay(b['poste_uuid'] as String, b['numero_jour'] as String?);
      }
    }
    seen(ctx.lastOrderNumber);
    ctx.lastTicketNumbers.forEach(seenDay);
    return RestoEngine(
      newUuid: _newUuid,
      now: () => now,
      stations: ctx.stations,
      counters: counters,
      sendToStations: ctx.settings.sendToProduction,
      vat: _restoVat,
      cancellationReasonRequired: ctx.settings.cancellationReason,
    );
  }

  /// Enregistre le fait rendu par le moteur : opération `resto_commande`, validée contre le contrat, dans la file. Les
  /// bons créés sont rendus dans la vue, à livrer ([_restoDeliver]) une fois le fait enregistré.
  Future<RestoOrderView> _restoRecord(RestoContext ctx, Operator operator, RestoResult result, {List<RestoApproval> approvals = const []}) async {
    final event = result.event;
    await _record(event.uuid, 'resto_commande', operator, (_) => {
      'maitre_generation': ctx.generation,
      'point_de_vente_uuid': ctx.pointOfSaleUuid,
      'commande_uuid': result.order.uuid,
      'version': event.version,
      'action': event.action,
      'fait': event.fact,
      'motif': event.reason,
      'autorisations': event.authorizations,
      'etat': event.state,
    });
    if (approvals.isNotEmpty) await _restoLedgerAdd(approvals);
    await _afterWrite();
    final track = (await _restoTracks())[result.order.uuid]!;
    return _restoView(track, await _paidOrders(), tickets: event.tickets);
  }

  /// Fait sur une commande existante : relue dans la file (jamais l'objet de l'écran), ouverte, sans version bloquée.
  /// Les bons créés partent vers leurs postes après l'enregistrement, hors du verrou de la file.
  Future<RestoOrderView> _restoAct(
    Operator operator,
    String orderUuid,
    RestoResult Function(RestoEngine engine, RestoOrder order) act, {
    List<RestoApproval> approvals = const [],
  }) async {
    final view = await serialized(() async {
      final ctx = _requireResto(operator);
      final tracks = await _restoTracks();
      final track = tracks[orderUuid] ?? (throw const OfflineRefusal('Commande introuvable sur ce terminal.'));
      if (track.blocked) {
        throw OfflineRefusal('Cette commande attend un arbitrage de la boutique${track.message == null ? '' : ' : ${track.message}'}');
      }
      if ((await _paidOrders()).contains(orderUuid)) throw const OfflineRefusal('Commande déjà réglée : elle ne se modifie plus.');
      try {
        return await _restoRecord(ctx, operator, act(await _restoEngine(ctx), track.order!), approvals: approvals);
      } on RestoRefusal catch (e) {
        throw OfflineRefusal(e.message);
      }
    });
    if (view.tickets.isNotEmpty) await _restoDeliver(operator, view.tickets);
    return view;
  }

  // ---------------------------------------------------------------- envoi et annulation d'un envoyé (R-3)

  Future<RestoOrderView> _restoSend(Operator operator, String orderUuid) {
    final routes = _resto?.routes ?? const <String, String?>{};
    return _restoAct(operator, orderUuid, (engine, order) => engine.send(order, route: (product) => routes[product]));
  }

  /// Annuler un article annoncé : droit `resto_modifier_envoye`, sinon (et toujours avec `annulation_envoye_responsable`)
  /// l'autorisation d'un approbateur restaurant, motif dans les deux cas (§4.3 bis).
  bool _restoApprovalRequired(Operator operator) =>
      !hasRight(operator, 'resto_modifier_envoye') || (_resto?.settings.sentCancelNeedsApprover ?? false);

  List<Map<String, dynamic>> _restoAuthorizations(Operator operator, RestoApproval? approval, String reason) {
    if (!_restoApprovalRequired(operator)) return const [];
    if (approval == null) throw const OfflineRefusal('Article déjà envoyé : l’autorisation d’un responsable est requise.');
    if (approval.approverId == operator.id) throw const OfflineRefusal('Le responsable doit être une autre personne que l’opérateur.');
    if (approval.reason != reason.trim()) throw const OfflineRefusal('Le motif a changé depuis l’autorisation : faites-la de nouveau.');
    return [approval.toJson()];
  }

  Future<RestoOrderView> _restoCancelLine(Operator operator, String orderUuid, String lineUuid, int quantity, String reason, {RestoApproval? approval}) async {
    final authorizations = _restoAuthorizations(operator, approval, reason);
    return _restoAct(
      operator,
      orderUuid,
      (engine, order) => engine.cancelLine(order, lineUuid, quantity, reason, authorizations: authorizations),
      approvals: [if (authorizations.isNotEmpty) approval!],
    );
  }

  Future<RestoOrderView> _restoCancel(Operator operator, String orderUuid, String? reason, {RestoApproval? approval}) => _restoAct(
    operator,
    orderUuid,
    (engine, order) {
      // Le droit ou l'autorisation ne sont exigés que si des articles sont annoncés aux postes.
      final authorizations = RestoEngine.hasAnnounced(order) ? _restoAuthorizations(operator, approval, reason ?? '') : const <Map<String, dynamic>>[];
      return engine.cancelOrder(order, reason, authorizations: authorizations);
    },
    approvals: [if (approval != null && _restoApprovalRequired(operator)) approval],
  );

  Future<List<Map<String, dynamic>>> _restoLedger() async {
    final day = _restoDay();
    return [
      for (final e in (jsonDecode(await v2.read(_approvalLedgerKey) ?? '[]') as List).cast<Map>())
        if (e['j'] == day) e.cast<String, dynamic>(),
    ];
  }

  Future<void> _restoLedgerAdd(List<RestoApproval> approvals) async {
    final day = _restoDay();
    await v2.write(_approvalLedgerKey, jsonEncode([
      ...await _restoLedger(),
      for (final a in approvals) {'a': a.approverId, 'j': day, 'm': a.amount},
    ]));
  }

  String _restoDay() => PassDay.of(now, _resto?.settings.timezone ?? _shopRules?['fuseau'] as String?);

  /// Approbateurs restaurant de ce terminal pour une annulation de [amount] F : autre personne que l'opérateur, manager
  /// ou assistant qui détient lui-même `resto_modifier_envoye`, avec un code publié ; un assistant dans ses plafonds.
  Future<List<Operator>> _restoApprovers(Operator cashier, int amount, {String type = 'resto_modifier_envoye', int? percent}) async {
    final ctx = _resto;
    if (ctx == null) return const [];
    final caps = ctx.settings.assistant;
    final ledger = await _restoLedger();
    final right = _restoRightOf(type);
    bool within(Operator o) {
      if (o.restaurantApprover == 'manager') return true;
      // Remise (R-4) : pourcentage de la ligne ou de la commande, arrondi au supérieur ; 0 = l'assistant n'en autorise pas.
      if (percent != null && percent > caps.maxDiscountPercent) return false;
      final mine = [for (final e in ledger) if (e['a'] == o.id) e['m'] as int];
      if (caps.amountPerOperation > 0 && amount > caps.amountPerOperation) return false;
      if (caps.operationsPerDay > 0 && mine.length >= caps.operationsPerDay) return false;
      if (caps.amountPerDay > 0 && mine.fold<int>(0, (s, m) => s + m) + amount > caps.amountPerDay) return false;
      return true;
    }

    return [
      for (final o in snapshot?.operators ?? const <Operator>[])
        if (o.id != cashier.id &&
            (o.restaurantApprover == 'manager' || o.restaurantApprover == 'assistant') &&
            (o.approvalCodeHash?.isNotEmpty ?? false) &&
            hasRight(o, right) &&
            within(o))
          o,
    ];
  }

  Future<RestoApproval> _restoAuthorize({
    required Operator cashier,
    required Operator approver,
    required String code,
    required String reason,
    required int amount,
    String type = 'resto_modifier_envoye',
    int? percent,
  }) async {
    final cancel = type == 'resto_modifier_envoye' || type == 'resto_annuler_commande';
    if (!(await _restoApprovers(cashier, amount, type: type, percent: percent)).any((o) => o.id == approver.id)) {
      throw OfflineRefusal('${approver.name} ne peut pas autoriser ${cancel ? 'cette annulation' : 'ce geste'} (droit, code ou plafonds).');
    }
    final motive = reason.trim();
    if (motive.length < 3 || motive.length > 500) throw OfflineRefusal('Indiquez le motif ${cancel ? 'de l’annulation' : 'du geste'} (3 à 500 caractères).');
    final wait = await approvalLockedFor(approver);
    if (wait != null) throw OfflineRefusal('Trop d’essais : réessayez dans ${wait.inSeconds + 1} s.');
    if (!await checkApprovalCode(approver, code)) throw const OfflineRefusal('Code d’autorisation incorrect.');
    return RestoApproval(approverId: approver.id, type: type, reason: motive, verifiedAt: now.toUtc().toIso8601String(), amount: amount);
  }

  // ---------------------------------------------------------------- gestes sur une commande (R-4)

  /// Droit de l'opérateur qui dispense d'autorisation, par type d'autorisation (§4.3 bis).
  static String _restoRightOf(String type) => switch (type) {
    'resto_offrir' => 'resto_offrir',
    'remise' => 'remise',
    _ => 'resto_modifier_envoye',
  };

  /// Remise de commande hors ligne : `restaurant.table_service_discount_max_percent` (Service de table) et
  /// `restaurant.order_discount_max_percent` (Restaurant) ne sont pas publiés ; la caisse applique leur valeur par défaut
  /// du web (100 % et 20 %), le serveur revérifie avec la valeur de la boutique.
  static int _restoOrderDiscountPercent(RestoOrder order) => order.profile == 'PRODUCTION' ? 20 : 100;

  /// [type] (`resto_offrir`, `remise`) exige-t-il l'autorisation d'un responsable pour [operator] ? Les gestes R-4 ne
  /// suivent pas `annulation_envoye_responsable` (droit OU autorisation).
  bool _restoNeedsApproval(Operator operator, String type) =>
      type == 'resto_modifier_envoye' || type == 'resto_annuler_commande' ? _restoApprovalRequired(operator) : !hasRight(operator, _restoRightOf(type));

  List<Map<String, dynamic>> _restoGestureAuthorizations(Operator operator, String type, RestoApproval? approval, String reason) {
    if (!_restoNeedsApproval(operator, type)) return const [];
    if (approval == null || approval.type != type) {
      throw OfflineRefusal('${operator.name} n’a pas le droit ${type == 'resto_offrir' ? 'd’offrir un article' : 'd’accorder une remise'} : l’autorisation d’un responsable est requise.');
    }
    if (approval.approverId == operator.id) throw const OfflineRefusal('Le responsable doit être une autre personne que l’opérateur.');
    if (approval.reason != reason.trim()) throw const OfflineRefusal('Le motif a changé depuis l’autorisation : faites-la de nouveau.');
    return [approval.toJson()];
  }

  /// Une autorisation vaut pour le montant vérifié (plafonds de l'assistant), pas pour un autre.
  static void _restoSameAmount(List<Map<String, dynamic>> authorizations, RestoApproval? approval, int Function() amount) {
    if (authorizations.isNotEmpty && approval!.amount != amount()) throw const OfflineRefusal('Le montant a changé depuis l’autorisation : faites-la de nouveau.');
  }

  Future<RestoOrderView> _restoOffer(Operator operator, String orderUuid, String lineUuid, String reason, {RestoApproval? approval}) async {
    final authorizations = _restoGestureAuthorizations(operator, 'resto_offrir', approval, reason);
    return _restoAct(
      operator,
      orderUuid,
      (engine, order) {
        _restoSameAmount(authorizations, approval, () => order.line(lineUuid).gross);
        return engine.offer(order, lineUuid, reason, authorizations: authorizations);
      },
      approvals: [if (authorizations.isNotEmpty) approval!],
    );
  }

  Future<RestoOrderView> _restoDiscountLine(Operator operator, String orderUuid, String lineUuid, {required bool percent, required int value, required String reason, RestoApproval? approval}) async {
    final authorizations = _restoGestureAuthorizations(operator, 'remise', approval, reason);
    return _restoAct(
      operator,
      orderUuid,
      (engine, order) {
        _restoSameAmount(authorizations, approval, () => RestoEngine.lineDiscountOf(order.line(lineUuid), percent: percent, value: value));
        return engine.discountLine(order, lineUuid, percent: percent, value: value, reason: reason, authorizations: authorizations);
      },
      approvals: [if (authorizations.isNotEmpty) approval!],
    );
  }

  /// Remise de commande ; [amount] = 0 la retire (droit REMISE de l'opérateur, sans motif ni autorisation possible).
  Future<RestoOrderView> _restoDiscountOrder(Operator operator, String orderUuid, int amount, {String? reason, RestoApproval? approval}) async {
    if (amount == 0 && !hasRight(operator, 'remise')) throw OfflineRefusal('${operator.name} n’a pas le droit de retirer la remise de la commande.');
    final authorizations = amount > 0 ? _restoGestureAuthorizations(operator, 'remise', approval, reason ?? '') : const <Map<String, dynamic>>[];
    return _restoAct(
      operator,
      orderUuid,
      (engine, order) {
        _restoSameAmount(authorizations, approval, () => amount);
        return engine.discountOrder(order, amount, reason: reason, maxPercent: _restoOrderDiscountPercent(order), authorizations: authorizations);
      },
      approvals: [if (authorizations.isNotEmpty) approval!],
    );
  }

  /// Plafond de la remise de commande pour [order] (montant après remises de ligne × plafond du profil).
  int _restoOrderDiscountCeiling(RestoOrder order) => RestoEngine.orderDiscountCeiling(order, _restoOrderDiscountPercent(order));

  /// Déplacement de lignes ([lines]) ou fusion (null) de [sourceUuid] vers [targetUuid] : une opération sur la source,
  /// qui cite la version courante de la cible (lignes reçues comprises).
  Future<RestoOrderView> _restoMoveOrMerge(Operator operator, String sourceUuid, String targetUuid, {Set<String>? lines, String? reason}) => serialized(() async {
    final ctx = _requireResto(operator);
    final tracks = await _restoTracks();
    final source = tracks[sourceUuid] ?? (throw const OfflineRefusal('Commande introuvable sur ce terminal.'));
    final target = tracks[targetUuid] ?? (throw const OfflineRefusal('Commande de destination introuvable sur ce terminal.'));
    for (final t in [source, target]) {
      if (t.blocked) throw OfflineRefusal('La commande ${t.order!.localNumber} attend un arbitrage de la boutique.');
    }
    final paid = await _paidOrders();
    if (paid.contains(sourceUuid) || paid.contains(targetUuid)) throw const OfflineRefusal('Une des deux commandes est déjà réglée : elle ne se modifie plus.');
    try {
      final engine = await _restoEngine(ctx);
      return await _restoRecord(ctx, operator, lines == null ? engine.merge(source.order!, target.order!, reason: reason) : engine.moveLines(source.order!, target.order!, lines));
    } on RestoRefusal catch (e) {
      throw OfflineRefusal(e.message);
    }
  });

  // ---------------------------------------------------------------- livraison des bons (R-3, plan §2)

  String _restoStamp() => '${now.toUtc().toIso8601String().substring(0, 19)}Z';

  Future<List<Map<String, dynamic>>> _restoJournalRead() async =>
      [for (final e in (jsonDecode(await v2.read(_ticketJournalKey) ?? '[]') as List).cast<Map>()) e.cast<String, dynamic>()];

  /// Garde les événements à remonter et les 1 000 derniers remontés (état de livraison affiché).
  Future<void> _restoJournalWrite(List<Map<String, dynamic>> journal) async {
    final sent = journal.where((e) => e['r'] == true).length;
    var drop = sent > 1000 ? sent - 1000 : 0;
    await v2.write(_ticketJournalKey, jsonEncode([
      for (final e in journal)
        if (e['r'] != true || drop-- <= 0) e,
    ]));
  }

  Future<void> _restoJournalAdd(Operator operator, Map<String, dynamic> event, {String? localOutcome}) => serialized(() async {
    final ctx = _resto;
    if (ctx == null) return;
    await _restoJournalWrite([
      ...await _restoJournalRead(),
      {'e': {'evenement_uuid': _newUuid(), ...event}, 'g': ctx.generation, 'o': '${operator.id}', 'r': false, 'x': ?localOutcome},
    ]);
  });

  /// Une cible : écran du poste (afficheur, absent d'Android : échec certain), imprimante du poste (adresse locale), ou
  /// imprimante de la caisse.
  Future<RestoOutcome> _restoSendTo(RestoTicket ticket, RestoStation station, RestoTarget target, {bool duplicate = false}) async {
    final ctx = _resto!;
    final order = (await _restoTracks())[ticket.orderUuid]?.order;
    final text = ticket.printLines(
      stationName: station.name,
      orderNumber: order?.localNumber ?? '',
      table: ctx.table(order?.tableUuid)?.name,
      columns: restoTicketColumns,
      duplicate: duplicate,
    );
    try {
      switch (target) {
        case RestoTarget.ecranPoste:
          final screen = restoStationScreen;
          return screen == null ? RestoOutcome.nonEnvoye : await screen(ticket, station);
        case RestoTarget.imprimantePoste:
          final address = _restoPrinters[station.uuid];
          if (address == null) return RestoOutcome.nonEnvoye;
          return await (restoStationPrinter ?? _restoLanPrint)(address, text);
        case RestoTarget.imprimanteCaisse:
          final printer = restoRegisterPrinter;
          return printer == null ? RestoOutcome.nonEnvoye : await printer(text);
      }
    } catch (_) {
      // Une exception après le départ possible d'octets : issue inconnue, jamais relancée.
      return RestoOutcome.aVerifier;
    }
  }

  /// Imprimante réseau ESC/POS (port 9100 par défaut) : connexion refusée = rien n'est parti ; erreur après la connexion
  /// = issue inconnue.
  static Future<RestoOutcome> _restoLanPrint(String address, List<String> text) async {
    final at = address.lastIndexOf(':');
    final host = at > 0 ? address.substring(0, at) : address;
    final port = at > 0 ? int.tryParse(address.substring(at + 1)) ?? 9100 : 9100;
    final Socket socket;
    try {
      socket = await Socket.connect(host, port, timeout: const Duration(seconds: 4));
    } catch (_) {
      return RestoOutcome.nonEnvoye;
    }
    try {
      socket.add(offlineTicketBytes([for (final line in text) stripAccents(line)]));
      await socket.flush().timeout(const Duration(seconds: 8));
      await socket.close().timeout(const Duration(seconds: 4));
      return RestoOutcome.transmis;
    } catch (_) {
      socket.destroy();
      return RestoOutcome.aVerifier;
    }
  }

  /// Livre chaque bon sur toutes les cibles de son poste, puis la chaîne de secours si toutes ont échoué avant tout
  /// octet ; « à vérifier » gèle le bon (jamais de relance). Chaque tentative est notée au journal.
  Future<void> _restoDeliver(Operator operator, List<RestoTicket> tickets) async {
    final ctx = _resto;
    if (ctx == null) return;
    for (final ticket in tickets) {
      final station = ctx.stations[ticket.stationUuid];
      if (station == null) continue;
      final attempts = <RestoAttempt>[];
      for (var plan = RestoDelivery.next(station, attempts); plan.isNotEmpty; plan = RestoDelivery.next(station, attempts)) {
        for (final (target, fallback) in plan) {
          final outcome = await _restoSendTo(ticket, station, target);
          attempts.add(RestoAttempt(target, outcome, fallback: fallback));
          await _restoJournalAdd(operator, {
            'type': 'livraison',
            'bon_uuid': ticket.uuid,
            'tentative_uuid': _newUuid(),
            'cible': target.code,
            'resultat': outcome.code,
            'secours': fallback,
            'le': _restoStamp(),
          });
        }
      }
    }
    await _restoFlush();
    notifyListeners();
  }

  /// Bons de la file (commandes de ce terminal) et état de leur livraison, du plus récent au plus ancien.
  Future<List<RestoTicketView>> _restoTicketViews({String? orderUuid}) async {
    final ctx = _resto;
    if (ctx == null) return const [];
    final events = <String, List<Map<String, dynamic>>>{};
    for (final e in await _restoJournalRead()) {
      (events[(e['e'] as Map)['bon_uuid'] as String] ??= []).add(e);
    }
    final tracks = await _restoTracks();
    final views = <RestoTicketView>[];
    for (final row in await v2.operationsOfType('resto_commande')) {
      final content = (row['operation'] as Map)['contenu'] as Map;
      final order = content['commande_uuid'] as String;
      if (orderUuid != null && order != orderUuid) continue;
      for (final b in _ticketsOf(content)) {
        final ticket = RestoTicket.fromJson(order, b);
        final mine = events[ticket.uuid] ?? const [];
        final deliveries = [for (final e in mine) if ((e['e'] as Map)['type'] == 'livraison') e['e'] as Map];
        final checks = {for (final e in mine) if ((e['e'] as Map)['type'] == 'verification') (e['e'] as Map)['tentative_uuid']: (e['e'] as Map)['constat']};
        final duplicated = mine.any((e) => (e['e'] as Map)['type'] == 'duplicata' && (e['x'] == 'transmis' || e['x'] == 'accuse'));
        final unknown = [for (final d in deliveries) if (d['resultat'] == 'a_verifier' && !checks.containsKey(d['tentative_uuid'])) d['tentative_uuid'] as String];
        final reached = deliveries.any((d) => d['resultat'] == 'accuse' || d['resultat'] == 'transmis') || checks.values.contains('sorti') || duplicated;
        final state = unknown.isNotEmpty
            ? RestoDeliveryState.toCheck
            : reached
            ? RestoDeliveryState.delivered
            : deliveries.isEmpty && checks.isEmpty
            ? RestoDeliveryState.pending
            : RestoDeliveryState.failed;
        final track = tracks[order]?.order;
        views.add(RestoTicketView(
          ticket: ticket,
          stationName: ctx.stations[ticket.stationUuid]?.name ?? 'Poste',
          orderNumber: track?.localNumber ?? '',
          table: ctx.table(track?.tableUuid)?.name,
          state: state,
          checkAttempt: unknown.firstOrNull,
          checked: checks.isNotEmpty,
        ));
      }
    }
    return views.reversed.toList();
  }

  /// Vérification sur place d'une livraison à l'issue inconnue : c'est elle qui fait tomber l'alerte côté serveur.
  Future<void> _restoVerify(Operator operator, String ticketUuid, {required bool printed}) async {
    _requireResto(operator);
    final view = (await _restoTicketViews()).where((t) => t.ticket.uuid == ticketUuid).firstOrNull ?? (throw const OfflineRefusal('Bon introuvable sur ce terminal.'));
    final attempt = view.checkAttempt ?? (throw const OfflineRefusal('Rien à vérifier pour ce bon.'));
    await _restoJournalAdd(operator, {
      'type': 'verification',
      'bon_uuid': ticketUuid,
      'tentative_uuid': attempt,
      'constat': printed ? 'sorti' : 'non_sorti',
      'operateur_id': '${operator.id}',
      'le': _restoStamp(),
    });
    await _restoFlush();
    notifyListeners();
  }

  /// Réimpression demandée par un opérateur (DUPLICATA, autre identifiant) : imprimante du poste si elle est réglée,
  /// sinon celle de la caisse.
  Future<RestoOutcome> _restoDuplicate(Operator operator, String ticketUuid, String reason) async {
    final ctx = _requireResto(operator);
    final motive = reason.trim();
    if (motive.length < 3 || motive.length > 500) throw const OfflineRefusal('Indiquez le motif de la réimpression (3 à 500 caractères).');
    final view = (await _restoTicketViews()).where((t) => t.ticket.uuid == ticketUuid).firstOrNull ?? (throw const OfflineRefusal('Bon introuvable sur ce terminal.'));
    final station = ctx.stations[view.ticket.stationUuid] ?? (throw const OfflineRefusal('Poste de ce bon inconnu sur ce terminal.'));
    var target = station.paper && _restoPrinters.containsKey(station.uuid) ? RestoTarget.imprimantePoste : RestoTarget.imprimanteCaisse;
    var outcome = await _restoSendTo(view.ticket, station, target, duplicate: true);
    if (outcome == RestoOutcome.nonEnvoye && target == RestoTarget.imprimantePoste) {
      target = RestoTarget.imprimanteCaisse;
      outcome = await _restoSendTo(view.ticket, station, target, duplicate: true);
    }
    await _restoJournalAdd(operator, {
      'type': 'duplicata',
      'bon_uuid': ticketUuid,
      'duplicata_uuid': _newUuid(),
      'cible': target.code,
      'motif': motive,
      'operateur_id': '${operator.id}',
      'le': _restoStamp(),
    }, localOutcome: outcome.code);
    await _restoFlush();
    notifyListeners();
    return outcome;
  }

  /// Remonte le journal par lots `resto_bons_etats` (200 événements au plus) : au plus un lot toutes les 10 s, vidé à la
  /// clôture d'une commande ou de la session ([force]). Seule la caisse maîtresse émet ; un lot par génération.
  Future<void> _restoFlush({bool force = false}) => serialized(() => _restoFlushLocked(force: force));

  /// [_restoFlush] déjà sous le verrou de la file (clôture de session).
  Future<void> _restoFlushLocked({bool force = false}) async {
    final ctx = _resto;
    if (ctx == null || !ctx.master || ctx.pointOfSaleUuid == null) return;
    final journal = await _restoJournalRead();
    final pending = [for (final e in journal) if (e['r'] != true) e];
    if (pending.isEmpty) return;
    final last = DateTime.tryParse(await v2.read(_ticketFlushKey) ?? '');
    if (!force && last != null && now.difference(last) < const Duration(seconds: 10) && !now.isBefore(last)) return;
    final byGeneration = <String, List<Map<String, dynamic>>>{};
    for (final e in pending) {
      (byGeneration[e['g'] as String] ??= []).add(e);
    }
    for (final entry in byGeneration.entries) {
      for (var i = 0; i < entry.value.length; i += 200) {
        final batch = entry.value.sublist(i, i + 200 > entry.value.length ? entry.value.length : i + 200);
        final id = int.parse(batch.last['o'] as String);
        final operator = snapshot?.operators.where((o) => o.id == id).firstOrNull ?? Operator({'id': id, 'nom': ''});
        await _record(_newUuid(), 'resto_bons_etats', operator, (_) => {
          'maitre_generation': entry.key,
          'point_de_vente_uuid': ctx.pointOfSaleUuid,
          'evenements': [for (final e in batch) e['e']],
        });
        for (final e in batch) {
          e['r'] = true;
        }
      }
    }
    await _restoJournalWrite(journal);
    await v2.write(_ticketFlushKey, now.toUtc().toIso8601String());
    await _afterWrite();
  }

  Future<void> _restoSetPrinter(String stationUuid, String? address) async {
    final value = address?.trim() ?? '';
    if (value.isNotEmpty && !RegExp(r'^[A-Za-z0-9.-]{1,253}(:[0-9]{1,5})?$').hasMatch(value)) {
      throw const OfflineRefusal('Adresse invalide : saisissez par exemple 192.168.1.50 ou 192.168.1.50:9100.');
    }
    if (value.isEmpty) {
      _restoPrinters.remove(stationUuid);
    } else {
      _restoPrinters[stationUuid] = value;
    }
    await v2.write(_printersKey, jsonEncode(_restoPrinters));
    notifyListeners();
  }

  Future<RestoOrderView> _restoOpen(Operator operator, String tableUuid, {int? covers}) => serialized(() async {
    final ctx = _requireResto(operator);
    final table = ctx.table(tableUuid) ?? (throw const OfflineRefusal('Table inconnue de ce point de vente.'));
    if (!ctx.settings.severalOrdersPerTable) {
      final busy = (await _restoTracks()).values.where((t) => t.order!.isOpen && t.order!.tableUuid == tableUuid).firstOrNull;
      if (busy != null) throw OfflineRefusal('La table ${table.name} a déjà une commande ouverte (${busy.order!.localNumber}).');
    }
    try {
      final engine = await _restoEngine(ctx);
      return await _restoRecord(
        ctx,
        operator,
        engine.open(
          prefix: ctx.settings.orderPrefix,
          businessDay: PassDay.of(now, ctx.settings.timezone ?? _shopRules?['fuseau'] as String?),
          profile: ctx.profile!,
          tableUuid: tableUuid,
          covers: covers,
          serverId: '${operator.id}',
        ),
      );
    } on RestoRefusal catch (e) {
      throw OfflineRefusal(e.message);
    }
  });

  /// Article ajouté : prix, libellé et coefficient du catalogue local au moment de l'ajout (tarif standard).
  RestoNewLine _restoNewLine(CartLine line, String? comment) {
    final productUuid = _productUuids[line.product.id] ?? (throw OfflineRefusal('« ${line.product.name} » n’est plus au catalogue local.'));
    final product = _products[productUuid]!;
    if (product['actif'] != true || product['vente_locale'] != true) throw OfflineRefusal('« ${product['nom']} » ne se vend qu’en ligne.');
    final packagingUuid = line.packaging == null ? null : (_packagingUuids[line.packaging!.id] ?? (throw OfflineRefusal('Conditionnement de « ${line.label} » retiré.')));
    final pack = packagingUuid == null ? null : _packagings[packagingUuid];
    if (packagingUuid != null && (pack == null || pack['actif'] != true)) throw OfflineRefusal('Conditionnement de « ${line.label} » retiré.');
    return RestoNewLine(
      productUuid: productUuid,
      packagingUuid: packagingUuid,
      label: pack == null ? product['nom'] as String : '${product['nom']} (${pack['nom']})',
      quantity: line.quantity.toInt(),
      coefficient: pack == null ? Decimal6.scale : Decimal6.parse(pack['coefficient'] as String),
      unitPrice: (pack?['prix'] ?? product['prix']) as int,
      comment: comment,
    );
  }

  /// Panier de règlement : une ligne par article actif, au prix figé de la commande ; chaque ligne est reliée à la
  /// sienne pour le règlement `full`.
  Future<List<CartLine>> _restoCart(String orderUuid) async {
    final order = await _restoOrder(orderUuid);
    final s = snapshot ?? (throw const OfflineRefusal('Aucun catalogue reçu.'));
    final lines = <CartLine>[];
    for (final l in order.activeLines) {
      final id = _ids[l.productUuid];
      final product = s.products.where((p) => p.id == id).firstOrNull ??
          (throw OfflineRefusal('« ${l.label} » n’est plus vendable sur ce terminal : réglez cette commande en ligne.'));
      final packagingId = l.packagingUuid == null ? null : _ids[l.packagingUuid];
      final packaging = packagingId == null ? null : product.packagings.where((p) => p.id == packagingId).firstOrNull;
      if (l.packagingUuid != null && packaging == null) throw OfflineRefusal('Conditionnement de « ${l.label} » retiré : réglez cette commande en ligne.');
      // Remise de la ligne de commande (offert, remise de ligne, R-4), de confiance à la vente.
      final line = CartLine(product: product, packaging: packaging, quantity: BigInt.from(l.quantity), fixedPrice: l.unitPrice, discount: l.lineDiscount);
      _restoCartLines[line] = (orderUuid, l.uuid);
      lines.add(line);
    }
    if (lines.isEmpty) throw const OfflineRefusal('Commande vide : rien à encaisser.');
    return lines;
  }

  Future<OfflineOperation> _restoSettle(Operator operator, String orderUuid, List<CartLine> lines, List<CartPayment> payments, {String? draftUuid}) async {
    _requireResto(operator);
    final tracks = await _restoTracks();
    final track = tracks[orderUuid] ?? (throw const OfflineRefusal('Commande introuvable sur ce terminal.'));
    final order = track.order!;
    if (!order.isOpen) throw const OfflineRefusal('Cette commande est close.');
    if ((await _paidOrders()).contains(orderUuid)) throw const OfflineRefusal('Commande déjà réglée.');
    // Règlement complet (Service de table) : exactement les lignes actives, quantités entières de la commande.
    final lineOf = <CartLine, String>{};
    final covered = <String, int>{};
    for (final l in lines) {
      final link = _restoCartLines[l];
      if (link == null || link.$1 != orderUuid) throw const OfflineRefusal('Panier différent de la commande : rouvrez l’encaissement.');
      lineOf[l] = link.$2;
      covered[link.$2] = (covered[link.$2] ?? 0) + l.quantity.toInt();
    }
    final expected = {for (final l in order.activeLines) l.uuid: l.quantity};
    if (covered.length != expected.length || expected.entries.any((e) => covered[e.key] != e.value)) {
      throw const OfflineRefusal('Le Service de table se règle en une fois, toute la commande : rouvrez l’encaissement.');
    }
    // R-4 : la vente reprend les remises de la commande, sans jamais les dépasser.
    final trusted = {for (final l in order.activeLines) l.uuid: l.lineDiscount};
    final discounts = <String, int>{};
    for (final l in lines) {
      discounts[lineOf[l]!] = (discounts[lineOf[l]!] ?? 0) + l.discount;
    }
    if (discounts.entries.any((e) => e.value > trusted[e.key]!)) throw const OfflineRefusal('Remise au-delà de celle de la commande : rouvrez l’encaissement.');
    // Règle du web : encaisser envoie ce qui est encore en attente, sans jamais refuser la vente.
    if (order.lines.any((l) => l.toSend > 0)) {
      try {
        await _restoSend(operator, orderUuid);
      } on OfflineRefusal {
        // Envoi impossible (commande bloquée…) : la vente reste permise, la commande garde ses articles en attente.
      }
    }
    final sale = await recordSale(lines, payments, operator, draftUuid: draftUuid,
        extras: SaleExtras(
          globalDiscount: order.globalDiscount,
          order: OrderSettlement(orderUuid: orderUuid, settlementUuid: _newUuid(), lineOf: lineOf, trustedLineDiscounts: trusted, trustedGlobalDiscount: order.globalDiscount),
        ));
    try {
      await _restoCloseNow(operator, orderUuid);
    } on OfflineRefusal {
      // La vente est faite : la commande reste « réglée, à clôturer » et se clôt depuis l'écran de salle.
    }
    return sale;
  }

  /// Clôture après la vente qui règle la commande (la vente précède la clôture dans la file) ; les états des bons en
  /// attente remontent avec elle.
  Future<RestoOrderView> _restoCloseNow(Operator operator, String orderUuid) async {
    final view = await serialized(() async {
      final ctx = _requireResto(operator);
      final track = (await _restoTracks())[orderUuid] ?? (throw const OfflineRefusal('Commande introuvable sur ce terminal.'));
      if (!(await _paidOrders()).contains(orderUuid)) throw const OfflineRefusal('Commande pas encore réglée : encaissez-la d’abord.');
      try {
        return await _restoRecord(ctx, operator, (await _restoEngine(ctx)).close(track.order!));
      } on RestoRefusal catch (e) {
        throw OfflineRefusal(e.message);
      }
    });
    await _restoFlush(force: true);
    return view;
  }
}
