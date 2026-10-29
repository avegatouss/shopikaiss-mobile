import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ipc/protocol.dart';
import 'register_controller.dart';
import 'sales_history.dart';
import 'brand_logo.dart';

class WindowsRegisterApp extends StatelessWidget {
  const WindowsRegisterApp({super.key, this.controller, this.onConnection});
  final VoidCallback? onConnection;
  final WindowsRegisterController? controller;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Shopikaiss · Caisse',
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff164e42)),
      scaffoldBackgroundColor: const Color(0xfff3f5f4),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(),
      ),
    ),
    home: controller == null
        ? const _NotConnected()
        : _Register(controller!, onConnection),
  );
}

class _NotConnected extends StatelessWidget {
  const _NotConnected();
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Shopikaiss · Caisse Windows')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: const Card(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ShopikaissLogo(width: 280),
                SizedBox(height: 20),
                Text(
                  'Votre caisse doit être configurée',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 16),
                Text(
                  'Le moteur de vente local n’est pas raccordé. Aucun encaissement n’est disponible sur cette installation.',
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 12),
                Text(
                  'Contactez votre responsable pour terminer la mise en service.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _Register extends StatefulWidget {
  const _Register(this.controller, this.onConnection);
  final VoidCallback? onConnection;
  final WindowsRegisterController controller;
  @override
  State<_Register> createState() => _RegisterState();
}

class _RegisterState extends State<_Register> {
  final _search = TextEditingController();
  final _scan = TextEditingController();
  bool _compact = false;
  final _scanFocus = FocusNode();
  WindowsRegisterController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    c.refresh();
  }

  @override
  void dispose() {
    _search.dispose();
    _scan.dispose();
    _scanFocus.dispose();
    super.dispose();
  }

  Future<void> _payment() async {
    if (!c.canPay) return;
    await c.command(HostCommand.preparePayment, {});
    if (!mounted || !c.canPay) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _Payment(c),
    );
  }

  bool get _canEdit => c.ready && !c.busy && c.uncertainOperation == null;

  Future<void> _submitScan() async {
    if (!_canEdit || _scan.text.trim().isEmpty) return;
    await c.command(HostCommand.scan, {'code': _scan.text.trim()});
    if (!mounted) return;
    if (c.message == null) _scan.clear();
    _scanFocus.requestFocus();
  }

  Future<void> _addProduct(Map<String, dynamic> product) async {
    if (!_canEdit) return;
    final packagings = (product['packagings'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    Object? packaging;
    if (packagings.isNotEmpty) {
      final choice = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(product['name'] as String),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, <String, dynamic>{}),
              child: Text('Unité · ${product['price_label']}'),
            ),
            for (final item in packagings)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, item),
                child: Text('${item['name']} · ${item['price_label']}'),
              ),
          ],
        ),
      );
      if (!mounted || choice == null || !_canEdit) return;
      packaging = choice['id'];
    }
    await c.command(HostCommand.addProduct, {
      'product_id': product['id'],
      'packaging_id': ?packaging,
    });
  }

  Future<void> _quantity(Map<String, dynamic> line) async {
    var input = '';
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Modifier la quantité'),
        content: TextField(
          onChanged: (value) => input = value,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'Nouvelle quantité',
            helperText:
                '${line['name']} · actuellement ${line['quantity_label']}',
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(input),
            child: const Text('Appliquer'),
          ),
        ],
      ),
    );
    if (!mounted || value == null || value.trim().isEmpty) return;
    await c.command(HostCommand.changeQuantity, {
      'line_id': line['id'],
      'quantity': value.trim(),
    });
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Vider le panier ?'),
        content: const Text('Tous les articles de ce panier seront retirés.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Conserver'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Vider le panier'),
          ),
        ],
      ),
    );
    if (mounted && confirmed == true) await c.command(HostCommand.clear, {});
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) => CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f4): _payment,
        const SingleActivator(LogicalKeyboardKey.f2): _scanFocus.requestFocus,
      },
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 48,
          title: Row(
            children: [
              const ShopikaissLogo(width: 155),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  c.view['store_name'] as String? ?? 'Caisse',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Ventes de ce poste',
              onPressed: c.ready && !c.busy
                  ? () => showDialog<void>(
                      context: context,
                      builder: (_) => SalesHistoryDialog(host: c.host),
                    )
                  : null,
              icon: const Icon(Icons.receipt_long_outlined),
            ),
            Chip(
              avatar: Icon(
                c.ready ? Icons.check_circle_outline : Icons.warning_amber,
                size: 18,
              ),
              label: Text(
                c.ready
                    ? c.view['sync_label'] as String? ?? 'Moteur local prêt'
                    : 'Moteur local indisponible',
              ),
            ),
            if (widget.onConnection != null)
              IconButton(
                tooltip: 'Connexion au moteur',
                onPressed: c.busy ? null : widget.onConnection,
                icon: const Icon(Icons.settings_input_component),
              ),
            const SizedBox(width: 16),
            IconButton(
              tooltip: 'Actualiser l’état local',
              onPressed: c.busy ? null : c.refresh,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: Column(
          children: [
            Material(
              color: Colors.white,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(
                          value: false,
                          icon: Icon(Icons.grid_view),
                          label: Text('Visuelle'),
                        ),
                        ButtonSegment(
                          value: true,
                          icon: Icon(Icons.view_list),
                          label: Text('Compacte'),
                        ),
                      ],
                      selected: {_compact},
                      onSelectionChanged: (value) =>
                          setState(() => _compact = value.single),
                    ),
                    const SizedBox(width: 12),
                    TextButton.icon(
                      onPressed: c.ready && !c.busy
                          ? () => showDialog<void>(
                              context: context,
                              builder: (_) => SalesHistoryDialog(host: c.host),
                            )
                          : null,
                      icon: const Icon(Icons.history),
                      label: const Text('Ventes récentes'),
                    ),
                  ],
                ),
              ),
            ),
            if (c.message != null)
              MaterialBanner(
                content: Text(c.message!),
                actions: [
                  if (c.uncertainOperation != null)
                    TextButton(
                      onPressed: c.busy ? null : c.reconcile,
                      child: const Text('Vérifier la vente'),
                    )
                  else
                    TextButton(
                      onPressed: c.busy ? null : c.refresh,
                      child: const Text('Vérifier l’état'),
                    ),
                ],
              ),
            if (c.receipt != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text('Vente enregistrée · ${c.receipt}'),
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) => box.maxWidth >= 900
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(flex: 58, child: _catalogue()),
                          Expanded(flex: 42, child: _cart()),
                        ],
                      )
                    : DefaultTabController(
                        length: 2,
                        child: Column(
                          children: [
                            const TabBar(
                              tabs: [
                                Tab(text: 'Articles'),
                                Tab(text: 'Panier'),
                              ],
                            ),
                            Expanded(
                              child: TabBarView(
                                children: [_catalogue(), _cart()],
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _catalogue() => Padding(
    padding: const EdgeInsets.all(8),
    child: Column(
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _scan,
                focusNode: _scanFocus,
                autofocus: true,
                enabled: c.ready && !c.busy && c.uncertainOperation == null,
                decoration: InputDecoration(
                  isDense: true,
                  labelText: 'Scanner (F2) puis Entrée',
                  prefixIcon: const Icon(Icons.barcode_reader),
                  suffixIcon: IconButton(
                    tooltip: 'Ajouter le code scanné',
                    icon: const Icon(Icons.arrow_forward),
                    onPressed: _canEdit ? _submitScan : null,
                  ),
                ),
                onSubmitted: (_) => _submitScan(),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _search,
                enabled: _canEdit,
                decoration: InputDecoration(
                  isDense: true,
                  labelText: 'Rechercher un produit',
                  suffixIcon: IconButton(
                    tooltip: 'Rechercher',
                    onPressed: _canEdit
                        ? () => c.command(HostCommand.search, {
                            'query': _search.text,
                          })
                        : null,
                    icon: const Icon(Icons.search),
                  ),
                ),
                onSubmitted: (query) =>
                    c.command(HostCommand.search, {'query': query}),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: c.products.isEmpty
              ? const Center(child: Text('Aucun article à afficher.'))
              : _compact
              ? ListView.separated(
                  itemCount: c.products.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final p = c.products[index];
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.inventory_2_outlined),
                      title: Text(p['name'] as String? ?? ''),
                      subtitle: Text(
                        'Stock : ${p['stock_label'] ?? "à vérifier"}',
                      ),
                      trailing: Text(p['price_label'] as String? ?? '—'),
                      onTap: _canEdit ? () => _addProduct(p) : null,
                    );
                  },
                )
              : GridView.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 185,
                    mainAxisExtent: 130,
                    crossAxisSpacing: 4,
                    mainAxisSpacing: 4,
                  ),
                  itemCount: c.products.length,
                  itemBuilder: (context, index) {
                    final p = c.products[index];
                    return Card(
                      color: const Color(0xffe4f1e9),
                      child: InkWell(
                        onTap:
                            c.ready && !c.busy && c.uncertainOperation == null
                            ? () => _addProduct(p)
                            : null,
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Text(
                                  p['name'] as String? ?? '',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                              Text(
                                p['price_label'] as String? ?? '—',
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                p['stock_label'] as String? ??
                                    'Stock à vérifier',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    ),
  );

  Widget _cart() => Card(
    margin: const EdgeInsets.all(8),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Panier',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: c.lines.isEmpty
                ? const Center(child: Text('Scannez votre premier article.'))
                : ListView.separated(
                    itemCount: c.lines.length,
                    separatorBuilder: (_, _) => const Divider(),
                    itemBuilder: (context, index) {
                      final line = c.lines[index];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(line['name'] as String? ?? ''),
                        onTap:
                            c.ready && !c.busy && c.uncertainOperation == null
                            ? () => _quantity(line)
                            : null,
                        subtitle: Text(
                          '${line['quantity_label'] ?? ''} · ${line['total_label'] ?? ''}',
                        ),
                        trailing: IconButton(
                          tooltip: 'Retirer du panier',
                          icon: const Icon(Icons.delete_outline),
                          onPressed:
                              c.ready && !c.busy && c.uncertainOperation == null
                              ? () => c.command(HostCommand.removeLine, {
                                  'line_id': line['id'],
                                })
                              : null,
                        ),
                      );
                    },
                  ),
          ),
          const Divider(),
          const Text('À payer', textAlign: TextAlign.end),
          Text(
            c.view['total_label'] as String? ?? '—',
            textAlign: TextAlign.end,
            style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              OutlinedButton(
                onPressed: _canEdit && c.lines.isNotEmpty ? _clear : null,
                child: const Text('Vider le panier'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: c.canPay ? _payment : null,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.all(20),
                  ),
                  icon: const Icon(Icons.payments_outlined),
                  label: const Text('Payer (F4)'),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _Payment extends StatefulWidget {
  const _Payment(this.c);
  final WindowsRegisterController c;
  @override
  State<_Payment> createState() => _PaymentState();
}

class _PaymentState extends State<_Payment> {
  WindowsRegisterController get c => widget.c;
  final _received = TextEditingController();
  String? _method;
  bool _cash = false;
  bool _accepted = false;
  String? _inputError;

  @override
  void dispose() {
    _received.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    if (_method == null || !c.canPay) return;
    final text = _received.text.trim();
    final value = text.isEmpty ? null : int.tryParse(text);
    setState(() {
      _accepted = false;
      _inputError = null;
    });
    if (_cash &&
        text.isNotEmpty &&
        (value == null || value < 0 || !RegExp(r'^\d+$').hasMatch(text))) {
      setState(
        () => _inputError = 'Saisissez un montant entier positif en F CFA.',
      );
      return;
    }
    await c.command(HostCommand.setPayment, {
      'method': _method,
      if (_cash && value != null) 'received': value,
    });
    if (mounted) {
      setState(
        () => _accepted = c.message == null && c.view['payment_valid'] == true,
      );
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) => AlertDialog(
      scrollable: true,
      title: const Text('Paiement'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              c.view['total_label'] as String? ?? '—',
              style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final method in c.paymentMethods)
                  OutlinedButton.icon(
                    icon: Icon(
                      method['cash'] == true
                          ? Icons.payments_outlined
                          : Icons.account_balance_wallet_outlined,
                    ),
                    onPressed: c.canPay
                        ? () {
                            setState(() {
                              _method = method['code'] as String;
                              _cash = method['cash'] == true;
                              _accepted = false;
                              _received.clear();
                            });
                            _apply();
                          }
                        : null,
                    label: Text(method['name'] as String),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (_cash) ...[
              TextField(
                controller: _received,
                enabled: c.canPay,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Montant reçu (F CFA)',
                  helperText: 'Laisser vide pour le montant exact.',
                  errorText: _inputError,
                ),
                onChanged: (_) => setState(() => _accepted = false),
                onSubmitted: (_) => _apply(),
              ),
              TextButton(
                onPressed: c.canPay ? _apply : null,
                child: const Text('Vérifier le montant reçu'),
              ),
              if (_accepted && c.paymentChange != null)
                Text('Monnaie à rendre : ${c.paymentChange} F CFA'),
            ],
            Text(
              c.view['payment_label'] as String? ??
                  'Choisissez un moyen autorisé dans le moteur local.',
            ),
            if (c.message != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(c.message!),
              ),
            if (c.uncertainOperation != null)
              TextButton(
                onPressed: c.busy ? null : c.reconcile,
                child: const Text('Vérifier cette vente'),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: c.busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Retour au panier'),
        ),
        FilledButton(
          onPressed: c.canPay && _accepted && c.view['payment_valid'] == true
              ? () async {
                  await c.commitSale();
                  if (context.mounted &&
                      c.receipt != null &&
                      c.uncertainOperation == null) {
                    Navigator.of(context).pop();
                  }
                }
              : null,
          child: Text(c.busy ? 'Enregistrement…' : 'Confirmer le paiement'),
        ),
      ],
    ),
  );
}
