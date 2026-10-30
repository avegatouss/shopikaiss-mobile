import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

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
    await _file.parent.create(recursive: true);
    await _file.writeAsString(
      jsonEncode({'url': printer.url, 'name': printer.name}),
      flush: true,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Imprimante de caisse : ${printer.name}')),
      );
    }
  }

  static Future<String> printLines(List<String> lines) async {
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
    final fontFile = File(
      '${Platform.environment['WINDIR'] ?? 'C:/Windows'}/Fonts/segoeui.ttf',
    );
    final font = pw.Font.ttf(
      ByteData.sublistView(await fontFile.readAsBytes()),
    );
    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat(
          80 * PdfPageFormat.mm,
          297 * PdfPageFormat.mm,
          marginAll: 4 * PdfPageFormat.mm,
        ),
        theme: pw.ThemeData.withFont(base: font),
        build: (_) => [
          for (final line in lines)
            pw.Text(line, style: const pw.TextStyle(fontSize: 9)),
        ],
      ),
    );
    final bytes = await doc.save();
    final sent = await Printing.directPrintPdf(
      printer: matching.first,
      onLayout: (_) async => bytes,
      name: 'Shopikaiss - ticket',
      format: PdfPageFormat(80 * PdfPageFormat.mm, 297 * PdfPageFormat.mm),
      dynamicLayout: false,
    );
    return sent
        ? 'Ticket transmis au pilote. Vérifiez la sortie papier.'
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
