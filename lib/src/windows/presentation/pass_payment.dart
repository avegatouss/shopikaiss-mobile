import 'dart:async';

import 'package:flutter/material.dart';

import '../ipc/protocol.dart';
import 'discount_approval.dart';
import 'pass_scan_dialog.dart';
import 'register_controller.dart';

/// Verification selects a pass for the current draft. Closing the scanner does
/// not undo that selection: this sheet always shows the authoritative draft.
class PassPaymentDialog extends StatelessWidget {
  const PassPaymentDialog({super.key, required this.controller});
  final WindowsRegisterController controller;

  Future<void> _scan(BuildContext context) async {
    final c = controller;
    await showDialog<PassScanVerdict>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PassScanDialog(
        selectsDraft: true,
        totalLabel: c.view['total_label']?.toString() ?? '—',
        manualEntryAllowed:
            (c.capabilities['pass'] as Map?)?['manual_entry'] == true,
        verify: (code) async {
          final result = await c.command(HostCommand.verifyPass, {
            'code': code,
          });
          final pass = result?['pass'] as Map?;
          return PassScanVerdict(
            allowed: pass != null,
            passId: pass?['pass_uuid'] as String?,
            holder: pass?['holder'] as String?,
            remainingToday: pass?['left_today'] as int?,
            remainingTotal: pass?['left_total'] as int?,
            verifiedOnline: pass?['online'] == true,
            reason: pass == null
                ? c.message ?? 'Vérification indisponible.'
                : null,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final c = controller;
      final passes = (c.view['passes'] as List? ?? const [])
          .whereType<Map>()
          .toList();
      final capability = c.capabilities['pass'] as Map?;
      final editable = !c.busy && c.uncertainOperation == null && c.ready;
      return PopScope(
        canPop: !c.busy,
        child: AlertDialog(
          title: Text('Pass événement · ${c.view['total_label'] ?? '—'}'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'La vente est enregistrée uniquement après validation. Après un redémarrage ou une reprise de panier, scannez à nouveau les passes.',
                  ),
                  const SizedBox(height: 16),
                  if (c.message != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        c.message!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (c.busy) const LinearProgressIndicator(),
                  for (final pass in passes)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.confirmation_number_outlined),
                        title: Text(
                          pass['holder']?.toString() ?? 'Porteur du pass',
                        ),
                        subtitle: Text(
                          'Restant aujourd’hui : ${pass['left_today'] ?? '—'} · Total : ${pass['left_total'] ?? '—'}\n${pass['online'] == true ? 'Vérifié en ligne' : 'Vérifié hors connexion'}',
                        ),
                        trailing: IconButton(
                          tooltip: 'Retirer ce pass',
                          onPressed: editable
                              ? () => c.command(HostCommand.removePass, {
                                  'pass_uuid': pass['pass_uuid'],
                                })
                              : null,
                          icon: const Icon(Icons.close),
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed:
                        editable &&
                            capability?['allowed'] == true &&
                            (passes.isEmpty ||
                                capability?['several_per_sale'] == true)
                        ? () => _scan(context)
                        : null,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: Text(
                      passes.isEmpty
                          ? 'Scanner le pass'
                          : 'Ajouter un autre pass',
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: !c.busy ? () => Navigator.pop(context) : null,
              child: const Text('Retour au panier'),
            ),
            if (c.uncertainOperation != null)
              FilledButton(
                onPressed: !c.busy ? c.reconcile : null,
                child: const Text('Vérifier la vente'),
              )
            else
              FilledButton(
                onPressed: c.canPay && passes.isNotEmpty
                    ? () async {
                        if (!await commitWithApproval(context, c)) return;
                        if (context.mounted && c.lines.isEmpty) {
                          Navigator.pop(context);
                        }
                        unawaited(c.printPendingTicket());
                      }
                    : null,
                child: const Text('Valider la vente'),
              ),
          ],
        ),
      );
    },
  );
}
