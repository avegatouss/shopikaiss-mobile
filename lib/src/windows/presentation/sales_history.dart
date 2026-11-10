import 'package:flutter/material.dart';

import 'cash_documents.dart';

import '../ipc/protocol.dart';
import '../platform/receipt_printing.dart';

/// Ticket original d'une vente enregistrée ; rend le message à afficher. Vérifie l'imprimante avant de demander l'original
/// au moteur, qui en consigne l'émission : une imprimante absente laisse l'original disponible dans l'historique.
Future<String> printOriginalTicket(WindowsHost host, String operation) async {
  final unavailable = await ReceiptPrinting.unavailableReason();
  if (unavailable != null) return unavailable;
  final result = await host.call(
    HostCommand.printTicket,
    operationId: operation,
    arguments: {'operation_id': operation},
  );
  final lines = result['lines'];
  if (result['operation_id'] != operation ||
      lines is! List ||
      lines.any((v) => v is! String)) {
    throw const FormatException();
  }
  return ReceiptPrinting.printLines(
    lines.cast<String>(),
    compact: result['compact'] == true,
  );
}

/// Read-only access to persisted sales; never retries or submits a payment.
class SalesHistoryDialog extends StatefulWidget {
  const SalesHistoryDialog({
    super.key,
    required this.host,
    this.printReceipt = ReceiptPrinting.printLines,
  });
  final WindowsHost host;
  final Future<String> Function(List<String> lines, {bool compact})
  printReceipt;

  @override
  State<SalesHistoryDialog> createState() => _SalesHistoryDialogState();
}

class _SalesHistoryDialogState extends State<SalesHistoryDialog> {
  bool _busy = true;
  String? _error;
  String? _printMessage;
  List<Map<String, dynamic>> _sales = [];
  List<String>? _ticket;
  bool _compact = false;

  Future<void> _printOriginal(String operation) async {
    setState(() {
      _busy = true;
      _error = null;
      _printMessage = null;
    });
    try {
      final message = await printOriginalTicket(widget.host, operation);
      if (mounted) {
        setState(() => _printMessage = message);
      }
    } catch (_) {
      if (mounted) _error = 'Impression à vérifier. La vente est conservée ; aucun renvoi automatique.';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load([String? operation]) async {
    setState(() {
      _busy = true;
      _error = null;
      _printMessage = null;
    });
    try {
      final result = await widget.host.call(
        operation == null ? HostCommand.history : HostCommand.reprint,
        arguments: operation == null
            ? {'limit': 200}
            : {'operation_id': operation},
      );
      if (!mounted) return;
      if (operation == null) {
        final items = result['items'];
        if (items is! List) throw const FormatException();
        _sales = items.whereType<Map<String, dynamic>>().toList();
        _ticket = null;
      } else {
        final lines = result['lines'];
        if (result['operation_id'] != operation ||
            lines is! List ||
            lines.any((line) => line is! String)) {
          throw const FormatException();
        }
        _ticket = lines.cast<String>();
        _compact = result['compact'] == true;
      }
    } on HostFailure catch (error) {
      if (mounted) _error = error.message;
    } catch (_) {
      if (mounted) {
        _error = 'Consultation indisponible. Aucune vente n’a été renvoyée.';
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _status(Map<String, dynamic> sale) {
    final status = sale['server_status'] ?? sale['status'];
    return switch (status) {
      'integree' => 'Intégrée au serveur',
      'a_arbitrer' => 'À arbitrer',
      'ecartee' => 'Écartée',
      'rejetee' => 'Rejetée',
      'transmise' => 'Transmise',
      _ => 'État : ${status ?? "à vérifier"}',
    };
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(_ticket == null ? 'Ventes de ce poste' : 'Duplicata du ticket'),
    content: SizedBox(
      width: 620,
      height: 420,
      child: Column(
        children: [
          if (_printMessage != null)
            Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(_printMessage!),
              ),
            ),
          Expanded(
            child: _busy
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(child: Text(_error!))
                : _ticket != null
                ? SingleChildScrollView(
                    child: SelectableText(
                      _ticket!.join('\n'),
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  )
                : _sales.isEmpty
                ? const Center(
                    child: Text('Aucune vente enregistrée sur ce poste.'),
                  )
                : ListView.builder(
                    itemCount: _sales.length,
                    itemBuilder: (context, index) {
                      final sale = _sales[index];
                      final id = sale['operation_id'];
                      return ListTile(
                        title: Text(
                          '${sale['server_number'] ?? sale['number'] ?? "Vente"} · ${sale['total_label'] ?? ""}',
                        ),
                        subtitle: Text(
                          '${sale['date'] ?? ""}\n${_status(sale)}',
                        ),
                        isThreeLine: true,
                        trailing: IconButton(
                          tooltip: 'Imprimer le reçu',
                          icon: const Icon(Icons.print_outlined),
                          onPressed: id is String && !_busy
                              ? () => _printOriginal(id)
                              : null,
                        ),
                        onTap: id is String ? () => _load(id) : null,
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy
            ? null
            : () => showDialog<void>(
                context: context,
                builder: (_) => CashDocumentsDialog(host: widget.host),
              ),
        child: const Text('Bons de retour / Z'),
      ),
      if (_ticket != null)
        TextButton.icon(
          icon: const Icon(Icons.print_outlined),
          onPressed: _busy
              ? null
              : () async {
                  setState(() {
                    _busy = true;
                    _printMessage = null;
                  });
                  String message;
                  try {
                    message = await widget.printReceipt(
                      _ticket!,
                      compact: _compact,
                    );
                  } catch (_) {
                    message = 'Impression à vérifier. Aucun renvoi automatique ; vente conservée.';
                  }
                  if (mounted && context.mounted) {
                    setState(() {
                      _busy = false;
                      _printMessage = message;
                    });
                  }
                },
          label: const Text('Imprimer le duplicata'),
        ),
      TextButton(
        onPressed: _busy ? null : () => _load(),
        child: Text(_ticket == null ? 'Actualiser' : 'Retour aux ventes'),
      ),
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Fermer'),
      ),
    ],
  );
}
