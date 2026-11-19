part of 'offline_register_page.dart';

/// Libellé de l'étape du Service de table (`ServiceStage::TABLE_LABELS` du web).
String _stageLabel(String? stage) => switch (stage) {
  'bill_printed' => 'Préfacture imprimée',
  'customer_validated' => 'Validée client',
  'amended' => 'Modifiée',
  _ => 'En attente',
};

/// Plan de salle de la caisse maîtresse (Service de table, capacité `restaurant.v1`, lots R-1 à R-3) : une tuile par
/// table, libre ou occupée par sa commande (numéro, montant, étape, remontée), bons à vérifier, imprimantes des postes.
/// Hors caisse maîtresse : lecture seule.
class _RestaurantFloor extends StatefulWidget {
  const _RestaurantFloor({required this.host});

  final _OfflineRegisterPageState host;

  @override
  State<_RestaurantFloor> createState() => _RestaurantFloorState();
}

class _RestaurantFloorState extends State<_RestaurantFloor> {
  List<RestoOrderView> _orders = const [];
  List<RestoTicketView> _alerts = const [];
  String? _room;
  bool _loading = true;

  CaisseEngine get _engine => widget.host._engine;

  @override
  void initState() {
    super.initState();
    _engine.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    _engine.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final orders = await _engine.restaurantOrders();
    final tickets = await _engine.restoTickets();
    if (!mounted) return;
    setState(() {
      _orders = orders;
      _alerts = [for (final t in tickets) if (t.state == RestoDeliveryState.toCheck || t.state == RestoDeliveryState.failed) t];
      _loading = false;
    });
  }

  /// Adresses des imprimantes de poste, saisies sur cette caisse (jamais reçues du serveur).
  Future<void> _printers() async {
    final ctx = _engine.restaurant!;
    final stations = ctx.stations.values.where((s) => s.active && s.paper).toList()..sort((a, b) => a.order.compareTo(b.order));
    final fields = {for (final s in stations) s.uuid: TextEditingController(text: _engine.restoPrinterAddresses[s.uuid] ?? '')};
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Imprimantes des postes'),
        content: SizedBox(
          width: 420,
          child: stations.isEmpty
              ? const Text('Aucun poste avec impression papier n’est publié pour cette boutique.')
              : SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Adresse réseau de l’imprimante ESC/POS de chaque poste (port 9100 par défaut). Vide : les bons sortent sur l’imprimante de la caisse.'),
                      const SizedBox(height: 8),
                      for (final s in stations)
                        TextField(
                          controller: fields[s.uuid],
                          keyboardType: TextInputType.url,
                          decoration: InputDecoration(labelText: s.name, hintText: '192.168.1.50:9100'),
                        ),
                    ],
                  ),
                ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          if (stations.isNotEmpty) FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Enregistrer')),
        ],
      ),
    );
    try {
      if (ok == true) {
        for (final s in stations) {
          await _engine.setRestoPrinterAddress(s.uuid, fields[s.uuid]!.text);
        }
        if (mounted) widget.host._toast('Imprimantes des postes enregistrées.');
      }
    } on OfflineRefusal catch (e) {
      await widget.host._refuse(e.message, title: 'Imprimante non enregistrée');
    } finally {
      for (final f in fields.values) {
        f.dispose();
      }
    }
  }

  Future<void> _showAlerts() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _TicketsSheet(host: widget.host, title: 'Bons à vérifier'),
    );
    await _reload();
  }

  Future<void> _openTable(RestoTable table, RestoOrderView? current) async {
    final operator = widget.host._operator!;
    var view = current;
    if (view == null) {
      final blocker = _engine.restaurantBlocker(operator);
      if (blocker != null) return widget.host._refuse(blocker, title: 'Commande impossible');
      final covers = await _askCovers(table);
      if (covers == null || !mounted) return;
      try {
        view = await _engine.restoOpen(operator, table.uuid, covers: covers == 0 ? null : covers);
      } on OfflineRefusal catch (e) {
        return widget.host._refuse(e.message, title: 'Commande impossible');
      }
    }
    if (!mounted) return;
    await Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => _RestaurantOrderPage(host: widget.host, orderUuid: view!.order.uuid)));
    await _reload();
  }

  /// Couverts à l'ouverture : 0 = non renseigné.
  Future<int?> _askCovers(RestoTable table) async {
    var covers = table.capacity ?? 0;
    return showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: Text('Ouvrir ${table.name}'),
          content: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton.filledTonal(onPressed: covers > 0 ? () => setDialog(() => covers--) : null, icon: const Icon(Icons.remove)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(covers == 0 ? '—' : '$covers couvert${covers > 1 ? 's' : ''}', style: const TextStyle(fontSize: 20)),
              ),
              IconButton.filledTonal(onPressed: covers < 500 ? () => setDialog(() => covers++) : null, icon: const Icon(Icons.add)),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.pop(context, covers), child: const Text('Ouvrir la commande')),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ctx = _engine.restaurant!;
    final operator = widget.host._operator!;
    final blocker = _engine.restaurantBlocker(operator);
    final brand = widget.host._brand;
    final rooms = ctx.rooms;
    final room = rooms.any((r) => r.uuid == _room) ? _room : (rooms.isEmpty ? null : rooms.first.uuid);
    final tables = [for (final t in ctx.tables) if (rooms.isEmpty || t.roomUuid == room || (t.roomUuid == null && room == rooms.first.uuid)) t];
    final byTable = <String, List<RestoOrderView>>{};
    for (final o in _orders) {
      if (o.order.tableUuid != null) (byTable[o.order.tableUuid!] ??= []).add(o);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (blocker != null)
          MaterialBanner(
            backgroundColor: Colors.amber.shade50,
            leading: const Icon(Icons.lock_outline),
            content: Text(blocker),
            actions: [TextButton(onPressed: () => widget.host._tryOnline(), child: const Text('Synchroniser'))],
          ),
        if (_alerts.isNotEmpty)
          MaterialBanner(
            backgroundColor: Colors.orange.shade50,
            leading: const Icon(Icons.print_disabled_outlined, color: Colors.deepOrange),
            content: Text('${_alerts.length} bon${_alerts.length > 1 ? 's' : ''} de production à vérifier : la cuisine ne l’a peut-être pas reçu.'),
            actions: [TextButton(onPressed: _showAlerts, child: const Text('Vérifier'))],
          ),
        if (blocker == null && ctx.settings.sendToProduction && ctx.stations.values.any((s) => s.active && s.paper))
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(onPressed: _printers, icon: const Icon(Icons.print_outlined, size: 18), label: const Text('Imprimantes des postes')),
          ),
        if (rooms.length > 1)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                for (final r in rooms)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(label: Text(r.name), selected: r.uuid == room, onSelected: (_) => setState(() => _room = r.uuid)),
                  ),
              ],
            ),
          ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : tables.isEmpty
              ? const Center(child: Text('Aucune table publiée pour ce point de vente.'))
              : GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 190, mainAxisExtent: 128, crossAxisSpacing: 10, mainAxisSpacing: 10),
                  itemCount: tables.length,
                  itemBuilder: (context, i) {
                    final table = tables[i];
                    final orders = byTable[table.uuid] ?? const [];
                    final view = orders.firstOrNull;
                    final busy = view != null;
                    return Material(
                      color: busy ? brand.withValues(alpha: .12) : Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(color: busy ? brand : Colors.black12, width: busy ? 2 : 1),
                      ),
                      child: InkWell(
                        key: ValueKey('table-${table.uuid}'),
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => _openTable(table, view),
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(child: Text(table.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis)),
                                  if (view != null && (view.serverMessage != null && !view.waiting))
                                    const Icon(Icons.warning_amber, color: Colors.orange, size: 20)
                                  else if (view != null && view.pendingVersions > 0)
                                    const Icon(Icons.cloud_upload_outlined, size: 18, color: Colors.black45),
                                ],
                              ),
                              const Spacer(),
                              if (view == null) ...[
                                Text(table.capacity == null ? 'Libre' : 'Libre · ${table.capacity} places', style: const TextStyle(color: Colors.black54)),
                              ] else ...[
                                Text(formatFcfa(view.payable), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: brand)),
                                Text(
                                  view.paid ? 'Réglée · à clôturer' : '${_stageLabel(view.order.stage)}${orders.length > 1 ? ' · ${orders.length} commandes' : ''}',
                                  style: const TextStyle(fontSize: 12),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(view.order.localNumber, style: const TextStyle(fontSize: 11, color: Colors.black45), maxLines: 1, overflow: TextOverflow.ellipsis),
                              ],
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// Bons de production (d'une commande, ou tous ceux à vérifier) : état de la livraison, vérification sur place,
/// duplicata.
class _TicketsSheet extends StatefulWidget {
  const _TicketsSheet({required this.host, required this.title, this.orderUuid});

  final _OfflineRegisterPageState host;
  final String title;
  final String? orderUuid;

  @override
  State<_TicketsSheet> createState() => _TicketsSheetState();
}

class _TicketsSheetState extends State<_TicketsSheet> {
  List<RestoTicketView>? _tickets;
  bool _busy = false;

  CaisseEngine get _engine => widget.host._engine;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final all = await _engine.restoTickets(orderUuid: widget.orderUuid);
    if (!mounted) return;
    setState(() => _tickets = widget.orderUuid != null ? all : [for (final t in all) if (t.state == RestoDeliveryState.toCheck || t.state == RestoDeliveryState.failed) t]);
  }

  Future<void> _act(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on OfflineRefusal catch (e) {
      if (mounted) await widget.host._refuse(e.message, title: 'Action impossible');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _reload();
    }
  }

  Future<void> _verify(RestoTicketView t) async {
    final printed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${t.ticket.title} ${t.ticket.dayNumber}'),
        content: Text('L’impression vers ${t.stationName} a eu une issue inconnue. Le bon est-il sorti au poste ?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Pas sorti')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Sorti')),
        ],
      ),
    );
    if (printed == null) return;
    await _act(() => _engine.restoVerifyTicket(widget.host._operator!, t.ticket.uuid, printed: printed));
  }

  Future<void> _duplicate(RestoTicketView t) async {
    final reason = TextEditingController(text: t.state == RestoDeliveryState.failed ? 'Bon non reçu au poste' : '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Réimprimer ${t.ticket.dayNumber}'),
        content: TextField(controller: reason, autofocus: true, maxLength: 500, decoration: const InputDecoration(labelText: 'Motif (3 caractères au moins)')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Imprimer le duplicata')),
        ],
      ),
    );
    final text = reason.text;
    reason.dispose();
    if (ok != true) return;
    await _act(() async {
      final outcome = await _engine.restoDuplicateTicket(widget.host._operator!, t.ticket.uuid, text);
      if (outcome == RestoOutcome.nonEnvoye && mounted) {
        await _show(t, 'Aucune imprimante n’a reçu le duplicata : remettez ce bon au poste.');
      } else if (outcome == RestoOutcome.aVerifier) {
        widget.host._toast('Impression du duplicata incertaine : vérifiez au poste.');
      }
    });
  }

  Future<void> _show(RestoTicketView t, [String? message]) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(t.ticket.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(message, style: const TextStyle(color: Colors.deepOrange))),
            Text(
              t.ticket.printLines(stationName: t.stationName, orderNumber: t.orderNumber, table: t.table).join('\n'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
          ],
        ),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Fermer'))],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final tickets = _tickets;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 8), child: Text(widget.title, style: Theme.of(context).textTheme.titleLarge)),
            if (tickets == null)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
            else if (tickets.isEmpty)
              const Padding(padding: EdgeInsets.all(24), child: Text('Aucun bon.'))
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final t in tickets)
                      ListTile(
                        leading: Icon(switch (t.state) {
                          RestoDeliveryState.delivered => Icons.check_circle_outline,
                          RestoDeliveryState.toCheck => Icons.help_outline,
                          RestoDeliveryState.failed => Icons.print_disabled_outlined,
                          RestoDeliveryState.pending => Icons.schedule,
                        }, color: switch (t.state) {
                          RestoDeliveryState.delivered => Colors.green,
                          RestoDeliveryState.pending => Colors.black45,
                          _ => Colors.deepOrange,
                        }),
                        title: Text('${t.ticket.title} · ${t.stationName} · ${t.ticket.dayNumber}'),
                        subtitle: Text([
                          if (widget.orderUuid == null) '${t.table == null ? '' : '${t.table} · '}${t.orderNumber}',
                          switch (t.state) {
                            RestoDeliveryState.delivered => 'Livré',
                            RestoDeliveryState.toCheck => 'Issue inconnue : à vérifier au poste',
                            RestoDeliveryState.failed => 'Non reçu par le poste',
                            RestoDeliveryState.pending => 'En cours de livraison',
                          },
                          '${t.ticket.lines.length} article${t.ticket.lines.length > 1 ? 's' : ''}',
                        ].join(' · ')),
                        onTap: () => _show(t),
                        trailing: _busy
                            ? null
                            : t.state == RestoDeliveryState.toCheck
                            ? TextButton(onPressed: () => _verify(t), child: const Text('Vérifier'))
                            : TextButton(onPressed: () => _duplicate(t), child: const Text('Réimprimer')),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Annulation d'un article envoyé ou d'une commande avec des articles annoncés : motif, puis, si l'opérateur n'a pas le
/// droit (ou si la boutique l'exige toujours), code de 8 chiffres d'un responsable.
class _SentCancelDialog extends StatefulWidget {
  const _SentCancelDialog({required this.engine, required this.operator, required this.title, required this.amountOf, this.maxQuantity});

  final CaisseEngine engine;
  final Operator operator;
  final String title;

  /// Montant autorisé pour une quantité donnée (plafonds de l'assistant).
  final int Function(int quantity) amountOf;

  /// Quantité maximale à annuler (article) ; null = commande entière.
  final int? maxQuantity;

  @override
  State<_SentCancelDialog> createState() => _SentCancelDialogState();
}

class _SentCancelDialogState extends State<_SentCancelDialog> {
  final _reason = TextEditingController();
  final _code = TextEditingController();
  late int _quantity = widget.maxQuantity == null ? 0 : (widget.maxQuantity! < Decimal6.scale ? widget.maxQuantity! : Decimal6.scale);
  List<Operator>? _approvers;
  Operator? _approver;
  String? _error;
  bool _busy = false;

  bool get _needsApproval => widget.engine.restoApprovalRequired(widget.operator);

  @override
  void initState() {
    super.initState();
    _loadApprovers();
  }

  @override
  void dispose() {
    _reason.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _loadApprovers() async {
    if (!_needsApproval) return;
    final list = await widget.engine.restoApprovers(widget.operator, widget.amountOf(_quantity));
    if (!mounted) return;
    setState(() {
      _approvers = list;
      if (!list.any((o) => o.id == _approver?.id)) _approver = list.firstOrNull;
    });
  }

  Future<void> _confirm() async {
    final reason = _reason.text.trim();
    if (reason.length < 3) return setState(() => _error = 'Indiquez le motif (3 caractères au moins).');
    RestoApproval? approval;
    if (_needsApproval) {
      final approver = _approver;
      if (approver == null) return setState(() => _error = 'Aucun responsable de ce terminal ne peut autoriser cette annulation.');
      setState(() => _busy = true);
      try {
        approval = await widget.engine.restoAuthorize(cashier: widget.operator, approver: approver, code: _code.text.trim(), reason: reason, amount: widget.amountOf(_quantity));
      } on OfflineRefusal catch (e) {
        _code.clear();
        return setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    }
    if (mounted) Navigator.pop(context, (quantity: _quantity, reason: reason, approval: approval));
  }

  @override
  Widget build(BuildContext context) {
    final max = widget.maxQuantity;
    final approvers = _approvers;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (max != null && max > Decimal6.scale)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton.filledTonal(
                      onPressed: _quantity > Decimal6.scale ? () {
                        setState(() => _quantity -= Decimal6.scale);
                        _loadApprovers();
                      } : null,
                      icon: const Icon(Icons.remove),
                    ),
                    Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text('${Decimal6.label(_quantity)} à annuler', style: const TextStyle(fontSize: 18))),
                    IconButton.filledTonal(
                      onPressed: _quantity + Decimal6.scale <= max ? () {
                        setState(() => _quantity += Decimal6.scale);
                        _loadApprovers();
                      } : null,
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
              TextField(
                controller: _reason,
                autofocus: true,
                maxLength: 500,
                decoration: const InputDecoration(labelText: 'Motif (obligatoire)'),
              ),
              if (_needsApproval) ...[
                const SizedBox(height: 4),
                const Text('Article déjà envoyé : un responsable autorise avec son code.', style: TextStyle(color: Colors.black54)),
                if (approvers == null)
                  const Padding(padding: EdgeInsets.all(8), child: Center(child: CircularProgressIndicator()))
                else if (approvers.isEmpty)
                  const Padding(padding: EdgeInsets.only(top: 8), child: Text('Aucun responsable de ce terminal ne peut autoriser cette annulation.', style: TextStyle(color: Colors.red)))
                else ...[
                  DropdownButtonFormField<int>(
                    initialValue: _approver?.id,
                    decoration: const InputDecoration(labelText: 'Responsable'),
                    items: [for (final o in approvers) DropdownMenuItem(value: o.id, child: Text(o.name))],
                    onChanged: (id) => setState(() => _approver = approvers.firstWhere((o) => o.id == id)),
                  ),
                  TextField(
                    controller: _code,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 8,
                    decoration: const InputDecoration(labelText: 'Code du responsable (8 chiffres)'),
                  ),
                ],
              ],
              if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Retour')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          onPressed: _busy ? null : _confirm,
          child: Text(max == null ? 'Annuler la commande' : 'Annuler l’article'),
        ),
      ],
    );
  }
}

/// Ligne ajoutée à l'écran, pas encore enregistrée : la validation en fait une version `lignes`.
class _DraftItem {
  _DraftItem(this.line);

  final CartLine line;
  String? comment;
}

/// Commande d'une table : lignes enregistrées, ajouts en cours, préfacture, transfert, annulation et encaissement.
class _RestaurantOrderPage extends StatefulWidget {
  const _RestaurantOrderPage({required this.host, required this.orderUuid});

  final _OfflineRegisterPageState host;
  final String orderUuid;

  @override
  State<_RestaurantOrderPage> createState() => _RestaurantOrderPageState();
}

class _RestaurantOrderPageState extends State<_RestaurantOrderPage> {
  final _search = TextEditingController();
  final _added = <_DraftItem>[];
  final _quantities = <String, int>{};
  final _removed = <String>{};
  RestoOrderView? _view;
  bool _busy = false;
  String? _category;

  CaisseEngine get _engine => widget.host._engine;
  Operator get _operator => widget.host._operator!;
  Color get _brand => widget.host._brand;
  bool get _dirty => _added.isNotEmpty || _quantities.isNotEmpty || _removed.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final all = await _engine.restaurantOrders(all: true);
    if (!mounted) return;
    setState(() => _view = all.where((o) => o.order.uuid == widget.orderUuid).firstOrNull);
  }

  Future<void> _refuse(String message, {String title = 'Action impossible'}) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.block, color: Colors.red, size: 40),
      title: Text(title),
      content: Text(message),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Compris'))],
    ),
  );

  /// Exécute une action du moteur ; refus affiché, commande relue.
  Future<bool> _run(Future<Object?> Function() action, {String title = 'Action impossible'}) async {
    if (_busy) return false;
    setState(() => _busy = true);
    try {
      await action();
      return true;
    } on OfflineRefusal catch (e) {
      if (mounted) await _refuse(e.message, title: title);
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
      await _reload();
    }
  }

  void _add(Product product, {Packaging? packaging}) {
    setState(() {
      final same = _added.where((d) => d.line.product.id == product.id && d.line.packaging?.id == packaging?.id && d.comment == null).firstOrNull;
      if (same != null) {
        same.line.quantity += BigInt.from(Decimal6.scale);
      } else {
        _added.add(_DraftItem(CartLine(product: product, packaging: packaging, quantity: BigInt.from(Decimal6.scale))));
      }
    });
  }

  Future<void> _pick(Product product) async {
    final packs = product.packagings;
    if (packs.isEmpty) return _add(product);
    final choice = await showModalBottomSheet<Packaging?>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(product.name), subtitle: Text(formatFcfa(product.price)), onTap: () => Navigator.pop(context)),
            for (final p in packs) ListTile(title: Text('${product.name} (${p.name})'), subtitle: Text(formatFcfa(p.price)), onTap: () => Navigator.pop(context, p)),
          ],
        ),
      ),
    );
    if (!mounted) return;
    _add(product, packaging: choice);
  }

  Future<void> _save() async {
    final ok = await _run(
      () => _engine.restoEditLines(
        _operator,
        widget.orderUuid,
        added: [for (final d in _added) (d.line, d.comment)],
        quantities: Map.of(_quantities),
        removed: Set.of(_removed),
      ),
      title: 'Commande non enregistrée',
    );
    if (ok && mounted) {
      setState(() {
        _added.clear();
        _quantities.clear();
        _removed.clear();
      });
    }
  }

  Future<void> _comment(_DraftItem item) async {
    final field = TextEditingController(text: item.comment ?? '');
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Commentaire · ${item.line.label}'),
        content: TextField(controller: field, autofocus: true, maxLength: 500, decoration: const InputDecoration(hintText: 'Bien cuit, sans piment…')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, field.text), child: const Text('OK')),
        ],
      ),
    );
    field.dispose();
    if (text != null && mounted) setState(() => item.comment = text.trim().isEmpty ? null : text.trim());
  }

  Future<void> _prebill() async {
    final view = _view;
    if (view == null) return;
    final ok = await _run(() => _engine.restoPrebill(_operator, widget.orderUuid), title: 'Préfacture impossible');
    if (ok) await _printPrebill();
  }

  /// Préfacture imprimée en local (le serveur n'imprime rien) : articles, total à payer, mention « pas un ticket de caisse ».
  Future<void> _printPrebill() async {
    final view = _view;
    final snapshot = widget.host._snapshot;
    if (view == null || snapshot == null) return;
    final width = widget.host.widget.session.rollWidth > 0 ? widget.host.widget.session.rollWidth : 58;
    final columns = width >= 80 ? 48 : 32;
    String row(String left, String right) {
      final room = columns - right.length - 1;
      final cut = left.length > room ? left.substring(0, room) : left;
      return '$cut${' ' * (columns - cut.length - right.length)}$right';
    }

    final order = view.order;
    final table = _engine.restaurant?.table(order.tableUuid)?.name ?? '';
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final text = <String>[
      snapshot.store.name,
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
    await widget.host._printText(text, failure: 'Préfacture non imprimée', saved: ' : elle est bien enregistrée.');
  }

  Future<void> _transfer() async {
    final ctx = _engine.restaurant!;
    final order = _view?.order;
    if (order == null) return;
    final target = await showDialog<RestoTable>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Transférer vers la table'),
        children: [
          for (final t in ctx.tables)
            if (t.uuid != order.tableUuid) SimpleDialogOption(onPressed: () => Navigator.pop(context, t), child: Text(t.name, style: const TextStyle(fontSize: 16))),
        ],
      ),
    );
    if (target == null || !mounted) return;
    await _run(() => _engine.restoTransfer(_operator, widget.orderUuid, target.uuid), title: 'Transfert impossible');
  }

  /// Envoi aux postes (ou « Valider », envoi éteint) : un bon par poste, livré aussitôt ; un bon non reçu est signalé.
  Future<void> _send() async {
    RestoOrderView? sent;
    final ok = await _run(() async => sent = await _engine.restoSend(_operator, widget.orderUuid), title: 'Envoi impossible');
    if (!ok || sent == null || !mounted) return;
    final tickets = sent!.tickets;
    // Comme « Mettre en attente » du web (TBC) : la commande reste ouverte et l'on revient à la salle.
    if (tickets.isEmpty) {
      widget.host._toast('Commande validée.');
      return Navigator.pop(context);
    }
    final states = {for (final t in await _engine.restoTickets(orderUuid: widget.orderUuid)) t.ticket.uuid: t.state};
    final missed = tickets.where((t) => states[t.uuid] != RestoDeliveryState.delivered).length;
    if (!mounted) return;
    if (missed == 0) {
      widget.host._toast('${tickets.length} bon${tickets.length > 1 ? 's' : ''} envoyé${tickets.length > 1 ? 's' : ''}.');
      Navigator.pop(context);
    } else {
      await _refuse('$missed bon${missed > 1 ? 's' : ''} sur ${tickets.length} pas reçu${missed > 1 ? 's' : ''} avec certitude : vérifiez au poste depuis « Bons ».',
          title: 'Envoi à vérifier');
    }
  }

  Future<void> _tickets() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _TicketsSheet(host: widget.host, title: 'Bons de la commande', orderUuid: widget.orderUuid),
    );
    await _reload();
  }

  /// Article envoyé : réduit ou annulé avec un motif, et l'autorisation d'un responsable si l'opérateur n'a pas le droit.
  Future<void> _cancelSent(RestoLine line) async {
    final result = await showDialog<({int quantity, String reason, RestoApproval? approval})>(
      context: context,
      builder: (_) => _SentCancelDialog(
        engine: _engine,
        operator: _operator,
        title: 'Annuler · ${line.label}',
        maxQuantity: line.quantity,
        amountOf: (quantity) => Decimal6.amount(line.unitPrice, quantity),
      ),
    );
    if (result == null || !mounted) return;
    await _run(
      () => _engine.restoCancelLine(_operator, widget.orderUuid, line.uuid, result.quantity, result.reason, approval: result.approval),
      title: 'Annulation impossible',
    );
  }

  Future<void> _cancel() async {
    final view = _view;
    if (view == null) return;
    if (RestoEngine.hasAnnounced(view.order)) {
      // Des articles sont partis aux postes : motif, droit ou responsable, bons d'ANNULATION.
      final result = await showDialog<({int quantity, String reason, RestoApproval? approval})>(
        context: context,
        builder: (_) => _SentCancelDialog(engine: _engine, operator: _operator, title: 'Annuler la commande ?', amountOf: (_) => view.payable),
      );
      if (result == null || !mounted) return;
      final ok = await _run(() => _engine.restoCancel(_operator, widget.orderUuid, result.reason, approval: result.approval), title: 'Annulation impossible');
      if (ok && mounted) Navigator.pop(context);
      return;
    }
    final reason = TextEditingController();
    // Profil Restaurant (R-4) : motif toujours exigé.
    final required = (_engine.restaurant?.settings.cancellationReason ?? false) || (_engine.restaurant?.production ?? false);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Annuler la commande ?'),
        content: TextField(controller: reason, maxLength: 500, decoration: InputDecoration(labelText: required ? 'Motif (obligatoire)' : 'Motif')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Retour')),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.red), onPressed: () => Navigator.pop(context, true), child: const Text('Annuler la commande')),
        ],
      ),
    );
    final text = reason.text;
    reason.dispose();
    if (confirmed != true || !mounted) return;
    final ok = await _run(() => _engine.restoCancel(_operator, widget.orderUuid, text), title: 'Annulation impossible');
    if (ok && mounted) Navigator.pop(context);
  }

  /// Encaissement de toute la commande : panier rendu par le moteur (prix figés), paiement comme à la caisse, vente v2
  /// avec la commande, ticket, puis clôture.
  Future<void> _settle() async {
    final snapshot = widget.host._snapshot;
    final view = _view;
    if (snapshot == null || view == null) return;
    if (_dirty) return _refuse('Enregistrez d’abord les modifications de la commande.', title: 'Encaissement impossible');
    if (!_engine.sessionOpen) return _refuse('Aucune session de caisse ouverte : ouvrez-la depuis la caisse.', title: 'Encaissement impossible');
    // Profil Restaurant (R-4) : tout, par articles ou par parts ; le Service de table règle toujours tout.
    final production = _engine.restaurant?.production ?? false;
    final first = view.order.activeLines.every((l) => l.settled == 0);
    _SettlePlan? plan;
    if (production) {
      final rest = [for (final l in view.order.activeLines) if (l.quantity > l.settled) l];
      final restPayable = first ? view.payable : webTotals(
        lineBases: [for (final l in rest) Decimal6.amount(l.unitPrice, l.quantity - l.settled)],
        lineDiscounts: [for (final _ in rest) 0],
        globalDiscount: 0,
        vatRate: snapshot.store.vatRate,
        vatIncluded: snapshot.store.vatIncluded,
      ).payable;
      plan = await showDialog<_SettlePlan>(context: context, builder: (_) => _SettleChoiceDialog(order: view.order, payable: restPayable));
      if (plan == null || !mounted) return;
    }
    final List<CartLine> lines;
    try {
      lines = plan?.items != null ? await _engine.restoCartItems(widget.orderUuid, plan!.items!) : await _engine.restoCart(widget.orderUuid);
      allocateLots(snapshot, lines);
    } on OfflineRefusal catch (e) {
      return _refuse(e.message, title: 'Encaissement impossible');
    }
    if (!mounted) return;
    // À payer de ce règlement : celui de la commande pour tout régler d'un coup, sinon celui du panier rendu.
    final payable = plan == null || (plan.mode == _SettleMode.all && first)
        ? view.payable
        : webTotals(
            lineBases: [for (final l in lines) l.base],
            lineDiscounts: [for (final l in lines) l.discount],
            globalDiscount: 0,
            vatRate: snapshot.store.vatRate,
            vatIncluded: snapshot.store.vatIncluded,
          ).payable;
    final compact = widget.host._compact;
    Future<List<CartPayment>?> pay(int amount) async => compact
        ? await Navigator.of(context).push<List<CartPayment>>(
            MaterialPageRoute(fullscreenDialog: true, builder: (_) => _PaymentDialog(snapshot: snapshot, payable: amount, cashDue: _engine.cashDue, fullScreen: true)),
          )
        : await showDialog<List<CartPayment>>(
            context: context,
            barrierDismissible: false,
            builder: (_) => _PaymentDialog(snapshot: snapshot, payable: amount, cashDue: _engine.cashDue),
          );
    final List<CartPayment> payments;
    List<RestoShare>? shares;
    if (payable == 0) {
      // Commande à 0 F (entièrement offerte) : réglée sans paiement.
      payments = const [];
    } else if (plan?.mode == _SettleMode.shares) {
      // Une part après l'autre : chaque paiement appartient à sa part.
      payments = [];
      shares = [];
      for (final (i, amount) in _equalShares(payable, plan!.shares).indexed) {
        if (amount <= 0) continue;
        widget.host._toast('Part ${i + 1} sur ${plan.shares} : ${formatFcfa(amount)}');
        final part = await pay(amount);
        if (part == null || !mounted) return;
        shares.add(RestoShare(label: 'Part ${i + 1}', amount: amount, payments: [for (var k = 0; k < part.length; k++) payments.length + k]));
        payments.addAll(part);
      }
    } else {
      final chosen = await pay(payable);
      if (chosen == null || !mounted) return;
      payments = chosen;
    }
    if (!mounted) return;
    OfflineOperation? operation;
    final ok = await _run(() async => operation = await _engine.restoSettle(_operator, widget.orderUuid, lines, payments, shares: shares), title: 'Encaissement refusé');
    if (!ok || operation == null || !mounted) return;
    final session = widget.host.widget.session;
    if (session.hasPrinter && payments.any((p) => p.method.isCash)) unawaited(session.channel.openDrawer());
    var printed = widget.host._look.ticketMode == 'auto';
    if (printed) await widget.host._print(snapshot, operation!, lines, payments);
    final change = payments.fold<int>(0, (sum, p) => sum + p.change);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          icon: Icon(Icons.check_circle, color: _brand, size: 48),
          title: Text('Vente ${operation!.number}'),
          content: Text(
            change > 0 ? 'Monnaie à rendre : ${formatFcfa(change)}' : (_view?.order.isOpen ?? false) ? 'Règlement enregistré : il reste à payer.' : 'Commande réglée et close.',
            style: const TextStyle(fontSize: 20),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await widget.host._print(snapshot, operation!, lines, payments, duplicate: printed);
                setDialog(() => printed = true);
              },
              child: Text(printed ? 'Réimprimer' : 'Imprimer le ticket'),
            ),
            FilledButton(onPressed: () => Navigator.pop(context), child: Text((_view?.order.isOpen ?? false) ? 'Retour à la commande' : 'Retour à la salle')),
          ],
        ),
      ),
    );
    // Règlement partiel (Restaurant) : on reste sur la commande pour la suite.
    if (mounted && !(_view?.order.isOpen ?? false)) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final view = _view;
    final order = view?.order;
    final ctx = _engine.restaurant;
    final blocker = _engine.restaurantBlocker(_operator);
    final editable = blocker == null && order != null && order.isOpen && !(view?.paid ?? false);
    final table = ctx?.table(order?.tableUuid)?.name ?? ctx?.channel(order?.channel)?.name;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Modifications non enregistrées'),
            content: const Text('Les articles ajoutés ou modifiés seront perdus.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Rester')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Quitter sans enregistrer')),
            ],
          ),
        );
        if (leave == true && context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(order == null ? 'Commande' : '${table ?? 'Commande'} · ${order.localNumber}'),
          actions: [
            if (order != null && order.lines.any((l) => l.status != RestoLineStatus.pending))
              IconButton(
                tooltip: 'Bons',
                onPressed: _tickets,
                icon: Badge(isLabelVisible: (view?.ticketsToCheck ?? 0) > 0, label: Text('${view?.ticketsToCheck ?? 0}'), child: const Icon(Icons.receipt_long_outlined)),
              ),
            if (editable) ...[
              if (order.tableUuid != null) IconButton(tooltip: 'Transférer', onPressed: _busy || _dirty ? null : _transfer, icon: const Icon(Icons.swap_horiz)),
              IconButton(tooltip: 'Annuler la commande', onPressed: _busy || _dirty ? null : _cancel, icon: const Icon(Icons.delete_outline)),
            ],
            if (view?.paid ?? false)
              TextButton(onPressed: _busy ? null : () => _run(() => _engine.restoClose(_operator, widget.orderUuid)), child: const Text('Clôturer')),
          ],
        ),
        body: order == null
            ? const Center(child: CircularProgressIndicator())
            : LayoutBuilder(
                builder: (context, box) {
                  final lines = _lines(order, editable);
                  final catalog = editable ? _catalog() : null;
                  if (box.maxWidth >= 760 && catalog != null) {
                    return Row(children: [Expanded(flex: 5, child: catalog), const VerticalDivider(width: 1), Expanded(flex: 4, child: lines)]);
                  }
                  return catalog == null
                      ? lines
                      : DefaultTabController(
                          length: 2,
                          child: Column(
                            children: [
                              TabBar(tabs: [Tab(text: 'Commande (${order.activeLines.length + _added.length})'), const Tab(text: 'Ajouter')]),
                              Expanded(child: TabBarView(children: [lines, catalog])),
                            ],
                          ),
                        );
                },
              ),
        bottomNavigationBar: order == null || !order.isOpen ? null : SafeArea(child: _actions(view!, editable)),
      ),
    );
  }

  Widget _lines(RestoOrder order, bool editable) {
    final view = _view!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            Chip(label: Text(order.isOpen ? _stageLabel(order.stage) : (order.status == 'settled' ? 'Réglée' : 'Annulée'))),
            if (order.covers != null) Chip(label: Text('${order.covers} couverts')),
            if (order.prebills > 0) Chip(label: Text('${order.prebills} préfacture${order.prebills > 1 ? 's' : ''}')),
            if (order.isOpen && order.activeLines.any((l) => l.settled > 0)) const Chip(label: Text('Réglée en partie')),
            if (order.externalReference != null) Chip(label: Text('Réf. ${order.externalReference}')),
            if (view.serverNumber != null) Chip(label: Text('Serveur ${view.serverNumber}')),
            if (view.pendingVersions > 0) Chip(avatar: const Icon(Icons.cloud_upload_outlined, size: 16), label: Text('${view.pendingVersions} à transmettre')),
          ],
        ),
        if (view.serverMessage != null)
          Card(
            color: view.waiting ? Colors.blue.shade50 : Colors.orange.shade50,
            child: ListTile(leading: Icon(view.waiting ? Icons.hourglass_top : Icons.warning_amber), title: Text(view.serverMessage!)),
          ),
        for (final l in order.lines)
          if (l.active || !editable)
            ListTile(
              contentPadding: EdgeInsets.zero,
              enabled: l.active && !_removed.contains(l.uuid),
              title: Text(l.label, style: TextStyle(decoration: !l.active || _removed.contains(l.uuid) ? TextDecoration.lineThrough : null)),
              subtitle: Text([
                '${Decimal6.label(_quantities[l.uuid] ?? l.quantity)} x ${formatFcfa(l.unitPrice)}',
                if (l.status == RestoLineStatus.sent) _engine.restaurant?.settings.sendToProduction == true && l.sent > 0 ? 'Envoyé' : 'Validé',
                if (l.comment != null) l.comment!,
              ].join(' · ')),
              trailing: !editable || !l.active
                  ? Text(formatFcfa(l.total))
                  : l.status == RestoLineStatus.sent
                  // Envoyé : il ne change plus, il s'annule avec un motif (on ajoute l'article à nouveau pour en servir plus).
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(formatFcfa(l.total)),
                        IconButton(tooltip: 'Annuler l’article', onPressed: _busy || _dirty ? null : () => _cancelSent(l), icon: const Icon(Icons.cancel_outlined)),
                      ],
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_removed.contains(l.uuid))
                          TextButton(onPressed: () => setState(() => _removed.remove(l.uuid)), child: const Text('Garder'))
                        else ...[
                          IconButton(
                            tooltip: 'Moins',
                            onPressed: () => setState(() {
                              final q = (_quantities[l.uuid] ?? l.quantity) - Decimal6.scale;
                              if (q <= 0) {
                                _removed.add(l.uuid);
                                _quantities.remove(l.uuid);
                              } else {
                                _quantities[l.uuid] = q;
                              }
                            }),
                            icon: const Icon(Icons.remove_circle_outline),
                          ),
                          IconButton(
                            tooltip: 'Plus',
                            onPressed: () => setState(() => _quantities[l.uuid] = (_quantities[l.uuid] ?? l.quantity) + Decimal6.scale),
                            icon: const Icon(Icons.add_circle_outline),
                          ),
                        ],
                      ],
                    ),
            ),
        if (_added.isNotEmpty) ...[
          const Divider(),
          Text('À ajouter', style: TextStyle(color: _brand, fontWeight: FontWeight.w600)),
          for (final d in _added)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(d.line.label),
              subtitle: Text(['${Decimal6.label(d.line.quantity.toInt())} x ${formatFcfa(d.line.unitPrice)}', if (d.comment != null) d.comment!].join(' · ')),
              onTap: () => _comment(d),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Moins',
                    onPressed: () => setState(() {
                      d.line.quantity -= BigInt.from(Decimal6.scale);
                      if (d.line.quantity <= BigInt.zero) _added.remove(d);
                    }),
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                  IconButton(
                    tooltip: 'Plus',
                    onPressed: () => setState(() => d.line.quantity += BigInt.from(Decimal6.scale)),
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }

  Widget _catalog() {
    final snapshot = widget.host._snapshot!;
    final products = snapshot.search(_search.text, limit: null, category: _category);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _search,
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Rechercher un article', border: OutlineInputBorder(), isDense: true),
            onChanged: (_) => setState(() {}),
          ),
        ),
        if (snapshot.categories.isNotEmpty)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Padding(padding: const EdgeInsets.only(right: 6), child: ChoiceChip(label: const Text('Tout'), selected: _category == null, onSelected: (_) => setState(() => _category = null))),
                for (final c in snapshot.categories)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(label: Text(c), selected: _category == c, onSelected: (_) => setState(() => _category = c)),
                  ),
              ],
            ),
          ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 170, mainAxisExtent: 76, crossAxisSpacing: 8, mainAxisSpacing: 8),
            itemCount: products.length,
            itemBuilder: (context, i) {
              final p = products[i];
              return OutlinedButton(
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.all(8), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                onPressed: () => _pick(p),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
                    Text(formatFcfa(p.price), style: TextStyle(color: _brand, fontWeight: FontWeight.w600)),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _actions(RestoOrderView view, bool editable) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('À payer', style: TextStyle(color: Colors.black54)),
                Text(formatFcfa(view.payable), style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: _brand)),
              ],
            ),
          ),
          if (editable && _dirty)
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: _brand, minimumSize: const Size(0, 48)),
              onPressed: _busy ? null : _save,
              icon: const Icon(Icons.check),
              label: const Text('Enregistrer'),
            )
          else if (editable) ...[
            if (view.order.lines.any((l) => l.toSend > 0)) ...[
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Colors.deepOrange, minimumSize: const Size(0, 48)),
                onPressed: _busy ? null : _send,
                icon: const Icon(Icons.send_outlined),
                label: Text(_engine.restaurant?.sendLabel ?? 'Envoyer'),
              ),
              const SizedBox(width: 8),
            ],
            // Petit téléphone : la préfacture en icône, pour que « Valider » et « Encaisser » tiennent sur la ligne.
            if (widget.host._compact)
              IconButton.outlined(
                tooltip: 'Préfacture',
                onPressed: _busy || view.order.activeLines.isEmpty ? null : _prebill,
                icon: const Icon(Icons.receipt_outlined),
              )
            else
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: _busy || view.order.activeLines.isEmpty ? null : _prebill,
                icon: const Icon(Icons.receipt_outlined),
                label: const Text('Préfacture'),
              ),
            const SizedBox(width: 8),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: _brand, minimumSize: const Size(0, 48)),
              onPressed: _busy || view.order.activeLines.isEmpty || !_engine.hasRight(_operator, 'vente') ? null : _settle,
              icon: const Icon(Icons.payments_outlined),
              label: const Text('Encaisser'),
            ),
          ],
        ],
      ),
    );
  }
}
