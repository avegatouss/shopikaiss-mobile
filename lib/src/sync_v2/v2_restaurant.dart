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

  /// Opération de la dernière version (ordre de la file : une annulation de vente postérieure rouvre la commande).
  Map? lastOperation;
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

  /// Remboursement restaurant (RESTAURANT-1 §4.10, lot R-5).
  static const _refundType = 'resto_remboursement';

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
      channels: [
        for (final e in (await v2.entities('restaurant.canal')).entries) RestoChannel.fromJson(e.key, e.value),
      ]..sort((a, b) => a.order != b.order ? a.order.compareTo(b.order) : a.name.compareTo(b.name)),
      promotions: await _restoPromotions(),
      categoryParents: {
        for (final e in (await v2.entities('restaurant.categorie')).entries) e.key: e.value['parent_uuid'] as String?,
      },
      // Lot R-5 : remise par client, publiée seulement si le réglage est actif.
      customerDiscounts: {
        for (final e in (await v2.entities('restaurant.remise_client')).values) e['client_uuid'] as String: e['pourcent'] as int,
      },
    );
  }

  /// Promotions actives publiées (`restaurant.promotion`, lot R-5), sauf si la boutique annonce encore la fonction
  /// restreinte (`restaurant.promotions`, serveur antérieur au lot R-5). Ancienneté : révision de publication.
  Future<List<RestoPromotion>> _restoPromotions() async {
    final restricted = ((_state?['fonctions_restreintes'] as List?) ?? const []).cast<Map>().any((f) => f['fonction'] == 'restaurant.promotions');
    if (restricted) return const [];
    final revisions = await v2.revisions('restaurant.promotion');
    return [
      for (final e in (await v2.entities('restaurant.promotion')).entries)
        RestoPromotion.fromJson(e.key, e.value, rank: BigInt.tryParse(revisions[e.key] ?? '')),
    ];
  }

  /// Conditions des promotions figées à la saisie des lignes (`{ligne_uuid: {p: promotion_uuid, d: conditions}}`), pour
  /// un changement de quantité ultérieur (`refreshLine` du web). Gardées tant que la commande de la ligne est ouverte.
  static const _promotionTermsKey = 'v2.resto_promotions_figees';

  Future<Map<String, RestoPromotion>> _restoPromotionTerms() async {
    final raw = jsonDecode(await v2.read(_promotionTermsKey) ?? '{}') as Map;
    return {
      for (final e in raw.entries)
        e.key as String: RestoPromotion.fromJson((e.value as Map)['p'] as String, (e.value as Map)['d'] as Map),
    };
  }

  Future<void> _restoKeepPromotionTerms(Map<String, RestoPromotion> added, Map<String, _RestoTrack> tracks) async {
    final open = {
      for (final t in tracks.values)
        if (t.order!.isOpen) ...[for (final l in t.order!.lines) l.uuid],
    };
    final terms = {...await _restoPromotionTerms(), ...added}..removeWhere((line, _) => !open.contains(line));
    await v2.write(_promotionTermsKey, jsonEncode({for (final e in terms.entries) e.key: {'p': e.value.uuid, 'd': e.value.toJson()}}));
  }

  String? _restaurantBlocker(Operator operator) {
    final ctx = _resto;
    if (ctx == null) return _unavailable;
    if (ctx.profile == null) return 'Ce point de vente est en mode Boutique : aucune commande à table.';
    if (!ctx.restaurantProfile) return 'Profil restaurant inconnu de ce terminal : mettez l’application à jour.';
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
        track.lastOperation = operation;
      }
      final state = row['etat'] as String;
      if (V2OperationState.unsent.contains(state)) track.pending++;
      final reason = row['raison'] as Map?;
      if (state != V2OperationState.integrated && state != V2OperationState.resolved && reason != null) {
        track.message = reason['message'] as String?;
        if (reason['code'] == 'restaurant.attente_version' || reason['code'] == 'restaurant.attente_reglement') track.waiting = true;
      }
      if (state == V2OperationState.rejected || state == V2OperationState.arbitration) track.blocked = true;
      if (version == 1 && row['numero_serveur'] != null) track.serverNumber = row['numero_serveur'] as String;
    }
    // Déplacements et fusions reçus (R-4) d'abord : le réglé porte ensuite sur l'état fusionné.
    _restoReceiveMoves(tracks, rows);
    // Réglé (R-4, règlements partiels) : quantités des ventes de ce terminal qui règlent chaque ligne, portées par la
    // version suivante (`reglee`) ; le serveur accepte un réglé en avance sur les ventes qu'il a intégrées.
    final sales = await _restoSaleFacts();
    for (final t in tracks.values) {
      final paid = sales.settled[t.uuid];
      // Lot R-5 : une commande qui a eu un règlement garde sa remise client (PromotionsCaisse::remiseClient).
      if (sales.withSale.contains(t.uuid)) t.order!.discountFrozen = true;
      final cancellation = sales.cancellations[t.uuid];
      if (cancellation != null) {
        // Annulation d'une vente (`resto_remboursement`, R-5) : les quantités réglées reviennent à la commande, une
        // commande soldée est rouverte SANS nouvelle version ; la version suivante part de cet état rouvert.
        for (final l in t.order!.lines) {
          l.settled = paid?[l.uuid] ?? 0;
        }
        if (t.order!.status == 'settled' && t.lastOperation != null && _after(cancellation, t.lastOperation!)) t.order!.status = 'open';
        continue;
      }
      if (paid == null) continue;
      for (final l in t.order!.lines) {
        final quantity = paid[l.uuid] ?? 0;
        if (quantity > l.settled) l.settled = quantity;
      }
    }
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


  /// Ventes de ce terminal qui règlent des commandes (hors quarantaine) : quantités réglées par commande puis par ligne
  /// (ventes annulées exclues, lot R-5), commandes qui ont eu un règlement, et dernière annulation de vente par commande.
  Future<({Map<String, Map<String, int>> settled, Set<String> withSale, Map<String, Map> cancellations})> _restoSaleFacts() async {
    final settled = <String, Map<String, int>>{};
    final withSale = <String>{};
    final cancellations = <String, Map>{};
    final cancelledSales = <String>{};
    for (final row in await v2.operationsOfType(_V2Restaurant._refundType)) {
      if (row['etat'] == V2OperationState.rejected) continue;
      final operation = row['operation'] as Map;
      final content = operation['contenu'] as Map;
      if (content['type'] != 'annulation') continue;
      cancelledSales.add((content['vente_ref'] as Map)['operation_uuid'] as String);
      cancellations[content['commande_uuid'] as String] = operation;
    }
    for (final row in await v2.operationsOfType('vente')) {
      if (row['etat'] == V2OperationState.rejected) continue;
      final link = ((row['operation'] as Map)['contenu'] as Map)['commande'];
      if (link is! Map) continue;
      withSale.add(link['commande_uuid'] as String);
      if (cancelledSales.contains((row['operation'] as Map)['uuid'])) continue;
      final lines = settled[link['commande_uuid'] as String] ??= {};
      for (final l in (link['lignes'] as List).cast<Map>()) {
        final uuid = l['ligne_commande_uuid'] as String;
        lines[uuid] = (lines[uuid] ?? 0) + Decimal6.parse(l['quantite'] as String);
      }
    }
    return (settled: settled, withSale: withSale, cancellations: cancellations);
  }

  /// Toutes les lignes actives réglées.
  static bool _restoFullyPaid(RestoOrder order) => order.activeLines.isNotEmpty && order.activeLines.every((l) => l.settled >= l.quantity);

  /// Commandes entièrement réglées par les ventes de ce terminal (clôture faite ou à faire) : elles ne se modifient plus.
  Future<Set<String>> _paidOrders() async => {
    for (final t in (await _restoTracks()).values)
      if (_restoFullyPaid(t.order!)) t.uuid,
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
      promotions: RestoPromotions(
        promotions: ctx.promotions,
        timezone: ctx.settings.timezone ?? _shopRules?['fuseau'] as String?,
        categoryParents: ctx.categoryParents,
        tableRooms: {for (final t in ctx.tables) t.uuid: t.roomUuid},
        entryTerms: await _restoPromotionTerms(),
      ),
      customerDiscounts: ctx.customerDiscounts,
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
    final tracks = await _restoTracks();
    if (event.promotionTerms.isNotEmpty) await _restoKeepPromotionTerms(event.promotionTerms, tracks);
    final track = tracks[result.order.uuid]!;
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
    // Profil Restaurant, envoi en production éteint : « Valider » (`validation`, R-4, vocabulaire du journal du web). Le
    // Service de table garde `envoi` à bons vides, admis depuis R-3 (le contrat ne distingue pas les profils).
    if ((_resto?.production ?? false) && !(_resto?.settings.sendToProduction ?? false)) {
      return _restoAct(operator, orderUuid, (engine, order) => engine.validate(order));
    }
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
  Future<List<Operator>> _restoApprovers(Operator cashier, int amount, {String type = 'resto_modifier_envoye', int? percent, String? refund}) async {
    final ctx = _resto;
    if (ctx == null) return const [];
    final caps = ctx.settings.assistant;
    final ledger = await _restoLedger();
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
            _restoApproverHolds(o, type, refund) &&
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
    String? refund,
  }) async {
    final cancel = type == 'resto_modifier_envoye' || type == 'resto_annuler_commande';
    if (!(await _restoApprovers(cashier, amount, type: type, percent: percent, refund: refund)).any((o) => o.id == approver.id)) {
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
  /// imprimante de la caisse. Null : tentative [attempt] confiée à [restoDeferredPrinter] (hôte Windows), résultat à venir.
  Future<RestoOutcome?> _restoSendTo(
    RestoTicket ticket,
    RestoStation station,
    RestoTarget target, {
    bool duplicate = false,
    String? attempt,
    String kind = 'livraison',
    bool fallback = false,
    Operator? operator,
  }) async {
    final ctx = _resto!;
    final order = (await _restoTracks())[ticket.orderUuid]?.order;
    final text = ticket.printLines(
      stationName: station.name,
      orderNumber: order?.localNumber ?? '',
      table: ctx.table(order?.tableUuid)?.name,
      columns: restoTicketColumns,
      duplicate: duplicate,
    );
    final deferred = restoDeferredPrinter;
    if (deferred != null && attempt != null && restoDeferredTargets.contains(target) && target != RestoTarget.ecranPoste) {
      final address = target == RestoTarget.imprimantePoste ? _restoPrinters[station.uuid] : null;
      if (target == RestoTarget.imprimantePoste && address == null) return RestoOutcome.nonEnvoye;
      try {
        await deferred(RestoDeferredPrint(
          uuid: attempt,
          kind: kind,
          ticketUuid: ticket.uuid,
          orderUuid: ticket.orderUuid,
          stationUuid: station.uuid,
          stationName: station.name,
          target: target,
          address: address,
          fallback: fallback,
          operatorId: operator?.id,
          lines: text,
        ));
        return null;
      } catch (_) {
        // Travail peut-être conservé : jamais de secours qui risquerait un bon en double.
        return RestoOutcome.aVerifier;
      }
    }
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
      await _restoDeliverTicket(operator, ticket, station, <RestoAttempt>[]);
    }
    await _restoFlush();
    notifyListeners();
  }

  /// Suite du plan de livraison d'un bon après [attempts] ; une cible confiée à l'hôte ([restoDeferredPrinter]) arrête
  /// le plan : son résultat le reprend ([_restoDeferredOutcome]).
  Future<void> _restoDeliverTicket(Operator operator, RestoTicket ticket, RestoStation station, List<RestoAttempt> attempts) async {
    for (var plan = RestoDelivery.next(station, attempts); plan.isNotEmpty; plan = RestoDelivery.next(station, attempts)) {
      var deferred = false;
      for (final (target, fallback) in plan) {
        final attempt = _newUuid();
        final outcome = await _restoSendTo(ticket, station, target, attempt: attempt, fallback: fallback, operator: operator);
        if (outcome == null) {
          deferred = true;
          continue;
        }
        attempts.add(RestoAttempt(target, outcome, fallback: fallback));
        await _restoJournalAdd(operator, {
          'type': 'livraison',
          'bon_uuid': ticket.uuid,
          'tentative_uuid': attempt,
          'cible': target.code,
          'resultat': outcome.code,
          'secours': fallback,
          'le': _restoStamp(),
        });
      }
      if (deferred) return;
    }
  }

  /// Résultat d'une impression confiée à l'hôte : noté au journal (livraison) ou sur le duplicata ; une livraison en échec
  /// certain reprend la chaîne de secours, sauf si une autre tentative du bon est encore en cours ([inFlight]). Une
  /// tentative déjà notée ne l'est pas deux fois.
  Future<void> _restoDeferredOutcome(Operator operator, RestoDeferredPrint job, RestoOutcome outcome, {Set<RestoTarget> inFlight = const {}}) async {
    final ctx = _resto ?? (throw const OfflineRefusal(_unavailable));
    if (job.kind == 'duplicata') {
      await serialized(() async {
        final journal = await _restoJournalRead();
        for (final e in journal) {
          if ((e['e'] as Map)['type'] == 'duplicata' && (e['e'] as Map)['duplicata_uuid'] == job.uuid) e['x'] = outcome.code;
        }
        await _restoJournalWrite(journal);
      });
      notifyListeners();
      return;
    }
    final mine = [
      for (final e in await _restoJournalRead())
        if ((e['e'] as Map)['type'] == 'livraison' && (e['e'] as Map)['bon_uuid'] == job.ticketUuid) e['e'] as Map,
    ];
    if (mine.any((e) => e['tentative_uuid'] == job.uuid)) return;
    await _restoJournalAdd(operator, {
      'type': 'livraison',
      'bon_uuid': job.ticketUuid,
      'tentative_uuid': job.uuid,
      'cible': job.target.code,
      'resultat': outcome.code,
      'secours': job.fallback,
      'le': _restoStamp(),
    });
    final station = ctx.stations[job.stationUuid];
    final ticket = outcome == RestoOutcome.nonEnvoye
        ? (await _restoTicketViews(orderUuid: job.orderUuid)).where((t) => t.ticket.uuid == job.ticketUuid).firstOrNull?.ticket
        : null;
    if (station != null && ticket != null) {
      final attempts = [
        for (final e in mine)
          RestoAttempt(
            RestoTarget.values.firstWhere((t) => t.code == e['cible']),
            RestoOutcome.values.firstWhere((o) => o.code == e['resultat']),
            fallback: e['secours'] == true,
          ),
        RestoAttempt(job.target, outcome, fallback: job.fallback),
        // Tentative encore en cours : comptée comme incertaine, le plan attend son résultat.
        for (final t in inFlight) RestoAttempt(t, RestoOutcome.aVerifier),
      ];
      await _restoDeliverTicket(operator, ticket, station, attempts);
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
  Future<RestoOutcome?> _restoDuplicate(Operator operator, String ticketUuid, String reason) async {
    final ctx = _requireResto(operator);
    final motive = reason.trim();
    if (motive.length < 3 || motive.length > 500) throw const OfflineRefusal('Indiquez le motif de la réimpression (3 à 500 caractères).');
    final view = (await _restoTicketViews()).where((t) => t.ticket.uuid == ticketUuid).firstOrNull ?? (throw const OfflineRefusal('Bon introuvable sur ce terminal.'));
    final station = ctx.stations[view.ticket.stationUuid] ?? (throw const OfflineRefusal('Poste de ce bon inconnu sur ce terminal.'));
    var target = station.paper && _restoPrinters.containsKey(station.uuid) ? RestoTarget.imprimantePoste : RestoTarget.imprimanteCaisse;
    final duplicate = _newUuid();
    var outcome = await _restoSendTo(view.ticket, station, target, duplicate: true, attempt: duplicate, kind: 'duplicata', operator: operator);
    if (outcome == RestoOutcome.nonEnvoye && target == RestoTarget.imprimantePoste) {
      target = RestoTarget.imprimanteCaisse;
      outcome = await _restoSendTo(view.ticket, station, target, duplicate: true, attempt: duplicate, kind: 'duplicata', operator: operator);
    }
    // Confié à l'hôte (null) : le duplicata est noté maintenant, son résultat local à son retour.
    await _restoJournalAdd(operator, {
      'type': 'duplicata',
      'bon_uuid': ticketUuid,
      'duplicata_uuid': duplicate,
      'cible': target.code,
      'motif': motive,
      'operateur_id': '${operator.id}',
      'le': _restoStamp(),
    }, localOutcome: outcome?.code);
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

  Future<RestoOrderView> _restoOpen(Operator operator, String tableUuid, {int? covers, Customer? customer}) => serialized(() async {
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
          customerUuid: customer?.uuid,
          customerName: customer?.name,
        ),
      );
    } on RestoRefusal catch (e) {
      throw OfflineRefusal(e.message);
    }
  });

  // ---------------------------------------------------------------- profil Restaurant et registre (R-4)

  /// Ouverture d'une commande du profil Restaurant sur un canal publié : table seulement si le canal l'exige, référence
  /// externe si le canal l'exige ; étape initiale null.
  Future<RestoOrderView> _restoOpenOnChannel(
    Operator operator,
    String channelCode, {
    String? tableUuid,
    String? reference,
    String? customerName,
    int? covers,
    String? customerUuid,
  }) => serialized(() async {
    final ctx = _requireResto(operator);
    if (!ctx.production) throw const OfflineRefusal('Le Service de table ouvre une commande à une table.');
    final channel = ctx.channel(channelCode);
    if (channel == null || !channel.active) throw const OfflineRefusal('Canal inconnu ou désactivé pour ce point de vente.');
    await _restoRequireRegister(ctx);
    if (channel.requiresTable) {
      final table = ctx.table(tableUuid) ?? (throw OfflineRefusal('Le canal « ${channel.name} » exige une table : choisissez-la.'));
      if (!ctx.settings.severalOrdersPerTable) {
        final busy = (await _restoTracks()).values.where((t) => t.order!.isOpen && t.order!.tableUuid == table.uuid).firstOrNull;
        if (busy != null) throw OfflineRefusal('La table ${table.name} a déjà une commande ouverte (${busy.order!.localNumber}).');
      }
    } else if (tableUuid != null) {
      throw OfflineRefusal('Le canal « ${channel.name} » ne prend pas de table.');
    }
    final ref = reference?.trim() ?? '';
    if (channel.requiresReference && ref.isEmpty) throw OfflineRefusal('Le canal « ${channel.name} » exige une référence (commande de la plateforme…).');
    try {
      final engine = await _restoEngine(ctx);
      return await _restoRecord(
        ctx,
        operator,
        engine.open(
          prefix: ctx.settings.orderPrefix,
          businessDay: _restoDay(),
          profile: ctx.profile!,
          channel: channel.code,
          tableUuid: channel.requiresTable ? tableUuid : null,
          externalReference: ref.isEmpty ? null : ref,
          customerName: customerName,
          customerUuid: customerUuid,
          covers: covers,
          serverId: '${operator.id}',
        ),
      );
    } on RestoRefusal catch (e) {
      throw OfflineRefusal(e.message);
    }
  });

  /// `registre_obligatoire` (profil Restaurant) : vendre et prendre commande exigent un registre ouvert sur la caisse.
  Future<void> _restoRequireRegister(RestoContext ctx) async {
    if (!ctx.production || !ctx.settings.registerRequired) return;
    if ((await _restoRegisterCurrent())?.open != true) throw const OfflineRefusal('Ouvrez d’abord le registre (journée) de cette caisse, depuis le menu de session.');
  }

  /// Compteur local des Z registre (`z_local.numero`), jamais réutilisé.
  static const _zLocalKey = 'v2.resto_z_local';

  /// Pourquoi [operator] ne peut pas ouvrir ou clôturer le registre, ou null.
  String? _restoRegisterBlocker(Operator operator) {
    final ctx = _resto;
    if (ctx == null) return _unavailable;
    if (!ctx.restaurantProfile) return 'Ce point de vente est en mode Boutique : pas de registre restaurant.';
    if (!ctx.master) return ctx.notMasterReason;
    if (!hasRight(operator, 'resto_registre')) return '${operator.name} n’a pas le droit d’ouvrir ou de clôturer le registre.';
    return blockReason;
  }

  static bool _after(Map operation, Map other) {
    final a = (operation['appareil'] as Map)['epoque'] as int, b = (other['appareil'] as Map)['epoque'] as int;
    return a != b ? a > b : (operation['sequence'] as int) > (other['sequence'] as int);
  }

  /// Registre de ce terminal : la dernière ouverture (hors quarantaine) et sa clôture éventuelle ; null si aucun.
  Future<RestoRegisterView?> _restoRegisterCurrent() async {
    final opens = [for (final r in await v2.operationsOfType('resto_registre_ouvre')) if (r['etat'] != V2OperationState.rejected) r];
    if (opens.isEmpty) return null;
    final open = opens.last;
    final operation = open['operation'] as Map;
    final content = operation['contenu'] as Map;
    final uuid = content['registre_uuid'] as String;
    final close = [
      for (final r in await v2.operationsOfType('resto_registre_clos'))
        if (r['etat'] != V2OperationState.rejected && ((r['operation'] as Map)['contenu'] as Map)['registre_uuid'] == uuid) r,
    ].lastOrNull;
    final row = close ?? open;
    final reason = row['raison'] as Map?;
    final state = row['etat'] as String;
    final closing = (close?['operation'] as Map?)?['contenu'] as Map?;
    final z = close == null ? null : await v2.read('${V2Keys.zRestaurantPrefix}${(close['operation'] as Map)['uuid']}');
    var sales = 0;
    if (closing == null) {
      for (final r in await v2.operationsOfType('vente')) {
        if (r['etat'] == V2OperationState.rejected || !_after(r['operation'] as Map, operation)) continue;
        sales += ((((r['operation'] as Map)['contenu'] as Map)['totaux'] as Map)['a_payer'] as int);
      }
    }
    final settled = state == V2OperationState.integrated || state == V2OperationState.resolved;
    return RestoRegisterView(
      uuid: uuid,
      businessDay: content['date_metier'] as String,
      openedAt: DateTime.parse(operation['cree_le'] as String).toLocal(),
      note: content['note'] as String?,
      closed: close != null,
      closedAt: close == null ? null : DateTime.parse((close['operation'] as Map)['cree_le'] as String).toLocal(),
      zLocalNumber: (closing?['z_local'] as Map?)?['numero'] as int?,
      salesTotal: closing == null ? sales : (closing['z_local'] as Map)['total_ventes'] as int,
      serverState: state,
      serverMessage: settled ? null : reason?['message'] as String?,
      waiting: !settled && reason?['code'] == 'restaurant.attente_reglement',
      serverZNumber: z == null ? null : (jsonDecode(z) as Map)['numero'] as int?,
    );
  }

  Future<RestoRegisterView> _restoRegisterOpen(Operator operator, {String? note}) => serialized(() async {
    final blocker = _restoRegisterBlocker(operator);
    if (blocker != null) throw OfflineRefusal(blocker);
    final ctx = _resto!;
    final current = await _restoRegisterCurrent();
    if (current != null && current.open) throw OfflineRefusal('Le registre du ${current.businessDay} est déjà ouvert sur cette caisse.');
    final text = note?.trim() ?? '';
    if (text.length > 2000) throw const OfflineRefusal('Note trop longue (2 000 caractères au plus).');
    await _record(_newUuid(), 'resto_registre_ouvre', operator, (_) => {
      'maitre_generation': ctx.generation,
      'point_de_vente_uuid': ctx.pointOfSaleUuid,
      'registre_uuid': _newUuid(),
      'date_metier': _restoDay(),
      'note': text.isEmpty ? null : text,
    });
    await _afterWrite();
    return (await _restoRegisterCurrent())!;
  });

  /// Clôture du registre et Z local : session close, plus aucune commande avec un reste à payer (règles de
  /// RegisterService::closeDay). Les ventes encore en route laissent la clôture en attente côté serveur
  /// (`restaurant.attente_reglement`), rejouée seule.
  Future<RestoRegisterView> _restoRegisterClose(Operator operator, {String? note}) => serialized(() async {
    final blocker = _restoRegisterBlocker(operator);
    if (blocker != null) throw OfflineRefusal(blocker);
    final ctx = _resto!;
    final current = await _restoRegisterCurrent();
    if (current == null || current.closed) throw const OfflineRefusal('Aucun registre ouvert sur cette caisse.');
    if (sessionOpen) throw const OfflineRefusal('Clôturez d’abord la session de caisse : le registre se clôt après elle.');
    final unpaid = [
      for (final t in (await _restoTracks()).values)
        if (t.order!.isOpen && t.order!.activeLines.any((l) => l.settled < l.quantity)) t.order!.localNumber,
    ];
    if (unpaid.isNotEmpty) {
      throw OfflineRefusal('Commande${unpaid.length > 1 ? 's' : ''} non soldée${unpaid.length > 1 ? 's' : ''} : ${unpaid.take(5).join(', ')}${unpaid.length > 5 ? '…' : ''}. Réglez-les ou annulez-les avant de clôturer le registre.');
    }
    final text = note?.trim() ?? '';
    if (text.length > 2000) throw const OfflineRefusal('Note trop longue (2 000 caractères au plus).');
    final done = (await v2.operationsOfType('resto_registre_clos')).length;
    final last = int.tryParse(await v2.read(_zLocalKey) ?? '') ?? 0;
    final number = (last > done ? last : done) + 1;
    await _record(_newUuid(), 'resto_registre_clos', operator, (_) => {
      'maitre_generation': ctx.generation,
      'point_de_vente_uuid': ctx.pointOfSaleUuid,
      'registre_uuid': current.uuid,
      'note': text.isEmpty ? null : text,
      'z_local': {'numero': number, 'total_ventes': current.salesTotal},
    });
    await v2.write(_zLocalKey, '$number');
    await _afterWrite();
    return (await _restoRegisterCurrent())!;
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
      categoryUuid: product['categorie_uuid'] as String?,
    );
  }

  /// Panier de règlement : une ligne par article actif, au prix figé de la commande ; chaque ligne est reliée à la
  /// sienne pour le règlement `full`.
  /// [quantities] (règlement par articles, profil Restaurant) : quantité choisie par ligne de commande, au plus son reste
  /// à régler ; null : tout le reste de chaque ligne.
  Future<List<CartLine>> _restoCart(String orderUuid, {Map<String, int>? quantities}) async {
    final order = await _restoOrder(orderUuid);
    final s = snapshot ?? (throw const OfflineRefusal('Aucun catalogue reçu.'));
    final lines = <CartLine>[];
    final rests = {for (final l in order.activeLines) l.uuid: l.quantity - l.settled};
    for (final uuid in quantities?.keys ?? const <String>[]) {
      if (!rests.containsKey(uuid)) throw const OfflineRefusal('Article inconnu de la commande : rouvrez l’encaissement.');
    }
    for (final l in order.activeLines) {
      final quantity = quantities == null ? rests[l.uuid]! : (quantities[l.uuid] ?? 0);
      if (quantity <= 0) continue;
      if (quantity > rests[l.uuid]!) throw OfflineRefusal('« ${l.label} » : il en reste ${Decimal6.label(rests[l.uuid]!)} à régler.');
      final id = _ids[l.productUuid];
      final product = s.products.where((p) => p.id == id).firstOrNull ??
          (throw OfflineRefusal('« ${l.label} » n’est plus vendable sur ce terminal : réglez cette commande en ligne.'));
      final packagingId = l.packagingUuid == null ? null : _ids[l.packagingUuid];
      final packaging = packagingId == null ? null : product.packagings.where((p) => p.id == packagingId).firstOrNull;
      if (l.packagingUuid != null && packaging == null) throw OfflineRefusal('Conditionnement de « ${l.label} » retiré : réglez cette commande en ligne.');
      // Remise de la ligne de commande (offert, remise de ligne, R-4), de confiance à la vente ; règlement par
      // articles : part au prorata de la quantité, arrondie sur le cumul (la somme des parts redonne la remise).
      int share(int q) => l.quantity == 0 ? 0 : (BigInt.from(l.lineDiscount) * BigInt.from(q) ~/ BigInt.from(l.quantity)).toInt();
      final discount = quantity == l.quantity ? l.lineDiscount : share(l.settled + quantity) - share(l.settled);
      final line = CartLine(product: product, packaging: packaging, quantity: BigInt.from(quantity), fixedPrice: l.unitPrice, discount: discount);
      _restoCartLines[line] = (orderUuid, l.uuid);
      lines.add(line);
    }
    if (lines.isEmpty) throw OfflineRefusal(quantities == null ? 'Commande vide : rien à encaisser.' : 'Choisissez au moins un article à régler.');
    return lines;
  }

  Future<OfflineOperation> _restoSettle(
    Operator operator,
    String orderUuid,
    List<CartLine> lines,
    List<CartPayment> payments, {
    String? draftUuid,
    List<RestoShare>? shares,
    String? operationUuid,
  }) async {
    final ctx = _requireResto(operator);
    final tracks = await _restoTracks();
    final track = tracks[orderUuid] ?? (throw const OfflineRefusal('Commande introuvable sur ce terminal.'));
    final order = track.order!;
    if (!order.isOpen) throw const OfflineRefusal('Cette commande est close.');
    if (_restoFullyPaid(order)) throw const OfflineRefusal('Commande déjà réglée.');
    // Service de table : exactement les lignes actives, quantités entières de la commande (`full`). Restaurant (R-4) :
    // `full` (tout, aucun règlement avant), `items` (une partie du reste) ou `shares` (tout le reste, en parts).
    final lineOf = <CartLine, String>{};
    final covered = <String, int>{};
    for (final l in lines) {
      final link = _restoCartLines[l];
      if (link == null || link.$1 != orderUuid) throw const OfflineRefusal('Panier différent de la commande : rouvrez l’encaissement.');
      lineOf[l] = link.$2;
      covered[link.$2] = (covered[link.$2] ?? 0) + l.quantity.toInt();
    }
    final expected = {for (final l in order.activeLines) if (l.quantity > l.settled) l.uuid: l.quantity - l.settled};
    final whole = covered.length == expected.length && expected.entries.every((e) => covered[e.key] == e.value);
    if (!ctx.production && (!whole || shares != null || order.activeLines.any((l) => l.settled > 0))) {
      throw const OfflineRefusal('Le Service de table se règle en une fois, toute la commande : rouvrez l’encaissement.');
    }
    final type = ctx.production ? _restoSettlementType(order, covered, expected, whole, payments, shares) : 'full';
    if (ctx.production) await _restoRequireRegister(ctx);
    // R-4 : la vente reprend les remises de la commande, sans jamais les dépasser.
    final trusted = {for (final l in order.activeLines) l.uuid: l.lineDiscount};
    final discounts = <String, int>{};
    for (final l in lines) {
      discounts[lineOf[l]!] = (discounts[lineOf[l]!] ?? 0) + l.discount;
    }
    if (discounts.entries.any((e) => e.value > trusted[e.key]!)) throw const OfflineRefusal('Remise au-delà de celle de la commande : rouvrez l’encaissement.');
    // Règle du web : encaisser envoie ce qui est encore en attente, sans jamais refuser la vente (au Restaurant,
    // seulement si l'envoi en production est actif).
    if (order.lines.any((l) => l.toSend > 0) && (!ctx.production || ctx.settings.sendToProduction)) {
      try {
        await _restoSend(operator, orderUuid);
      } on OfflineRefusal {
        // Envoi impossible (commande bloquée…) : la vente reste permise, la commande garde ses articles en attente.
      }
    }
    final sale = await recordSale(lines, payments, operator, draftUuid: draftUuid, operationUuid: operationUuid,
        extras: SaleExtras(
          globalDiscount: order.globalDiscount,
          order: OrderSettlement(
            orderUuid: orderUuid,
            settlementUuid: _newUuid(),
            lineOf: lineOf,
            type: type,
            shares: type == 'shares' ? [for (final share in shares!) share.toJson()] : null,
            label: type == 'shares' ? '${shares!.length} parts' : null,
            trustedLineDiscounts: trusted,
            trustedGlobalDiscount: order.globalDiscount,
          ),
        ));
    if (!(await _paidOrders()).contains(orderUuid)) return sale; // règlement partiel : la commande reste ouverte
    try {
      await _restoCloseNow(operator, orderUuid);
    } on OfflineRefusal {
      // La vente est faite : la commande reste « réglée, à clôturer » et se clôt depuis l'écran de salle.
    }
    return sale;
  }

  /// Type du règlement au profil Restaurant (BillingService::settleItems et ::settleShares du web) ; [OfflineRefusal]
  /// si le panier ou les parts ne le permettent pas.
  String _restoSettlementType(
    RestoOrder order,
    Map<String, int> covered,
    Map<String, int> rests,
    bool whole,
    List<CartPayment> payments,
    List<RestoShare>? shares,
  ) {
    for (final e in covered.entries) {
      if (!rests.containsKey(e.key) || e.value > rests[e.key]!) throw const OfflineRefusal('Quantité au-delà du reste à régler : rouvrez l’encaissement.');
    }
    if (shares != null) {
      if (!whole) throw const OfflineRefusal('Le partage en parts règle tout le reste de la commande.');
      if (shares.length < 2 || shares.length > 50) throw const OfflineRefusal('Partagez l’addition en 2 à 50 parts.');
      final used = <int>{};
      var total = 0;
      for (final share in shares) {
        final label = share.label.trim();
        if (label.isEmpty || label.length > 120) throw const OfflineRefusal('Chaque part a un libellé (120 caractères au plus).');
        if (share.payments.isEmpty || share.payments.length > 20) throw OfflineRefusal('« $label » : 1 à 20 paiements par part.');
        var paid = 0;
        for (final index in share.payments) {
          if (index < 0 || index >= payments.length || !used.add(index)) throw const OfflineRefusal('Chaque paiement appartient à une part et une seule.');
          paid += payments[index].amount;
        }
        if (share.amount <= 0 || paid != share.amount) throw OfflineRefusal('« $label » : ses paiements ne font pas son montant.');
        total += share.amount;
      }
      if (used.length != payments.length) throw const OfflineRefusal('Chaque paiement appartient à une part et une seule.');
      if (total != payments.fold<int>(0, (sum, p) => sum + p.amount)) throw const OfflineRefusal('Les parts ne font pas le montant de la vente.');
      return 'shares';
    }
    if (whole && order.activeLines.every((l) => l.settled == 0)) return 'full';
    // Une remise de commande ne se partage pas entre règlements partiels (`remise_globale_partagee`).
    if (order.globalDiscount > 0 && !whole) throw const OfflineRefusal('Commande avec une remise globale : réglez tout le reste en une fois.');
    return 'items';
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

  // ---------------------------------------------------------------- tarif du personnel (R-5)

  /// Articles servis à l'employé [staffId] au tarif du personnel (« Vente personnel » du web, PromotionEngine catégorie
  /// `staff`) : pour chaque article, la promotion du personnel qui vaut maintenant au lieu de la commande ; refus si aucune
  /// ne s'applique (comme le web). Le maximum par employé et par jour est un contrôle du serveur, jamais un refus ici.
  List<(RestoNewLine, int)> _restoStaffItems(RestoContext ctx, RestoPromotions promotions, RestoOrder order, int staffId, List<(CartLine, String?)> added) {
    if (!ctx.production) throw const OfflineRefusal('Le tarif du personnel est celui du Restaurant : le Service de table n’en a pas.');
    final staff = snapshot?.operators.where((o) => o.id == staffId).firstOrNull ?? (throw const OfflineRefusal('Employé introuvable sur ce terminal.'));
    if (added.isEmpty) throw const OfflineRefusal('Ajoutez les articles servis à l’employé.');
    return [
      for (final (line, comment) in added) _restoStaffItem(promotions, _restoNewLine(line, comment), '${staff.id}', order),
    ];
  }

  /// Un article au tarif du personnel et sa remise : même moteur de promotions que le reste du lot R-5 (catégorie `staff`,
  /// à l'heure de la caisse) ; l'engine refait ce choix et fige ses conditions à l'enregistrement.
  (RestoNewLine, int) _restoStaffItem(RestoPromotions promotions, RestoNewLine item, String staffId, RestoOrder order) {
    final best = promotions.best(
          RestoPromotionLine(
            productUuid: item.productUuid,
            categoryUuid: item.categoryUuid,
            unitPrice: item.unitPrice,
            quantity: item.quantity,
            coefficient: item.coefficient,
            channel: order.channel,
            tableUuid: order.tableUuid,
          ),
          now,
          categories: const ['staff'],
        ) ??
        (throw OfflineRefusal('Le tarif du personnel ne s’applique pas à « ${item.label} » maintenant : il n’existe qu’aux jours, heures et articles configurés.'));
    return (
      RestoNewLine(
        productUuid: item.productUuid,
        packagingUuid: item.packagingUuid,
        label: item.label,
        quantity: item.quantity,
        coefficient: item.coefficient,
        unitPrice: item.unitPrice,
        routing: item.routing,
        comment: item.comment,
        categoryUuid: item.categoryUuid,
        staffId: staffId,
      ),
      best.lineDiscount(item.unitPrice, item.quantity, coefficient: item.coefficient),
    );
  }

  /// Remise totale de ces articles au tarif du personnel : montant de l'autorisation `remise` (plafonds de l'assistant).
  Future<int> _restoStaffDiscount(String orderUuid, int staffId, List<(CartLine, String?)> added) async {
    final ctx = _resto ?? (throw const OfflineRefusal(_unavailable));
    final promotions = (await _restoEngine(ctx)).promotions;
    return _restoStaffItems(ctx, promotions, await _restoOrder(orderUuid), staffId, added).fold<int>(0, (sum, i) => sum + i.$2);
  }

  /// Une version `lignes` d'articles au tarif du personnel : droit `remise` ou autorisation `remise` d'un responsable (pour
  /// la remise totale), motif obligatoire (« Vente personnel pour … »), employé servi sur chaque ligne (`personnel_id`).
  Future<RestoOrderView> _restoStaffLines(Operator operator, String orderUuid, int staffId, List<(CartLine, String?)> added, {required String reason, RestoApproval? approval}) async {
    final authorizations = _restoGestureAuthorizations(operator, 'remise', approval, reason);
    return _restoAct(
      operator,
      orderUuid,
      (engine, order) {
        final items = _restoStaffItems(_resto!, engine.promotions, order, staffId, added);
        _restoSameAmount(authorizations, approval, () => items.fold<int>(0, (sum, i) => sum + i.$2));
        return engine.editLines(order, added: [for (final i in items) i.$1], reason: reason, authorizations: authorizations);
      },
      approvals: [if (authorizations.isNotEmpty) approval!],
    );
  }

  // ---------------------------------------------------------------- remboursement restaurant (R-5, §4.10)

  /// Pourquoi [operator] ne peut pas rembourser sur cette caisse : caisse maîtresse du profil Restaurant (le Service de table
  /// garde le retour en espèces), session de caisse ouverte (le remboursement sort de son tiroir).
  String? _restoRefundBlocker(Operator operator) {
    final reason = _restaurantBlocker(operator);
    if (reason != null) return reason;
    if (!_resto!.production) return 'Le Service de table rembourse par le retour en espèces de la caisse.';
    if (!sessionOpen) return 'Aucune session de caisse ouverte : ouvrez-la d’abord.';
    return null;
  }

  /// Droits du web (RefundService::missingPermissions) : `ANNULATION` pour une annulation, `RETOUR_CREER` et
  /// `RETOUR_REMBOURSER_ESPECES` pour un retour en espèces.
  static List<String> _restoRefundRights(String type) => type == 'annulation' ? const ['annulation'] : const ['retour_creer', 'retour_rembourser_especes'];

  bool _restoRefundNeedsApproval(Operator operator, String type) => !_restoRefundRights(type).every((r) => hasRight(operator, r));

  /// Un approbateur détient le droit du geste ; pour un remboursement, les permissions qui manquent à l'opérateur.
  /// `ANNULATION` n'est pas publiée aux terminaux : un manager est présumé la détenir, le serveur revérifie.
  bool _restoApproverHolds(Operator o, String type, String? refund) {
    if (type != 'remboursement') return hasRight(o, _restoRightOf(type));
    return _restoRefundRights(refund ?? 'retour').every((r) => hasRight(o, r)) || (refund == 'annulation' && o.restaurantApprover == 'manager');
  }

  /// Vente de ce terminal qui règle une commande : parts archivées par ligne, quantités déjà rendues, total déjà remboursé
  /// (retours de la caisse et remboursements restaurant, hors quarantaine), vente déjà annulée.
  Future<({Map content, Map<String, int> shares, Map<String, int> before, int refunded, bool cancelled})> _restoRefundBasis(String saleUuid) async {
    final row = await v2.operation(saleUuid);
    final operation = row?['operation'] as Map?;
    final content = operation?['contenu'] as Map?;
    if (operation == null || operation['type'] != 'vente' || content?['commande'] is! Map) {
      throw const OfflineRefusal('Seules les ventes de cette caisse qui règlent une commande se remboursent ici.');
    }
    if (row!['etat'] == V2OperationState.rejected) throw const OfflineRefusal('Cette vente est en quarantaine : remboursement impossible.');
    final lines = (content!['lignes'] as List).cast<Map>();
    final parts = archivedShares(V2Engine._saleNet(content), [for (final l in lines) l['total'] as int], _shopRules?['retour_residuel'] as String?) ??
        (throw const OfflineRefusal('Le montant de ce remboursement dépend d’une règle d’arrondi de la boutique : faites-le en ligne.'));
    final shares = {for (final (i, l) in lines.indexed) l['ligne_uuid'] as String: parts[i]};
    final before = <String, int>{};
    var refunded = 0;
    var cancelled = false;
    for (final other in await v2.operationRows()) {
      final past = other['operation'] as Map;
      if ((past['type'] != 'retour' && past['type'] != _refundType) || other['etat'] == V2OperationState.rejected) continue;
      final pastContent = past['contenu'] as Map;
      if ((pastContent['vente_ref'] as Map)['operation_uuid'] != saleUuid) continue;
      refunded += pastContent['montant'] as int;
      if (pastContent['type'] == 'annulation') cancelled = true;
      for (final l in (pastContent['lignes'] as List).cast<Map>()) {
        before.update(l['ligne_uuid'] as String, (v) => v + Decimal6.parse(l['quantite'] as String), ifAbsent: () => Decimal6.parse(l['quantite'] as String));
      }
    }
    return (content: content, shares: shares, before: before, refunded: refunded, cancelled: cancelled);
  }

  /// Montant rendu (RefundService::estimate) : retour = parts archivées des quantités rendues ; annulation = tout ce qui a
  /// été payé. Une vente déjà remboursée en partie s'annule en ligne (répartition du reste entre ses moyens).
  int _restoRefundAmountOf(({Map content, Map<String, int> shares, Map<String, int> before, int refunded, bool cancelled}) basis, String type, Map<String, int> quantities) {
    if (basis.cancelled) throw const OfflineRefusal('Cette vente est déjà annulée.');
    if (type == 'annulation') {
      if (basis.refunded > 0) throw const OfflineRefusal('Cette vente a déjà un remboursement : annulez le reste en ligne.');
      return (basis.content['paiements'] as List).cast<Map>().fold<int>(0, (sum, p) => sum + (p['montant'] as int));
    }
    if (quantities.isEmpty) throw const OfflineRefusal('Choisissez au moins une quantité à rendre.');
    if (quantities.length > 100) throw const OfflineRefusal('100 lignes au plus par remboursement.');
    return _amountOf((content: basis.content, shares: basis.shares, before: basis.before, refunded: basis.refunded), quantities);
  }

  Future<int> _restoRefundAmount(String saleUuid, String type, Map<String, int> quantities) async =>
      _restoRefundAmountOf(await _restoRefundBasis(saleUuid), type, quantities);

  /// Remboursement restaurant (`resto_remboursement`) : `retour` (lignes de la vente, en espèces) ou `annulation` (toute la
  /// vente, sur ses moyens d'origine : la commande soldée est rouverte, sans nouvelle version). Droits du web, sinon
  /// autorisation `remboursement` d'un responsable pour ce montant ; motif obligatoire. Le serveur recalcule le montant
  /// (`restaurant.remboursement_incoherent` s'il diffère, rien n'est remboursé) et attend la vente si elle n'est pas
  /// encore intégrée (`restaurant.attente_reglement`).
  Future<OfflineOperation> _restoRefund(Operator operator, String saleUuid, String type, Map<String, int> quantities, String reason, {RestoApproval? approval, String? operationUuid}) =>
      serialized(() async {
        final blocker = _restoRefundBlocker(operator);
        if (blocker != null) throw OfflineRefusal(blocker);
        final ctx = _resto!;
        if (type != 'retour' && type != 'annulation') throw const OfflineRefusal('Type de remboursement inconnu.');
        final motive = reason.trim();
        if (motive.length < 3 || motive.length > 500) throw const OfflineRefusal('Indiquez le motif du remboursement (3 à 500 caractères).');
        final basis = await _restoRefundBasis(saleUuid);
        final amount = _restoRefundAmountOf(basis, type, type == 'annulation' ? const {} : quantities);
        if (amount <= 0) throw const OfflineRefusal('Rien à rembourser.');
        final orderUuid = (basis.content['commande'] as Map)['commande_uuid'] as String;
        final order = (await _restoTracks())[orderUuid]?.order;
        if (order == null || order.profile != 'PRODUCTION') throw const OfflineRefusal('Le remboursement restaurant concerne une commande du Restaurant de cette caisse.');
        var authorizations = const <Map<String, dynamic>>[];
        if (_restoRefundNeedsApproval(operator, type)) {
          if (approval == null || approval.type != 'remboursement') {
            throw OfflineRefusal('${operator.name} n’a pas le droit ${type == 'annulation' ? 'd’annuler une vente' : 'de rembourser en espèces'} : l’autorisation d’un responsable est requise.');
          }
          if (approval.approverId == operator.id) throw const OfflineRefusal('Le responsable doit être une autre personne que l’opérateur.');
          if (approval.reason != motive) throw const OfflineRefusal('Le motif a changé depuis l’autorisation : faites-la de nouveau.');
          if (approval.amount != amount) throw const OfflineRefusal('Le montant a changé depuis l’autorisation : faites-la de nouveau.');
          authorizations = [approval.toJson()];
        }
        final operation = await _record(operationUuid ?? _newUuid(), _refundType, operator, (_) => {
          'maitre_generation': ctx.generation,
          'point_de_vente_uuid': ctx.pointOfSaleUuid,
          'vente_ref': {'operation_uuid': saleUuid},
          'commande_uuid': orderUuid,
          'type': type,
          'lignes': type == 'annulation'
              ? <Map<String, dynamic>>[]
              : [for (final e in quantities.entries) {'ligne_uuid': e.key, 'quantite': Decimal6.format(e.value)}],
          'montant': amount,
          'motif': motive,
          'autorisations': authorizations,
        });
        if (authorizations.isNotEmpty) await _restoLedgerAdd([approval!]);
        await _afterWrite();
        return operation;
      });

  /// Ventes de cette caisse qui ont réglé une commande du Restaurant, la plus récente d'abord, avec ce qui reste à rendre
  /// et l'état de leurs remboursements (attente du règlement, arbitrage).
  Future<List<RestoSettledSale>> _restoSettledSales() async {
    final ctx = _resto;
    if (ctx == null || !ctx.production) return const [];
    final tracks = await _restoTracks();
    final refunds = <String, List<Map<String, dynamic>>>{};
    for (final row in [...await v2.operationsOfType('retour'), ...await v2.operationsOfType(_refundType)]) {
      if (row['etat'] == V2OperationState.rejected) continue;
      final ref = (((row['operation'] as Map)['contenu'] as Map)['vente_ref'] as Map)['operation_uuid'] as String;
      (refunds[ref] ??= []).add(row);
    }
    final sales = <RestoSettledSale>[];
    for (final row in await v2.operationsOfType('vente')) {
      if (row['etat'] == V2OperationState.rejected) continue;
      final operation = row['operation'] as Map;
      final content = operation['contenu'] as Map;
      final link = content['commande'];
      if (link is! Map) continue;
      final order = tracks[link['commande_uuid']]?.order;
      if (order == null || order.profile != 'PRODUCTION') continue;
      final returned = <String, int>{};
      final views = <RestoRefundView>[];
      for (final r in refunds[operation['uuid']] ?? const <Map<String, dynamic>>[]) {
        final refund = (r['operation'] as Map)['contenu'] as Map;
        for (final l in (refund['lignes'] as List).cast<Map>()) {
          returned.update(l['ligne_uuid'] as String, (v) => v + Decimal6.parse(l['quantite'] as String), ifAbsent: () => Decimal6.parse(l['quantite'] as String));
        }
        final state = r['etat'] as String;
        final raison = r['raison'] as Map?;
        final done = state == V2OperationState.integrated || state == V2OperationState.resolved;
        views.add(RestoRefundView(
          uuid: (r['operation'] as Map)['uuid'] as String,
          type: refund['type'] as String? ?? 'retour',
          amount: refund['montant'] as int,
          reason: refund['motif'] as String? ?? '',
          state: state,
          message: done ? null : raison?['message'] as String?,
          waiting: !done && raison?['code'] == 'restaurant.attente_reglement',
        ));
      }
      sales.add(RestoSettledSale(
        saleUuid: operation['uuid'] as String,
        number: row['numero_serveur'] as String? ?? content['numero_local'] as String,
        orderUuid: order.uuid,
        orderNumber: order.localNumber,
        at: DateTime.parse(operation['cree_le'] as String).toLocal(),
        total: (content['totaux'] as Map)['a_payer'] as int,
        lines: [
          for (final l in (content['lignes'] as List).cast<Map>())
            RestoSaleLine(
              lineUuid: l['ligne_uuid'] as String,
              label: l['libelle'] as String,
              sold: Decimal6.parse(l['quantite_base'] as String),
              remaining: Decimal6.parse(l['quantite_base'] as String) - (returned[l['ligne_uuid']] ?? 0),
            ),
        ],
        refunds: views,
      ));
    }
    return sales.reversed.toList();
  }
}
