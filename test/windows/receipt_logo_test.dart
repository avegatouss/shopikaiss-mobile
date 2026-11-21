import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/widgets.dart' as pw;
import 'package:shopikaiss_terminal/src/windows/platform/receipt_logo.dart';
import 'package:shopikaiss_terminal/src/windows/platform/receipt_pdf.dart';

void main() {
  test('logo fits receipt, transparent background stays white and renders in PDF', () async {
    final source = img.Image(width: 640, height: 640, numChannels: 4);
    img.fill(source, color: img.ColorRgba8(0, 0, 0, 0));
    final png = normalizeReceiptLogo(Uint8List.fromList(img.encodePng(source)));
    final resized = img.decodePng(png)!;
    expect(resized.width, 160);
    expect(resized.height, 160);
    for (final width in [58, 80]) {
      final raw = receiptLogoRaster(png, width);
      expect(raw, isNotEmpty);
      // Two raster bands, no hidden four-line advance after the logo.
      expect(raw.length, 2 + 2 * 8 + (width == 58 ? 48 : 72) * 160);
      // Raster band payload starts after ESC @ (2 bytes) and GS v 0 (8 bytes).
      expect(
        raw.sublist(10, 10 + (width == 58 ? 48 : 72) * 128),
        everyElement(0),
      );
      final pdf = await buildReceiptPdf(
        ['TBC', 'DONT TVA 100 F'],
        font: pw.Font.helvetica(),
        paperWidth: width,
        logoPng: png,
        copies: 3,
      );
      expect(pdf.heights, hasLength(3));
    }
  });
  test('opaque logo produces black dots instead of a blank receipt', () {
    final source = img.Image(width: 16, height: 16, numChannels: 4);
    img.fill(source, color: img.ColorRgba8(0, 0, 0, 255));
    final png = normalizeReceiptLogo(Uint8List.fromList(img.encodePng(source)));
    final raw = receiptLogoRaster(png, 80);
    expect(raw.sublist(10).where((b) => b != 0).length, 32);
  });
  test(
    'invalid logo rejected and TVA wording changes without changing numbers',
    () {
      expect(
        () => normalizeReceiptLogo(Uint8List.fromList([1, 2, 3])),
        throwsFormatException,
      );
      expect(
        receiptSaleLines(['TBC', 'dont TVA    150 F', 'Total HT  850 F']),
        ['TBC', 'DONT TVA    150 F', 'Total HT  850 F'],
      );
    },
  );
}
