part of 'offline_register_page.dart';

/// Libellé de l'étape du Service de table (`ServiceStage::TABLE_LABELS` du web).
String _stageLabel(String? stage) => switch (stage) {
  'bill_printed' => 'Préfacture imprimée',
  'customer_validated' => 'Validée client',
  'amended' => 'Modifiée',
  _ => 'En attente',
};

/// Plan de salle de la caisse maîtresse (Service de table, capacité `restaurant.v1`, lots R-1 et R-2) : une tuile par
/// table, libre ou occupée par sa commande (numéro, montant, étape, remontée). Hors caisse maîtresse : lecture seule.
class _RestaurantFloor extends StatefulWidget {
  const _RestaurantFloor({required this.host});

  final _OfflineRegisterPageState host;

  @override
  State<_RestaurantFloor> createState() => _RestaurantFloorState();
}

class _RestaurantFloorState extends State<_RestaurantFloor> {
  List<RestoOrderView> _orders = const [];
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
    if (!mounted) return;
    setState(() {
      _orders = orders;
      _loading = false;
    });
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

  Future<void> _cancel() async {
    final reason = TextEditingController();
    final required = _engine.restaurant?.settings.cancellationReason ?? false;
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
    final List<CartLine> lines;
    try {
      lines = await _engine.restoCart(widget.orderUuid);
      allocateLots(snapshot, lines);
    } on OfflineRefusal catch (e) {
      return _refuse(e.message, title: 'Encaissement impossible');
    }
    if (!mounted) return;
    final compact = widget.host._compact;
    final payments = compact
        ? await Navigator.of(context).push<List<CartPayment>>(
            MaterialPageRoute(fullscreenDialog: true, builder: (_) => _PaymentDialog(snapshot: snapshot, payable: view.payable, cashDue: _engine.cashDue, fullScreen: true)),
          )
        : await showDialog<List<CartPayment>>(
            context: context,
            barrierDismissible: false,
            builder: (_) => _PaymentDialog(snapshot: snapshot, payable: view.payable, cashDue: _engine.cashDue),
          );
    if (payments == null || !mounted) return;
    OfflineOperation? operation;
    final ok = await _run(() async => operation = await _engine.restoSettle(_operator, widget.orderUuid, lines, payments), title: 'Encaissement refusé');
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
          content: Text(change > 0 ? 'Monnaie à rendre : ${formatFcfa(change)}' : 'Commande réglée et close.', style: const TextStyle(fontSize: 20)),
          actions: [
            TextButton(
              onPressed: () async {
                await widget.host._print(snapshot, operation!, lines, payments, duplicate: printed);
                setDialog(() => printed = true);
              },
              child: Text(printed ? 'Réimprimer' : 'Imprimer le ticket'),
            ),
            FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Retour à la salle')),
          ],
        ),
      ),
    );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final view = _view;
    final order = view?.order;
    final ctx = _engine.restaurant;
    final blocker = _engine.restaurantBlocker(_operator);
    final editable = blocker == null && order != null && order.isOpen && !(view?.paid ?? false);
    final table = ctx?.table(order?.tableUuid)?.name;
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
            if (editable) ...[
              IconButton(tooltip: 'Transférer', onPressed: _busy || _dirty ? null : _transfer, icon: const Icon(Icons.swap_horiz)),
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
                if (l.comment != null) l.comment!,
              ].join(' · ')),
              trailing: !editable || !l.active
                  ? Text(formatFcfa(l.total))
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
