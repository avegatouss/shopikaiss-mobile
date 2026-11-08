import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Measured roll pages: short receipts do not become 297 mm sheets.
/// Long documents keep every line and are split into manageable roll sections.
Future<({Uint8List bytes, PdfPageFormat format, List<double> heights})>
buildReceiptPdf(List<String> lines, {required pw.Font font}) async {
  if (lines.isEmpty || lines.length > 10000) {
    throw const FormatException('Ticket invalide');
  }
  final doc = pw.Document();
  final pages = <pw.Page>[];
  for (var start = 0; start < lines.length; start += 40) {
    final end = start + 40 < lines.length ? start + 40 : lines.length;
    final page = pw.Page(
      pageFormat: PdfPageFormat(
        80 * PdfPageFormat.mm,
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
        ],
      ),
    );
    pages.add(page);
    doc.addPage(page);
  }
  final bytes = await doc.save();
  return (
    bytes: bytes,
    format: pages.first.pageFormat,
    heights: [for (final page in pages) page.pageFormat.height],
  );
}
