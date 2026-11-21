import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../printer/escpos.dart';

List<String> receiptSaleLines(List<String> lines) => [
  for (final line in lines)
    line.replaceAll(
      RegExp(r'\bdont\s+TVA\b', caseSensitive: false),
      'DONT TVA',
    ),
];

/// Store a bounded local PNG so printing never depends on the original file.
Uint8List normalizeReceiptLogo(Uint8List bytes) {
  if (bytes.length > 2 * 1024 * 1024) {
    throw const FormatException('Logo limité à 2 Mo.');
  }
  final decoder = img.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (info == null || info.width > 4096 || info.height > 4096) {
    throw const FormatException(
      'Image PNG/JPG invalide ou trop grande (4096 pixels maximum).',
    );
  }
  final source = decoder!.decodeFrame(0);
  if (source == null) throw const FormatException('Logo illisible.');
  final scale = (320 / source.width)
      .clamp(0.0, 160 / source.height)
      .clamp(0.0, 1.0);
  final resized = img.copyResize(
    source.convert(format: img.Format.uint8, numChannels: 4),
    width: (source.width * scale).round().clamp(1, 320),
    height: (source.height * scale).round().clamp(1, 160),
  );
  return Uint8List.fromList(img.encodePng(resized));
}

Uint8List receiptLogoRaster(Uint8List png, int paperWidth) {
  final logo = img
      .decodePng(png)
      ?.convert(format: img.Format.uint8, numChannels: 4);
  if (logo == null) throw const FormatException('Logo local illisible.');
  final width = EscPos.dotsFor(paperWidth);
  final rowBytes = (width + 7) ~/ 8;
  final bits = Uint8List(rowBytes * logo.height);
  final left = (width - logo.width) ~/ 2;
  for (var y = 0; y < logo.height; y++) {
    for (var x = 0; x < logo.width; x++) {
      final p = logo.getPixel(x, y);
      final alpha = p.aNormalized;
      final luminance =
          255 *
              (.299 * p.rNormalized +
                  .587 * p.gNormalized +
                  .114 * p.bNormalized) *
              alpha +
          255 * (1 - alpha);
      if (luminance < 160) {
        final px = left + x;
        bits[y * rowBytes + (px >> 3)] |= 0x80 >> (px & 7);
      }
    }
  }
  return EscPos.raster(bits, width, logo.height, cut: false, trailingLines: 0);
}
