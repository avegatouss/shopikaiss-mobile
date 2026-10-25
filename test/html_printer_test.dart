import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/printer/escpos.dart';
import 'package:shopikaiss_terminal/src/printer/html_printer.dart';

void main() {
  group('Rendu des tickets HTML (X, Z…)', () {
    test('page à la hauteur réelle, deux fois la résolution de la tête : X ou Z d’environ 15 cm', () {
      final plan = ticketRasterPlan(paperWidth: 80, dots: EscPos.dotsFor(80), contentHeightMm: 150, paperMargin: 2);
      expect(plan.pageHeightMm, 166);
      expect(plan.widthPixels(80), 1152);
      expect(plan.widthPixels(80) * plan.heightPixels(), lessThan(HtmlPrinter.maxPagePixels));
    });

    test('aucune page ne dépasse le plafond, quelle que soit la longueur ou la largeur (ancien rendu : 20 millions de pixels)', () {
      for (final paper in [58, 80]) {
        for (final roll in [58, 80]) {
          for (final height in <double>[0, 30, 150, 400, 1200, 5000]) {
            final plan = ticketRasterPlan(paperWidth: paper, dots: EscPos.dotsFor(roll), contentHeightMm: height);
            final pixels = plan.widthPixels(paper) * plan.heightPixels();
            expect(pixels, lessThanOrEqualTo(HtmlPrinter.maxPagePixels + 2000), reason: 'papier $paper, rouleau $roll, $height mm');
            expect(plan.dpi, greaterThanOrEqualTo(EscPos.dotsFor(roll) * 25.4 / paper - 0.001), reason: 'jamais sous la résolution de la tête');
          }
        }
      }
    });

    test('hauteur inconnue : page de 300 mm (plusieurs pages pour un long document)', () {
      expect(ticketRasterPlan(paperWidth: 58, dots: 384, contentHeightMm: 0).pageHeightMm, 300);
    });

    test('job : hauteur, marge et cadre principal lus depuis la page', () {
      final job = HtmlPrintJob.fromMap({'html': '<p>Z</p>', 'paperWidth': 80, 'paperMargin': 2, 'contentHeightMm': 152, 'mainFrame': false});
      expect(job.isTicket, isTrue);
      expect(job.contentHeightMm, 152);
      expect(job.paperMargin, 2);
      expect(job.mainFrame, isFalse);
    });
  });
}
