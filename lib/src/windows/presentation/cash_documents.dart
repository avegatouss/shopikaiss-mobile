import 'package:flutter/material.dart';

import '../ipc/protocol.dart';
import '../platform/receipt_printing.dart';

class CashDocumentsDialog extends StatefulWidget {
  const CashDocumentsDialog({super.key, required this.host});
  final WindowsHost host;
  @override
  State<CashDocumentsDialog> createState() => _CashDocumentsState();
}

class _CashDocumentsState extends State<CashDocumentsDialog> {
  List<Map> documents = [];
  bool busy = true;
  String? message;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final result = await widget.host.call(HostCommand.cashDocuments);
      documents = (result['items'] as List).cast<Map>();
    } catch (_) {
      message = 'Documents indisponibles. Aucune opération renvoyée.';
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> printDocument(String id) async {
    setState(() => busy = true);
    try {
      final unavailable = await ReceiptPrinting.unavailableReason();
      if (unavailable != null) {
        message = unavailable;
      } else {
        final result = await widget.host.call(
          HostCommand.cashDocument,
          arguments: {'operation_id': id},
        );
        if (result['operation_id'] != id) throw const FormatException();
        message = await ReceiptPrinting.printLines(
          (result['lines'] as List).cast<String>(),
        );
      }
    } catch (e) {
      message = e is HostFailure
          ? e.message
          : 'Impression à vérifier. Aucune opération financière rejouée.';
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Bons de retour et rapports Z'),
    content: SizedBox(
      width: 620,
      height: 400,
      child: Column(
        children: [
          if (busy) const LinearProgressIndicator(),
          if (message != null) Text(message!),
          Expanded(
            child: documents.isEmpty
                ? const Center(child: Text('Aucun document sur ce poste.'))
                : ListView(
                    children: [
                      for (final d in documents)
                        ListTile(
                          title: Text('${d['title']} · ${d['date']}'),
                          subtitle: Text(
                            d['available'] == true
                                ? '${d['status']}'
                                : 'Z en attente de synchronisation',
                          ),
                          trailing: IconButton(
                            tooltip: 'Imprimer',
                            icon: const Icon(Icons.print),
                            onPressed: busy || d['available'] != true
                                ? null
                                : () => printDocument(
                                    d['operation_id'] as String,
                                  ),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : load,
        child: const Text('Actualiser'),
      ),
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('Fermer'),
      ),
    ],
  );
}
