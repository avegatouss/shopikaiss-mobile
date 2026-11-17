import 'dart:async';

import 'package:flutter/material.dart';

import '../ipc/protocol.dart';
import 'register_controller.dart';
import 'discount_approval.dart';
import 'payment_message.dart';

class MultiplePayments extends StatefulWidget {
  const MultiplePayments({super.key, required this.controller});
  final WindowsRegisterController controller;
  @override
  State<MultiplePayments> createState() => _MultiplePaymentsState();
}

class _PaymentRow {
  String? method;
  String amount = '';
  String received = '';
  String reference = '';
}

class _MultiplePaymentsState extends State<MultiplePayments> {
  WindowsRegisterController get c => widget.controller;
  final rows = <_PaymentRow>[_PaymentRow()];
  Timer? timer;
  int revision = 0;
  bool accepted = false;
  int? get remaining {
    final total = c.paymentPayable;
    if (total == null) return null;
    var allocated = 0;
    for (final row in rows) {
      final amount = int.tryParse(row.amount.trim());
      if (amount == null || amount < 0) return null;
      allocated += amount;
    }
    return total - allocated;
  }

  @override
  void initState() {
    super.initState();
    rows.first.amount = c.paymentPayable?.toString() ?? '';
  }

  bool get editable => c.ready && c.uncertainOperation == null;
  Widget paymentRow(BuildContext context, _PaymentRow row) {
    final cash = c.paymentMethods.any(
      (m) => m['code'] == row.method && m['cash'] == true,
    );
    final requiredReference = c.paymentMethods.any(
      (m) => m['code'] == row.method && m['reference'] == 'obligatoire',
    );
    final method = DropdownButtonFormField<String>(
      initialValue: row.method,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Moyen de paiement'),
      items: [
        for (final m in c.paymentMethods)
          DropdownMenuItem(
            value: m['code'] as String,
            child: Text(m['name'] as String, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: editable
          ? (value) {
              row.method = value;
              row.received = '';
              row.reference = '';
              changed();
            }
          : null,
    );
    final amount = TextFormField(
      initialValue: row.amount,
      enabled: editable,
      keyboardType: TextInputType.number,
      decoration: const InputDecoration(labelText: 'Montant (F CFA)'),
      onChanged: (value) {
        row.amount = value;
        changed();
      },
    );
    final details = cash
        ? TextFormField(
            key: ValueKey('${row.method}-received'),
            initialValue: row.received,
            enabled: editable,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Espèces reçues',
              hintText: 'Vide = montant exact arrondi',
            ),
            onChanged: (value) {
              row.received = value;
              changed();
            },
          )
        : TextFormField(
            key: ValueKey('${row.method}-reference'),
            initialValue: row.reference,
            enabled: editable && row.method != null,
            maxLength: 100,
            decoration: InputDecoration(
              labelText: requiredReference
                  ? 'Référence obligatoire'
                  : 'Référence (facultative)',
              counterText: '',
            ),
            onChanged: (value) {
              row.reference = value;
              changed();
            },
          );
    final remove = IconButton(
      tooltip: 'Retirer ce paiement',
      icon: const Icon(Icons.delete_outline),
      onPressed: editable
          ? () {
              rows.remove(row);
              changed();
            }
          : null,
    );
    // A full row on desktop; two compact rows only on narrow windows.
    final wide = MediaQuery.sizeOf(context).width >= 850;
    return Card(
      key: ObjectKey(row),
      margin: const EdgeInsets.symmetric(vertical: 5),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: wide
            ? Row(
                children: [
                  Expanded(flex: 3, child: method),
                  const SizedBox(width: 12),
                  Expanded(flex: 2, child: amount),
                  const SizedBox(width: 12),
                  Expanded(flex: 3, child: details),
                  const SizedBox(width: 8),
                  remove,
                ],
              )
            : Column(
                children: [
                  Row(
                    children: [
                      Expanded(child: method),
                      const SizedBox(width: 12),
                      Expanded(child: amount),
                      remove,
                    ],
                  ),
                  const SizedBox(height: 12),
                  details,
                ],
              ),
      ),
    );
  }

  void changed() {
    ++revision;
    setState(() => accepted = false);
    timer?.cancel();
    timer = Timer(const Duration(milliseconds: 250), validate);
  }

  Future<void> validate() async {
    timer?.cancel();
    if (!mounted || !editable) return;
    if (c.busy) {
      timer = Timer(const Duration(milliseconds: 100), validate);
      return;
    }
    final current = revision;
    await c.command(HostCommand.setPayments, {
      'payments': [
        for (final row in rows)
          {
            'method': row.method ?? '',
            if (row.amount.trim().isNotEmpty || rows.length > 1)
              'amount': int.tryParse(row.amount.trim()) ?? row.amount.trim(),
            if (row.received.trim().isNotEmpty)
              'received':
                  int.tryParse(row.received.trim()) ?? row.received.trim(),
            if (row.reference.trim().isNotEmpty)
              'reference': row.reference.trim(),
          },
      ],
    });
    if (mounted && current == revision) {
      setState(
        () => accepted = c.message == null && c.view['payment_valid'] == true,
      );
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) => AlertDialog(
      scrollable: false,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Répartir le paiement'),
          Text(
            'À payer : ${c.view['total_label'] ?? '—'}',
            style: const TextStyle(fontSize: 22),
          ),
          if (remaining != null)
            Text(
              'Reste à répartir : $remaining F CFA',
              style: const TextStyle(fontSize: 16),
            ),
          PaymentMessage(message: c.message),
        ],
      ),
      content: SizedBox(
        width: 920,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Saisissez la part du premier moyen, puis ajoutez un moyen pour le solde. Les montants sont vérifiés automatiquement avant confirmation.',
              ),
              for (final row in rows) paymentRow(context, row),
              TextButton.icon(
                onPressed:
                    editable &&
                        rows.length < 10 &&
                        (remaining == null || remaining! > 0)
                    ? () {
                        rows.add(
                          _PaymentRow()..amount = remaining?.toString() ?? '',
                        );
                        changed();
                      }
                    : null,
                icon: const Icon(Icons.add),
                label: const Text('Ajouter un paiement'),
              ),
              if (accepted && c.view['payment'] is Map)
                Wrap(
                  spacing: 20,
                  runSpacing: 8,
                  children: [
                    Text(
                      'Total saisi : ${(c.view['payment'] as Map)['paid_label'] ?? '—'}',
                    ),
                    Text(
                      'Reste : ${(c.view['payment'] as Map)['remaining_label'] ?? '—'}',
                    ),
                    if ((c.view['payment'] as Map)['change_label'] != null)
                      Text(
                        'Monnaie : ${(c.view['payment'] as Map)['change_label']}',
                      ),
                    if ((c.view['payment'] as Map)['rounding_label'] != null)
                      Text(
                        'Arrondi espèces : ${(c.view['payment'] as Map)['rounding_label']}',
                      ),
                  ],
                ),
              if (c.uncertainOperation != null)
                TextButton(
                  onPressed: c.busy ? null : c.reconcile,
                  child: const Text('Vérifier cette vente'),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: c.busy ? null : () => Navigator.pop(context),
          child: const Text('Retour'),
        ),
        FilledButton(
          onPressed: accepted && c.canPay && c.view['payment_valid'] == true
              ? () async {
                  if (!accepted ||
                      !c.canPay ||
                      c.view['payment_valid'] != true) {
                    return;
                  }
                  if (!await commitWithApproval(context, c)) return;
                  if (context.mounted &&
                      c.receipt != null &&
                      c.uncertainOperation == null &&
                      c.message == null) {
                    Navigator.pop(context, true);
                  }
                }
              : null,
          child: const Text('Confirmer ces paiements'),
        ),
      ],
    ),
  );
}
