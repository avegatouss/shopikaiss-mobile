import 'dart:convert';
import 'dart:io';

import '../platform/closure_edition_journal.dart';
import '../platform/restaurant_intent.dart';

import 'package:flutter/material.dart';

import '../ipc/protocol.dart';
import '../platform/receipt_printing.dart';

class CashDocumentsDialog extends StatefulWidget {
  const CashDocumentsDialog({
    super.key,
    required this.host,
    this.originalZ = false,
    this.editionFile,
    this.restaurantIntent,
  });
  final WindowsHost host;
  final bool originalZ;
  final File? editionFile;
  final RestaurantIntent? restaurantIntent;
  @override
  State<CashDocumentsDialog> createState() => _CashDocumentsState();
}

class _CashDocumentsState extends State<CashDocumentsDialog> {
  List<Map> documents = [];
  bool busy = true;
  String? message;
  late final editions = ClosureEditionJournal(
    widget.host,
    file: widget.editionFile,
  );
  String closureKind = 'pre-x';
  String closureVersion = 'detailed';
  bool originalRequested = false;

  Future<void> printClosure() async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await widget.restaurantIntent?.requireResolved();
      await editions.load();
      if (editions.pending != null) {
        throw StateError(
          "Édition précédente à vérifier avant une nouvelle impression.",
        );
      }
      final unavailable = await ReceiptPrinting.unavailableReason();
      if (unavailable != null) {
        message = unavailable;
      } else {
        final result = await widget.host.call(
          HostCommand.cashClosureDocument,
          arguments: {
            'kind': closureKind,
            'version': closureVersion,
            'paper_width': await ReceiptPrinting.paperWidth(),
            'duplicate':
                closureKind == 'z-session' &&
                !(widget.originalZ &&
                    !originalRequested &&
                    closureKind == 'z-session'),
          },
        );
        final editionId = result['edition_id'] as String?;
        if (editionId != null) await editions.begin(editionId);
        if (closureKind == 'z-session') originalRequested = true;
        message = await ReceiptPrinting.printLines(
          (result['lines'] as List).cast<String>(),
          escposBytes: base64Decode(result['escpos_base64'] as String),
          onTransmitted: editionId == null ? null : editions.confirm,
        );
      }
    } catch (e) {
      message = e is HostFailure
          ? e.message
          : 'Impression à vérifier. Aucune session clôturée par cette action.';
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> resolveEdition(bool transmitted) async {
    setState(() => busy = true);
    try {
      if (transmitted) {
        await editions.confirm();
      } else {
        await editions.discard();
      }
      message = 'Vérification enregistrée. Aucun ticket renvoyé.';
    } catch (e) {
      message = e is HostFailure
          ? e.message
          : 'Confirmation à reprendre, sans réimpression.';
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  void initState() {
    super.initState();
    if (widget.originalZ) closureKind = 'z-session';
    load();
  }

  Future<void> load() async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await editions.load();
      final result = await widget.host.call(HostCommand.cashDocuments);
      documents = (result['items'] as List).cast<Map>();
    } catch (e) {
      message = e is HostFailure
          ? e.message
          : 'Documents indisponibles. Aucune opération renvoyée.';
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
    title: const Text('Documents de caisse'),
    content: SizedBox(
      width: 620,
      height: 400,
      child: Column(
        children: [
          if (busy) const LinearProgressIndicator(),
          if (message != null) Text(message!),
          if (editions.pending != null)
            Wrap(
              spacing: 8,
              children: [
                const Text(
                  'Édition précédente : vérifier le papier et la file Windows.',
                ),
                TextButton(
                  onPressed: busy ? null : () => resolveEdition(true),
                  child: const Text('Confirmer la transmission'),
                ),
                if (editions.pending?['state'] == 'prepared')
                  TextButton(
                    onPressed: busy ? null : () => resolveEdition(false),
                    child: const Text('Confirmer aucun envoi'),
                  ),
              ],
            ),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: closureKind,
                  decoration: const InputDecoration(
                    labelText: 'Document local',
                  ),
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(
                      value: 'pre-x',
                      child: Text('Pré-X de la session'),
                    ),
                    const DropdownMenuItem(
                      value: 'pre-z',
                      child: Text('Pré-Z de la journée'),
                    ),
                    DropdownMenuItem(
                      value: 'z-session',
                      child: Text(
                        widget.originalZ && !originalRequested
                            ? 'Z original de la clôture'
                            : 'Dernier Z (duplicata)',
                      ),
                    ),
                  ],
                  onChanged: busy
                      ? null
                      : (value) => setState(() => closureKind = value!),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: closureVersion,
                  decoration: const InputDecoration(labelText: 'Présentation'),
                  items: const [
                    DropdownMenuItem(
                      value: 'detailed',
                      child: Text('Détaillé'),
                    ),
                    DropdownMenuItem(value: 'short', child: Text('Court')),
                  ],
                  onChanged: busy
                      ? null
                      : (value) => setState(() => closureVersion = value!),
                ),
              ),
              IconButton(
                tooltip: 'Imprimer le document local',
                onPressed: busy ? null : printClosure,
                icon: const Icon(Icons.print),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Pré-X / pré-Z : documents provisoires. La journée regroupe les sessions reçues et les données locales ; les sessions non synchronisées peuvent manquer. Imprimer ne clôture pas la caisse.',
              style: TextStyle(fontSize: 12),
            ),
          ),
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
