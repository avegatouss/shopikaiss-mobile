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

/// Restaurant hors connexion (capacité `restaurant.v1`, RESTAURANT-1 validé, lots R-1 et R-2) : la caisse maîtresse
/// tient ses commandes du Service de table et les fait remonter par `resto_commande` (une version par validation, état
/// complet), puis les règle par une vente v2 avec `commande` (`full`) suivie de la `cloture`.
///
/// La file des opérations fait foi : la commande courante est l'état de sa dernière version enregistrée, rien d'autre
/// n'est stocké. Un fait n'est enregistré que si la caisse est maîtresse (bloc `/etat.restaurant` ET désignation publiée).
extension _V2Restaurant on V2Engine {
  static const _unavailable = 'Restaurant non disponible sur ce terminal.';

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
    for (final row in await v2.operationsOfType('resto_commande')) {
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
    return tracks;
  }

  /// Ventes de ce terminal qui règlent une commande (hors quarantaine).
  Future<Set<String>> _paidOrders() async => {
    for (final row in await v2.operationsOfType('vente'))
      if (row['etat'] != V2OperationState.rejected)
        if (((row['operation'] as Map)['contenu'] as Map)['commande'] case final Map order) order['commande_uuid'] as String,
  };

  RestoOrderView _restoView(_RestoTrack track, Set<String> paid) => RestoOrderView(
    order: track.order!,
    payable: track.order!.totals(_restoVat).payable,
    paid: paid.contains(track.uuid) && track.order!.isOpen,
    pendingVersions: track.pending,
    serverMessage: track.message,
    waiting: track.waiting,
    serverNumber: track.serverNumber,
  );

  Future<List<RestoOrderView>> _restaurantOrders({bool all = false}) async {
    if (_resto == null) return const [];
    final tracks = await _restoTracks();
    final paid = await _paidOrders();
    return [
      for (final t in tracks.values)
        if (all || t.order!.isOpen) _restoView(t, paid),
    ];
  }

  Future<RestoOrder> _restoOrder(String uuid) async {
    final track = (await _restoTracks())[uuid];
    if (track == null) throw const OfflineRefusal('Commande introuvable sur ce terminal.');
    return track.order!;
  }

  /// Moteur pur, avec les compteurs repris de la file et du dernier numéro reçu par le serveur (jamais réutilisé).
  Future<RestoEngine> _restoEngine(RestoContext ctx) async {
    final counters = RestoCounters();
    void seen(String? number) {
      final parsed = RestoEngine.parseLocalNumber(number);
      if (parsed == null) return;
      final key = 'commande|${parsed.$1}';
      if ((counters.values[key] ?? 0) < parsed.$2) counters.values[key] = parsed.$2;
    }

    for (final t in (await _restoTracks()).values) {
      seen(t.order!.localNumber);
    }
    seen(ctx.lastOrderNumber);
    return RestoEngine(
      newUuid: _newUuid,
      now: () => now,
      stations: const {},
      counters: counters,
      sendToStations: false,
      vat: _restoVat,
      cancellationReasonRequired: ctx.settings.cancellationReason,
    );
  }

  /// Enregistre le fait rendu par le moteur : opération `resto_commande`, validée contre le contrat, dans la file.
  Future<RestoOrderView> _restoRecord(RestoContext ctx, Operator operator, RestoResult result) async {
    final event = result.event;
    if (event.tickets.isNotEmpty || event.action == 'envoi' || event.action == 'annulation_ligne') {
      throw const OfflineRefusal('Envoi en production : pas encore pris en charge par le serveur (lot R-3).');
    }
    await _record(event.uuid, 'resto_commande', operator, (_) => {
      'maitre_generation': ctx.generation,
      'point_de_vente_uuid': ctx.pointOfSaleUuid,
      'commande_uuid': result.order.uuid,
      'version': event.version,
      'action': event.action,
      'fait': event.fact,
      'motif': event.reason,
      'autorisations': const <Map<String, dynamic>>[],
      'etat': event.state,
    });
    await _afterWrite();
    final track = (await _restoTracks())[result.order.uuid]!;
    return _restoView(track, await _paidOrders());
  }

  /// Fait sur une commande existante : relue dans la file (jamais l'objet de l'écran), ouverte, sans version bloquée.
  Future<RestoOrderView> _restoAct(Operator operator, String orderUuid, RestoResult Function(RestoEngine engine, RestoOrder order) act) => serialized(() async {
    final ctx = _requireResto(operator);
    final tracks = await _restoTracks();
    final track = tracks[orderUuid] ?? (throw const OfflineRefusal('Commande introuvable sur ce terminal.'));
    if (track.blocked) {
      throw OfflineRefusal('Cette commande attend un arbitrage de la boutique${track.message == null ? '' : ' : ${track.message}'}');
    }
    if ((await _paidOrders()).contains(orderUuid)) throw const OfflineRefusal('Commande déjà réglée : elle ne se modifie plus.');
    try {
      return await _restoRecord(ctx, operator, act(await _restoEngine(ctx), track.order!));
    } on RestoRefusal catch (e) {
      throw OfflineRefusal(e.message);
    }
  });

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
      final line = CartLine(product: product, packaging: packaging, quantity: BigInt.from(l.quantity), fixedPrice: l.unitPrice);
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
    final sale = await recordSale(lines, payments, operator, draftUuid: draftUuid,
        extras: SaleExtras(order: OrderSettlement(orderUuid: orderUuid, settlementUuid: _newUuid(), lineOf: lineOf)));
    try {
      await _restoCloseNow(operator, orderUuid);
    } on OfflineRefusal {
      // La vente est faite : la commande reste « réglée, à clôturer » et se clôt depuis l'écran de salle.
    }
    return sale;
  }

  /// Clôture après la vente qui règle la commande (la vente précède la clôture dans la file).
  Future<RestoOrderView> _restoCloseNow(Operator operator, String orderUuid) => serialized(() async {
    final ctx = _requireResto(operator);
    final track = (await _restoTracks())[orderUuid] ?? (throw const OfflineRefusal('Commande introuvable sur ce terminal.'));
    if (!(await _paidOrders()).contains(orderUuid)) throw const OfflineRefusal('Commande pas encore réglée : encaissez-la d’abord.');
    try {
      return await _restoRecord(ctx, operator, (await _restoEngine(ctx)).close(track.order!));
    } on RestoRefusal catch (e) {
      throw OfflineRefusal(e.message);
    }
  });
}
