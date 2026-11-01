import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../ipc/protocol.dart';
import 'register_controller.dart';
import 'payment_message.dart';
import 'cash_documents.dart';

/// Persists an immutable request before a financial mutation. Retry uses the
/// same operation id and payload, including after an application restart.
class CashOperationsDialog extends StatefulWidget {
  const CashOperationsDialog({
    super.key,
    required this.controller,
    this.returns = false,
  });
  final WindowsRegisterController controller;
  final bool returns;
  @override
  State<CashOperationsDialog> createState() => _CashOperationsState();
}

class _CashOperationsState extends State<CashOperationsDialog> {
  WindowsRegisterController get c => widget.controller;
  final cash = TextEditingController();
  final reason = TextEditingController();
  final amounts = <String, TextEditingController>{};
  final justifications = <String, TextEditingController>{};
  List<Map<String, dynamic>> methods = [], sales = [], lines = [];
  String? sale, preview, message;
  Map<String, dynamic>? pending;
  bool busy = true, done = false, broken = false;
  File? get file => c.journal == null
      ? null
      : File(
          '${c.journal!.file.parent.path}/${widget.returns ? 'pending-return' : 'pending-close'}-v2.json',
        );
  String get capability => widget.returns ? 'returns' : 'close_session';
  bool get allowed => (c.capabilities[capability] as Map?)?['allowed'] == true;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      if (file != null && await file!.exists()) {
        broken = true;
        final decoded = jsonDecode(await file!.readAsString());
        if (decoded is! Map<String, dynamic> ||
            decoded['command'] !=
                (widget.returns ? 'commitReturn' : 'closeSession') ||
            decoded['arguments'] is! Map ||
            decoded['operation_id'] is! String) {
          broken = true;
          throw const FormatException();
        }
        pending = decoded;
        broken = false;
        message = 'Opération interrompue à vérifier. La reprise conserve le même identifiant et les mêmes valeurs.';
        return;
      }
      if (widget.returns) {
        final data = await c.host.call(
          HostCommand.history,
          arguments: {'limit': 200},
        );
        sales = (data['items'] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .toList();
      } else {
        final data = await c.host.call(HostCommand.preparePayment);
        methods = (data['methods'] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .where((m) => m['cash'] != true)
            .toList();
        for (final m in methods) {
          amounts[m['code'] as String] = TextEditingController();
          justifications[m['code'] as String] = TextEditingController();
        }
      }
    } catch (e) {
      message = e is HostFailure ? e.message : 'Lecture impossible. Fermez puis réessayez ; ne supprimez pas les données.';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> chooseSale(String id) async {
    setState(() {
      busy = true;
      message = null;
      preview = null;
      sale = id;
    });
    try {
      final data = await c.host.call(
        HostCommand.returnableSale,
        arguments: {'sale_id': id},
      );
      for (final t in amounts.values) {
        t.dispose();
      }
      amounts.clear();
      lines = (data['lines'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();
      for (final line in lines) {
        amounts[line['line_id'] as String] = TextEditingController(text: '0');
      }
    } catch (e) {
      lines = [];
      message = e is HostFailure ? e.message : 'Vente indisponible.';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Map<String, dynamic> returnArgs() => {
    'sale_id': sale,
    'reason': reason.text.trim(),
    'lines': [
      for (final line in lines)
        if (!RegExp(r'^0([.,]0+)?$')
            .hasMatch(amounts[line['line_id']]!.text.trim()))
          {
            'line_id': line['line_id'],
            'quantity': amounts[line['line_id']]!.text.trim(),
          },
    ],
  };
  Future<void> estimate() async {
    setState(() {
      busy = true;
      message = null;
      preview = null;
    });
    try {
      final data = await c.host.call(
        HostCommand.previewReturn,
        arguments: returnArgs(),
      );
      preview = data['amount_label'] as String?;
    } catch (e) {
      message = e is HostFailure ? e.message : 'Vérification impossible.';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  int count(String value) {
    if (!RegExp(r'^\d+$').hasMatch(value.trim())) throw const FormatException();
    return int.parse(value.trim());
  }

  Future<void> submit() async {
    if (busy || broken || (!allowed && pending == null)) return;
    final recovering = pending != null;
    if (pending == null) {
      Map<String, dynamic> args;
      try {
        if (widget.returns) {
          if (preview == null || reason.text.trim().isEmpty) {
            throw const FormatException();
          }
          args = returnArgs();
        } else {
          if (c.lines.isNotEmpty) {
            setState(
              () => message =
                  'Terminez ou mettez le panier en attente avant de clôturer.',
            );
            return;
          }
          args = {
            'cash': count(cash.text),
            'comment': reason.text.trim(),
            'counts': [
              for (final m in methods)
                {
                  'method': m['code'],
                  'amount': count(amounts[m['code']]!.text),
                  'justification': justifications[m['code']]!.text.trim(),
                },
            ],
          };
        }
      } catch (_) {
        setState(
          () => message = widget.returns
              ? 'Vérifiez les quantités et renseignez le motif.'
              : 'Renseignez chaque montant compté en francs entiers, y compris 0.',
        );
        return;
      }
      final yes = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            widget.returns ? 'Confirmer le retour ?' : 'Confirmer la clôture ?',
          ),
          content: Text(
            widget.returns ? 'Remboursement en espèces : $preview' : 'Les montants saisis sont votre comptage définitif. Le rapport Z sera fourni par le serveur.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Corriger'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirmer'),
            ),
          ],
        ),
      );
      if (!mounted || yes != true) return;
      pending = {
        'command': widget.returns ? 'commitReturn' : 'closeSession',
        'operation_id': const Uuid().v4(),
        'arguments': args,
      };
      try {
        if (file != null) {
          await file!.parent.create(recursive: true);
          await file!.writeAsString(jsonEncode(pending), flush: true);
        }
      } catch (_) {
        pending = null;
        setState(() {
          broken = true;
          message = 'Écriture de secours impossible. Aucune opération envoyée.';
        });
        return;
      }
    }
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final result = await c.host.call(
        widget.returns ? HostCommand.commitReturn : HostCommand.closeSession,
        arguments: Map<String, dynamic>.from(pending!['arguments'] as Map),
        operationId: pending!['operation_id'] as String,
      );
      if (widget.returns
          ? result['operation_id'] != pending!['operation_id']
          : result['session_open'] != false) {
        throw const HostFailure(
          'unknown',
          'Résultat à vérifier avec la même opération.',
          outcomeUnknown: true,
        );
      }
      if (file != null && await file!.exists()) await file!.delete();
      pending = null;
      done = true;
      message = widget.returns
          ? 'Retour enregistré : ${result['amount_label'] ?? preview ?? ''}. Ne remboursez qu’une fois.'
          : 'Clôture enregistrée localement. Le rapport Z sera disponible après synchronisation.';
      await c.refresh();
    } on HostFailure catch (e) {
      message = e.message;
      if (!recovering &&
          !e.outcomeUnknown &&
          e.code != 'host_unavailable' &&
          e.code != 'timeout') {
        try {
          if (file != null && await file!.exists()) await file!.delete();
          pending = null;
        } catch (_) {
          message = 'Journal à vérifier avant de recommencer.';
        }
      }
    } catch (_) {
      message = 'Résultat inconnu. Reprenez la même opération pour vérifier, sans refaire le remboursement.';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    cash.dispose();
    reason.dispose();
    for (final t in [...amounts.values, ...justifications.values]) {
      t.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      scrollable: true,
      title: Text(widget.returns ? 'Retour en espèces' : 'Clôturer ma session'),
      content: SizedBox(
        width: 540,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (busy) const LinearProgressIndicator(),
            PaymentMessage(message: message),
            if (!allowed && pending == null)
              Text(
                (c.capabilities[capability] as Map?)?['reason'] as String? ??
                    'Fonction indisponible.',
              ),
            if (!done && pending == null) ...[
              if (widget.returns) ...[
                const Text(
                  'Ventes connues de ce poste uniquement. Le moteur contrôle les quantités et les règles de retour.',
                ),
                DropdownButtonFormField<String>(
                  initialValue: sale,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Vente à retourner',
                  ),
                  items: [
                    for (final s in sales)
                      DropdownMenuItem(
                        value: s['operation_id'] as String,
                        child: Text(
                          '${s['server_number'] ?? s['number']} · ${s['total_label']}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: busy || !allowed
                      ? null
                      : (v) {
                          if (v != null) chooseSale(v);
                        },
                ),
                for (final line in lines)
                  TextField(
                    controller: amounts[line['line_id']],
                    enabled: !busy && allowed,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: line['label'] as String?,
                      helperText:
                          'Restant retournable : ${line['remaining']} · quantité en unité de base',
                    ),
                    onChanged: (_) => setState(() => preview = null),
                  ),
                TextButton(
                  onPressed: busy || !allowed || lines.isEmpty
                      ? null
                      : estimate,
                  child: const Text('Calculer le remboursement'),
                ),
                if (preview != null) Text('À rembourser : $preview'),
              ] else ...[
                const Text(
                  'Saisissez uniquement les montants réellement comptés. Les montants attendus ne sont pas affichés.',
                ),
                TextField(
                  controller: cash,
                  enabled: !busy && allowed,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Espèces comptées (F CFA)',
                  ),
                ),
                for (final m in methods) ...[
                  TextField(
                    controller: amounts[m['code']],
                    enabled: !busy && allowed,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: '${m['name']} : montant compté (F CFA)',
                    ),
                  ),
                  TextField(
                    controller: justifications[m['code']],
                    enabled: !busy && allowed,
                    maxLength: 500,
                    decoration: InputDecoration(
                      labelText: 'Justification ${m['name']} (si nécessaire)',
                    ),
                  ),
                ],
              ],
              TextField(
                controller: reason,
                enabled: !busy && allowed,
                maxLength: 500,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: widget.returns
                      ? 'Motif obligatoire'
                      : 'Commentaire',
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (done)
          TextButton.icon(
            onPressed: busy ? null : () => showDialog<void>(context: context, builder: (_) => CashDocumentsDialog(host: c.host)),
            icon: const Icon(Icons.print),
            label: Text(widget.returns ? 'Imprimer le bon de retour' : 'Consulter / imprimer le Z'),
          ),
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('Fermer'),
        ),
        if (!done)
          FilledButton(
            onPressed: busy || broken || (!allowed && pending == null)
                ? null
                : submit,
            child: Text(
              pending != null
                  ? 'Vérifier / reprendre la même opération'
                  : widget.returns
                  ? 'Enregistrer le retour'
                  : 'Clôturer la session',
            ),
          ),
      ],
    ),
  );
}
