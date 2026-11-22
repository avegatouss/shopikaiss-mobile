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
/// Le logo est une copie locale (PNG normalisé) : rien n'est téléchargé à l'impression. Quand la boutique publie son
/// logo (capacité `boutique.logo`), c'est lui qui est imprimé ([shopLogo]) ; la copie importée sur le poste est gardée
/// ([localLogoPng]) pour un serveur qui ne le publie pas.
class ReceiptSettings {
  const ReceiptSettings({this.copies = 1, this.qrEnabled = true, this.link = '', this.logoPng, this.localLogoPng, this.shopLogo = false});

  final int copies;
  final bool qrEnabled;
  final String link;

  /// Logo imprimé.
  final Uint8List? logoPng;

  /// Copie importée sur le poste (enregistrée), quand [shopLogo] l'emporte.
  final Uint8List? localLogoPng;

  /// Logo décidé par la boutique (publié au web) : pas d'import sur le poste.
  final bool shopLogo;

  static String key(Snapshot snapshot) => 'ticket-reglages-v1:${(snapshot.raw['boutique'] as Map?)?['uuid'] ?? snapshot.store.name}';

  static int copyCount(Object? value) => value is int && value >= 1 && value <= 3 ? value : 1;

  static Future<ReceiptSettings> read(CaisseEngine engine) async {
    final snapshot = engine.snapshot;
    if (snapshot == null) return const ReceiptSettings();
    final raw = await engine.store.read(key(snapshot));
    if (raw == null) return ReceiptSettings(logoPng: engine.receiptLogo(null), shopLogo: engine.shopLogoPublished);
    try {
      final m = jsonDecode(raw) as Map;
      final link = m['qr_link'] is String ? m['qr_link'] as String : '';
      final local = m['logo_png'] is String ? base64Decode(m['logo_png'] as String) : null;
      return ReceiptSettings(
        copies: copyCount(m['copies']),
        qrEnabled: m['qr_enabled'] != false,
        link: validReceiptLink(link) ? link.trim() : '',
        logoPng: engine.receiptLogo(local),
        localLogoPng: local,
        shopLogo: engine.shopLogoPublished,
      );
    } on FormatException {
      return ReceiptSettings(logoPng: engine.receiptLogo(null), shopLogo: engine.shopLogoPublished);
    }
  }

  Future<void> write(CaisseEngine engine) async {
    final snapshot = engine.snapshot;
    if (snapshot == null) throw StateError('Catalogue local absent.');
    if (!validReceiptLink(link)) throw const FormatException('Lien invalide (http ou https, 350 octets au plus).');
    await engine.store.write(
      key(snapshot),
      jsonEncode({'copies': copyCount(copies), 'qr_enabled': qrEnabled, 'qr_link': link.trim(), 'logo_png': ?switch (shopLogo ? localLogoPng : logoPng) {
        final png? => base64Encode(png),
        null => null,
      }}),
    );
  }

  ReceiptSettings copyWith({int? copies, bool? qrEnabled, String? link, Uint8List? logoPng, bool removeLogo = false}) => ReceiptSettings(
    copies: copies ?? this.copies,
    qrEnabled: qrEnabled ?? this.qrEnabled,
    link: link ?? this.link,
    logoPng: removeLogo ? null : logoPng ?? this.logoPng,
    localLogoPng: localLogoPng,
    shopLogo: shopLogo,
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
      // Demande du responsable (22/11) : rien avant le logo, ni ligne ni avance de papier ; seulement l'initialisation.
      // La marge de fin (après le dernier QR, puis la coupe) sépare les exemplaires.
      out.add(EscPos.init());
      if (logo != null) out.add(logo);
      out.add(ticket);
    }
    return out.takeBytes();
  }

  /// Document imprimé autre qu'un ticket de vente (X, Z, transfert, prévente…) : commence par le logo (rien au-dessus),
  /// puis l'entête de la boutique ([header]), le document [body] (octets ESC/POS déjà mis en page), le pied ([footer]),
  /// l'avance et la coupe. L'initialisation et la coupe propres à [body] sont retirées pour n'en garder qu'une.
  Uint8List documentBytes(Uint8List body, {required int paperWidth, List<String> header = const [], List<String> footer = const []}) {
    final logo = logoPng == null ? null : receiptLogoRaster(logoPng!, paperWidth);
    var start = 0;
    final init = EscPos.init();
    if (body.length >= init.length && _same(body, 0, init)) start = init.length;
    var end = body.length;
    for (var n = 2; n <= 6; n++) {
      final cut = EscPos.feedAndCut(n);
      if (end - start >= cut.length && _same(body, end - cut.length, cut)) {
        end -= cut.length;
        break;
      }
    }
    List<int> text(List<String> lines, {bool boldFirst = false}) => [
      EscPos.esc, 0x61, 1, // centré
      for (final (i, line) in lines.indexed) ...[
        if (boldFirst && i == 0) ...[EscPos.esc, 0x45, 1],
        ...latin1.encode('${stripAccents(line).replaceAll(RegExp(r'[^\x20-\x7E]'), '?')}\n'),
        if (boldFirst && i == 0) ...[EscPos.esc, 0x45, 0],
      ],
      EscPos.esc, 0x61, 0, // à gauche
    ];
    final out = BytesBuilder(copy: false)..add(init);
    if (logo != null) out.add(logo);
    if (header.isNotEmpty) out.add(text(header, boldFirst: true));
    out.add(body.sublist(start, end));
    if (footer.isNotEmpty) out.add(text(footer));
    out.add(EscPos.feedAndCut(3));
    return out.takeBytes();
  }

  static bool _same(Uint8List bytes, int at, List<int> expected) {
    for (var i = 0; i < expected.length; i++) {
      if (bytes[at + i] != expected[i]) return false;
    }
    return true;
  }
}

/// Entête d'un document imprimé (raison sociale, adresse, téléphone, NCC, texte d'entête) et son pied.
({List<String> header, List<String> footer}) storeFrame(StoreInfo? store) {
  if (store == null) return (header: const [], footer: const []);
  String? clean(String? s) => s == null || s.trim().isEmpty ? null : s.trim();
  return (
    header: [
      ?clean(store.legalName),
      ?clean(store.address),
      if (clean(store.phone) case final phone?) 'Tél. $phone',
      if (clean(store.taxId) case final ncc?) 'NCC $ncc',
      ...?clean(store.header)?.split('\n'),
    ],
    footer: [...?clean(store.footer)?.split('\n')],
  );
}
