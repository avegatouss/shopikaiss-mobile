import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'receipt_qr.dart';

/// Measured roll pages: short receipts do not become 297 mm sheets.
/// Long documents keep every line and are split into manageable roll sections.
Future<({Uint8List bytes, PdfPageFormat format, List<double> heights})>
buildReceiptPdf(
  List<String> lines, {
  required pw.Font font,
  bool a4 = false,
  int paperWidth = 80,
  int copies = 1,
  List<ReceiptQr> qrCodes = const [],
}) async {
  if (copies < 1 || copies > 3) {
    throw const FormatException('Nombre d’exemplaires invalide');
  }
  if (lines.isEmpty || lines.length > 10000) {
    throw const FormatException('Ticket invalide');
  }
  final doc = pw.Document();
  final pages = <pw.Page>[];
  for (var copy = 0; copy < copies; copy++) {
    for (var start = 0; start < lines.length; start += 40) {
      final end = start + 40 < lines.length ? start + 40 : lines.length;
      final page = pw.Page(
        pageFormat: a4
            ? PdfPageFormat.a4
            : PdfPageFormat(
                paperWidth * PdfPageFormat.mm,
                double.infinity,
                marginAll: 4 * PdfPageFormat.mm,
              ),
        theme: pw.ThemeData.withFont(base: font),
        build: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          mainAxisSize: pw.MainAxisSize.min,
          children: [
            for (final line in lines.sublist(start, end))
              pw.Text(line, style: const pw.TextStyle(fontSize: 9)),
            if (end == lines.length)
              for (final code in qrCodes)
                pw.Center(
                  child: pw.Column(
                    children: [
                      pw.SizedBox(height: 8),
                      pw.Text(
                        code.label,
                        style: const pw.TextStyle(fontSize: 9),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.BarcodeWidget(
                          barcode: pw.Barcode.qrCode(),
                          data: code.data,
                          width: 110,
                          height: 110,
                          drawText: false,
                        ),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      );
      pages.add(page);
      doc.addPage(page);
    }
  }
  final bytes = await doc.save();
  return (
    bytes: bytes,
    format: pages.first.pageFormat,
    heights: [for (final page in pages) page.pageFormat.height],
  );
}
