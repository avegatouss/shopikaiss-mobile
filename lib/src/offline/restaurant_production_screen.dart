part of 'offline_register_page.dart';

/// Écran d'accueil du profil Restaurant (`PRODUCTION`, capacité `restaurant.v1`, lot R-4) : commandes ouvertes groupées
/// par canal, « Nouvelle commande » (canal, puis table ou référence si le canal l'exige), état du registre et bons à
/// vérifier. La commande s'ouvre dans le même écran de saisie que le Service de table. Hors caisse maîtresse : lecture
/// seule.
class _RestaurantBoard extends StatefulWidget {
  const _RestaurantBoard({required this.host});

  final _OfflineRegisterPageState host;

  @override
  State<_RestaurantBoard> createState() => _RestaurantBoardState();
}

class _RestaurantBoardState extends State<_RestaurantBoard> {
  List<RestoOrderView> _orders = const [];
  List<RestoTicketView> _alerts = const [];
  RestoRegisterView? _register;
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
    final register = await _engine.restoRegister();
    if (!mounted) return;
    setState(() {
      _orders = orders;
      _alerts = [for (final t in tickets) if (t.state == RestoDeliveryState.toCheck || t.state == RestoDeliveryState.failed) t];
      _register = register;
      _loading = false;
    });
  }

  Future<void> _open(RestoOrderView view) async {
    await Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => _RestaurantOrderPage(host: widget.host, orderUuid: view.order.uuid)));
    await _reload();
  }

  Future<void> _newOrder() async {
    final operator = widget.host._operator!;
    final blocker = _engine.restaurantBlocker(operator);
    if (blocker != null) return widget.host._refuse(blocker, title: 'Commande impossible');
    final ctx = _engine.restaurant!;
    final choice = await showDialog<({RestoChannel channel, String? table, String? reference, String? customer, Customer? client})>(
      context: context,
      builder: (_) => _NewOrderDialog(context: ctx, busyTables: {for (final o in _orders) ?o.order.tableUuid}, engine: _engine),
    );
    if (choice == null || !mounted) return;
    final RestoOrderView view;
    try {
      view = await _engine.restoOpenOnChannel(operator, choice.channel.code,
          tableUuid: choice.table, reference: choice.reference, customerName: choice.client?.name ?? choice.customer, customerUuid: choice.client?.uuid);
    } on OfflineRefusal catch (e) {
      return widget.host._refuse(e.message, title: 'Commande impossible');
    }
    if (mounted) await _open(view);
  }

  Future<void> _showAlerts() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _TicketsSheet(host: widget.host, title: 'Bons à vérifier'),
    );
    await _reload();
  }

  /// Ventes réglées de la caisse : remboursement (retour en espèces ou annulation de la vente), état des remboursements.
  Future<void> _refunds() async {
    await showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (_) => _RefundsSheet(host: widget.host));
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final ctx = _engine.restaurant!;
    final operator = widget.host._operator!;
    final blocker = _engine.restaurantBlocker(operator);
    final brand = widget.host._brand;
    final register = _register;
    // Commandes groupées par canal, dans l'ordre publié ; un canal disparu depuis garde ses commandes à la fin.
    final groups = <String?, List<RestoOrderView>>{for (final c in ctx.channels) c.code: []};
    for (final o in _orders) {
      (groups[o.order.channel] ??= []).add(o);
    }
    final registerText = register == null || register.closed
        ? 'Registre fermé'
        : 'Registre du ${register.businessDay} ouvert · ventes ${formatFcfa(register.salesTotal)}';
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
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ActionChip(
                key: const ValueKey('resto-registre'),
                avatar: Icon(register != null && register.open ? Icons.event_available : Icons.event_busy, size: 18),
                label: Text(registerText),
                onPressed: () async {
                  await _restoRegisterDialog(widget.host);
                  await _reload();
                },
              ),
              FilledButton.icon(
                key: const ValueKey('resto-nouvelle-commande'),
                style: FilledButton.styleFrom(backgroundColor: brand, minimumSize: const Size(0, 44)),
                onPressed: blocker == null ? _newOrder : null,
                icon: const Icon(Icons.add),
                label: const Text('Nouvelle commande'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('resto-remboursements'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                onPressed: blocker == null ? _refunds : null,
                icon: const Icon(Icons.undo),
                label: const Text('Ventes réglées'),
              ),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _orders.isEmpty
              ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Aucune commande ouverte.', textAlign: TextAlign.center)))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                  children: [
                    for (final entry in groups.entries)
                      if (entry.value.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 12, bottom: 4),
                          child: Text(
                            '${ctx.channel(entry.key)?.name ?? entry.key ?? 'Sans canal'} (${entry.value.length})',
                            style: TextStyle(color: brand, fontWeight: FontWeight.w700),
                          ),
                        ),
                        for (final view in entry.value) _orderTile(ctx, view, brand),
                      ],
                  ],
                ),
        ),
      ],
    );
  }

  Widget _orderTile(RestoContext ctx, RestoOrderView view, Color brand) {
    final order = view.order;
    final partly = order.activeLines.any((l) => l.settled > 0);
    final details = [
      if (ctx.table(order.tableUuid) case final table?) 'Table ${table.name}',
      ?order.externalReference,
      ?order.customerName,
      view.paid ? 'Réglée · à clôturer' : (partly ? 'Réglée en partie' : (order.stage == RestoStage.billPrinted ? 'Addition imprimée' : 'En cours')),
    ];
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        key: ValueKey('resto-commande-${order.uuid}'),
        onTap: () => _open(view),
        title: Text(order.localNumber, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(details.join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (view.serverMessage != null && !view.waiting)
              const Padding(padding: EdgeInsets.only(right: 6), child: Icon(Icons.warning_amber, color: Colors.orange, size: 20))
            else if (view.pendingVersions > 0)
              const Padding(padding: EdgeInsets.only(right: 6), child: Icon(Icons.cloud_upload_outlined, size: 18, color: Colors.black45)),
            Text(formatFcfa(view.payable), style: TextStyle(fontWeight: FontWeight.w700, color: brand)),
          ],
        ),
      ),
    );
  }
}

/// Nouvelle commande du profil Restaurant : canal actif, puis table (canal qui l'exige) et référence (canal qui l'exige).
class _NewOrderDialog extends StatefulWidget {
  const _NewOrderDialog({required this.context, required this.busyTables, this.engine});

  final RestoContext context;

  /// Recherche des clients connus (lot R-5 : le client cité à l'ouverture porte la remise client).
  final CaisseEngine? engine;

  /// Tables qui ont déjà une commande ouverte (une seule par table, sauf réglage contraire).
  final Set<String> busyTables;

  @override
  State<_NewOrderDialog> createState() => _NewOrderDialogState();
}

class _NewOrderDialogState extends State<_NewOrderDialog> {
  final _reference = TextEditingController();
  final _customer = TextEditingController();
  RestoChannel? _channel;
  String? _table;
  String? _error;
  Customer? _client;

  List<RestoChannel> get _channels => [for (final c in widget.context.channels) if (c.active) c];

  @override
  void initState() {
    super.initState();
    final channels = _channels;
    if (channels.length == 1) _channel = channels.single;
  }

  @override
  void dispose() {
    _reference.dispose();
    _customer.dispose();
    super.dispose();
  }

  void _confirm() {
    final channel = _channel;
    if (channel == null) return setState(() => _error = 'Choisissez le canal.');
    if (channel.requiresTable && _table == null) return setState(() => _error = 'Choisissez la table.');
    final reference = _reference.text.trim();
    if (channel.requiresReference && reference.isEmpty) return setState(() => _error = 'Saisissez la référence de la commande.');
    final customer = _customer.text.trim();
    Navigator.pop(context, (
      channel: channel,
      table: channel.requiresTable ? _table : null,
      reference: reference.isEmpty ? null : reference,
      customer: customer.isEmpty ? null : customer,
      client: _client,
    ));
  }

  Future<void> _pickClient() async {
    final picked = await _restoPickClient(context, widget.engine!, widget.context.customerDiscounts);
    if (picked != null && mounted) setState(() => _client = picked.$1);
  }

  @override
  Widget build(BuildContext context) {
    final channels = _channels;
    final channel = _channel;
    final tables = widget.context.tables;
    final several = widget.context.settings.severalOrdersPerTable;
    return AlertDialog(
      title: const Text('Nouvelle commande'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (channels.isEmpty)
                const Text('Aucun canal actif n’est publié pour ce point de vente : synchronisez la caisse.')
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final c in channels)
                      ChoiceChip(
                        key: ValueKey('canal-${c.code}'),
                        label: Text(c.name),
                        selected: c.code == channel?.code,
                        onSelected: (_) => setState(() {
                          _channel = c;
                          _error = null;
                        }),
                      ),
                  ],
                ),
              if (channel != null && channel.requiresTable) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _table,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Table'),
                  items: [
                    for (final t in tables)
                      DropdownMenuItem(
                        value: t.uuid,
                        enabled: several || !widget.busyTables.contains(t.uuid),
                        child: Text(!several && widget.busyTables.contains(t.uuid) ? '${t.name} (occupée)' : t.name),
                      ),
                  ],
                  onChanged: (value) => setState(() => _table = value),
                ),
              ],
              if (channel != null && channel.requiresReference)
                TextField(
                  controller: _reference,
                  maxLength: 80,
                  decoration: const InputDecoration(labelText: 'Référence (obligatoire)', hintText: 'N° de la plateforme…'),
                ),
              if (channel != null && (widget.engine?.customersSupported ?? false))
                ListTile(
                  key: const ValueKey('resto-client'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.person_search_outlined),
                  title: Text(_client?.name ?? 'Client enregistré (facultatif)'),
                  subtitle: _client == null
                      ? null
                      : Text((widget.context.customerDiscounts[_client!.uuid] ?? 0) > 0 ? 'Remise client ${widget.context.customerDiscounts[_client!.uuid]} %' : 'Sans remise client'),
                  onTap: _pickClient,
                ),
              if (channel != null && _client == null)
                TextField(controller: _customer, maxLength: 160, decoration: const InputDecoration(labelText: 'Nom du client (facultatif)')),
              if (channel != null && channel.tracksDelivery)
                const Text('Le suivi de livraison reste sur la caisse web.', style: TextStyle(color: Colors.black54)),
              if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton(onPressed: channels.isEmpty ? null : _confirm, child: const Text('Ouvrir la commande')),
      ],
    );
  }
}

/// Client connu de la boutique (recherche par nom ou téléphone), cité à l'ouverture d'une commande seulement (lot R-5 : il
/// porte la remise client) ; `(null,)` : aucun client, null : abandon.
Future<(Customer?,)?> _restoPickClient(BuildContext context, CaisseEngine engine, Map<String, int> discounts) async {
  var results = await engine.searchCustomers('');
  if (!context.mounted) return null;
  return showDialog<(Customer?,)>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setLocal) => AlertDialog(
        title: const Text('Client de la commande'),
        content: SizedBox(
          width: 360,
          height: 300,
          child: Column(
            children: [
              TextField(
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Nom ou téléphone'),
                onChanged: (text) async {
                  final found = await engine.searchCustomers(text);
                  setLocal(() => results = found);
                },
              ),
              Expanded(
                child: results.isEmpty
                    ? const Center(child: Text('Aucun client.'))
                    : ListView(
                        children: [
                          for (final c in results)
                            ListTile(
                              dense: true,
                              title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text([c.phone ?? 'Sans téléphone', if (discounts[c.uuid] case final p?) 'remise $p %'].join(' · ')),
                              onTap: () => Navigator.pop(context, (c,)),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, (null,)), child: const Text('Aucun client')),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        ],
      ),
    ),
  );
}

/// Registre (journée) de la caisse, depuis le menu de session : ouverture avec une note, clôture après la session avec
/// le Z local, état de la remontée (attente des règlements, numéro du Z du serveur).
Future<void> _restoRegisterDialog(_OfflineRegisterPageState host) async {
  final operator = host._operator;
  if (operator == null) return;
  final engine = host._engine;
  final register = await engine.restoRegister();
  if (!host.mounted) return;
  final note = TextEditingController();
  final blocker = engine.restoRegisterBlocker(operator);
  final open = register != null && register.open;
  String two(int v) => v.toString().padLeft(2, '0');
  String at(DateTime d) => '${two(d.day)}/${two(d.month)} ${two(d.hour)}:${two(d.minute)}';
  final confirmed = await showDialog<bool>(
    context: host.context,
    builder: (context) => AlertDialog(
      title: const Text('Registre de la caisse'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (register == null)
                const Text('Aucun registre ouvert sur cette caisse.')
              else if (open)
                Text('Journée du ${register.businessDay}, ouverte le ${at(register.openedAt)}.\nVentes de la caisse : ${formatFcfa(register.salesTotal)}.')
              else ...[
                Text('Dernière journée : ${register.businessDay}, close le ${at(register.closedAt ?? register.openedAt)}.'),
                Text('Z local n° ${register.zLocalNumber ?? '-'} · ventes ${formatFcfa(register.salesTotal)}'
                    '${register.serverZNumber != null ? ' · Z serveur n° ${register.serverZNumber}' : ''}'),
              ],
              if (register?.serverMessage != null)
                Card(
                  color: register!.waiting ? Colors.blue.shade50 : Colors.orange.shade50,
                  child: ListTile(
                    leading: Icon(register.waiting ? Icons.hourglass_top : Icons.warning_amber),
                    title: Text(register.waiting ? 'En attente des règlements : ${register.serverMessage}' : register.serverMessage!),
                  ),
                ),
              if (open && engine.sessionOpen)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('Clôturez d’abord la session de caisse : le registre se clôt après elle.', style: TextStyle(color: Colors.black54)),
                ),
              if (blocker != null)
                Padding(padding: const EdgeInsets.only(top: 8), child: Text(blocker, style: const TextStyle(color: Colors.red)))
              else
                TextField(controller: note, maxLength: 2000, decoration: const InputDecoration(labelText: 'Note (facultatif)')),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Fermer')),
        if (blocker == null)
          FilledButton(
            key: const ValueKey('resto-registre-action'),
            onPressed: open && engine.sessionOpen ? null : () => Navigator.pop(context, true),
            child: Text(open ? 'Clôturer le registre' : 'Ouvrir le registre'),
          ),
      ],
    ),
  );
  final text = note.text;
  note.dispose();
  if (confirmed != true || !host.mounted) return;
  try {
    final done = open ? await engine.restoRegisterClose(operator, note: text) : await engine.restoRegisterOpen(operator, note: text);
    host._toast(open ? 'Registre clos · Z local n° ${done.zLocalNumber}.' : 'Registre du ${done.businessDay} ouvert.');
  } on OfflineRefusal catch (e) {
    await host._refuse(e.message, title: 'Registre');
  }
}

/// Mode d'encaissement du profil Restaurant : tout le reste, une partie (articles choisis) ou des parts égales.
enum _SettleMode { all, items, shares }

/// Choix fait avant le paiement : quantités par ligne ([items]) ou nombre de parts ([shares]).
class _SettlePlan {
  const _SettlePlan(this.mode, {this.items, this.shares = 0});

  final _SettleMode mode;
  final Map<String, int>? items;
  final int shares;
}

/// Montants de [count] parts égales de [total] : le reste de la division va aux premières parts.
List<int> _equalShares(int total, int count) => [for (var i = 0; i < count; i++) total ~/ count + (i < total % count ? 1 : 0)];

/// Choix Tout / Par articles / Par parts (profil Restaurant, R-4).
class _SettleChoiceDialog extends StatefulWidget {
  const _SettleChoiceDialog({required this.order, required this.payable});

  final RestoOrder order;

  /// À payer du reste (affichage, et plafond du nombre de parts).
  final int payable;

  @override
  State<_SettleChoiceDialog> createState() => _SettleChoiceDialogState();
}

class _SettleChoiceDialogState extends State<_SettleChoiceDialog> {
  _SettleMode _mode = _SettleMode.all;
  final Map<String, int> _items = {};
  int _shares = 2;

  List<RestoLine> get _rest => [for (final l in widget.order.activeLines) if (l.quantity > l.settled) l];

  int _step(int rest) => rest < Decimal6.scale ? rest : Decimal6.scale;

  @override
  Widget build(BuildContext context) {
    final rest = _rest;
    final maxShares = widget.payable < 50 ? widget.payable : 50;
    final itemsTotal = rest.fold<int>(0, (sum, l) => sum + Decimal6.amount(l.unitPrice, _items[l.uuid] ?? 0));
    return AlertDialog(
      title: const Text('Encaisser'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<_SettleMode>(
                showSelectedIcon: false,
                segments: [
                  const ButtonSegment(value: _SettleMode.all, label: Text('Tout')),
                  const ButtonSegment(value: _SettleMode.items, label: Text('Articles')),
                  ButtonSegment(value: _SettleMode.shares, label: const Text('Parts'), enabled: maxShares >= 2),
                ],
                selected: {_mode},
                onSelectionChanged: (value) => setState(() => _mode = value.single),
              ),
              const SizedBox(height: 12),
              if (_mode == _SettleMode.all)
                Text('Reste à payer : ${formatFcfa(widget.payable)}', style: const TextStyle(fontSize: 18))
              else if (_mode == _SettleMode.items) ...[
                for (final l in rest)
                  Row(
                    children: [
                      Expanded(child: Text('${l.label}\n${Decimal6.label(l.quantity - l.settled)} à régler', maxLines: 3, overflow: TextOverflow.ellipsis)),
                      IconButton(
                        tooltip: 'Moins',
                        onPressed: (_items[l.uuid] ?? 0) > 0 ? () => setState(() => _items[l.uuid] = (_items[l.uuid]! - _step(l.quantity - l.settled)).clamp(0, l.quantity - l.settled)) : null,
                        icon: const Icon(Icons.remove_circle_outline),
                      ),
                      Text(Decimal6.label(_items[l.uuid] ?? 0)),
                      IconButton(
                        tooltip: 'Plus',
                        onPressed: (_items[l.uuid] ?? 0) < l.quantity - l.settled
                            ? () => setState(() => _items[l.uuid] = ((_items[l.uuid] ?? 0) + _step(l.quantity - l.settled)).clamp(0, l.quantity - l.settled))
                            : null,
                        icon: const Icon(Icons.add_circle_outline),
                      ),
                    ],
                  ),
                Text('Sélection : ${formatFcfa(itemsTotal)}', style: const TextStyle(fontWeight: FontWeight.w600)),
              ] else ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton.filledTonal(onPressed: _shares > 2 ? () => setState(() => _shares--) : null, icon: const Icon(Icons.remove)),
                    Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text('$_shares parts', style: const TextStyle(fontSize: 18))),
                    IconButton.filledTonal(onPressed: _shares < maxShares ? () => setState(() => _shares++) : null, icon: const Icon(Icons.add)),
                  ],
                ),
                Text(
                  [for (final (i, amount) in _equalShares(widget.payable, _shares).indexed) 'Part ${i + 1} : ${formatFcfa(amount)}'].join('\n'),
                  textAlign: TextAlign.center,
                ),
                const Text('Chaque part se paie à son tour.', textAlign: TextAlign.center, style: TextStyle(color: Colors.black54)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton(
          key: const ValueKey('resto-encaisser-suite'),
          onPressed: _mode == _SettleMode.items && !_items.values.any((q) => q > 0)
              ? null
              : () => Navigator.pop(context, switch (_mode) {
                  _SettleMode.all => const _SettlePlan(_SettleMode.all),
                  _SettleMode.items => _SettlePlan(_SettleMode.items, items: {for (final e in _items.entries) if (e.value > 0) e.key: e.value}),
                  _SettleMode.shares => _SettlePlan(_SettleMode.shares, shares: _shares),
                }),
          child: const Text('Continuer'),
        ),
      ],
    );
  }
}

/// Ventes réglées de la caisse (profil Restaurant, lot R-5) : remboursement d'une commande soldée — retour d'articles en
/// espèces ou annulation de toute la vente (moyens d'origine, la commande est rouverte) — et état de la remontée (attente
/// du règlement, montant à arbitrer).
class _RefundsSheet extends StatefulWidget {
  const _RefundsSheet({required this.host});

  final _OfflineRegisterPageState host;

  @override
  State<_RefundsSheet> createState() => _RefundsSheetState();
}

class _RefundsSheetState extends State<_RefundsSheet> {
  List<RestoSettledSale>? _sales;

  CaisseEngine get _engine => widget.host._engine;
  Operator get _operator => widget.host._operator!;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final sales = await _engine.restoSettledSales();
    if (mounted) setState(() => _sales = sales);
  }

  Future<void> _refund(RestoSettledSale sale) async {
    final blocker = _engine.restoRefundBlocker(_operator);
    if (blocker != null) return widget.host._refuse(blocker, title: 'Remboursement impossible');
    final plan = await showDialog<({String type, Map<String, int> quantities, int amount})>(context: context, builder: (_) => _RefundChoiceDialog(engine: _engine, sale: sale));
    if (plan == null || !mounted) return;
    final cancel = plan.type == 'annulation';
    final result = await showDialog<({bool percent, int value, String reason, RestoApproval? approval})>(
      context: context,
      builder: (_) => _GestureDialog(
        engine: _engine,
        operator: _operator,
        gesture: _Gesture.refund,
        title: cancel ? 'Annuler la vente ${sale.number}' : 'Retour sur la vente ${sale.number}',
        base: plan.amount,
        refund: plan.type,
        description: cancel
            ? 'Toute la vente (${formatFcfa(plan.amount)}) est rendue sur ses moyens de paiement ; la commande ${sale.orderNumber} est rouverte.'
            : '${formatFcfa(plan.amount)} à rendre en espèces.',
      ),
    );
    if (result == null || !mounted) return;
    try {
      await _engine.restoRefund(_operator, sale.saleUuid, plan.type, plan.quantities, result.reason, approval: result.approval);
      widget.host._toast(cancel ? 'Vente annulée : la commande ${sale.orderNumber} est rouverte.' : 'Remboursement enregistré : ${formatFcfa(plan.amount)} à rendre en espèces.');
    } on OfflineRefusal catch (e) {
      await widget.host._refuse(e.message, title: 'Remboursement refusé');
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final sales = _sales;
    String two(int v) => v.toString().padLeft(2, '0');
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .85),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(padding: EdgeInsets.fromLTRB(16, 16, 16, 4), child: Text('Ventes réglées', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
            if (sales == null)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
            else if (sales.isEmpty)
              const Padding(padding: EdgeInsets.all(24), child: Text('Aucune vente réglée sur cette caisse.', textAlign: TextAlign.center))
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  children: [
                    for (final sale in sales)
                      Card(
                        child: ListTile(
                          key: ValueKey('resto-vente-${sale.saleUuid}'),
                          title: Text('Vente ${sale.number} · ${formatFcfa(sale.total)}', maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text([
                            'Commande ${sale.orderNumber} · ${two(sale.at.day)}/${two(sale.at.month)} ${two(sale.at.hour)}:${two(sale.at.minute)}',
                            if (sale.cancelled) 'Vente annulée' else if (sale.refunded > 0) 'Remboursé : ${formatFcfa(sale.refunded)}',
                            for (final r in sale.refunds)
                              if (r.message != null) '${r.waiting ? 'En attente' : (r.toArbitrate ? 'À arbitrer' : 'Serveur')} : ${r.message}',
                          ].join('\n')),
                          trailing: sale.refundable ? TextButton(onPressed: () => _refund(sale), child: const Text('Rembourser')) : null,
                        ),
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

/// Choix du remboursement : retour d'articles (quantités en unité de base, rendues en espèces) ou annulation de la vente.
class _RefundChoiceDialog extends StatefulWidget {
  const _RefundChoiceDialog({required this.engine, required this.sale});

  final CaisseEngine engine;
  final RestoSettledSale sale;

  @override
  State<_RefundChoiceDialog> createState() => _RefundChoiceDialogState();
}

class _RefundChoiceDialogState extends State<_RefundChoiceDialog> {
  String _type = 'retour';
  final _quantities = <String, int>{};
  int? _amount;
  String? _error;

  Future<void> _compute() async {
    final quantities = {for (final e in _quantities.entries) if (e.value > 0) e.key: e.value};
    if (_type == 'retour' && quantities.isEmpty) return setState(() => _amount = _error = null);
    try {
      final amount = await widget.engine.restoRefundAmount(widget.sale.saleUuid, _type, _type == 'annulation' ? const {} : quantities);
      if (mounted) {
        setState(() {
          _amount = amount;
          _error = null;
        });
      }
    } on OfflineRefusal catch (e) {
      if (mounted) {
        setState(() {
          _amount = null;
          _error = e.message;
        });
      }
    }
  }

  void _step(RestoSaleLine line, int delta) {
    final next = ((_quantities[line.lineUuid] ?? 0) + delta).clamp(0, line.remaining);
    setState(() => _quantities[line.lineUuid] = next);
    _compute();
  }

  @override
  Widget build(BuildContext context) {
    final amount = _amount;
    return AlertDialog(
      title: Text('Rembourser la vente ${widget.sale.number}'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    key: const ValueKey('remboursement-retour'),
                    label: const Text('Retour d’articles (espèces)'),
                    selected: _type == 'retour',
                    onSelected: (_) {
                      setState(() => _type = 'retour');
                      _compute();
                    },
                  ),
                  ChoiceChip(
                    key: const ValueKey('remboursement-annulation'),
                    label: const Text('Annuler la vente'),
                    selected: _type == 'annulation',
                    onSelected: (_) {
                      setState(() => _type = 'annulation');
                      _compute();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_type == 'annulation')
                const Text('Toute la vente est rendue sur ses moyens de paiement d’origine ; la commande est rouverte.')
              else
                for (final line in widget.sale.lines)
                  if (line.remaining > 0)
                    Row(
                      children: [
                        Expanded(child: Text(line.label, maxLines: 2, overflow: TextOverflow.ellipsis)),
                        IconButton(
                          tooltip: 'Moins',
                          onPressed: (_quantities[line.lineUuid] ?? 0) > 0 ? () => _step(line, -Decimal6.scale) : null,
                          icon: const Icon(Icons.remove_circle_outline),
                        ),
                        Text('${Decimal6.label(_quantities[line.lineUuid] ?? 0)} / ${Decimal6.label(line.remaining)}'),
                        IconButton(
                          tooltip: 'Plus',
                          onPressed: (_quantities[line.lineUuid] ?? 0) < line.remaining ? () => _step(line, Decimal6.scale) : null,
                          icon: const Icon(Icons.add_circle_outline),
                        ),
                      ],
                    ),
              if (amount != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text('À rendre : ${formatFcfa(amount)}', style: const TextStyle(fontWeight: FontWeight.bold))),
              if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton(
          key: const ValueKey('remboursement-suite'),
          onPressed: amount == null || amount <= 0
              ? null
              : () => Navigator.pop(context, (type: _type, quantities: {for (final e in _quantities.entries) if (e.value > 0) e.key: e.value}, amount: amount)),
          child: const Text('Continuer'),
        ),
      ],
    );
  }
}
