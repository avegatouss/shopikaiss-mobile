part of 'register_adapter.dart';

/// Résultat conservé d'une commande restaurant par identifiant d'opération (`resto_operation.<uuid>`).
const _restoOperationPrefix = 'resto_operation.';

/// File durable des bons confiés à l'interface (hôte Windows) : `[{job_id, ..., state, result}]`.
const _restoJobsKey = 'resto_impression.travaux';

/// Travaux terminés gardés pour l'affichage et le rejeu des acquittements.
const _restoJobsKept = 200;

/// Règlement préparé par `restoPrepareSettlement` : panier rendu par le moteur (mêmes objets, reliés à la commande),
/// montant à payer et parts, tels que l'écran Android les calcule avant le dialogue de paiement.
class _RestoSettlement {
  _RestoSettlement({required this.orderUuid, required this.mode, required this.lines, required this.payable, required this.shares});

  final String orderUuid;

  /// `full`, `items` ou `shares`.
  final String mode;
  final List<CartLine> lines;
  final int payable;

  /// Montants des parts (mode `shares`), sans part nulle.
  final List<int> shares;
}

/// Montant, type et besoin d'autorisation d'un geste, calculés comme les dialogues de l'écran Android.
typedef _RestoTerms = ({String type, int amount, int? percent, String? refund, bool required});

/// Commandes restaurant de l'adaptateur (capacité `restaurant.v1`, lots R-1 à R-5) : mêmes appels au moteur et mêmes
/// contrôles que l'écran Android (`restaurant_screen.dart`, `restaurant_production_screen.dart`) ; aucune règle métier ici.
extension _RestoCommands on LocalRegisterAdapter {
  Future<Map<String, dynamic>>? _restoCommand(String command, Map<String, dynamic> args, String? operationId) => switch (command) {
    // ---- lectures (caissier identifié, sans identifiant d'opération)
    'restaurantView' => _restaurantView(),
    'restoOrder' => _restoOrderRead(args),
    'restoTickets' => _restoTicketsRead(args),
    'restoApprovalInfo' => _restoApprovalInfo(args),
    'restoRegister' => _restoRegisterRead(),
    'restoSettledSales' => _restoSettledSales(),
    'restoRefundPreview' => _restoRefundPreview(args),
    'restoPrepareSettlement' => _restoPrepareSettlement(args),
    // ---- écritures (caissier identifié, identifiant d'opération, rejeu sans double)
    'restoOpen' => _restoOpen(args, operationId),
    'restoOpenOnChannel' => _restoOpenOnChannel(args, operationId),
    'restoEditLines' => _restoEditLines(args, operationId),
    'restoStaffLines' => _restoStaffLines(args, operationId),
    'restoSend' => _restoOrderWrite('restoSend', args, operationId, (op, uuid) => engine.restoSend(op, uuid)),
    'restoPrebill' => _restoPrebill(args, operationId),
    'restoTransfer' => _restoOrderWrite('restoTransfer', args, operationId, (op, uuid) => engine.restoTransfer(op, uuid, _text(args, 'table_uuid', max: 36))),
    'restoMoveLines' => _restoMoveLines(args, operationId),
    'restoMerge' => _restoOrderWrite('restoMerge', args, operationId,
        (op, uuid) => engine.restoMerge(op, uuid, _text(args, 'target_uuid', max: 36), reason: _optionalText(args, 'reason', max: 500))),
    'restoCoversAndServer' => _restoCoversAndServer(args, operationId),
    'restoValidateCustomer' => _restoOrderWrite('restoValidateCustomer', args, operationId, (op, uuid) => engine.restoValidateCustomer(op, uuid)),
    'restoCancelLine' => _restoCancelLine(args, operationId),
    'restoCancel' => _restoCancel(args, operationId),
    'restoOffer' => _restoOffer(args, operationId),
    'restoDiscountLine' => _restoDiscountLine(args, operationId),
    'restoDiscountOrder' => _restoDiscountOrder(args, operationId),
    'restoSettle' => _restoSettle(args, operationId),
    'restoClose' => _restoOrderWrite('restoClose', args, operationId, (op, uuid) => engine.restoClose(op, uuid)),
    'restoRegisterOpen' => _restoRegisterWrite('restoRegisterOpen', args, operationId),
    'restoRegisterClose' => _restoRegisterWrite('restoRegisterClose', args, operationId),
    'restoRefund' => _restoRefund(args, operationId),
    'restoVerifyTicket' => _restoVerifyTicket(args, operationId),
    'restoDuplicateTicket' => _restoDuplicateTicket(args, operationId),
    'restoSetPrinterAddress' => _restoSetPrinterAddress(args, operationId),
    // ---- pont d'impression (acquittements de l'interface, idempotents par travail)
    'restoPrintJobs' => _restoPrintJobs(),
    'restoPrintStart' => _restoPrintStart(args),
    'restoPrintResult' => _restoPrintResult(args),
    _ => null,
  };

  // ------------------------------------------------------------------ socle : caissier, identifiant, rejeu

  Operator _restoOperator() => _operator ?? (throw const AdapterFailure('caissier_requis', 'Identifiez le caissier.'));

  RestoContext _restoContext() => engine.restaurant ?? (throw const AdapterFailure('restaurant_indisponible', 'Restaurant non disponible sur ce terminal.'));

  /// Écriture rejouable : caissier identifié, [operationId] obligatoire. Rejouée avec le même identifiant, elle rend le
  /// résultat conservé sans rien refaire. Un refus du moteur (avant toute écriture) libère l'identifiant ; un arrêt pendant
  /// l'écriture laisse l'opération « en cours » : [recover] la retrouve dans la file (vente, remboursement), sinon le
  /// rejeu répond `resultat_incertain` (jamais de seconde exécution).
  Future<Map<String, dynamic>> _restoWrite(
    String command,
    String? operationId,
    Future<Map<String, dynamic>> Function(Operator operator, String operationId) body, {
    Future<Map<String, dynamic>?> Function(String operationId)? recover,
  }) async {
    final id = LocalRegisterAdapter._requireOperationId(operationId);
    final operator = _restoOperator();
    final key = '$_restoOperationPrefix$id';
    final raw = await engine.store.read(key);
    if (raw != null) {
      final stored = (jsonDecode(raw) as Map).cast<String, dynamic>();
      if (stored['commande'] != command) {
        throw const AdapterFailure('identifiant_reutilise', 'Cet identifiant d’opération a déjà servi à une autre commande : prenez-en un nouveau.');
      }
      if (stored['etat'] == 'fait') return {...(stored['resultat'] as Map).cast<String, dynamic>(), 'replayed': true};
      final found = recover == null ? null : await recover(id);
      if (found != null) {
        await engine.store.write(key, jsonEncode({'commande': command, 'etat': 'fait', 'resultat': found}));
        return {...found, 'replayed': true};
      }
      if (recover == null) {
        throw const AdapterFailure('resultat_incertain',
            'L’hôte s’est arrêté pendant cette opération : relisez la commande avant de recommencer avec un nouvel identifiant.', notCommitted: false);
      }
      // [recover] certifie que rien n'a été enregistré : l'opération peut s'exécuter.
    }
    await engine.store.write(key, jsonEncode({'commande': command, 'etat': 'en_cours', 'le': DateTime.now().toUtc().toIso8601String()}));
    _restoNewJobs.clear();
    final Map<String, dynamic> result;
    try {
      result = await body(operator, id);
    } on OfflineRefusal catch (e) {
      await engine.store.write(key, null);
      throw AdapterFailure('restaurant_refuse', e.message);
    } on AdapterFailure catch (e) {
      if (e.notCommitted) await engine.store.write(key, null);
      rethrow;
    }
    final response = {...result, 'operation_id': id, if (_restoNewJobs.isNotEmpty) 'print_jobs': [..._restoNewJobs]};
    await engine.store.write(key, jsonEncode({'commande': command, 'etat': 'fait', 'resultat': response}));
    _emit('restaurant');
    return response;
  }

  /// Fait sur une commande existante (`order_uuid`) : la réponse est la commande après le fait.
  Future<Map<String, dynamic>> _restoOrderWrite(
    String command,
    Map<String, dynamic> args,
    String? operationId,
    Future<RestoOrderView> Function(Operator operator, String orderUuid) act,
  ) {
    final orderUuid = _text(args, 'order_uuid', max: 36);
    return _restoWrite(command, operationId, (operator, _) async => {'order': _restoOrderJson(await act(operator, orderUuid))});
  }

  // ------------------------------------------------------------------ lectures

  Future<Map<String, dynamic>> _restaurantView() async {
    final operator = _operator ?? (throw const AdapterFailure('caissier_requis', 'Identifiez le caissier pour consulter la salle.'));
    final ctx = engine.restaurant;
    if (ctx == null) return {'available': false, 'message': 'Le mode restaurant n’est pas disponible sur cet appareil.', 'tables': <Object>[]};
    final orders = await engine.restaurantOrders();
    final blocker = engine.restaurantBlocker(operator);
    final tables = <Map<String, dynamic>>[];
    for (final table in ctx.tables) {
      final room = ctx.rooms.where((r) => r.uuid == table.roomUuid).firstOrNull;
      final matching = [for (final o in orders) if (o.order.tableUuid == table.uuid) o];
      final base = {'table_uuid': table.uuid, 'name': table.name, 'room': room?.name ?? 'Sans salle', 'room_uuid': table.roomUuid, 'capacity': table.capacity};
      if (matching.isEmpty) tables.add({...base, 'id': table.uuid, 'state': 'free', 'lines': <Object>[]});
      // Plusieurs commandes sur une table : autant d'entrées, jamais un total additionné.
      for (final o in matching) {
        tables.add({
          ...base,
          'id': '${table.uuid}:${o.order.uuid}',
          'order_uuid': o.order.uuid,
          'state': o.order.prebills > 0 ? 'payment' : 'occupied',
          'order_label': o.serverNumber ?? o.order.localNumber,
          'total_label': formatFcfa(o.payable),
          'guests_label': o.order.covers == null ? null : '${o.order.covers} couverts',
          'sync_message': _restoSyncMessage(o),
          'lines': [
            for (final l in o.order.lines)
              {'name': l.label, 'quantity_label': Decimal6.label(l.quantity), 'total_label': formatFcfa(l.total), 'state_label': _restoLineState(l), 'note': l.comment},
          ],
        });
      }
    }
    final jobs = await _restoJobs();
    return {
      'available': true,
      'profile': ctx.profile,
      'master': ctx.master,
      'message': blocker ?? 'Commandes restaurant disponibles sur cette caisse.',
      'blocker': blocker,
      'point_of_sale_name': ctx.pointOfSaleName,
      'production': ctx.production,
      'table_service': ctx.tableService,
      'send_label': ctx.sendLabel,
      'session_open': engine.sessionOpen,
      'staff_pricing': ctx.staffPricing,
      'settings': {
        'several_orders_per_table': ctx.settings.severalOrdersPerTable,
        'cancellation_reason': ctx.settings.cancellationReason || ctx.production,
        'register_required': ctx.production && ctx.settings.registerRequired,
        'send_to_production': ctx.settings.sendToProduction,
        'prebill_on_request': ctx.settings.prebillOnRequest,
      },
      'rights': {
        'sent_cancel_needs_approval': engine.restoApprovalRequired(operator),
        'offer_needs_approval': engine.restoNeedsApproval(operator, 'resto_offrir'),
        'discount_needs_approval': engine.restoNeedsApproval(operator, 'remise'),
        'register_blocker': engine.restoRegisterBlocker(operator),
        'refund_blocker': engine.restoRefundBlocker(operator),
      },
      'rooms': [for (final r in ctx.rooms) {'uuid': r.uuid, 'code': r.code, 'name': r.name}],
      'tables': tables,
      'channels': [
        for (final c in ctx.channels)
          {'code': c.code, 'name': c.name, 'kind': c.kind, 'requires_table': c.requiresTable, 'requires_reference': c.requiresReference, 'active': c.active},
      ],
      'stations': [
        for (final s in ctx.stations.values)
          {'uuid': s.uuid, 'code': s.code, 'name': s.name, 'screen': s.screen, 'paper': s.paper, 'active': s.active, 'printer_address': engine.restoPrinterAddresses[s.uuid]},
      ],
      'staff': [for (final o in engine.snapshot?.operators ?? const <Operator>[]) {'id': o.id, 'name': o.name}],
      'customer_discounts': ctx.customerDiscounts,
      'orders': [for (final o in orders) _restoOrderJson(o)],
      'register': _restoRegisterJson(await engine.restoRegister()),
      'tickets_to_check': orders.fold<int>(0, (sum, o) => sum + o.ticketsToCheck),
      'print_jobs_pending': jobs.where((j) => j['state'] != 'termine').length,
    };
  }

  Future<Map<String, dynamic>> _restoOrderRead(Map<String, dynamic> args) async {
    _restoOperator();
    return {'order': _restoOrderJson(await _restoFind(_text(args, 'order_uuid', max: 36)))};
  }

  Future<Map<String, dynamic>> _restoTicketsRead(Map<String, dynamic> args) async {
    _restoOperator();
    final order = _optionalText(args, 'order_uuid', max: 36);
    final jobs = await _restoJobs();
    return {
      'tickets': [
        for (final t in await engine.restoTickets(orderUuid: order))
          () {
            final printing = [for (final j in jobs) if (j['ticket_uuid'] == t.ticket.uuid && j['state'] != 'termine') j['job_id']];
            return {
              ..._restoTicketJson(t.ticket),
              'station_name': t.stationName,
              'order_number': t.orderNumber,
              'table': t.table,
              // Une tentative confiée à l'interface sans résultat : ni livré ni en échec tant qu'elle n'a pas répondu.
              'state': switch (t.state) {
                RestoDeliveryState.delivered => 'livre',
                RestoDeliveryState.toCheck => 'a_verifier',
                _ when printing.isNotEmpty => 'en_impression',
                RestoDeliveryState.failed => 'echec',
                RestoDeliveryState.pending => 'en_attente',
              },
              'check_attempt': t.checkAttempt,
              'checked': t.checked,
              'print_jobs': printing,
            };
          }(),
      ],
    };
  }

  Future<Map<String, dynamic>> _restoRegisterRead() async {
    final operator = _restoOperator();
    return {'register': _restoRegisterJson(await engine.restoRegister()), 'blocker': engine.restoRegisterBlocker(operator)};
  }

  Future<Map<String, dynamic>> _restoSettledSales() async {
    final operator = _restoOperator();
    return {
      'blocker': engine.restoRefundBlocker(operator),
      'sales': [
        for (final s in await engine.restoSettledSales())
          {
            'sale_uuid': s.saleUuid,
            'number': s.number,
            'order_uuid': s.orderUuid,
            'order_number': s.orderNumber,
            'date': s.at.toUtc().toIso8601String(),
            'total': s.total,
            'total_label': formatFcfa(s.total),
            'refunded': s.refunded,
            'cancelled': s.cancelled,
            'refundable': s.refundable,
            'lines': [
              for (final l in s.lines)
                {'line_uuid': l.lineUuid, 'label': l.label, 'sold': Decimal6.format(l.sold), 'remaining': Decimal6.format(l.remaining), 'remaining_label': Decimal6.label(l.remaining)},
            ],
            'refunds': [
              for (final r in s.refunds)
                {'uuid': r.uuid, 'type': r.type, 'amount': r.amount, 'amount_label': formatFcfa(r.amount), 'reason': r.reason, 'state': r.state, 'message': r.message, 'waiting': r.waiting},
            ],
          },
      ],
    };
  }

  /// Montant, type et responsables possibles d'un geste avant de le faire (dialogue d'autorisation de l'écran) :
  /// `gesture` ∈ cancel_line, cancel_order, offer, discount_line, discount_order, staff, refund, avec les arguments de
  /// la commande correspondante.
  Future<Map<String, dynamic>> _restoApprovalInfo(Map<String, dynamic> args) async {
    final operator = _restoOperator();
    final terms = await _restoTerms(operator, _text(args, 'gesture', max: 32), args);
    final approvers = terms.required
        ? await engine.restoApprovers(operator, terms.amount, type: terms.type, percent: terms.percent, refund: terms.refund)
        : const <Operator>[];
    return {
      'required': terms.required,
      'type': terms.type,
      'amount': terms.amount,
      'amount_label': formatFcfa(terms.amount),
      'percent': terms.percent,
      'approvers': [for (final o in approvers) {'id': o.id, 'name': o.name}],
    };
  }

  Future<Map<String, dynamic>> _restoRefundPreview(Map<String, dynamic> args) async {
    final info = await _restoApprovalInfo({...args, 'gesture': 'refund'});
    return {...info, 'blocker': engine.restoRefundBlocker(_restoOperator())};
  }

  // ------------------------------------------------------------------ ouverture et lignes

  Future<Map<String, dynamic>> _restoOpen(Map<String, dynamic> args, String? operationId) {
    final table = _text(args, 'table_uuid', max: 36);
    final covers = _restoCovers(args);
    final customer = _restoCustomer(args);
    return _restoWrite('restoOpen', operationId, (operator, _) async {
      final blocker = engine.restaurantBlocker(operator);
      if (blocker != null) throw OfflineRefusal(blocker);
      return {'order': _restoOrderJson(await engine.restoOpen(operator, table, covers: covers, customer: customer))};
    });
  }

  Future<Map<String, dynamic>> _restoOpenOnChannel(Map<String, dynamic> args, String? operationId) {
    final channel = _text(args, 'channel', max: 64);
    final table = _optionalText(args, 'table_uuid', max: 36);
    final reference = _optionalText(args, 'reference', max: 120);
    final customerName = _optionalText(args, 'customer_name', max: 160);
    final customerUuid = _optionalText(args, 'customer_uuid', max: 36);
    final covers = _restoCovers(args);
    return _restoWrite('restoOpenOnChannel', operationId, (operator, _) async {
      final blocker = engine.restaurantBlocker(operator);
      if (blocker != null) throw OfflineRefusal(blocker);
      return {
        'order': _restoOrderJson(await engine.restoOpenOnChannel(operator, channel,
            tableUuid: table, reference: reference, customerName: customerName, covers: covers, customerUuid: customerUuid)),
      };
    });
  }

  /// Une validation = une version : articles ajoutés (`added` : product_id, packaging_id, quantity, comment), quantités
  /// (`quantities` : {line_uuid: "2"}), commentaires (`comments` : {line_uuid: texte|null}), articles retirés (`removed`).
  Future<Map<String, dynamic>> _restoEditLines(Map<String, dynamic> args, String? operationId) {
    final added = _restoItems(args['added']);
    final quantities = _restoQuantities(args['quantities']);
    final removed = _restoUuidList(args['removed']);
    final comments = <String, String?>{};
    final rawComments = args['comments'];
    if (rawComments != null) {
      if (rawComments is! Map || rawComments.length > 200) throw const AdapterFailure('argument_invalide', 'Argument « comments » invalide.');
      for (final e in rawComments.entries) {
        final value = e.value;
        if (e.key is! String || (value != null && (value is! String || value.length > 500))) throw const AdapterFailure('argument_invalide', 'Argument « comments » invalide.');
        final text = (value as String?)?.trim();
        comments[e.key as String] = text == null || text.isEmpty ? null : text;
      }
    }
    return _restoOrderWrite('restoEditLines', args, operationId,
        (operator, uuid) => engine.restoEditLines(operator, uuid, added: added, quantities: quantities, comments: comments, removed: removed.toSet()));
  }

  /// Articles servis à un employé au tarif du personnel (`staff_id`, `added`, `reason`, `approval` si l'opérateur n'a pas
  /// le droit Remise) ; les autres changements de la commande s'enregistrent avant par `restoEditLines`.
  Future<Map<String, dynamic>> _restoStaffLines(Map<String, dynamic> args, String? operationId) {
    final orderUuid = _text(args, 'order_uuid', max: 36);
    final staff = _int(args, 'staff_id');
    final added = _restoItems(args['added']);
    final reason = _restoReason(args);
    return _restoWrite('restoStaffLines', operationId, (operator, _) async {
      final approval = await _restoApproval(operator, args, await _restoTerms(operator, 'staff', args), reason);
      return {'order': _restoOrderJson(await engine.restoStaffLines(operator, orderUuid, staff, added, reason: reason, approval: approval))};
    });
  }

  Future<Map<String, dynamic>> _restoPrebill(Map<String, dynamic> args, String? operationId) {
    final orderUuid = _text(args, 'order_uuid', max: 36);
    return _restoWrite('restoPrebill', operationId, (operator, _) async {
      final view = await engine.restoPrebill(operator, orderUuid);
      return {'order': _restoOrderJson(view), 'prebill_lines': _restoPrebillLines(view)};
    });
  }

  Future<Map<String, dynamic>> _restoMoveLines(Map<String, dynamic> args, String? operationId) {
    final target = _text(args, 'target_uuid', max: 36);
    final lines = _restoUuidList(args['line_uuids']);
    if (lines.isEmpty) throw const AdapterFailure('argument_invalide', 'Choisissez au moins un article à déplacer.');
    return _restoOrderWrite('restoMoveLines', args, operationId, (operator, uuid) => engine.restoMoveLines(operator, uuid, target, lines.toSet()));
  }

  Future<Map<String, dynamic>> _restoCoversAndServer(Map<String, dynamic> args, String? operationId) {
    final covers = _restoCovers(args);
    final server = args['server_id'] == null ? null : '${args['server_id']}';
    if (server != null && server.length > 20) throw const AdapterFailure('argument_invalide', 'Argument « server_id » invalide.');
    return _restoOrderWrite('restoCoversAndServer', args, operationId, (operator, uuid) => engine.restoCoversAndServer(operator, uuid, covers: covers, serverId: server));
  }

  // ------------------------------------------------------------------ gestes autorisés (R-3 à R-5)

  Future<Map<String, dynamic>> _restoCancelLine(Map<String, dynamic> args, String? operationId) {
    final orderUuid = _text(args, 'order_uuid', max: 36);
    final line = _text(args, 'line_uuid', max: 36);
    final quantity = _restoMicros(args, 'quantity');
    final reason = _restoReason(args);
    return _restoWrite('restoCancelLine', operationId, (operator, _) async {
      final approval = await _restoApproval(operator, args, await _restoTerms(operator, 'cancel_line', args), reason);
      return {'order': _restoOrderJson(await engine.restoCancelLine(operator, orderUuid, line, quantity, reason, approval: approval))};
    });
  }

  /// Annulation de la commande : articles annoncés aux postes = motif, droit ou responsable ; sinon motif facultatif
  /// (exigé par le moteur selon la boutique).
  Future<Map<String, dynamic>> _restoCancel(Map<String, dynamic> args, String? operationId) {
    final orderUuid = _text(args, 'order_uuid', max: 36);
    final text = _optionalText(args, 'reason', max: 500);
    return _restoWrite('restoCancel', operationId, (operator, _) async {
      final view = await _restoFind(orderUuid);
      if (RestoEngine.hasAnnounced(view.order)) {
        final reason = _restoReason(args);
        final approval = await _restoApproval(operator, args, await _restoTerms(operator, 'cancel_order', args), reason);
        return {'order': _restoOrderJson(await engine.restoCancel(operator, orderUuid, reason, approval: approval))};
      }
      return {'order': _restoOrderJson(await engine.restoCancel(operator, orderUuid, text ?? ''))};
    });
  }

  Future<Map<String, dynamic>> _restoOffer(Map<String, dynamic> args, String? operationId) {
    final orderUuid = _text(args, 'order_uuid', max: 36);
    final line = _text(args, 'line_uuid', max: 36);
    final reason = _restoReason(args);
    return _restoWrite('restoOffer', operationId, (operator, _) async {
      final approval = await _restoApproval(operator, args, await _restoTerms(operator, 'offer', args), reason);
      return {'order': _restoOrderJson(await engine.restoOffer(operator, orderUuid, line, reason, approval: approval))};
    });
  }

  /// Remise d'un article : `percent` (booléen) et `value` (francs, ou 1 à 100 %), motif.
  Future<Map<String, dynamic>> _restoDiscountLine(Map<String, dynamic> args, String? operationId) {
    final orderUuid = _text(args, 'order_uuid', max: 36);
    final line = _text(args, 'line_uuid', max: 36);
    final percent = args['percent'] == true;
    final value = _int(args, 'value');
    final reason = _restoReason(args);
    return _restoWrite('restoDiscountLine', operationId, (operator, _) async {
      final terms = await _restoTerms(operator, 'discount_line', args);
      final approval = await _restoApproval(operator, args, terms, reason);
      return {
        'order': _restoOrderJson(await engine.restoDiscountLine(operator, orderUuid, line, percent: percent, value: value, reason: reason, approval: approval)),
      };
    });
  }

  /// Remise de la commande en francs (`value`, plafonnée) ; 0 la retire (droit Remise, sans motif ni autorisation).
  Future<Map<String, dynamic>> _restoDiscountOrder(Map<String, dynamic> args, String? operationId) {
    final orderUuid = _text(args, 'order_uuid', max: 36);
    final value = _int(args, 'value');
    final reason = value == 0 ? null : _restoReason(args);
    return _restoWrite('restoDiscountOrder', operationId, (operator, _) async {
      final approval = value == 0 ? null : await _restoApproval(operator, args, await _restoTerms(operator, 'discount_order', args), reason!);
      return {'order': _restoOrderJson(await engine.restoDiscountOrder(operator, orderUuid, value, reason: reason, approval: approval))};
    });
  }

  /// Autorisation d'un responsable quand le geste l'exige : `approval` {approver_id, code} ; le code n'est jamais gardé.
  Future<RestoApproval?> _restoApproval(Operator operator, Map<String, dynamic> args, _RestoTerms terms, String reason) async {
    if (!terms.required) return null;
    final raw = args['approval'];
    if (raw is! Map) {
      throw const AdapterFailure('autorisation_requise', 'Ce geste exige l’autorisation d’un responsable : joignez approval {approver_id, code}.');
    }
    final fields = raw.cast<String, dynamic>();
    final approvers = await engine.restoApprovers(operator, terms.amount, type: terms.type, percent: terms.percent, refund: terms.refund);
    final approver = approvers.where((o) => '${o.id}' == '${fields['approver_id']}').firstOrNull ??
        (throw const AdapterFailure('autorisation_refusee', 'Ce responsable ne peut pas autoriser ce geste (droit, code ou plafonds).'));
    try {
      return await engine.restoAuthorize(
        cashier: operator,
        approver: approver,
        code: _text(fields, 'code', max: 8),
        reason: reason,
        amount: terms.amount,
        type: terms.type,
        percent: terms.percent,
        refund: terms.refund,
      );
    } on OfflineRefusal catch (e) {
      throw AdapterFailure('autorisation_refusee', e.message);
    }
  }

  /// Montant du geste (plafonds de l'assistant), type d'autorisation et besoin d'un responsable : mêmes calculs que les
  /// dialogues de l'écran Android, mêmes contrôles de saisie.
  Future<_RestoTerms> _restoTerms(Operator operator, String gesture, Map<String, dynamic> args) async {
    switch (gesture) {
      case 'cancel_line':
        final line = _restoLine((await _restoFind(_text(args, 'order_uuid', max: 36))).order, _text(args, 'line_uuid', max: 36));
        final quantity = _restoMicros(args, 'quantity');
        return (type: 'resto_modifier_envoye', amount: Decimal6.amount(line.unitPrice, quantity), percent: null, refund: null, required: engine.restoApprovalRequired(operator));
      case 'cancel_order':
        final view = await _restoFind(_text(args, 'order_uuid', max: 36));
        final announced = RestoEngine.hasAnnounced(view.order);
        return (type: 'resto_modifier_envoye', amount: view.payable, percent: null, refund: null, required: announced && engine.restoApprovalRequired(operator));
      case 'offer':
        final line = _restoLine((await _restoFind(_text(args, 'order_uuid', max: 36))).order, _text(args, 'line_uuid', max: 36));
        return (type: 'resto_offrir', amount: line.gross, percent: null, refund: null, required: engine.restoNeedsApproval(operator, 'resto_offrir'));
      case 'discount_line':
        final line = _restoLine((await _restoFind(_text(args, 'order_uuid', max: 36))).order, _text(args, 'line_uuid', max: 36));
        final percent = args['percent'] == true;
        final value = _int(args, 'value');
        if (value < 1 || (percent && value > 100)) {
          throw AdapterFailure('remise_invalide', percent ? 'Pourcentage de 1 à 100.' : 'Saisissez un montant d’au moins 1 F.');
        }
        final amount = RestoEngine.lineDiscountOf(line, percent: percent, value: value);
        if (amount < 1 || amount > line.gross) throw AdapterFailure('remise_invalide', 'La remise doit être comprise entre 1 F et ${formatFcfa(line.gross)}.');
        return (
          type: 'remise',
          amount: amount,
          percent: percent ? value : RestoEngine.percentOf(amount, line.gross),
          refund: null,
          required: engine.restoNeedsApproval(operator, 'remise'),
        );
      case 'discount_order':
        final order = (await _restoFind(_text(args, 'order_uuid', max: 36))).order;
        final value = _int(args, 'value');
        if (value < 0) throw const AdapterFailure('remise_invalide', 'Saisissez un montant d’au moins 1 F.');
        final ceiling = engine.restoOrderDiscountCeiling(order);
        if (value > ceiling) throw AdapterFailure('remise_invalide', 'La remise de commande est plafonnée à ${formatFcfa(ceiling)}.');
        return (
          type: 'remise',
          amount: value,
          percent: RestoEngine.percentOf(value, RestoEngine.orderDiscountBase(order)),
          refund: null,
          required: value > 0 && engine.restoNeedsApproval(operator, 'remise'),
        );
      case 'staff':
        final orderUuid = _text(args, 'order_uuid', max: 36);
        final int amount;
        try {
          amount = await engine.restoStaffDiscount(orderUuid, _int(args, 'staff_id'), _restoItems(args['added']));
        } on OfflineRefusal catch (e) {
          throw AdapterFailure('restaurant_refuse', e.message);
        }
        return (type: 'remise', amount: amount, percent: null, refund: null, required: engine.restoNeedsApproval(operator, 'remise'));
      case 'refund':
        final type = _text(args, 'type', max: 16);
        final int amount;
        try {
          amount = await engine.restoRefundAmount(_text(args, 'sale_uuid', max: 36), type, type == 'annulation' ? const {} : _restoQuantities(args['lines']));
        } on OfflineRefusal catch (e) {
          throw AdapterFailure('restaurant_refuse', e.message);
        }
        return (type: 'remboursement', amount: amount, percent: null, refund: type, required: engine.restoRefundNeedsApproval(operator, type));
      default:
        throw AdapterFailure('argument_invalide', 'Geste inconnu : $gesture.');
    }
  }

  // ------------------------------------------------------------------ règlement et clôture

  /// Prépare l'encaissement comme l'écran Android avant le dialogue de paiement : `mode` full (défaut), items
  /// (`items` : {line_uuid: "1"}) ou shares (`shares` : nombre de parts égales) ; le Service de table règle tout.
  Future<Map<String, dynamic>> _restoPrepareSettlement(Map<String, dynamic> args) async {
    _restoOperator();
    final snapshot = _snapshot();
    final ctx = _restoContext();
    final orderUuid = _text(args, 'order_uuid', max: 36);
    final mode = args['mode'] == null ? 'full' : _text(args, 'mode', max: 8);
    if (!const {'full', 'items', 'shares'}.contains(mode)) throw const AdapterFailure('argument_invalide', 'Argument « mode » invalide (full, items, shares).');
    final view = await _restoFind(orderUuid);
    if (!engine.sessionOpen) throw const AdapterFailure('session_requise', 'Aucune session de caisse ouverte : ouvrez-la depuis la caisse.');
    final production = ctx.production;
    if (!production && mode != 'full') throw const AdapterFailure('reglement_refuse', 'Le Service de table se règle en une fois, toute la commande.');
    final first = view.order.activeLines.every((l) => l.settled == 0);
    final rest = [for (final l in view.order.activeLines) if (l.quantity > l.settled) l];
    final restPayable = first
        ? view.payable
        : webTotals(
            lineBases: [for (final l in rest) Decimal6.amount(l.unitPrice, l.quantity - l.settled)],
            lineDiscounts: [for (final _ in rest) 0],
            globalDiscount: 0,
            vatRate: snapshot.store.vatRate,
            vatIncluded: snapshot.store.vatIncluded,
          ).payable;
    Map<String, int>? items;
    var count = 0;
    if (mode == 'items') {
      items = {for (final e in _restoQuantities(args['items']).entries) if (e.value > 0) e.key: e.value};
      if (items.isEmpty) throw const AdapterFailure('reglement_refuse', 'Choisissez au moins un article à régler.');
    } else if (mode == 'shares') {
      count = _int(args, 'shares');
      final maxShares = restPayable < 50 ? restPayable : 50;
      if (count < 2 || count > maxShares) throw AdapterFailure('reglement_refuse', 'Partagez l’addition en 2 à $maxShares parts.');
    }
    final List<CartLine> lines;
    try {
      lines = items != null ? await engine.restoCartItems(orderUuid, items) : await engine.restoCart(orderUuid);
      allocateLots(snapshot, lines);
    } on OfflineRefusal catch (e) {
      throw AdapterFailure('reglement_refuse', e.message);
    }
    // À payer de ce règlement : celui de la commande pour tout régler d'un coup, sinon celui du panier rendu.
    final payable = !production || (mode == 'full' && first)
        ? view.payable
        : webTotals(
            lineBases: [for (final l in lines) l.base],
            lineDiscounts: [for (final l in lines) l.discount],
            globalDiscount: 0,
            vatRate: snapshot.store.vatRate,
            vatIncluded: snapshot.store.vatIncluded,
          ).payable;
    final shares = mode == 'shares' ? [for (var i = 0; i < count; i++) payable ~/ count + (i < payable % count ? 1 : 0)].where((a) => a > 0).toList() : <int>[];
    _restoSettlementPrepared = _RestoSettlement(orderUuid: orderUuid, mode: mode, lines: lines, payable: payable, shares: shares);
    return {
      'order_uuid': orderUuid,
      'mode': mode,
      'payable': payable,
      'payable_label': formatFcfa(payable),
      'rest_payable': restPayable,
      'shares': [for (final (i, a) in shares.indexed) {'index': i, 'label': 'Part ${i + 1}', 'amount': a, 'amount_label': formatFcfa(a)}],
      'lines': [for (final l in lines) {'label': l.label, 'quantity_label': formatMicros(l.quantity), 'total_label': formatFcfa(l.base - l.discount)}],
      'methods': [for (final m in snapshot.methods) {'code': m.code, 'name': m.name, 'cash': m.isCash, 'reference': m.referenceMode}],
    };
  }

  /// Encaissement du règlement préparé (`payments` : method, amount, received, reference, et `share` en mode parts) ; la
  /// vente porte l'identifiant d'opération, la commande se clôt une fois soldée. Rejeu : la même vente.
  Future<Map<String, dynamic>> _restoSettle(Map<String, dynamic> args, String? operationId) {
    final orderUuid = _text(args, 'order_uuid', max: 36);
    final rawPayments = args['payments'] ?? const [];
    if (rawPayments is! List || rawPayments.length > 50 || rawPayments.any((p) => p is! Map)) {
      throw const AdapterFailure('argument_invalide', 'Argument « payments » invalide.');
    }
    final entries = [for (final p in rawPayments) Map<String, dynamic>.from(p as Map)];
    return _restoWrite('restoSettle', operationId, (operator, id) async {
      final prepared = _restoSettlementPrepared;
      if (prepared == null || prepared.orderUuid != orderUuid) {
        throw const AdapterFailure('reglement_a_preparer', 'Préparez d’abord l’encaissement de cette commande (restoPrepareSettlement).');
      }
      if (!engine.sessionOpen) throw const AdapterFailure('session_requise', 'Aucune session de caisse ouverte : ouvrez-la depuis la caisse.');
      final snapshot = _snapshot();
      final drafts = <_DraftPayment>[];
      final groups = <int, List<_DraftPayment>>{};
      final shareOf = <int>[];
      for (final e in entries) {
        final method = snapshot.methods.where((m) => m.code == e['method']).firstOrNull;
        final amount = e['amount'];
        final received = e['received'];
        final reference = e['reference'];
        if (method == null) throw const AdapterFailure('paiement_invalide', 'Moyen de paiement non autorisé sur ce terminal.');
        if (amount is! int || (received != null && received is! int) || (reference != null && reference is! String)) {
          throw const AdapterFailure('paiement_invalide', 'Paiement mal formé (montant et reçu en francs entiers).');
        }
        final text = (reference as String?)?.trim() ?? '';
        final draft = _DraftPayment(
          methodCode: method.code,
          amount: amount,
          received: method.isCash ? (received as int? ?? engine.cashDue(amount)) : null,
          reference: method.isCash || text.isEmpty ? null : text,
        );
        drafts.add(draft);
        final share = prepared.shares.isEmpty ? 0 : e['share'];
        if (share is! int || (prepared.shares.isNotEmpty && (share < 0 || share >= prepared.shares.length))) {
          throw const AdapterFailure('paiement_invalide', 'Chaque paiement indique sa part (`share`).');
        }
        shareOf.add(share);
        (groups[share] ??= []).add(draft);
      }
      if (prepared.payable == 0) {
        // Commande à 0 F (entièrement offerte) : réglée sans paiement.
        if (drafts.isNotEmpty) throw const AdapterFailure('paiement_invalide', 'Commande à 0 F : aucun paiement.');
      } else if (prepared.shares.isEmpty) {
        final error = _paymentsError(snapshot, drafts, prepared.payable);
        if (error != null) throw AdapterFailure('paiement_invalide', error);
      } else {
        for (final (i, amount) in prepared.shares.indexed) {
          final error = _paymentsError(snapshot, groups[i] ?? const [], amount);
          if (error != null) throw AdapterFailure('paiement_invalide', 'Part ${i + 1} : $error');
        }
      }
      final payments = [
        for (final p in drafts)
          CartPayment(
            method: snapshot.methods.firstWhere((m) => m.code == p.methodCode),
            amount: p.amount,
            received: p.received,
            reference: p.reference,
            cashDue: p.received == null ? null : engine.cashDue(p.amount),
          ),
      ];
      final shares = prepared.shares.isEmpty
          ? null
          : [
              for (final (i, amount) in prepared.shares.indexed)
                RestoShare(label: 'Part ${i + 1}', amount: amount, payments: [for (var k = 0; k < shareOf.length; k++) if (shareOf[k] == i) k]),
            ];
      final sale = await engine.restoSettle(operator, orderUuid, prepared.lines, payments, shares: shares, operationUuid: id);
      _restoSettlementPrepared = null;
      return _restoSettled(sale, orderUuid, change: payments.fold<int>(0, (sum, p) => sum + p.change));
    }, recover: (id) async {
      final sale = await engine.saleStatus(id);
      return sale == null ? null : await _restoSettled(sale, orderUuid);
    });
  }

  Future<Map<String, dynamic>> _restoSettled(OfflineOperation sale, String orderUuid, {int? change}) async {
    final view = (await engine.restaurantOrders(all: true)).where((o) => o.order.uuid == orderUuid).firstOrNull;
    return {
      'state': 'committed',
      'sale_id': sale.uuid,
      'number': sale.number,
      'total': sale.total,
      'server_status': sale.serverStatus,
      'change': change,
      'change_label': change == null ? null : formatFcfa(change),
      'order': view == null ? null : _restoOrderJson(view),
      'closed': view != null && !view.order.isOpen,
    };
  }

  Future<Map<String, dynamic>> _restoRegisterWrite(String command, Map<String, dynamic> args, String? operationId) {
    final note = _optionalText(args, 'note', max: 2000);
    return _restoWrite(command, operationId, (operator, _) async {
      final register = command == 'restoRegisterOpen' ? await engine.restoRegisterOpen(operator, note: note) : await engine.restoRegisterClose(operator, note: note);
      return {'register': _restoRegisterJson(register)};
    });
  }

  /// Remboursement d'une vente restaurant : `type` retour (`lines` : {line_uuid: "1"}) ou annulation, motif, autorisation
  /// `remboursement` si l'opérateur n'a pas les droits ; l'opération porte l'identifiant d'opération.
  Future<Map<String, dynamic>> _restoRefund(Map<String, dynamic> args, String? operationId) {
    final sale = _text(args, 'sale_uuid', max: 36);
    final type = _text(args, 'type', max: 16);
    final quantities = type == 'annulation' ? const <String, int>{} : _restoQuantities(args['lines']);
    final reason = _restoReason(args);
    Map<String, dynamic> done(OfflineOperation o) => {
      'refund_id': o.uuid,
      'amount': o.content['montant'],
      'amount_label': o.content['montant'] is int ? formatFcfa(o.content['montant'] as int) : null,
      'server_status': o.serverStatus,
    };
    return _restoWrite('restoRefund', operationId, (operator, id) async {
      final blocker = engine.restoRefundBlocker(operator);
      if (blocker != null) throw OfflineRefusal(blocker);
      final approval = await _restoApproval(operator, args, await _restoTerms(operator, 'refund', args), reason);
      return done(await engine.restoRefund(operator, sale, type, quantities, reason, approval: approval, operationUuid: id));
    }, recover: (id) async {
      final found = await engine.saleStatus(id);
      return found == null ? null : done(found);
    });
  }

  // ------------------------------------------------------------------ bons : vérification, duplicata, imprimantes

  Future<Map<String, dynamic>> _restoVerifyTicket(Map<String, dynamic> args, String? operationId) {
    final ticket = _text(args, 'ticket_uuid', max: 36);
    final printed = args['printed'];
    if (printed is! bool) throw const AdapterFailure('argument_invalide', 'Argument « printed » invalide (true : sorti, false : pas sorti).');
    return _restoWrite('restoVerifyTicket', operationId, (operator, _) async {
      await engine.restoVerifyTicket(operator, ticket, printed: printed);
      return {'ticket_uuid': ticket, 'printed': printed};
    });
  }

  /// DUPLICATA d'un bon avec un motif : `transmis`, `non_envoye`, `a_verifier`, ou `delegue` (travail confié à l'interface,
  /// `print_jobs` dans la réponse).
  Future<Map<String, dynamic>> _restoDuplicateTicket(Map<String, dynamic> args, String? operationId) {
    final ticket = _text(args, 'ticket_uuid', max: 36);
    final reason = _text(args, 'reason', max: 500);
    return _restoWrite('restoDuplicateTicket', operationId, (operator, _) async {
      final outcome = await engine.restoDuplicateTicket(operator, ticket, reason);
      return {'ticket_uuid': ticket, 'result': outcome?.code ?? 'delegue'};
    });
  }

  Future<Map<String, dynamic>> _restoSetPrinterAddress(Map<String, dynamic> args, String? operationId) {
    final station = _text(args, 'station_uuid', max: 36);
    final address = _optionalText(args, 'address', max: 260);
    return _restoWrite('restoSetPrinterAddress', operationId, (operator, _) async {
      final blocker = engine.restaurantBlocker(operator);
      if (blocker != null) throw OfflineRefusal(blocker);
      await engine.setRestoPrinterAddress(station, address);
      return {'station_uuid': station, 'address': engine.restoPrinterAddresses[station]};
    });
  }

  // ------------------------------------------------------------------ pont d'impression hôte → interface

  /// Crochet du moteur ([CaisseEngine.restoDeferredPrinter]) : le travail est conservé AVANT de rendre la main ; l'interface
  /// est prévenue par `resto_impression`.
  Future<void> _restoEnqueue(RestoDeferredPrint job) async {
    final jobs = await _restoJobs();
    if (!jobs.any((j) => j['job_id'] == job.uuid)) {
      jobs.add({
        ...job.toJson(),
        'job_id': job.uuid,
        'state': 'en_attente',
        'result': null,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'journalized': false,
      });
      await _restoJobsWrite(jobs);
    }
    _restoNewJobs.add(job.uuid);
    _emit('resto_impression');
  }

  Future<List<Map<String, dynamic>>> _restoJobs() async =>
      [for (final j in (jsonDecode(await engine.store.read(_restoJobsKey) ?? '[]') as List).cast<Map>()) j.cast<String, dynamic>()];

  /// Garde les travaux en cours et les [_restoJobsKept] derniers terminés (et journalisés).
  Future<void> _restoJobsWrite(List<Map<String, dynamic>> jobs) async {
    final finished = jobs.where((j) => j['state'] == 'termine' && j['journalized'] == true).length;
    var drop = finished > _restoJobsKept ? finished - _restoJobsKept : 0;
    await engine.store.write(_restoJobsKey, jsonEncode([
      for (final j in jobs)
        if (j['state'] != 'termine' || j['journalized'] != true || drop-- <= 0) j,
    ]));
  }

  Map<String, dynamic> _restoJobJson(Map<String, dynamic> j) => {
    'job_id': j['job_id'],
    'kind': j['kind'],
    'ticket_uuid': j['ticket_uuid'],
    'order_uuid': j['order_uuid'],
    'station_uuid': j['station_uuid'],
    'station_name': j['station_name'],
    'target': j['target'],
    'address': j['address'],
    'fallback': j['fallback'],
    'lines': j['lines'],
    'state': j['state'],
    'result': j['result'],
    'created_at': j['created_at'],
  };

  /// Travaux à imprimer (`en_attente`) et commencés sans résultat (`en_cours`, à déclarer `a_verifier` après un arrêt de
  /// l'interface), du plus ancien au plus récent. Sans caissier : l'impression ne dépend pas de l'écran verrouillé.
  Future<Map<String, dynamic>> _restoPrintJobs() async => {
    'jobs': [for (final j in await _restoJobs()) if (j['state'] != 'termine') _restoJobJson(j)],
  };

  /// L'interface commence l'impression : `print: true` une seule fois par travail. Déjà commencé ou terminé : `print:
  /// false`, ne jamais imprimer (issue inconnue = `a_verifier`).
  Future<Map<String, dynamic>> _restoPrintStart(Map<String, dynamic> args) async {
    final id = _text(args, 'job_id', max: 36);
    final jobs = await _restoJobs();
    final job = jobs.where((j) => j['job_id'] == id).firstOrNull ?? (throw const AdapterFailure('travail_inconnu', 'Travail d’impression introuvable.'));
    if (job['state'] != 'en_attente') return {..._restoJobJson(job), 'print': false};
    job
      ..['state'] = 'en_cours'
      ..['started_at'] = DateTime.now().toUtc().toIso8601String();
    await _restoJobsWrite(jobs);
    return {..._restoJobJson(job), 'print': true};
  }

  /// Acquittement durable d'un travail : `transmis`, `non_envoye` (rien n'est parti : la chaîne de secours du moteur
  /// reprend), `a_verifier` (issue inconnue : jamais relancé, vérification sur place). Rejoué avec le même résultat, il
  /// rend la même réponse ; un autre résultat est refusé.
  Future<Map<String, dynamic>> _restoPrintResult(Map<String, dynamic> args) async {
    final id = _text(args, 'job_id', max: 36);
    final code = _text(args, 'result', max: 16);
    if (!const {'transmis', 'non_envoye', 'a_verifier'}.contains(code)) {
      throw const AdapterFailure('argument_invalide', 'Résultat invalide (transmis, non_envoye, a_verifier).');
    }
    final jobs = await _restoJobs();
    final job = jobs.where((j) => j['job_id'] == id).firstOrNull ?? (throw const AdapterFailure('travail_inconnu', 'Travail d’impression introuvable.'));
    var replayed = false;
    if (job['state'] == 'termine') {
      if (job['result'] != code) throw AdapterFailure('resultat_deja_enregistre', 'Résultat déjà enregistré pour ce travail : ${job['result']}.');
      replayed = true;
    } else {
      job
        ..['state'] = 'termine'
        ..['result'] = code
        ..['journalized'] = false
        ..['finished_at'] = DateTime.now().toUtc().toIso8601String();
      await _restoJobsWrite(jobs);
    }
    _restoNewJobs.clear();
    final journalized = job['journalized'] == true || await _restoJournalize(id);
    _emit('resto_impression');
    return {
      ..._restoJobJson(job),
      'state': 'termine',
      'result': code,
      'journalized': journalized,
      if (replayed) 'replayed': true,
      // Secours repris par le moteur après un échec certain : nouveaux travaux, autre identifiant.
      if (_restoNewJobs.isNotEmpty) 'print_jobs': [..._restoNewJobs],
    };
  }

  /// Passe l'acquittement [id] au journal des bons du moteur, une seule fois ; false si le moteur le refuse (restaurant
  /// indisponible) : l'acquittement reste conservé et repasse au démarrage suivant.
  Future<bool> _restoJournalize(String id) async {
    final job = (await _restoJobs()).where((j) => j['job_id'] == id).firstOrNull;
    if (job == null || job['state'] != 'termine') return false;
    if (job['journalized'] == true) return true;
    final print = RestoDeferredPrint.fromJson(job);
    final outcome = RestoOutcome.values.firstWhere((o) => o.code == job['result']);
    final inFlight = {
      for (final j in await _restoJobs())
        if (j['job_id'] != id && j['kind'] == 'livraison' && j['ticket_uuid'] == job['ticket_uuid'] && j['state'] != 'termine')
          RestoTarget.values.firstWhere((t) => t.code == j['target']),
    };
    final operatorId = print.operatorId;
    final operator = engine.snapshot?.operators.where((o) => o.id == operatorId).firstOrNull ??
        _operator ??
        Operator({'id': operatorId ?? 0, 'nom': ''});
    try {
      await engine.restoDeferredOutcome(operator, print, outcome, inFlight: inFlight);
    } on OfflineRefusal {
      return false;
    }
    // Relu : la reprise de la chaîne de secours a pu ajouter des travaux.
    final jobs = await _restoJobs();
    for (final j in jobs) {
      if (j['job_id'] == id) j['journalized'] = true;
    }
    await _restoJobsWrite(jobs);
    return true;
  }

  /// Au démarrage : acquittements conservés mais pas encore passés au journal (hôte arrêté entre les deux).
  Future<void> _restoJournalizePending() async {
    for (final j in await _restoJobs()) {
      if (j['state'] == 'termine' && j['journalized'] != true) await _restoJournalize(j['job_id'] as String);
    }
  }

  // ------------------------------------------------------------------ vues JSON

  Map<String, dynamic> _restoOrderJson(RestoOrderView v) {
    final ctx = engine.restaurant;
    final o = v.order;
    final active = o.activeLines;
    return {
      'order_uuid': o.uuid,
      'local_number': o.localNumber,
      'server_number': v.serverNumber,
      'business_day': o.businessDay,
      'profile': o.profile,
      'channel': o.channel,
      'channel_name': ctx?.channel(o.channel)?.name,
      'table_uuid': o.tableUuid,
      'table_name': ctx?.table(o.tableUuid)?.name,
      'covers': o.covers,
      'server_id': o.serverId,
      'customer_uuid': o.customerUuid,
      'customer_name': o.customerName,
      'external_reference': o.externalReference,
      'comment': o.comment,
      'status': o.status,
      'stage': o.stage,
      'version': o.version,
      'prebills': o.prebills,
      'gross': active.fold<int>(0, (sum, l) => sum + l.gross),
      'discounts': active.fold<int>(o.globalDiscount, (sum, l) => sum + l.lineDiscount),
      'global_discount': o.globalDiscount,
      'global_discount_label': formatFcfa(o.globalDiscount),
      'global_discount_source': o.globalDiscountSource,
      'discount_frozen': o.discountFrozen,
      'discount_base': RestoEngine.orderDiscountBase(o),
      'discount_ceiling': engine.restoOrderDiscountCeiling(o),
      'payable': v.payable,
      'payable_label': formatFcfa(v.payable),
      'paid': v.paid,
      'announced': RestoEngine.hasAnnounced(o),
      'pending_versions': v.pendingVersions,
      'server_message': v.serverMessage,
      'waiting': v.waiting,
      'sync_message': _restoSyncMessage(v),
      'tickets_to_check': v.ticketsToCheck,
      'lines': [
        for (final l in o.lines)
          {
            'line_uuid': l.uuid,
            'label': l.label,
            'quantity': Decimal6.format(l.quantity),
            'quantity_label': Decimal6.label(l.quantity),
            'unit_price': l.unitPrice,
            'unit_price_label': formatFcfa(l.unitPrice),
            'gross': l.gross,
            'discount': l.lineDiscount,
            'total': l.total,
            'total_label': formatFcfa(l.total),
            'comment': l.comment,
            'status': l.status.name,
            'state_label': _restoLineState(l),
            'active': l.active,
            'free': l.free,
            'sent': Decimal6.format(l.sent),
            'to_send': Decimal6.format(l.toSend),
            'settled': Decimal6.format(l.settled),
            'rest': Decimal6.format(l.quantity > l.settled ? l.quantity - l.settled : 0),
            'station_uuid': l.stationUuid,
            'promotion_uuid': l.promotionUuid,
            'promotion_name': l.promotionUuid == null ? null : ctx?.promotion(l.promotionUuid)?.name,
            'tariff': l.tariff,
            'staff_id': l.staffId,
          },
      ],
      // Bons créés par ce fait (envoi, annulation) : leur livraison est suivie par restoTickets.
      'tickets': [for (final t in v.tickets) _restoTicketJson(t)],
    };
  }

  Map<String, dynamic> _restoTicketJson(RestoTicket t) => {
    'ticket_uuid': t.uuid,
    'order_uuid': t.orderUuid,
    'station_uuid': t.stationUuid,
    'number': t.number,
    'day_number': t.dayNumber,
    'type': t.type,
    'title': t.title,
    'lines': [for (final l in t.lines) {'line_uuid': l.lineUuid, 'label': l.label, 'quantity_label': Decimal6.label(l.quantity), 'comment': l.comment, 'action': l.action}],
  };

  Map<String, dynamic>? _restoRegisterJson(RestoRegisterView? r) => r == null
      ? null
      : {
          'uuid': r.uuid,
          'business_day': r.businessDay,
          'opened_at': r.openedAt.toUtc().toIso8601String(),
          'note': r.note,
          'open': r.open,
          'closed_at': r.closedAt?.toUtc().toIso8601String(),
          'z_local_number': r.zLocalNumber,
          'sales_total': r.salesTotal,
          'sales_total_label': formatFcfa(r.salesTotal),
          'server_state': r.serverState,
          'server_message': r.serverMessage,
          'waiting': r.waiting,
          'server_z_number': r.serverZNumber,
        };

  String _restoLineState(RestoLine l) => switch (l.status) {
    RestoLineStatus.cancelled => 'Annulée',
    RestoLineStatus.pending => 'En attente',
    RestoLineStatus.sent => engine.restaurant?.settings.sendToProduction == true && l.sent > 0 ? 'Envoyé' : 'Validé',
  };

  String? _restoSyncMessage(RestoOrderView o) =>
      o.serverMessage ?? (o.waiting ? 'En attente d’une version précédente' : o.pendingVersions > 0 ? 'Synchronisation en attente' : null);

  /// Préfacture imprimée en local, texte de l'écran Android : articles, total à payer, « pas un ticket de caisse ».
  List<String> _restoPrebillLines(RestoOrderView view) {
    final columns = paperWidth >= 80 ? 48 : 32;
    String row(String left, String right) {
      final room = columns - right.length - 1;
      final cut = left.length > room ? left.substring(0, room) : left;
      return '$cut${' ' * (columns - cut.length - right.length)}$right';
    }

    final order = view.order;
    final table = engine.restaurant?.table(order.tableUuid)?.name ?? '';
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return [
      engine.snapshot?.store.name ?? '',
      'PRÉFACTURE ${order.prebills > 1 ? '(${order.prebills})' : ''}'.trim(),
      'Commande ${order.localNumber}',
      if (table.isNotEmpty) 'Table $table${order.covers == null ? '' : ' · ${order.covers} couverts'}',
      '${two(now.day)}/${two(now.month)}/${now.year} ${two(now.hour)}:${two(now.minute)}',
      '-' * columns,
      for (final l in order.activeLines) ...[
        l.label,
        row('  ${Decimal6.label(l.quantity)} x ${formatFcfa(l.unitPrice)}', formatFcfa(l.total)),
        if (l.comment != null) '  > ${l.comment}',
      ],
      '-' * columns,
      row('TOTAL À PAYER', formatFcfa(view.payable)),
      '',
      'Ce document n’est pas un ticket de caisse.',
    ];
  }

  // ------------------------------------------------------------------ arguments

  Future<RestoOrderView> _restoFind(String orderUuid) async =>
      (await engine.restaurantOrders(all: true)).where((o) => o.order.uuid == orderUuid).firstOrNull ??
      (throw const AdapterFailure('commande_inconnue', 'Commande introuvable sur ce terminal.'));

  RestoLine _restoLine(RestoOrder order, String uuid) =>
      order.lines.where((l) => l.uuid == uuid).firstOrNull ?? (throw const AdapterFailure('ligne_inconnue', 'Ligne introuvable dans la commande.'));

  /// Motif saisi (3 à 500 caractères), sans espaces autour.
  String _restoReason(Map<String, dynamic> args) {
    final value = args['reason'];
    final text = value is String ? value.trim() : '';
    if (text.length < 3 || text.length > 500) throw const AdapterFailure('motif_requis', 'Indiquez le motif (3 caractères au moins).');
    return text;
  }

  int? _restoCovers(Map<String, dynamic> args) {
    final value = args['covers'];
    if (value == null || value == 0) return null;
    if (value is! int || value < 0 || value > 500) throw const AdapterFailure('argument_invalide', 'Argument « covers » invalide (0 à 500).');
    return value;
  }

  /// Client connu cité à l'ouverture (`customer` {uuid, name}) : porte la remise client (R-5).
  Customer? _restoCustomer(Map<String, dynamic> args) {
    final raw = args['customer'];
    if (raw == null) return null;
    if (raw is! Map) throw const AdapterFailure('argument_invalide', 'Argument « customer » invalide.');
    final fields = raw.cast<String, dynamic>();
    return Customer(uuid: _text(fields, 'uuid', max: 36), name: _text(fields, 'name', max: 160), phone: fields['phone'] as String?);
  }

  /// Quantité en unité de base, « 1 », « 0,5 » ou « 1.5 » (six décimales au plus), strictement positive.
  int _restoMicros(Map<String, dynamic> args, String key) {
    final value = args[key];
    final micros = value is String && value.length <= 32 ? parseMicros(value) : null;
    if (micros == null || micros <= BigInt.zero) throw AdapterFailure('quantite_invalide', 'Argument « $key » : quantité positive, six décimales au plus.');
    return micros.toInt();
  }

  Map<String, int> _restoQuantities(Object? raw) {
    if (raw == null) return const {};
    if (raw is! Map || raw.length > 200) throw const AdapterFailure('argument_invalide', 'Quantités invalides ({line_uuid: "1"}).');
    final quantities = <String, int>{};
    for (final e in raw.entries) {
      final key = e.key;
      if (key is! String || key.length > 36) throw const AdapterFailure('argument_invalide', 'Quantités invalides ({line_uuid: "1"}).');
      quantities[key] = _restoMicros({'quantite': e.value}, 'quantite');
    }
    return quantities;
  }

  List<String> _restoUuidList(Object? raw) {
    if (raw == null) return const [];
    if (raw is! List || raw.length > 200 || raw.any((v) => v is! String || v.length > 36)) {
      throw const AdapterFailure('argument_invalide', 'Liste d’identifiants invalide.');
    }
    return raw.cast<String>();
  }

  /// Articles ajoutés : produit du catalogue du terminal, conditionnement facultatif, quantité (1 par défaut), commentaire.
  List<(CartLine, String?)> _restoItems(Object? raw) {
    if (raw == null) return const [];
    if (raw is! List || raw.length > 200 || raw.any((v) => v is! Map)) throw const AdapterFailure('argument_invalide', 'Argument « added » invalide.');
    final snapshot = _snapshot();
    return [
      for (final r in raw)
        () {
          final m = Map<String, dynamic>.from(r as Map);
          final product = snapshot.byId(_int(m, 'product_id')) ?? (throw const AdapterFailure('produit_inconnu', 'Produit absent du catalogue du terminal.'));
          final packagingId = m['packaging_id'];
          if (packagingId != null && packagingId is! int) throw const AdapterFailure('argument_invalide', 'Argument « packaging_id » invalide.');
          final packaging = packagingId == null
              ? null
              : product.packaging(packagingId as int) ?? (throw const AdapterFailure('conditionnement_inconnu', 'Conditionnement inconnu pour ce produit.'));
          final quantity = m['quantity'] == null ? Decimal6.scale : _restoMicros(m, 'quantity');
          final comment = _optionalText(m, 'comment', max: 500)?.trim();
          return (
            CartLine(product: product, packaging: packaging, quantity: BigInt.from(quantity)),
            comment == null || comment.isEmpty ? null : comment,
          );
        }(),
    ];
  }

  static String? _optionalText(Map<String, dynamic> args, String key, {required int max}) => args[key] == null ? null : _text(args, key, max: max);

  static String _text(Map<String, dynamic> args, String key, {required int max}) => LocalRegisterAdapter._text(args, key, max: max);

  static int _int(Map<String, dynamic> args, String key) => LocalRegisterAdapter._int(args, key);
}
