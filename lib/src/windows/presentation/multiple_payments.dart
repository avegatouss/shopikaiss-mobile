import 'dart:async';

import 'package:flutter/material.dart';

import '../ipc/protocol.dart';
import 'register_controller.dart';
import 'discount_approval.dart';

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
  bool get editable => c.ready && c.uncertainOperation == null;
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
      scrollable: true,
      title: const Text('Paiements et références'),
      content: SizedBox(
        width: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'À payer : ${c.view['total_label'] ?? '—'}',
              style: const TextStyle(fontSize: 24),
            ),
            const Text(
              'Un seul paiement : montant vide = total exact. Plusieurs paiements : indiquez chaque montant. Validation automatique, sans encaissement automatique.',
            ),
            for (final row in rows)
              Card(
                key: ObjectKey(row),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      DropdownButtonFormField<String>(
                        initialValue: row.method,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Moyen de paiement',
                        ),
                        items: [
                          for (final method in c.paymentMethods)
                            DropdownMenuItem(
                              value: method['code'] as String,
                              child: Text(method['name'] as String),
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
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        initialValue: row.amount,
                        enabled: editable,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Montant affecté (F CFA)',
                        ),
                        onChanged: (value) {
                          row.amount = value;
                          changed();
                        },
                      ),
                      if (c.paymentMethods.any(
                        (m) => m['code'] == row.method && m['cash'] == true,
                      ))
                        TextFormField(
                          key: ValueKey('${row.method}-received'),
                          initialValue: row.received,
                          enabled: editable,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText:
                                'Espèces reçues (vide = montant exact arrondi)',
                          ),
                          onChanged: (value) {
                            row.received = value;
                            changed();
                          },
                        )
                      else if (row.method != null)
                        TextFormField(
                          key: ValueKey('${row.method}-reference'),
                          initialValue: row.reference,
                          enabled: editable,
                          maxLength: 100,
                          decoration: InputDecoration(
                            labelText:
                                c.paymentMethods.any(
                                  (m) =>
                                      m['code'] == row.method &&
                                      m['reference'] == 'obligatoire',
                                )
                                ? 'Référence obligatoire'
                                : 'Référence du paiement',
                          ),
                          onChanged: (value) {
                            row.reference = value;
                            changed();
                          },
                        ),
                      TextButton.icon(
                        onPressed: editable
                            ? () {
                                rows.remove(row);
                                changed();
                              }
                            : null,
                        icon: const Icon(Icons.remove_circle_outline),
                        label: const Text('Retirer ce paiement'),
                      ),
                    ],
                  ),
                ),
              ),
            TextButton.icon(
              onPressed: editable && rows.length < 10
                  ? () {
                      rows.add(_PaymentRow());
                      changed();
                    }
                  : null,
              icon: const Icon(Icons.add),
              label: const Text('Ajouter un paiement'),
            ),
            if (accepted) ...[
              for (final payment
                  in (c.view['payments'] as List? ?? const []).whereType<Map>())
                Text(
                  '${payment['name'] ?? payment['method']} : ${payment['amount_label'] ?? '—'}${payment['reference'] == null ? '' : ' · ${payment['reference']}'}',
                ),
            ],
            if (accepted && c.view['payment'] is Map) ...[
              Text(
                'Total saisi : ${(c.view['payment'] as Map)['paid_label'] ?? '—'}',
              ),
              Text(
                'Reste : ${(c.view['payment'] as Map)['remaining_label'] ?? '—'}',
              ),
              if ((c.view['payment'] as Map)['change_label'] != null)
                Text('Monnaie : ${(c.view['payment'] as Map)['change_label']}'),
              if ((c.view['payment'] as Map)['rounding_label'] != null)
                Text(
                  'Arrondi espèces : ${(c.view['payment'] as Map)['rounding_label']}',
                ),
            ],
            if (c.message != null) Text(c.message!),
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
