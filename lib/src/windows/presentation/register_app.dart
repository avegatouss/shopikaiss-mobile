import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ipc/protocol.dart';
import 'register_controller.dart';
import 'sales_history.dart';

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
                Icon(Icons.desktop_windows_outlined, size: 52),
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
      bindings: {const SingleActivator(LogicalKeyboardKey.f4): _payment},
      child: Scaffold(
        appBar: AppBar(
          title: Text(c.view['store_name'] as String? ?? 'Shopikaiss'),
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
                          Expanded(flex: 3, child: _catalogue()),
                          Expanded(flex: 2, child: _cart()),
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
    padding: const EdgeInsets.all(16),
    child: Column(
      children: [
        TextField(
          controller: _search,
          focusNode: _scanFocus,
          enabled: c.ready && !c.busy && c.uncertainOperation == null,
          decoration: InputDecoration(
            labelText: 'Scanner un code ou rechercher un produit',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: IconButton(
              tooltip: 'Rechercher',
              icon: const Icon(Icons.arrow_forward),
              onPressed: c.ready && !c.busy
                  ? () => c.command(HostCommand.search, {'query': _search.text})
                  : null,
            ),
          ),
          onSubmitted: (code) async {
            await c.command(HostCommand.scan, {'code': code});
            if (mounted && c.message == null) _search.clear();
            if (mounted) _scanFocus.requestFocus();
          },
        ),
        const SizedBox(height: 16),
        Expanded(
          child: c.products.isEmpty
              ? const Center(child: Text('Aucun article à afficher.'))
              : GridView.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 240,
                    mainAxisExtent: 150,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: c.products.length,
                  itemBuilder: (context, index) {
                    final p = c.products[index];
                    return Card(
                      child: InkWell(
                        onTap:
                            c.ready && !c.busy && c.uncertainOperation == null
                            ? () => c.command(HostCommand.addProduct, {
                                'product_id': p['id'],
                              })
                            : null,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
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
                                  ),
                                ),
                              ),
                              Text(
                                p['price_label'] as String? ?? '—',
                                style: const TextStyle(
                                  fontSize: 20,
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
    margin: const EdgeInsets.all(16),
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Panier',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          if (c.lines.isNotEmpty)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: c.ready && !c.busy && c.uncertainOperation == null
                    ? _clear
                    : null,
                icon: const Icon(Icons.remove_shopping_cart_outlined),
                label: const Text('Vider le panier'),
              ),
            ),
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
          Text(
            c.view['total_label'] as String? ?? '—',
            textAlign: TextAlign.end,
            style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: c.canPay ? _payment : null,
            style: FilledButton.styleFrom(padding: const EdgeInsets.all(20)),
            icon: const Icon(Icons.payments_outlined),
            label: const Text('Encaisser · F4'),
          ),
        ],
      ),
    ),
  );
}

class _Payment extends StatelessWidget {
  const _Payment(this.c);
  final WindowsRegisterController c;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) => AlertDialog(
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
                        ? () => c.command(HostCommand.setPayment, {
                            'method': method['code'],
                          })
                        : null,
                    label: Text(method['name'] as String),
                  ),
              ],
            ),
            const SizedBox(height: 12),
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
          onPressed: c.canPay && c.view['payment_valid'] == true
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
