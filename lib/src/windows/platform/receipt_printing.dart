import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'receipt_pdf.dart';
import 'raw_receipt_printer.dart';
import '../../offline/ticket.dart';

/// App-specific printer; never changes the Windows system default.
class ReceiptPrinting {
  static File get _file =>
      File('${Platform.environment['LOCALAPPDATA']}/ShopiKaiss/printer.json');
  static Future<void> choose(BuildContext context) async {
    final printer = await Printing.pickPrinter(
      context: context,
      title: 'Imprimante par défaut de la caisse',
    );
    if (printer == null) return;
    final previous = await _file.exists()
        ? jsonDecode(await _file.readAsString()) as Map
        : <String, dynamic>{};
    await _file.parent.create(recursive: true);
    await _file.writeAsString(
      jsonEncode({...previous, 'url': printer.url, 'name': printer.name}),
      flush: true,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Imprimante de caisse : ${printer.name}')),
      );
    }
  }

  static Future<void> configure(BuildContext context) async {
    if (!await _file.exists()) {
      if (context.mounted) await choose(context);
      if (!await _file.exists()) return;
    }
    final saved = jsonDecode(await _file.readAsString()) as Map;
    var mode = saved['mode'] as String? ?? 'raw';
    var fallback = saved['pdf_fallback'] != false;
    if (!context.mounted) return;
    final options = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Mode d’impression du poste'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${saved['name']}'),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: mode,
                  items: const [
                    DropdownMenuItem(
                      value: 'raw',
                      child: Text('Caisse : ESC/POS brut (par défaut)'),
                    ),
                    DropdownMenuItem(
                      value: 'pdf_roll',
                      child: Text('Secours : PDF rouleau par pilote'),
                    ),
                    DropdownMenuItem(
                      value: 'pdf_a4',
                      child: Text('Imprimante A4 : PDF par pilote'),
                    ),
                  ],
                  onChanged: (v) => update(() => mode = v ?? 'raw'),
                ),
                if (mode == 'raw')
                  SwitchListTile(
                    title: const Text('Secours PDF si rien n’a été envoyé'),
                    subtitle: const Text(
                      'Jamais de second envoi automatique après une réponse incertaine.',
                    ),
                    value: fallback,
                    onChanged: (v) => update(() => fallback = v),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, {
                'mode': mode,
                'pdf_fallback': fallback,
              }),
              child: const Text('Enregistrer'),
            ),
          ],
        ),
      ),
    );
    if (options != null) {
      await _file.writeAsString(
        jsonEncode({...saved, ...options}),
        flush: true,
      );
    }
  }

  static Future<String> testTicket() => printLines([
    'SHOPIKAISS - TEST',
    'AUCUNE VENTE',
    'Impression et coupe du papier',
    '0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ',
    'Derniere ligne : doit rester lisible.',
  ]);

  static Future<String> printLines(
    List<String> lines, {
    bool compact = false,
    Uint8List? escposBytes,
  }) async {
    if (lines.isEmpty || lines.length > 10000) {
      throw const FormatException('Ticket invalide');
    }
    if (!await _file.exists()) {
      return 'Choisissez une imprimante de caisse dans les réglages.';
    }
    final saved = jsonDecode(await _file.readAsString()) as Map;
    final printers = await Printing.listPrinters();
    final matching = printers.where(
      (p) => p.url == saved['url'] && p.isAvailable,
    );
    if (matching.isEmpty) {
      return 'Imprimante choisie indisponible. Aucun autre périphérique sélectionné automatiquement.';
    }
    final mode = saved['mode'] as String? ?? 'raw';
    var fallbackUsed = false;
    if (mode == 'raw') {
      final outcome = await const RawReceiptPrinter().send(
        matching.first.name,
        escposBytes ?? offlineTicketBytes(lines, compact: compact),
      );
      if (outcome == RawPrintOutcome.transmitted) {
        return 'Ticket ESC/POS transmis au spouleur. Vérifiez le papier et la coupe.';
      }
      if (!usePdfFallback(outcome, saved['pdf_fallback'] != false)) {
        return outcome == RawPrintOutcome.unknown
            ? 'Impression à vérifier : envoi peut-être effectué. Aucun secours automatique. Vérifiez le papier et la file Windows avant un duplicata.'
            : 'Impression brute non envoyée. Choisissez le secours PDF dans les réglages.';
      }
      fallbackUsed = true;
    }
    final fontFile = File(
      '${Platform.environment['WINDIR'] ?? 'C:/Windows'}/Fonts/segoeui.ttf',
    );
    final font = pw.Font.ttf(
      ByteData.sublistView(await fontFile.readAsBytes()),
    );
    final receipt = await buildReceiptPdf(
      lines,
      font: font,
      a4: mode == 'pdf_a4',
    );
    final sent = await Printing.directPrintPdf(
      printer: matching.first,
      onLayout: (_) async => receipt.bytes,
      name: 'Shopikaiss - ticket',
      format: receipt.format,
      dynamicLayout: false,
    );
    return sent
        ? '${fallbackUsed ? 'Secours PDF : ' : ''}Ticket transmis au pilote. Vérifiez la sortie papier.'
        : 'Impression annulée ou non confirmée. Vente conservée.';
  }

  /// Check before requesting an original ticket (which records its issuance).
  static Future<String?> unavailableReason() async {
    if (!await _file.exists()) {
      return 'Choisissez une imprimante de caisse dans les réglages.';
    }
    final saved = jsonDecode(await _file.readAsString()) as Map;
    final printers = await Printing.listPrinters();
    if (!printers.any((p) => p.url == saved['url'] && p.isAvailable)) {
      return 'Imprimante choisie indisponible. Aucun ticket demandé au moteur.';
    }
    return null;
  }
}
