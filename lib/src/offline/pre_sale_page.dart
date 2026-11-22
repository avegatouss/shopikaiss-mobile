import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import 'engine.dart';
import 'local_sessions_ui.dart' show formatDayFr;
import 'models.dart';
import 'money.dart';

/// Prévente / réservations (2.1 lot 15) : liste et recherche (code, nom, téléphone), détail, retrait par le panier,
/// désistement. La création se fait depuis le panier de la caisse ([showCreatePreSale]).
class PreSalePage extends StatefulWidget {
  const PreSalePage({super.key, required this.engine, required this.operator, required this.onWithdraw, required this.onPrint});

  final CaisseEngine engine;
  final Operator operator;

  /// Retrait : la page se ferme, la caisse charge les lignes et déduit l'acompte.
  final void Function(PreSale preSale) onWithdraw;

  /// Impression de la facture (création, réimpression) ou du ticket de désistement.
  final Future<void> Function(PreSale preSale) onPrint;

  @override
  State<PreSalePage> createState() => _PreSalePageState();
}

class _PreSalePageState extends State<PreSalePage> {
  final _query = TextEditingController();
  bool _openOnly = true;
  List<PreSale>? _list;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await widget.engine.preSales(query: _query.text, openOnly: _openOnly);
    if (mounted) setState(() => _list = list);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final list = _list;
    return Scaffold(
      appBar: AppBar(title: const Text('Préventes')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _query,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                labelText: 'Code, nom ou téléphone',
                border: const OutlineInputBorder(),
                suffixIcon: _query.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _query.clear();
                          _load();
                        },
                      ),
              ),
              onChanged: (_) => _load(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                ChoiceChip(label: const Text('Ouvertes'), selected: _openOnly, onSelected: (_) {
                    _openOnly = true;
                    _load();
                  }),
                const SizedBox(width: 8),
                ChoiceChip(label: const Text('Toutes'), selected: !_openOnly, onSelected: (_) {
                    _openOnly = false;
                    _load();
                  }),
              ],
            ),
          ),
          Expanded(
            child: list == null
                ? const Center(child: CircularProgressIndicator())
                : list.isEmpty
                ? Center(child: Text(_query.text.isEmpty ? 'Aucune prévente ouverte.\nRemplissez le panier puis « Nouvelle prévente ».' : 'Aucune prévente trouvée.', textAlign: TextAlign.center))
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) => _tile(theme, list[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _tile(ThemeData theme, PreSale p) {
    final (label, color) = switch (p.status) {
      'ouverte' => ('Ouverte', const Color(0xFF2E7D32)),
      'retiree' => ('Retirée', const Color(0xFF1565C0)),
      'desistee' => ('Désistée', const Color(0xFFC62828)),
      _ => ('Fermée ailleurs', const Color(0xFF616161)),
    };
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _detail(p),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(color: theme.colorScheme.primary.withValues(alpha: .08), borderRadius: BorderRadius.circular(8)),
                child: Text(p.code, style: const TextStyle(fontFamily: 'monospace', fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: 1.5)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.customerName, style: theme.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(
                      [
                        if ((p.customerPhone ?? '').isNotEmpty) p.customerPhone!,
                        if (p.pickupAt != null) 'retrait ${formatDayFr(p.pickupAt!.toLocal().toIso8601String().substring(0, 10))}',
                        if (!p.local) 'autre caisse',
                      ].join(' · '),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(formatFcfa(p.total), style: const TextStyle(fontWeight: FontWeight.w700)),
                  if (p.deposit > 0) Text('acompte ${formatFcfa(p.deposit)}', style: theme.textTheme.bodySmall),
                  const SizedBox(height: 2),
                  Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _detail(PreSale p) async {
    final theme = Theme.of(context);
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(p.code, textAlign: TextAlign.center, style: const TextStyle(fontFamily: 'monospace', fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: 4)),
              Text(p.customerName, textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
              if ((p.customerPhone ?? '').isNotEmpty) Text(p.customerPhone!, textAlign: TextAlign.center),
              const Divider(height: 24),
              for (final l in p.lines)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [Expanded(child: Text('${l.quantity.replaceFirst(RegExp(r'\.?0+$'), '')} × ${l.label}')), Text(formatFcfa(l.total))]),
                ),
              const Divider(height: 24),
              _row('Total réservé', formatFcfa(p.total)),
              _row('Acompte versé', formatFcfa(p.deposit)),
              _row('Reste à payer', formatFcfa(p.due), bold: true),
              if ((p.note ?? '').isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Note : ${p.note}')),
              if (p.serverMessage != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(p.serverMessage!, style: const TextStyle(color: Color(0xFFE65100)))),
              const SizedBox(height: 16),
              if (p.open)
                FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  onPressed: () => Navigator.pop(context, 'retirer'),
                  icon: const Icon(Icons.shopping_cart_checkout),
                  label: Text(p.due > 0 ? 'Retirer · encaisser ${formatFcfa(p.due)}' : 'Retirer (déjà réglée)'),
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: OutlinedButton.icon(onPressed: () => Navigator.pop(context, 'imprimer'), icon: const Icon(Icons.print), label: const Text('Réimprimer'))),
                  if (p.open) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFC62828)),
                        onPressed: () => Navigator.pop(context, 'desister'),
                        icon: const Icon(Icons.cancel_outlined),
                        label: const Text('Désistement'),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'retirer':
        Navigator.of(context).pop();
        widget.onWithdraw(p);
      case 'imprimer':
        await widget.onPrint(p);
      case 'desister':
        await _cancel(p);
    }
  }

  Widget _row(String label, String value, {bool bold = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(children: [Expanded(child: Text(label, style: TextStyle(fontWeight: bold ? FontWeight.w700 : null))), Text(value, style: TextStyle(fontWeight: bold ? FontWeight.w700 : null))]),
  );

  Future<void> _cancel(PreSale p) async {
    final reason = TextEditingController();
    final refund = TextEditingController(text: p.deposit > 0 ? '${p.deposit}' : '0');
    final methods = widget.engine.snapshot?.methods ?? const <PaymentMethodInfo>[];
    var method = methods.where((m) => m.code == p.depositMethod).firstOrNull ?? methods.firstOrNull;
    final operationUuid = const Uuid().v4();
    String? error;
    var busy = false;
    final done = await showDialog<PreSale>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text('Désistement · ${p.code}'),
          scrollable: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(controller: reason, autofocus: true, maxLength: 500, decoration: const InputDecoration(labelText: 'Motif (obligatoire)')),
              if (p.deposit > 0) ...[
                Text('Acompte versé : ${formatFcfa(p.deposit)}. Remboursement de 0 à ${formatFcfa(p.deposit)}.'),
                TextField(
                  controller: refund,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: 'Montant remboursé (F)'),
                ),
                DropdownButtonFormField<String>(
                  initialValue: method?.code,
                  decoration: const InputDecoration(labelText: 'Rembourser par'),
                  items: [for (final m in methods) DropdownMenuItem(value: m.code, child: Text(m.name))],
                  onChanged: (v) => setLocal(() => method = methods.firstWhere((m) => m.code == v)),
                ),
              ],
              if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: const TextStyle(color: Colors.red))),
            ],
          ),
          actions: [
            TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: const Text('Retour')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFFC62828)),
              onPressed: busy
                  ? null
                  : () async {
                      setLocal(() => (busy = true, error = null));
                      try {
                        final amount = int.tryParse(refund.text) ?? 0;
                        final cancelled = await widget.engine.cancelPreSale(widget.operator, p.uuid,
                            reason: reason.text, refund: amount, refundMethod: amount > 0 ? method : null, operationUuid: operationUuid);
                        if (context.mounted) Navigator.pop(context, cancelled);
                      } on OfflineRefusal catch (e) {
                        setLocal(() => (busy = false, error = e.message));
                      }
                    },
              child: const Text('Confirmer le désistement'),
            ),
          ],
        ),
      ),
    );
    if (done == null || !mounted) return;
    await widget.onPrint(done);
    await _load();
  }
}

/// Nouvelle prévente depuis le panier : client (nom seul obligatoire), téléphone, retrait prévu, acompte facultatif.
Future<PreSale?> showCreatePreSale(BuildContext context, {required CaisseEngine engine, required Operator operator, required List<CartLine> lines, Customer? customer}) {
  final name = TextEditingController(text: customer?.name ?? '');
  final phone = TextEditingController(text: customer?.phone ?? '');
  final deposit = TextEditingController(text: '0');
  final received = TextEditingController();
  final note = TextEditingController();
  final methods = engine.snapshot?.methods ?? const <PaymentMethodInfo>[];
  var method = methods.where((m) => m.isCash).firstOrNull ?? methods.firstOrNull;
  DateTime? pickup;
  final total = lines.fold<int>(0, (s, l) => s + l.base - l.discount);
  final operationUuid = const Uuid().v4();
  String? error;
  var busy = false;
  return showDialog<PreSale>(
    context: context,
    barrierDismissible: false,
    builder: (context) => StatefulBuilder(
      builder: (context, setLocal) {
        final amount = int.tryParse(deposit.text) ?? 0;
        return AlertDialog(
          icon: const Icon(Icons.bookmark_add_outlined),
          title: Text('Nouvelle prévente · ${formatFcfa(total)}'),
          scrollable: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('${lines.length} article(s) du panier.'),
              TextField(controller: name, autofocus: name.text.isEmpty, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Nom du client')),
              TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Téléphone (facultatif)')),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () async {
                  final now = DateTime.now();
                  final day = await showDatePicker(context: context, firstDate: DateTime(now.year, now.month, now.day), lastDate: now.add(const Duration(days: 365)), initialDate: now);
                  if (day == null || !context.mounted) return;
                  final time = await showTimePicker(context: context, initialTime: const TimeOfDay(hour: 12, minute: 0));
                  setLocal(() => pickup = DateTime(day.year, day.month, day.day, time?.hour ?? 12, time?.minute ?? 0));
                },
                icon: const Icon(Icons.event),
                label: Text(pickup == null ? 'Retrait prévu (facultatif)' : 'Retrait le ${formatDayFr(pickup!.toIso8601String().substring(0, 10))} à ${pickup!.hour.toString().padLeft(2, '0')}:${pickup!.minute.toString().padLeft(2, '0')}'),
              ),
              TextField(
                controller: deposit,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(labelText: 'Acompte (F, 0 permis)', helperText: 'Reste au retrait : ${formatFcfa(total - amount)}'),
                onChanged: (_) => setLocal(() {}),
              ),
              if (amount > 0) ...[
                DropdownButtonFormField<String>(
                  initialValue: method?.code,
                  decoration: const InputDecoration(labelText: 'Moyen de l’acompte'),
                  items: [for (final m in methods) DropdownMenuItem(value: m.code, child: Text(m.name))],
                  onChanged: (v) => setLocal(() => method = methods.firstWhere((m) => m.code == v)),
                ),
                if (method?.isCash ?? false)
                  TextField(
                    controller: received,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: 'Reçu du client (facultatif)',
                      helperText: (int.tryParse(received.text) ?? 0) > amount ? 'Monnaie : ${formatFcfa((int.tryParse(received.text) ?? 0) - amount)}' : null,
                    ),
                    onChanged: (_) => setLocal(() {}),
                  ),
              ],
              TextField(controller: note, maxLength: 500, decoration: const InputDecoration(labelText: 'Note (facultatif)')),
              if (error != null) Text(error!, style: const TextStyle(color: Colors.red)),
            ],
          ),
          actions: [
            TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: const Text('Annuler')),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: busy
                  ? null
                  : () async {
                      setLocal(() => (busy = true, error = null));
                      try {
                        final created = await engine.createPreSale(
                          operator,
                          customerName: name.text,
                          customerPhone: phone.text,
                          customerUuid: customer?.uuid,
                          pickupAt: pickup,
                          lines: lines,
                          deposit: amount,
                          depositMethod: amount > 0 ? method : null,
                          received: int.tryParse(received.text),
                          note: note.text,
                          operationUuid: operationUuid,
                        );
                        if (context.mounted) Navigator.pop(context, created);
                      } on OfflineRefusal catch (e) {
                        setLocal(() => (busy = false, error = e.message));
                      }
                    },
              child: const Text('Enregistrer et imprimer'),
            ),
          ],
        );
      },
    ),
  );
}
