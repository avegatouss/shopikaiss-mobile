import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models.dart';
import 'money.dart';

/// Avancement du paiement, poussé à l'afficheur client (`payment` de `CustomerDisplayFeed` du web).
class PaymentProgress {
  const PaymentProgress({required this.amountDue, required this.paid, required this.received, required this.remaining, required this.change, required this.methods});

  final int amountDue;

  /// Somme des montants saisis sur les lignes.
  final int paid;

  /// Remis par le client : espèces reçues (montant exact arrondi si vide) et montants des autres moyens.
  final int received;
  final int remaining;
  final int change;

  /// Moyens saisis : `{name, amount}` (sans QR hors ligne).
  final List<({String name, int amount})> methods;

  Map<String, dynamic> toDisplay() => {
    'amount_due': amountDue,
    'paid': paid,
    'received': received,
    'change': change,
    'remaining': remaining,
    'methods': [for (final m in methods) {'name': m.name, 'amount': m.amount}],
    'qr': const <Map<String, dynamic>>[],
  };
}

/// Une ligne de paiement à l'écran : moyen, montant, puis espèces reçues ou référence.
class _PaymentRow {
  _PaymentRow(this.method, int? amount) : amount = TextEditingController(text: amount == null ? '' : '$amount');

  PaymentMethodInfo method;
  final TextEditingController amount;
  final received = TextEditingController();
  final reference = TextEditingController();

  /// Ligne ajoutée alors que la première couvrait tout : sa saisie réduit d'autant la première (brief TBC §4).
  bool balanceFirst = false;

  int? get value => int.tryParse(amount.text.trim());

  void dispose() {
    amount.dispose();
    received.dispose();
    reference.dispose();
  }
}

/// Coupures FCFA proposées en montants rapides sur la ligne espèces (brief TBC §4).
const cashQuickNotes = [1000, 2000, 5000, 10000];

/// Au plus 10 lignes de paiement par vente (règle du moteur Windows et du web).
const maxPaymentRows = 10;

/// Encaissement en lignes (parité avec la caisse Windows, `multiple_payments.dart`) : une ligne par moyen, montant
/// prérempli avec le reste, référence ou espèces reçues sur la même ligne. L'écran n'invente aucun montant : il affiche
/// le reste et la monnaie, le moteur ([check]) valide la répartition avant de rendre la main.
///
/// Largeur d'au moins 600 dp (tablette, terminal) : chaque ligne tient sur une rangée. En dessous (téléphone) : la ligne
/// passe sur deux rangées ; [fullScreen] l'ouvre en page plein écran, boutons en bas.
class OfflinePaymentDialog extends StatefulWidget {
  const OfflinePaymentDialog({super.key, required this.methods, required this.payable, required this.cashDue, this.fullScreen = false, this.check, this.onProgress});

  /// Moyens autorisés hors ligne, dans l'ordre d'affichage configuré par la boutique (le premier est proposé).
  final List<PaymentMethodInfo> methods;
  final int payable;

  /// Montant dû au tiroir pour une ligne d'espèces (arrondi de caisse de la boutique).
  final int Function(int amount) cashDue;

  /// Petit téléphone : page plein écran qui défile, boutons en bas (au lieu d'une boîte de dialogue).
  final bool fullScreen;

  /// Contrôle du moteur sur la répartition complète : motif du refus, ou null si elle est acceptée.
  final String? Function(List<CartPayment> payments)? check;

  /// Chaque changement de saisie (afficheur client).
  final void Function(PaymentProgress progress)? onProgress;

  @override
  State<OfflinePaymentDialog> createState() => _OfflinePaymentDialogState();
}

class _OfflinePaymentDialogState extends State<OfflinePaymentDialog> {
  late final List<_PaymentRow> _rows = [_PaymentRow(widget.methods.first, widget.payable)];
  String? _error;

  /// Reste à répartir ; null tant qu'un montant est illisible.
  int? get _remaining {
    var allocated = 0;
    for (final row in _rows) {
      final value = row.value;
      if (value == null) {
        if (row.amount.text.trim().isEmpty) continue;
        return null;
      }
      allocated += value;
    }
    return widget.payable - allocated;
  }

  _PaymentRow? get _cashRow => _rows.where((r) => r.method.isCash).firstOrNull;

  /// Monnaie à rendre sur la ligne espèces (sur elle seule, jamais sur le total dû).
  int _change(_PaymentRow row) {
    final amount = row.value;
    final received = int.tryParse(row.received.text.trim());
    if (amount == null || received == null) return 0;
    final due = widget.cashDue(amount);
    return received > due ? received - due : 0;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _report());
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  void _changed() {
    setState(() => _error = null);
    _report();
  }

  void _report() {
    final onProgress = widget.onProgress;
    if (onProgress == null || !mounted) return;
    var paid = 0;
    var received = 0;
    var change = 0;
    final methods = <({String name, int amount})>[];
    for (final row in _rows) {
      final amount = row.value ?? 0;
      paid += amount;
      methods.add((name: row.method.name, amount: amount));
      if (row.method.isCash) {
        received += int.tryParse(row.received.text.trim()) ?? widget.cashDue(amount);
        change += _change(row);
      } else {
        received += amount;
      }
    }
    final remaining = widget.payable - paid;
    onProgress(PaymentProgress(amountDue: widget.payable, paid: paid, received: received, remaining: remaining > 0 ? remaining : 0, change: change, methods: methods));
  }

  void _addRow() {
    if (_rows.length >= maxPaymentRows) return;
    final remaining = _remaining;
    final used = {for (final r in _rows) r.method.code};
    // Moyen proposé : le premier de l'ordre configuré qui n'est pas déjà sur une ligne.
    final method = widget.methods.firstWhere((m) => !used.contains(m.code), orElse: () => widget.methods.first);
    _rows.add(
      _PaymentRow(method, remaining == null ? null : (remaining > 0 ? remaining : 0))..balanceFirst = _rows.length == 1 && remaining == 0,
    );
    _changed();
  }

  void _removeRow(_PaymentRow row) {
    if (_rows.length <= 1) return;
    _rows.remove(row);
    row.dispose();
    for (final r in _rows) {
      r.balanceFirst = false;
    }
    _changed();
  }

  void _amountChanged(_PaymentRow row, String value) {
    // Répartition en deux d'une première ligne pleine : la seconde prend sa part, la première garde le solde.
    if (row.balanceFirst && _rows.length == 2 && identical(row, _rows.last)) {
      final part = int.tryParse(value.trim());
      if (part != null && part >= 0 && part <= widget.payable) _rows.first.amount.text = '${widget.payable - part}';
    }
    _changed();
  }

  /// Montant rapide sur la ligne espèces : « Exact » = montant à encaisser, une coupure s'ajoute aux espèces reçues.
  void _quick(_PaymentRow row, int? note) {
    final amount = row.value ?? 0;
    if (note == null) {
      row.received.text = '${widget.cashDue(amount)}';
    } else {
      row.received.text = '${(int.tryParse(row.received.text.trim()) ?? 0) + note}';
    }
    _changed();
  }

  /// Répartition saisie, ou le motif qui l'empêche (mêmes messages que le moteur).
  (List<CartPayment>?, String?) _collect() {
    final payments = <CartPayment>[];
    for (final (i, row) in _rows.indexed) {
      final amount = row.value;
      if (amount == null || amount <= 0) return (null, 'Ligne ${i + 1} : saisissez un montant positif ou retirez la ligne.');
      final reference = row.reference.text.trim();
      if (row.method.referenceMode == 'obligatoire' && reference.isEmpty) return (null, 'Référence obligatoire pour « ${row.method.name} ».');
      final due = widget.cashDue(amount);
      final received = row.method.isCash ? (int.tryParse(row.received.text.trim()) ?? due) : null;
      if (received != null && received < due) return (null, 'Espèces reçues inférieures au montant à encaisser (${formatFcfa(due)}).');
      payments.add(
        CartPayment(method: row.method, amount: amount, received: received, cashDue: due, reference: row.method.isCash || reference.isEmpty ? null : reference),
      );
    }
    if (payments.where((p) => p.method.isCash).length > 1) return (null, 'Une seule ligne d’espèces par vente.');
    final remaining = _remaining ?? 0;
    if (remaining > 0) return (null, 'Reste à répartir : ${formatFcfa(remaining)}.');
    if (remaining < 0) return (null, 'Montants saisis supérieurs de ${formatFcfa(-remaining)} au montant à payer.');
    return (payments, null);
  }

  void _validate() {
    var (payments, error) = _collect();
    if (payments != null) error = widget.check?.call(payments);
    if (error != null || payments == null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(context, payments);
  }

  Widget _rowView(BuildContext context, int index, _PaymentRow row, bool wide) {
    final method = DropdownButtonFormField<String>(
      key: ValueKey('paiement-moyen-$index-${row.method.code}'),
      initialValue: row.method.code,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Moyen', isDense: true),
      items: [
        for (final m in widget.methods)
          DropdownMenuItem(value: m.code, child: Text(m.name, overflow: TextOverflow.ellipsis)),
      ],
      onChanged: (code) {
        final chosen = widget.methods.where((m) => m.code == code).firstOrNull;
        if (chosen == null || chosen.code == row.method.code) return;
        row
          ..method = chosen
          ..received.clear()
          ..reference.clear();
        _changed();
      },
    );
    final amount = TextField(
      key: ValueKey('paiement-montant-$index'),
      controller: row.amount,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: const InputDecoration(labelText: 'Montant', isDense: true, suffixText: 'F'),
      onChanged: (value) => _amountChanged(row, value),
      onSubmitted: (_) => _validate(),
    );
    final value = row.value ?? 0;
    final due = widget.cashDue(value);
    final change = _change(row);
    final details = row.method.isCash
        ? TextField(
            key: ValueKey('paiement-recu-$index'),
            controller: row.received,
            autofocus: index == 0,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: 'Espèces reçues',
              hintText: 'Vide = montant exact',
              isDense: true,
              helperText: [
                if (due != value) 'À encaisser : ${formatFcfa(due)}',
                if (change > 0) 'Monnaie : ${formatFcfa(change)}',
              ].join(' · '),
            ),
            onChanged: (_) => _changed(),
            onSubmitted: (_) => _validate(),
          )
        : TextField(
            key: ValueKey('paiement-reference-$index'),
            controller: row.reference,
            maxLength: 100,
            decoration: InputDecoration(
              labelText: row.method.referenceMode == 'obligatoire' ? 'Référence obligatoire' : 'Référence (facultative)',
              isDense: true,
              counterText: '',
            ),
            onChanged: (_) => _changed(),
            onSubmitted: (_) => _validate(),
          );
    final remove = IconButton(
      key: ValueKey('paiement-retirer-$index'),
      tooltip: 'Retirer ce paiement',
      icon: const Icon(Icons.delete_outline),
      onPressed: _rows.length > 1 ? () => _removeRow(row) : null,
    );
    final quick = row.method.isCash
        ? Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              ActionChip(key: ValueKey('paiement-exact-$index'), label: const Text('Exact'), onPressed: () => _quick(row, null)),
              for (final note in cashQuickNotes)
                ActionChip(key: ValueKey('paiement-coupure-$index-$note'), label: Text('+${formatFcfa(note)}'), onPressed: () => _quick(row, note)),
            ],
          )
        : null;
    return Card(
      key: ObjectKey(row),
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (wide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 3, child: method),
                  const SizedBox(width: 10),
                  Expanded(flex: 2, child: amount),
                  const SizedBox(width: 10),
                  Expanded(flex: 3, child: details),
                  remove,
                ],
              )
            else ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: method),
                  const SizedBox(width: 8),
                  Expanded(child: amount),
                  remove,
                ],
              ),
              Padding(padding: const EdgeInsets.only(right: 8), child: details),
            ],
            if (quick != null) Padding(padding: const EdgeInsets.only(top: 6), child: quick),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 600;
    final remaining = _remaining;
    final cash = _cashRow;
    final change = cash == null ? 0 : _change(cash);
    final title = Text('Encaisser ${formatFcfa(widget.payable)}');
    final summary = Wrap(
      spacing: 16,
      runSpacing: 4,
      children: [
        Text(
          remaining == null
              ? 'Reste à répartir : —'
              : remaining >= 0
              ? 'Reste à répartir : ${formatFcfa(remaining)}'
              : 'Trop saisi : ${formatFcfa(-remaining)}',
          key: const ValueKey('paiement-reste'),
          style: TextStyle(fontWeight: FontWeight.w600, color: remaining == 0 ? null : Colors.orange.shade900),
        ),
        if (change > 0)
          Text('Monnaie à rendre : ${formatFcfa(change)}', key: const ValueKey('paiement-monnaie'), style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    );
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        summary,
        const SizedBox(height: 4),
        for (final (i, row) in _rows.indexed) _rowView(context, i, row, wide),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('paiement-ajouter'),
            onPressed: _rows.length < maxPaymentRows ? _addRow : null,
            icon: const Icon(Icons.add),
            label: const Text('Ajouter un moyen'),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(_error!, key: const ValueKey('paiement-erreur'), style: const TextStyle(color: Colors.red)),
          ),
      ],
    );
    final cancel = TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler'));
    final validate = FilledButton(onPressed: _validate, child: const Text('Valider la vente'));
    if (widget.fullScreen) {
      return Scaffold(
        appBar: AppBar(title: title, automaticallyImplyLeading: false),
        body: SingleChildScrollView(padding: const EdgeInsets.all(12), child: content),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                Expanded(child: cancel),
                const SizedBox(width: 8),
                Expanded(flex: 2, child: SizedBox(height: 52, child: validate)),
              ],
            ),
          ),
        ),
      );
    }
    return AlertDialog(
      title: title,
      insetPadding: EdgeInsets.symmetric(horizontal: wide ? 40 : 12, vertical: 24),
      content: SizedBox(width: wide ? 760 : 420, child: SingleChildScrollView(child: content)),
      actions: [cancel, validate],
    );
  }
}
