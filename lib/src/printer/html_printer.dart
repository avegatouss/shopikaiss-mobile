import 'dart:isolate';
import 'dart:math' as math;

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
        paperWidth = (m['paperWidth'] as num?)?.toInt() ?? 0,
        paperMargin = (m['paperMargin'] as num?)?.toDouble() ?? 0,
        contentHeightMm = (m['contentHeightMm'] as num?)?.toDouble() ?? 0,
        mainFrame = m['mainFrame'] == true;

  final String html;
  final String baseUrl;
  final String title;

  /// Largeur du ticket déclarée par la page (`[data-paper-width]`), 0 pour un document A4.
  final int paperWidth;

  /// Marge du ticket (mm) et hauteur réelle de son contenu mesurée par la page (mm, 0 = inconnue).
  final double paperMargin;
  final double contentHeightMm;

  /// Impression demandée par la page elle-même (et non par un cadre caché) : la vue peut s'imprimer telle qu'affichée.
  final bool mainFrame;

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

  /// Pixels d'une page rastérisée au plus (≈ 24 Mo en ARGB) : au-delà, Android peut fermer l'application faute de
  /// mémoire, sans que le Dart puisse l'intercepter (le greffon d'impression copie l'image plusieurs fois).
  static const maxPagePixels = 6000000;

  /// [printPage] : impression native Android de la vue affichée (document A4 demandé par la page elle-même).
  Future<NativeResult> print(HtmlPrintJob job, {required bool hasPrinter, required int rollWidth, Future<bool> Function()? printPage}) async {
    if (job.html.isEmpty) return NativeResult.failure('document_vide');
    if (job.isTicket && hasPrinter) {
      return _printTicket(job, rollWidth > 0 ? rollWidth : job.paperWidth);
    }
    if (job.mainFrame && printPage != null) {
      // Service d'impression d'Android sur la page affichée : pas de seconde vue web ni de conversion PDF intermédiaire.
      return await printPage() ? const NativeResult({'ok': true}) : NativeResult.failure('impression_annulee');
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
    final plan = ticketRasterPlan(paperWidth: job.paperWidth, dots: dots, contentHeightMm: job.contentHeightMm, paperMargin: job.paperMargin);
    // Page à la hauteur réelle du ticket (plusieurs pages pour un très long document) ; le blanc final est retiré au rendu.
    final format = PdfPageFormat(job.paperWidth * PdfPageFormat.mm, plan.pageHeightMm * PdfPageFormat.mm, marginAll: 0);
    // ignore: deprecated_member_use
    final pdf = await Printing.convertHtml(format: format, html: withPageSize(job.html, job.paperWidth, plan.pageHeightMm, job.paperMargin), baseUrl: job.baseUrl);
    final bitmap = MonoBitmap(dots);
    await for (final page in Printing.raster(pdf, dpi: plan.dpi)) {
      // Conversion en noir et blanc hors du fil de l'écran : plus de gel de la caisse sur un long document.
      final pixels = page.pixels;
      final width = page.width;
      final height = page.height;
      final converted = await Isolate.run(() {
        final one = MonoBitmap(dots)..addPage(pixels, width, height, threshold: 150);
        return (one.bits, one.height);
      });
      bitmap.append(converted.$1, converted.$2);
    }
    if (bitmap.height == 0) return NativeResult.failure('ticket_vide');
    return channel.printRaw(EscPos.raster(bitmap.bits, dots, bitmap.height));
  }
}

/// Hauteur de page et résolution du rendu d'un ticket HTML.
class TicketRasterPlan {
  const TicketRasterPlan(this.pageHeightMm, this.dpi);

  final double pageHeightMm;
  final double dpi;

  int widthPixels(int paperWidth) => (paperWidth / 25.4 * dpi).round();
  int heightPixels() => (pageHeightMm / 25.4 * dpi).round();
}

/// Choisit la page et la résolution d'un ticket : la hauteur réelle mesurée par la page (marges et coupe comprises), sinon
/// 300 mm ; rendu à deux fois la résolution de la tête (contours nets) tant que la page reste sous [HtmlPrinter.maxPagePixels],
/// sinon moins, jusqu'à la résolution de la tête ; au-delà, la page est raccourcie et le document s'imprime en plusieurs pages.
TicketRasterPlan ticketRasterPlan({required int paperWidth, required int dots, required double contentHeightMm, double paperMargin = 0}) {
  final base = dots * 25.4 / paperWidth;
  var heightMm = contentHeightMm > 0 ? contentHeightMm + 2 * paperMargin + 12 : 300.0;
  heightMm = heightMm.clamp(40.0, 3000.0);
  double pixels(double scale, double mm) => (dots * scale) * (mm / 25.4 * base * scale);
  var scale = 2.0;
  while (scale > 1 && pixels(scale, heightMm) > HtmlPrinter.maxPagePixels) {
    scale -= 0.25;
  }
  if (pixels(scale, heightMm) > HtmlPrinter.maxPagePixels) {
    heightMm = HtmlPrinter.maxPagePixels / (dots * scale) / (base * scale) * 25.4;
  }
  return TicketRasterPlan(math.max(40, heightMm), base * scale);
}

/// Impose au document la taille de page du rendu. Sans cela, la règle `@page` du ticket (souvent 297 mm de haut) était
/// plus haute que la page demandée : le moteur réduisait tout le ticket pour l'y faire tenir, d'où un X ou un Z imprimé
/// en miniature (version 1.1.3). La règle ajoutée en fin de document l'emporte sur celles de la page.
String withPageSize(String html, int paperWidth, double pageHeightMm, double marginMm) {
  final rule = '<style data-sk-page>@page{size:${paperWidth}mm ${pageHeightMm.toStringAsFixed(1)}mm !important;'
      'margin:${marginMm.toStringAsFixed(1)}mm !important}</style>';
  final close = html.lastIndexOf(RegExp('</body>', caseSensitive: false));
  return close < 0 ? '$html$rule' : html.replaceRange(close, close, rule);
}
