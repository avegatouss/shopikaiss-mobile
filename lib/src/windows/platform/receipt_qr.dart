import 'dart:convert';
import 'dart:typed_data';

import 'package:qr/qr.dart';

import '../../printer/escpos.dart';
import '../../offline/ticket.dart';

class ReceiptQr {
  const ReceiptQr(this.label, this.data);
  final String label;
  final String data;
}

bool validReceiptLink(String value) {
  if (value.trim().isEmpty) return true;
  final uri = Uri.tryParse(value.trim());
  return uri != null &&
      ['https', 'http'].contains(uri.scheme) &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      !value.contains(RegExp(r'[\x00-\x20]')) &&
      utf8.encode(value).length <= 350;
}

/// A local summary, not a server validation URL. No customer data or payment reference.
List<ReceiptQr> receiptQrCodes(
  List<String> lines, {
  bool enabled = true,
  String link = '',
}) {
  final codes = <ReceiptQr>[];
  if (enabled) {
    final summary = <String>['RESUME DU TICKET'];
    if (lines.isNotEmpty) summary.add(lines.first.trim());
    for (final line in lines.skip(1)) {
      final text = line.trim().replaceAll(RegExp(r' {2,}'), ' : ');
      if (!RegExp(
        r'^(Ticket\s|Date\s|Caisse\s|TOTAL\s|Total HT\s|dont TVA\s|TVA\s)',
        caseSensitive: false,
      ).hasMatch(text)) {
        continue;
      }
      if (utf8.encode([...summary, text].join('\n')).length <= 600) {
        summary.add(text);
      }
    }
    codes.add(ReceiptQr('Informations du ticket', summary.join('\n')));
  }
  if (link.trim().isNotEmpty && validReceiptLink(link.trim())) {
    codes.add(ReceiptQr('Retrouvez-nous en ligne', link.trim()));
  }
  return codes;
}

Uint8List receiptBytesWithQr(
  List<String> lines,
  List<ReceiptQr> codes, {
  bool compact = false,
  int paperWidth = 80,
}) {
  final base = offlineTicketBytes(lines, compact: compact);
  if (codes.isEmpty) return base;
  final out = BytesBuilder()
    ..add(base.sublist(0, base.length - EscPos.feedAndCut().length));
  for (final code in codes) {
    out.add(latin1.encode('${code.label}\n'));
    final qr = QrImage(
      QrCode.fromData(
        data: code.data,
        errorCorrectLevel: QrErrorCorrectLevel.M,
      ),
    );
    const quiet = 4;
    final width = EscPos.dotsFor(paperWidth);
    final scale = (width ~/ (qr.moduleCount + quiet * 2)).clamp(1, 4);
    final height = (qr.moduleCount + quiet * 2) * scale;
    final widthBytes = (width + 7) ~/ 8;
    final bits = Uint8List(widthBytes * height);
    final left = (width - qr.moduleCount * scale) ~/ 2;
    for (var y = 0; y < qr.moduleCount; y++) {
      for (var x = 0; x < qr.moduleCount; x++) {
        if (!qr.isDark(y, x)) continue;
        for (var dy = 0; dy < scale; dy++) {
          for (var dx = 0; dx < scale; dx++) {
            final px = left + x * scale + dx;
            bits[((y + quiet) * scale + dy) * widthBytes + (px >> 3)] |=
                0x80 >> (px & 7);
          }
        }
      }
    }
    out.add(EscPos.raster(bits, width, height, cut: false));
  }
  out.add(EscPos.feedAndCut(compact ? 2 : 3));
  return out.toBytes();
}
