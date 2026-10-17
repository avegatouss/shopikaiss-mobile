import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

import '../terminal/terminal_channel.dart';
import 'escpos.dart';

/// Document capturé par `window.print()` dans la caisse (voir `bridge_script.dart`).
class HtmlPrintJob {
  HtmlPrintJob.fromMap(Map<String, dynamic> m)
      : html = (m['html'] ?? '') as String,
        baseUrl = (m['baseUrl'] ?? '') as String,
        title = (m['title'] ?? 'ShopiKaiss') as String,
        paperWidth = (m['paperWidth'] as num?)?.toInt() ?? 0;

  final String html;
  final String baseUrl;
  final String title;

  /// Largeur du ticket déclarée par la page (`[data-paper-width]`), 0 pour un document A4.
  final int paperWidth;

  bool get isTicket => paperWidth > 0;
}

/// Impression des documents HTML de la plateforme :
/// - ticket (`[data-paper-width]`) + imprimante intégrée → rendu PDF, rastérisation à la largeur du
///   rouleau, envoi ESC/POS `GS v 0` à l'imprimante (aucune boîte de dialogue) ;
/// - sinon (factures et rapports A4, ou terminal sans imprimante) → boîte d'impression du système
///   (Android : service d'impression, « Enregistrer en PDF », imprimantes réseau).
class HtmlPrinter {
  HtmlPrinter(this.channel);

  final TerminalChannel channel;

  Future<NativeResult> print(HtmlPrintJob job, {required bool hasPrinter, required int rollWidth}) async {
    if (job.html.isEmpty) return NativeResult.failure('document_vide');
    if (job.isTicket && hasPrinter) {
      return _printTicket(job, rollWidth > 0 ? rollWidth : job.paperWidth);
    }
    // convertHtml est marqué obsolète (pas de successeur HTML dans printing) mais reste le rendu
    // natif du WebView du système, fidèle aux feuilles de style de la caisse.
    final done = await Printing.layoutPdf(
      name: job.title,
      // ignore: deprecated_member_use
      onLayout: (format) => Printing.convertHtml(format: format, html: job.html, baseUrl: job.baseUrl),
    );
    return done ? const NativeResult({'ok': true}) : NativeResult.failure('impression_annulee');
  }

  Future<NativeResult> _printTicket(HtmlPrintJob job, int rollWidth) async {
    final dots = EscPos.dotsFor(rollWidth);
    // Page très haute : un ticket tient sur une page ; le blanc final est retiré au rendu.
    final format = PdfPageFormat(job.paperWidth * PdfPageFormat.mm, 1200 * PdfPageFormat.mm, marginAll: 0);
    // ignore: deprecated_member_use
    final pdf = await Printing.convertHtml(format: format, html: job.html, baseUrl: job.baseUrl);
    final bitmap = MonoBitmap(dots);
    // Rendu à deux fois la résolution de la tête puis moyenne 2×2 (MonoBitmap) : contours nets, sans traits empâtés.
    final dpi = 2 * dots * 25.4 / job.paperWidth;
    await for (final page in Printing.raster(pdf, dpi: dpi)) {
      bitmap.addPage(page.pixels, page.width, page.height, threshold: 150);
    }
    if (bitmap.height == 0) return NativeResult.failure('ticket_vide');
    return channel.printRaw(EscPos.raster(bitmap.bits, dots, bitmap.height));
  }
}
