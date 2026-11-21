import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:shopikaiss_terminal/src/windows/platform/receipt_qr.dart';
import 'package:shopikaiss_terminal/src/windows/platform/receipt_pdf.dart';
import 'package:shopikaiss_terminal/src/printer/escpos.dart';

void main() {
  const lines = [
    'TBC',
    'Ticket     TBC-0001',
    'Date     21/11/2026',
    'Client     Prive',
    'TOTAL     2500 F',
  ];
  test('summary preserves printed values and optional link has its own QR', () {
    final codes = receiptQrCodes(lines, link: 'https://example.com/tbc');
    expect(codes, hasLength(2));
    expect(codes.first.data, contains('TBC-0001'));
    expect(codes.first.data, contains('2500 F'));
    expect(codes.first.data, isNot(contains('Prive')));
    expect(codes.last.data, 'https://example.com/tbc');
    expect(receiptQrCodes(lines, enabled: false), isEmpty);
    expect(validReceiptLink('javascript:alert(1)'), isFalse);
    expect(validReceiptLink('https://user:pass@example.com'), isFalse);
  });
  test('raw ticket has raster QR before a single final cut on both widths', () {
    for (final width in [58, 80]) {
      final bytes = receiptBytesWithQr(
        lines,
        receiptQrCodes(lines, link: 'https://example.com'),
        paperWidth: width,
      );
      final cut = EscPos.feedAndCut(3);
      expect(bytes.skip(bytes.length - cut.length), cut);
      var cuts = 0;
      for (var i = 0; i < bytes.length - 3; i++) {
        if (bytes[i] == 29 &&
            bytes[i + 1] == 86 &&
            bytes[i + 2] == 66 &&
            bytes[i + 3] == 0) {
          cuts++;
        }
      }
      expect(cuts, 1);
      expect(bytes.length, greaterThan(1000));
    }
  });
  test('PDF QR is included in every requested copy on 58 mm and A4', () async {
    for (final a4 in [false, true]) {
      final receipt = await buildReceiptPdf(
        lines,
        font: pw.Font.helvetica(),
        copies: 3,
        paperWidth: 58,
        a4: a4,
        qrCodes: receiptQrCodes(lines, link: 'https://example.com'),
      );
      expect(receipt.heights, hasLength(3));
      expect(receipt.bytes, isNotEmpty);
    }
  });
}
