import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'receipt_pdf.dart';
import 'receipt_qr.dart';
import 'receipt_logo.dart';
import 'raw_receipt_printer.dart';
import 'production_printing.dart';
import '../../restaurant/resto_engine.dart';
import '../../printer/escpos.dart';

/// App-specific printer; never changes the Windows system default.
class ReceiptPrinting {
  static int copyCount(Object? value) =>
      value is int && value >= 1 && value <= 3 ? value : 1;

  static Future<String> printSale(List<String> lines, {bool compact = false}) =>
      printLines(lines, compact: compact, useConfiguredCopies: true);
  static Future<int> paperWidth() async {
    if (!await _file.exists()) return 80;
    final settings = jsonDecode(await _file.readAsString()) as Map;
    return settings['paper_width'] == 58 ? 58 : 80;
  }

  static Future<String> printProduction(List<String> lines) async {
    // Production never falls back to PDF after an uncertain spool result.
    String name;
    try {
      if (!await _file.exists()) return 'non_envoye';
      final saved = jsonDecode(await _file.readAsString()) as Map;
      if ((saved['mode'] ?? 'raw') != 'raw') return 'non_envoye';
      final printers = await Printing.listPrinters();
      final selected = printers
          .where((p) => p.url == saved['url'] && p.isAvailable)
          .firstOrNull;
      if (selected == null) return 'non_envoye';
      name = selected.name;
    } catch (_) {
      return 'non_envoye';
    }
    return switch (await const ProductionPrinting().send(name, lines)) {
      RestoOutcome.transmis => 'transmis',
      RestoOutcome.nonEnvoye => 'non_envoye',
      _ => 'a_verifier',
    };
  }

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

  static Future<void> configure(
    BuildContext context, {
    File? settingsFile,
  }) async {
    final file = settingsFile ?? _file;
    final saved = await file.exists()
        ? jsonDecode(await file.readAsString()) as Map
        : <String, dynamic>{};
    var mode = saved['mode'] as String? ?? 'raw';
    var fallback = saved['pdf_fallback'] != false;
    var width = saved['paper_width'] == 58 ? 58 : 80;
    var copies = copyCount(saved['copies']);
    var qrEnabled = saved['qr_enabled'] != false;
    var link = saved['qr_link'] as String? ?? '';
    var logo = saved['logo_png'] as String?;
    var logoPath = '';
    String? logoError;
    if (!context.mounted) return;
    final options = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Tickets : logo, QR et impression'),
          scrollable: true,
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${saved['name'] ?? 'Aucune imprimante sélectionnée'}'),
                if (logo != null) Image.memory(base64Decode(logo!), height: 70),
                if (logo == null)
                  const Text(
                    'Aucun logo enregistré. Importez une image puis cliquez sur Enregistrer pour l’imprimer sur les reçus.',
                  ),
                TextFormField(
                  decoration: const InputDecoration(
                    labelText: 'Chemin du logo (PNG/JPG)',
                    helperText: 'Ex. C:\\Images\\logo-tbc.png — copie conservée hors connexion.',
                  ),
                  onChanged: (value) => logoPath = value,
                ),
                Wrap(
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.image_outlined),
                      label: const Text('Importer le logo'),
                      onPressed: () async {
                        try {
                          final file = File(
                            logoPath.trim().replaceAll('"', ''),
                          );
                          if (await file.length() > 2 * 1024 * 1024) {
                            throw const FormatException('Logo limité à 2 Mo.');
                          }
                          final data = normalizeReceiptLogo(
                            await file.readAsBytes(),
                          );
                          if (context.mounted) {
                            update(() {
                              logo = base64Encode(data);
                              logoError = null;
                            });
                          }
                        } catch (_) {
                          if (context.mounted) {
                            update(
                              () => logoError = 'Logo non importé. Vérifiez le chemin et une image de 2 Mo maximum (4096 pixels).',
                            );
                          }
                        }
                      },
                    ),
                    if (logo != null)
                      TextButton(
                        onPressed: () => update(() => logo = null),
                        child: const Text('Retirer le logo'),
                      ),
                  ],
                ),
                if (logoError != null)
                  Text(
                    logoError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                SwitchListTile(
                  title: const Text('QR code des informations du ticket'),
                  subtitle: const Text(
                    'Résumé lisible hors connexion : boutique, numéro, date et totaux imprimés.',
                  ),
                  value: qrEnabled,
                  onChanged: (value) => update(() => qrEnabled = value),
                ),
                TextFormField(
                  initialValue: link,
                  decoration: InputDecoration(
                    labelText: 'Lien facultatif : site ou Facebook',
                    helperText: 'Un second QR ouvre directement ce lien. Vide : aucun lien.',
                    errorText: validReceiptLink(link.trim()) ? null : 'Adresse HTTP(S) valide requise (350 octets maximum).',
                  ),
                  onChanged: (value) => update(() => link = value),
                ),
                DropdownButtonFormField<int>(
                  initialValue: copies,
                  decoration: const InputDecoration(
                    labelText: 'Exemplaires du ticket de vente',
                  ),
                  items: [
                    for (final count in [1, 2, 3])
                      DropdownMenuItem(
                        value: count,
                        child: Text('$count exemplaire${count > 1 ? 's' : ''}'),
                      ),
                  ],
                  onChanged: (value) => update(() => copies = value ?? 1),
                ),
                const Text(
                  'Appliqué aux ventes, réimpressions et tickets d’essai. Les bons cuisine et documents Z restent en un exemplaire.',
                ),
                DropdownButtonFormField<int>(
                  initialValue: width,
                  decoration: const InputDecoration(
                    labelText: 'Papier (tickets de vente après redémarrage)',
                  ),
                  items: const [
                    DropdownMenuItem(value: 58, child: Text('58 mm')),
                    DropdownMenuItem(value: 80, child: Text('80 mm')),
                  ],
                  onChanged: (v) => update(() => width = v ?? 80),
                ),
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
              onPressed: !validReceiptLink(link.trim())
                  ? null
                  : () => Navigator.pop(context, {
                      'mode': mode,
                      'pdf_fallback': fallback,
                      'paper_width': width,
                      'copies': copies,
                      'qr_enabled': qrEnabled,
                      'qr_link': link.trim(),
                      'logo_png': logo,
                    }),
              child: const Text('Enregistrer'),
            ),
          ],
        ),
      ),
    );
    if (options != null) {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({...saved, ...options}), flush: true);
    }
  }

  static Future<String> testTicket() => printLines([
    'SHOPIKAISS - TEST',
    'AUCUNE VENTE',
    'Impression et coupe du papier',
    '0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ',
    'Derniere ligne : doit rester lisible.',
  ], useConfiguredCopies: true);

  static Future<String> printLines(
    List<String> lines, {
    bool compact = false,
    Uint8List? escposBytes,
    Future<void> Function()? onTransmitted,
    bool useConfiguredCopies = false,
  }) async {
    if (lines.isEmpty || lines.length > 10000) {
      throw const FormatException('Ticket invalide');
    }
    if (!await _file.exists()) {
      return 'Choisissez une imprimante de caisse dans les réglages.';
    }
    final saved = jsonDecode(await _file.readAsString()) as Map;
    final copies = useConfiguredCopies ? copyCount(saved['copies']) : 1;
    if (useConfiguredCopies) lines = receiptSaleLines(lines);
    final logo = useConfiguredCopies && saved['logo_png'] is String
        ? base64Decode(saved['logo_png'] as String)
        : null;
    final qrCodes = useConfiguredCopies
        ? receiptQrCodes(
            lines,
            enabled: saved['qr_enabled'] != false,
            link: saved['qr_link'] as String? ?? '',
          )
        : <ReceiptQr>[];
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
      final ticket =
          escposBytes ??
          receiptBytesWithQr(
            lines,
            qrCodes,
            compact: compact,
            paperWidth: saved['paper_width'] == 58 ? 58 : 80,
          );
      final batch = BytesBuilder(copy: false);
      for (var i = 0; i < copies; i++) {
        if (useConfiguredCopies && escposBytes == null) {
          batch.add([...EscPos.init(), EscPos.esc, 0x64, 2]);
        }
        if (logo != null && escposBytes == null) {
          batch.add(
            receiptLogoRaster(logo, saved['paper_width'] == 58 ? 58 : 80),
          );
        }
        batch.add(ticket);
      }
      final outcome = await const RawReceiptPrinter().send(
        matching.first.name,
        batch.takeBytes(),
      );
      if (outcome == RawPrintOutcome.transmitted) {
        await onTransmitted?.call();
        return '$copies exemplaire(s) transmis au spouleur. Vérifiez le papier et la coupe.';
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
      paperWidth: saved['paper_width'] == 58 ? 58 : 80,
      copies: copies,
      qrCodes: qrCodes,
      logoPng: logo,
    );
    final sent = await Printing.directPrintPdf(
      printer: matching.first,
      onLayout: (_) async => receipt.bytes,
      name: 'Shopikaiss - ticket',
      format: receipt.format,
      dynamicLayout: false,
    );
    if (sent) await onTransmitted?.call();
    return sent
        ? '${fallbackUsed ? 'Secours PDF : ' : ''}$copies exemplaire(s) transmis au pilote. Vérifiez la sortie papier.'
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
