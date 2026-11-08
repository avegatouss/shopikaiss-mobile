import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:shopikaiss_terminal/src/windows/platform/receipt_pdf.dart';

void main() {
  test(
    'short roll receipt has measured height, not an A4-length sheet',
    () async {
      final receipt = await buildReceiptPdf([
        'SHOPIKAISS',
        'Ticket test',
        'Savon x 1 : 1000 F',
        'TOTAL : 1000 F',
        'Merci',
      ], font: pw.Font.helvetica());
      expect(receipt.bytes, isNotEmpty);
      expect(receipt.format.width, 80 * PdfPageFormat.mm);
      expect(receipt.heights.single, greaterThan(8 * PdfPageFormat.mm));
      expect(receipt.heights.single, lessThan(80 * PdfPageFormat.mm));
    },
  );

  test(
    'long documents split, trailing section also has measured height',
    () async {
      final receipt = await buildReceiptPdf(
        List.generate(85, (i) => 'Article $i : 1000 F'),
        font: pw.Font.helvetica(),
      );
      expect(receipt.heights, hasLength(3));
      expect(receipt.heights.last, lessThan(receipt.heights.first));
      expect(receipt.heights.every((h) => h.isFinite && h > 0), isTrue);
    },
  );
}
