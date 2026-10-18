import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../terminal/terminal_session.dart';
import 'engine.dart';
import 'models.dart';
import 'money.dart';
import 'pending_operations_page.dart';
import 'ticket.dart';

const _brand = Color(0xFF0F3E2E);
const _offline = Color(0xFFB45309);

/// Caisse hors ligne : vente sur le dernier catalogue reçu, ticket imprimé, file envoyée au retour de la connexion.
///
/// [onBackOnline] est appelé quand la boutique répond de nouveau et que la file est vide (retour à la caisse web).
class OfflineRegisterPage extends StatefulWidget {
  const OfflineRegisterPage({super.key, required this.engine, required this.session, required this.onBackOnline});

  final OfflineEngine engine;
  final TerminalSession session;
  final VoidCallback onBackOnline;

  @override
  State<OfflineRegisterPage> createState() => _OfflineRegisterPageState();
}

class _OfflineRegisterPageState extends State<OfflineRegisterPage> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final List<CartLine> _cart = [];
  Operator? _operator;
  Timer? _probe;
  Map<int, BigInt> _sold = {};
  bool _probing = false;
  String? _lastSyncMessage;

  OfflineEngine get _engine => widget.engine;
  Snapshot? get _snapshot => _engine.snapshot;

  @override
  void initState() {
    super.initState();
    _engine.addListener(_changed);
    final rules = _snapshot?.rules;
    _probe = Timer.periodic(Duration(seconds: rules?.probeSeconds ?? 20), (_) => _tryOnline(automatic: true));
    if (rules != null && !rules.pinRequired) _operator = _snapshot!.operatorById(_snapshot!.lastOperatorId);
    _refreshSold();
  }

  @override
  void dispose() {
    _probe?.cancel();
    _engine.removeListener(_changed);
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshSold() async {
    final sold = await _engine.soldSinceSnapshot();
    if (mounted) setState(() => _sold = sold);
  }

  /// Retour de la connexion : envoi de la file, puis retour à la caisse web si tout est parti (ou sur demande).
  Future<void> _tryOnline({bool automatic = false}) async {
    if (_probing) return;
    _probing = true;
    try {
      if (!await _engine.probe()) {
        if (!automatic) _toast('La boutique ne répond toujours pas.');
        return;
      }
      final report = await _engine.sync();
      setState(
        () => _lastSyncMessage = report.sent > 0
            ? '${report.sent} opération(s) envoyée(s) : ${report.integrated} intégrée(s)${report.pending > 0 ? ', ${report.pending} à arbitrer par la boutique' : ''}${report.refused > 0 ? ', ${report.refused} refusée(s)' : ''}.'
            : report.message,
      );
      if (_engine.pendingCount > 0) return;
      unawaited(_engine.refreshSnapshot());
      if (_cart.isNotEmpty) {
        _toast('Connexion rétablie : terminez cette vente, puis revenez à la caisse en ligne.');
        return;
      }
      if (!automatic || (_snapshot?.rules.automaticSwitch ?? true)) widget.onBackOnline();
    } finally {
      _probing = false;
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final reason = _engine.blockReason;
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFFF6F7F6),
        body: SafeArea(
          child: Column(
            children: [
              _banner(),
              Expanded(
                child: reason != null || snapshot == null
                    ? _Blocked(message: reason ?? 'Catalogue absent.', onRetry: () => _tryOnline())
                    : _operator == null
                    ? _OperatorLogin(engine: _engine, onLogged: (o) => setState(() => _operator = o))
                    : !_engine.sessionOpen
                    ? _SessionOpening(engine: _engine, operator: _operator!, onOpened: () => setState(() {}))
                    : _register(snapshot),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _banner() {
    final remaining = _engine.remaining;
    final contact = _engine.lastContact;
    String two(int v) => v.toString().padLeft(2, '0');
    final since = contact == null
        ? 'jamais'
        : '${two(contact.toLocal().day)}/${two(contact.toLocal().month)} ${two(contact.toLocal().hour)}:${two(contact.toLocal().minute)}';
    return Material(
      color: _offline,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            const Icon(Icons.cloud_off, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Caisse hors ligne · dernier contact $since'
                '${remaining != null ? ' · reste ${remaining.inHours} h ${two(remaining.inMinutes % 60)}' : ''}'
                ' · ${_engine.pendingCount} en attente'
                '${_lastSyncMessage != null ? ' · $_lastSyncMessage' : ''}',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (_operator != null)
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                onPressed: _cart.isEmpty && (_snapshot?.rules.pinRequired ?? true) ? () => setState(() => _operator = null) : null,
                icon: const Icon(Icons.person),
                label: Text(_operator!.name),
              ),
            IconButton(
              tooltip: 'Opérations hors ligne',
              color: Colors.white,
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PendingOperationsPage(engine: _engine))),
              icon: const Icon(Icons.receipt_long),
            ),
            FilledButton.tonalIcon(
              onPressed: _engine.syncing ? null : () => _tryOnline(),
              icon: _engine.syncing
                  ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.wifi_find),
              label: const Text('Reconnecter'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _register(Snapshot snapshot) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 760;
        final catalogue = _catalogue(snapshot);
        final cart = _cartPanel(snapshot);
        if (wide) {
          return Row(
            children: [
              Expanded(flex: 3, child: catalogue),
              SizedBox(width: 380, child: cart),
            ],
          );
        }
        return Column(
          children: [
            Expanded(flex: 3, child: catalogue),
            SizedBox(height: constraints.maxHeight * 0.45, child: cart),
          ],
        );
      },
    );
  }

  Widget _catalogue(Snapshot snapshot) {
    final results = snapshot.search(_search.text);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          TextField(
            controller: _search,
            focusNode: _searchFocus,
            autofocus: true,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: 'Rechercher ou scanner un article',
              filled: true,
              fillColor: Colors.white,
              border: const OutlineInputBorder(),
              suffixIcon: _search.text.isEmpty ? null : IconButton(icon: const Icon(Icons.clear), onPressed: () => setState(_search.clear)),
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (value) => _scan(snapshot, value),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: results.isEmpty
                ? const Center(child: Text('Aucun article.'))
                : GridView.builder(
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 220,
                      mainAxisExtent: 92,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                    ),
                    itemCount: results.length,
                    itemBuilder: (context, index) => _productTile(results[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _productTile(Product product) {
    final stock = product.signedStock - (_sold[product.id] ?? BigInt.zero);
    final low = !product.unlimitedStock && stock <= BigInt.zero;
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _add(product, null),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                product.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Row(
                children: [
                  Text(
                    formatFcfa(product.price),
                    style: const TextStyle(color: _brand, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  if (!product.unlimitedStock)
                    Text(
                      'stock ${formatMicros(stock.abs())}${stock.isNegative ? ' (−)' : ''}',
                      style: TextStyle(fontSize: 11, color: low ? Colors.red : Colors.black54),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _scan(Snapshot snapshot, String value) {
    final code = value.trim();
    if (code.isEmpty) return;
    final found = snapshot.byCode(code);
    if (found != null) {
      _add(found.$1, found.$1.packaging(found.$2));
      _search.clear();
    } else {
      final results = snapshot.search(code);
      if (results.length == 1) {
        _add(results.first, null);
        _search.clear();
      } else if (results.isEmpty) {
        _toast('Article « $code » introuvable dans le catalogue hors ligne.');
      }
    }
    setState(() {});
    _searchFocus.requestFocus();
  }

  Future<void> _add(Product product, Packaging? packaging) async {
    var chosen = packaging;
    if (chosen == null && product.packagings.isNotEmpty) {
      chosen = await showDialog<Packaging?>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(product.name),
          children: [
            SimpleDialogOption(onPressed: () => Navigator.pop(context, null), child: Text('À l’unité — ${formatFcfa(product.price)}')),
            for (final p in product.packagings)
              SimpleDialogOption(onPressed: () => Navigator.pop(context, p), child: Text('${p.name} — ${formatFcfa(p.price)}')),
          ],
        ),
      );
    }
    setState(() {
      final existing = _cart.where((l) => l.product.id == product.id && l.packaging?.id == chosen?.id).firstOrNull;
      if (existing != null) {
        existing.quantity += BigInt.from(1000000);
      } else {
        _cart.add(CartLine(product: product, packaging: chosen));
      }
    });
    _searchFocus.requestFocus();
  }

  Widget _cartPanel(Snapshot snapshot) {
    final totals = saleTotals([for (final l in _cart) l.total], snapshot.store.vatRate, snapshot.store.vatIncluded);
    return Material(
      color: Colors.white,
      elevation: 2,
      child: Column(
        children: [
          ListTile(
            title: Text('Panier (${_cart.length})', style: const TextStyle(fontWeight: FontWeight.bold)),
            trailing: _cart.isEmpty ? null : TextButton(onPressed: () => setState(_cart.clear), child: const Text('Vider')),
          ),
          const Divider(height: 1),
          Expanded(
            child: _cart.isEmpty
                ? const Center(child: Text('Touchez ou scannez un article.'))
                : ListView.separated(
                    itemCount: _cart.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final line = _cart[index];
                      return ListTile(
                        dense: true,
                        title: Text(line.label, maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          '${formatMicros(line.quantity)} × ${formatFcfa(line.unitPrice)}${line.discount > 0 ? ' − ${formatFcfa(line.discount)}' : ''}',
                        ),
                        onTap: () => _editLine(snapshot, line),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.remove_circle_outline),
                              onPressed: () => setState(() {
                                line.quantity -= BigInt.from(1000000);
                                if (line.quantity <= BigInt.zero) _cart.remove(line);
                                line.discount = line.discount.clamp(0, maxLineDiscount(line.base, snapshot.rules.maxLineDiscountPercent));
                              }),
                            ),
                            Text(formatFcfa(line.total), style: const TextStyle(fontWeight: FontWeight.w600)),
                            IconButton(
                              icon: const Icon(Icons.add_circle_outline),
                              onPressed: () => setState(() => line.quantity += BigInt.from(1000000)),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                if (snapshot.store.hasVat)
                  Row(children: [Text(snapshot.store.vatIncluded ? 'dont TVA' : 'TVA'), const Spacer(), Text(formatFcfa(totals.vat))]),
                Row(
                  children: [
                    const Text('Total', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                    const Spacer(),
                    Text(
                      formatFcfa(totals.payable),
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: _brand),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: _brand),
                    onPressed: _cart.isEmpty ? null : () => _checkout(snapshot, totals.payable),
                    icon: const Icon(Icons.payments),
                    label: const Text('Encaisser', style: TextStyle(fontSize: 18)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _editLine(Snapshot snapshot, CartLine line) async {
    final quantity = TextEditingController(text: formatMicros(line.quantity));
    final discount = TextEditingController(text: line.discount > 0 ? '${line.discount}' : '');
    final maxPercent = snapshot.rules.maxLineDiscountPercent;
    String? error;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(line.label),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: quantity,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Quantité'),
              ),
              if (maxPercent > 0)
                TextField(
                  controller: discount,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(labelText: 'Remise (F, au plus $maxPercent %)'),
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(error!, style: const TextStyle(color: Colors.red)),
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => {setState(() => _cart.remove(line)), Navigator.pop(context)}, child: const Text('Retirer')),
            FilledButton(
              onPressed: () {
                final q = parseMicros(quantity.text);
                if (q == null || q <= BigInt.zero) return setLocal(() => error = 'Quantité invalide (six décimales au plus).');
                final d = int.tryParse(discount.text) ?? 0;
                if (d > maxLineDiscount(lineBase(line.unitPrice, q), maxPercent)) return setLocal(() => error = 'Remise au-delà de $maxPercent %.');
                setState(() => (line.quantity = q, line.discount = d));
                Navigator.pop(context);
              },
              child: const Text('Valider'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _checkout(Snapshot snapshot, int payable) async {
    final payments = await showDialog<List<CartPayment>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PaymentDialog(snapshot: snapshot, payable: payable),
    );
    if (payments == null || !mounted) return;
    final OfflineOperation operation;
    try {
      operation = await _engine.recordSale(List.of(_cart), payments, _operator!);
    } on OfflineRefusal catch (e) {
      _toast(e.message);
      return;
    }
    final lines = List.of(_cart);
    setState(_cart.clear);
    unawaited(_refreshSold());
    await _print(snapshot, operation, lines, payments);
    final change = payments.fold<int>(0, (sum, p) => sum + p.change);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.check_circle, color: _brand, size: 48),
        title: Text('Vente ${operation.number}'),
        content: Text(
          change > 0 ? 'Monnaie à rendre : ${formatFcfa(change)}' : 'Vente enregistrée sur le terminal.',
          style: const TextStyle(fontSize: 20),
        ),
        actions: [
          TextButton(onPressed: () => _print(snapshot, operation, lines, payments, duplicate: true), child: const Text('Réimprimer')),
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Vente suivante')),
        ],
      ),
    );
    _searchFocus.requestFocus();
  }

  Future<void> _print(
    Snapshot snapshot,
    OfflineOperation operation,
    List<CartLine> lines,
    List<CartPayment> payments, {
    bool duplicate = false,
  }) async {
    final session = widget.session;
    final width = session.rollWidth > 0 ? session.rollWidth : 58;
    final text = offlineTicketLines(
      snapshot: snapshot,
      operation: operation,
      lines: lines,
      payments: payments,
      operatorName: _operator?.name ?? '',
      paperWidth: width,
      duplicate: duplicate,
    );
    if (session.hasPrinter) {
      final result = await session.channel.printRaw(offlineTicketBytes(text));
      if (payments.any((p) => p.method.isCash) && !duplicate) await session.channel.openDrawer();
      if (!result.ok) _toast('Ticket non imprimé (${result.error}) : la vente est bien enregistrée.');
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ticket (aucune imprimante)'),
        content: SingleChildScrollView(
          child: Text(text.join('\n'), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Fermer'))],
      ),
    );
  }
}

class _Blocked extends StatelessWidget {
  const _Blocked({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.block, size: 56, color: _offline),
          const SizedBox(height: 12),
          Text('Vente hors ligne impossible', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Réessayer la connexion')),
        ],
      ),
    ),
  );
}

/// Choix du caissier : PIN de caisse vérifié sur le terminal (empreinte reçue avec le catalogue).
class _OperatorLogin extends StatefulWidget {
  const _OperatorLogin({required this.engine, required this.onLogged});

  final OfflineEngine engine;
  final ValueChanged<Operator> onLogged;

  @override
  State<_OperatorLogin> createState() => _OperatorLoginState();
}

class _OperatorLoginState extends State<_OperatorLogin> {
  Operator? _selected;
  String _pin = '';
  String? _error;
  bool _checking = false;
  int _failures = 0;
  DateTime? _lockedUntil;

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.engine.snapshot!;
    final operators = snapshot.operators.where((o) => !snapshot.rules.pinRequired || (o.pinHash ?? '').isNotEmpty).toList();
    if (!snapshot.rules.pinRequired) {
      final last = snapshot.operatorById(snapshot.lastOperatorId);
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(last == null ? 'Aucun caissier connu sur ce terminal.' : 'Caissier : ${last.name}', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            if (last != null) FilledButton(onPressed: () => widget.onLogged(last), child: const Text('Continuer')),
          ],
        ),
      );
    }
    if (_selected == null) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Qui encaisse ?', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 12),
              if (operators.isEmpty) const Text('Aucun caissier avec un PIN de caisse : définissez les PIN dans ShopiKaiss (Utilisateurs).'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final o in operators)
                    ActionChip(
                      avatar: const Icon(Icons.person),
                      label: Text(o.name),
                      onPressed: () => setState(() => (_selected = o, _pin = '', _error = null)),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_selected!.name, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text('•' * _pin.length + '○' * (6 - _pin.length).clamp(0, 6), style: const TextStyle(fontSize: 28, letterSpacing: 6)),
            if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 8),
            GridView.count(
              shrinkWrap: true,
              crossAxisCount: 3,
              childAspectRatio: 1.6,
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
              children: [
                for (final key in ['1', '2', '3', '4', '5', '6', '7', '8', '9', '←', '0', 'OK'])
                  FilledButton.tonal(
                    onPressed: _checking ? null : () => _key(key),
                    child: _checking && key == 'OK' ? const CircularProgressIndicator() : Text(key, style: const TextStyle(fontSize: 20)),
                  ),
              ],
            ),
            TextButton(onPressed: () => setState(() => _selected = null), child: const Text('Changer de caissier')),
          ],
        ),
      ),
    );
  }

  Future<void> _key(String key) async {
    if (key == '←') return setState(() => _pin = _pin.isEmpty ? '' : _pin.substring(0, _pin.length - 1));
    if (key != 'OK') {
      if (_pin.length < 6) setState(() => _pin += key);
      return;
    }
    final locked = _lockedUntil;
    if (locked != null && DateTime.now().isBefore(locked)) {
      return setState(() => _error = 'Trop d’essais : patientez ${locked.difference(DateTime.now()).inSeconds + 1} s.');
    }
    setState(() => (_checking = true, _error = null));
    final ok = await widget.engine.checkPin(_selected!, _pin);
    if (!mounted) return;
    if (ok) {
      _failures = 0;
      widget.onLogged(_selected!);
    } else {
      _failures++;
      // Même progression que le serveur (PinService) : 3 essais, puis 30 s doublées à chaque nouvel échec.
      if (_failures >= 3) _lockedUntil = DateTime.now().add(Duration(seconds: (30 * (1 << (_failures - 3))).clamp(30, 900)));
      setState(() => (_checking = false, _pin = '', _error = 'PIN incorrect.'));
    }
  }
}

class _SessionOpening extends StatefulWidget {
  const _SessionOpening({required this.engine, required this.operator, required this.onOpened});

  final OfflineEngine engine;
  final Operator operator;
  final VoidCallback onOpened;

  @override
  State<_SessionOpening> createState() => _SessionOpeningState();
}

class _SessionOpeningState extends State<_SessionOpening> {
  final _float = TextEditingController(text: '0');
  String? _error;

  @override
  Widget build(BuildContext context) {
    final allowed = widget.engine.snapshot?.rules.sessionOpening ?? false;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Aucune session de caisse ouverte', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  allowed
                      ? 'Comptez le fond de caisse : la session sera ouverte sur la boutique au retour de la connexion.'
                      : 'La boutique n’autorise pas l’ouverture de session hors ligne : la vente reprendra en ligne.',
                ),
                if (allowed) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _float,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(labelText: 'Fond de caisse (F)', errorText: _error),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _open, child: const Text('Ouvrir la session')),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _open() async {
    try {
      await widget.engine.openSession(int.tryParse(_float.text) ?? 0, widget.operator);
      widget.onOpened();
    } on OfflineRefusal catch (e) {
      setState(() => _error = e.message);
    }
  }
}

/// Encaissement : un ou plusieurs moyens autorisés hors ligne ; les espèces calculent la monnaie.
class _PaymentDialog extends StatefulWidget {
  const _PaymentDialog({required this.snapshot, required this.payable});

  final Snapshot snapshot;
  final int payable;

  @override
  State<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<_PaymentDialog> {
  final List<CartPayment> _payments = [];
  late PaymentMethodInfo _method = widget.snapshot.methods.first;
  final _amount = TextEditingController();
  final _received = TextEditingController();
  String? _error;

  int get _remaining => widget.payable - _payments.fold<int>(0, (sum, p) => sum + p.amount);

  @override
  void initState() {
    super.initState();
    _reset();
  }

  void _reset() {
    _amount.text = '$_remaining';
    _received.text = '';
  }

  @override
  Widget build(BuildContext context) {
    final cash = _method.isCash;
    final received = int.tryParse(_received.text);
    final amount = int.tryParse(_amount.text) ?? 0;
    return AlertDialog(
      title: Text('Encaisser ${formatFcfa(widget.payable)}'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final p in _payments)
              ListTile(
                dense: true,
                title: Text(p.method.name),
                subtitle: p.change > 0 ? Text('reçu ${formatFcfa(p.received!)} · monnaie ${formatFcfa(p.change)}') : null,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(formatFcfa(p.amount)),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() {
                        _payments.remove(p);
                        _reset();
                      }),
                    ),
                  ],
                ),
              ),
            if (_remaining > 0) ...[
              Wrap(
                spacing: 6,
                children: [
                  for (final m in widget.snapshot.methods)
                    ChoiceChip(label: Text(m.name), selected: m.code == _method.code, onSelected: (_) => setState(() => _method = m)),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _amount,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(labelText: 'Montant réglé (reste ${formatFcfa(_remaining)})'),
                onChanged: (_) => setState(() {}),
              ),
              if (cash)
                TextField(
                  controller: _received,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    labelText: 'Espèces reçues',
                    helperText: received != null && received > amount ? 'Monnaie : ${formatFcfa(received - amount)}' : null,
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _addPayment(),
                ),
              if (cash)
                Wrap(
                  spacing: 6,
                  children: [
                    for (final note in _quickNotes(amount))
                      ActionChip(label: Text(formatFcfa(note)), onPressed: () => setState(() => _received.text = '$note')),
                  ],
                ),
              const SizedBox(height: 8),
              OutlinedButton.icon(onPressed: _addPayment, icon: const Icon(Icons.add), label: const Text('Ajouter ce paiement')),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton(
          onPressed: () {
            if (_remaining > 0 && !_addPayment()) return;
            if (_remaining == 0) Navigator.pop(context, _payments);
          },
          child: const Text('Valider la vente'),
        ),
      ],
    );
  }

  List<int> _quickNotes(int amount) {
    final notes = <int>{amount};
    for (final step in [500, 1000, 2000, 5000, 10000]) {
      final rounded = ((amount + step - 1) ~/ step) * step;
      if (rounded > amount) notes.add(rounded);
    }
    return notes.take(5).toList();
  }

  bool _addPayment() {
    final amount = int.tryParse(_amount.text) ?? 0;
    if (amount <= 0 || amount > _remaining) {
      setState(() => _error = 'Montant entre 1 et ${formatFcfa(_remaining)}.');
      return false;
    }
    final received = _method.isCash ? (int.tryParse(_received.text) ?? amount) : null;
    if (received != null && received < amount) {
      setState(() => _error = 'Espèces reçues inférieures au montant.');
      return false;
    }
    setState(() {
      _payments.add(CartPayment(method: _method, amount: amount, received: received));
      _error = null;
      _reset();
    });
    return true;
  }
}
