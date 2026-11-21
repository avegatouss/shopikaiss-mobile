import 'dart:convert';
import 'dart:typed_data';

import '../printer/escpos.dart';
import '../windows/platform/receipt_logo.dart';
import '../windows/platform/receipt_qr.dart';
import 'engine.dart';
import 'models.dart';

/// Réglages des tickets de vente de ce terminal : logo, QR résumé, lien facultatif, 1 à 3 exemplaires.
/// Mêmes règles que Windows (C, `a2b56d2`, `bd7c87c`, `6ea2f2f`, `e8354be`), mais rangés **par boutique** dans la base
/// du moteur : le logo ou le lien d'une boutique ne passe pas sur une autre (réserve de la passation C du 21/11).
/// Le logo est une copie locale (PNG normalisé) : rien n'est téléchargé à l'impression.
class ReceiptSettings {
  const ReceiptSettings({this.copies = 1, this.qrEnabled = true, this.link = '', this.logoPng});

  final int copies;
  final bool qrEnabled;
  final String link;
  final Uint8List? logoPng;

  static String key(Snapshot snapshot) => 'ticket-reglages-v1:${(snapshot.raw['boutique'] as Map?)?['uuid'] ?? snapshot.store.name}';

  static int copyCount(Object? value) => value is int && value >= 1 && value <= 3 ? value : 1;

  static Future<ReceiptSettings> read(CaisseEngine engine) async {
    final snapshot = engine.snapshot;
    if (snapshot == null) return const ReceiptSettings();
    final raw = await engine.store.read(key(snapshot));
    if (raw == null) return const ReceiptSettings();
    try {
      final m = jsonDecode(raw) as Map;
      final link = m['qr_link'] is String ? m['qr_link'] as String : '';
      return ReceiptSettings(
        copies: copyCount(m['copies']),
        qrEnabled: m['qr_enabled'] != false,
        link: validReceiptLink(link) ? link.trim() : '',
        logoPng: m['logo_png'] is String ? base64Decode(m['logo_png'] as String) : null,
      );
    } on FormatException {
      return const ReceiptSettings();
    }
  }

  Future<void> write(CaisseEngine engine) async {
    final snapshot = engine.snapshot;
    if (snapshot == null) throw StateError('Catalogue local absent.');
    if (!validReceiptLink(link)) throw const FormatException('Lien invalide (http ou https, 350 octets au plus).');
    await engine.store.write(
      key(snapshot),
      jsonEncode({'copies': copyCount(copies), 'qr_enabled': qrEnabled, 'qr_link': link.trim(), 'logo_png': logoPng == null ? null : base64Encode(logoPng!)}),
    );
  }

  ReceiptSettings copyWith({int? copies, bool? qrEnabled, String? link, Uint8List? logoPng, bool removeLogo = false}) => ReceiptSettings(
    copies: copies ?? this.copies,
    qrEnabled: qrEnabled ?? this.qrEnabled,
    link: link ?? this.link,
    logoPng: removeLogo ? null : logoPng ?? this.logoPng,
  );

  /// Lignes d'un ticket de vente telles qu'imprimées (« DONT TVA » en capitales, montant inchangé).
  static List<String> saleLines(List<String> lines) => receiptSaleLines(lines);

  /// Octets ESC/POS d'un ticket de vente : logo, texte, QR résumé et lien, répétés [copies] fois (défaut : le réglage).
  /// Un seul envoi à l'imprimante : aucune vente n'est rejouée pour les exemplaires.
  Uint8List saleBytes(List<String> lines, {required int paperWidth, bool compact = false, int? copies}) {
    final printed = saleLines(lines);
    final ticket = receiptBytesWithQr(printed, receiptQrCodes(printed, enabled: qrEnabled, link: link), compact: compact, paperWidth: paperWidth);
    final logo = logoPng == null ? null : receiptLogoRaster(logoPng!, paperWidth);
    final out = BytesBuilder(copy: false);
    for (var i = 0; i < copyCount(copies ?? this.copies); i++) {
      // Marges de C (`398a128`, puis `9e044dd`) : deux lignes avant le logo ou le texte, deux après le dernier QR (dans receiptBytesWithQr).
      out.add([...EscPos.init(), EscPos.esc, 0x64, 2]);
      if (logo != null) out.add(logo);
      out.add(ticket);
    }
    return out.takeBytes();
  }
}
