import 'dart:convert';
import 'dart:typed_data';

import '../printer/escpos.dart';
import 'models.dart';
import 'money.dart';

/// Ticket d'une vente hors ligne, en lignes de texte à la largeur du rouleau (32 ou 48 colonnes).
///
/// Il porte le numéro du ticket hors ligne (préfixe du terminal + séquence) : le numéro définitif de la vente est
/// attribué par la boutique à la synchronisation, et le numéro hors ligne y reste en commentaire.
List<String> offlineTicketLines({
  required Snapshot snapshot,
  required OfflineOperation operation,
  required List<CartLine> lines,
  required List<CartPayment> payments,
  required String operatorName,
  required int paperWidth,
  bool duplicate = false,
}) {
  final cols = EscPos.columnsFor(paperWidth);
  final store = snapshot.store;
  final currency = store.currency == 'FCFA' ? 'F' : store.currency;
  String money(int amount) => formatFcfa(amount, currency);
  String pair(String left, String right) {
    final room = cols - right.length - 1;
    final l = left.length > room ? left.substring(0, room < 0 ? 0 : room) : left;
    return '$l${' ' * (cols - l.length - right.length)}$right';
  }

  String center(String text) {
    final t = text.length > cols ? text.substring(0, cols) : text;
    return '${' ' * ((cols - t.length) ~/ 2)}$t';
  }

  final out = <String>[];
  void wrap(String text, {bool centered = true}) {
    for (final paragraph in text.split('\n')) {
      var rest = paragraph.trim();
      while (rest.isNotEmpty) {
        var cut = rest.length <= cols ? rest.length : rest.lastIndexOf(' ', cols);
        if (cut <= 0) cut = rest.length < cols ? rest.length : cols;
        final piece = rest.substring(0, cut).trim();
        out.add(centered ? center(piece) : piece);
        rest = rest.substring(cut).trim();
      }
    }
  }

  wrap(store.legalName);
  if (store.address != null && store.address!.isNotEmpty) wrap(store.address!);
  if (store.phone != null && store.phone!.isNotEmpty) wrap('Tel : ${store.phone}');
  if (store.taxId != null && store.taxId!.isNotEmpty) wrap(store.taxId!);
  if (store.header != null && store.header!.isNotEmpty) wrap(store.header!);
  out.add('-' * cols);
  out.add(center(duplicate ? 'DUPLICATA - VENTE HORS LIGNE' : 'VENTE HORS LIGNE'));
  out.add(pair('Ticket', operation.number ?? ''));
  final d = operation.date;
  String two(int v) => v.toString().padLeft(2, '0');
  out.add(pair('Date', '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}'));
  out.add(pair('Caisse', snapshot.terminal.name));
  out.add(pair('Caissier', operatorName));
  out.add('-' * cols);
  for (final line in lines) {
    wrap(line.label, centered: false);
    final quantity = formatMicros(line.quantity);
    out.add(pair('  $quantity x ${money(line.unitPrice)}', money(line.base)));
    if (line.discount > 0) out.add(pair('  Remise', '-${money(line.discount)}'));
  }
  out.add('-' * cols);
  final totals = saleTotals([for (final l in lines) l.total], store.vatRate, store.vatIncluded);
  if (store.hasVat) {
    final rate = formatMicros(parseMicros(store.vatRate) ?? BigInt.zero);
    if (!store.vatIncluded) out.add(pair('Total HT', money(totals.baseHt)));
    out.add(pair(store.vatIncluded ? 'dont TVA $rate %' : 'TVA $rate %', money(totals.vat)));
  }
  out.add(pair('TOTAL', money(totals.payable)));
  for (final payment in payments) {
    out.add(pair(payment.method.name, money(payment.method.isCash ? (payment.received ?? payment.amount) : payment.amount)));
    if (payment.change > 0) out.add(pair('Monnaie rendue', money(payment.change)));
  }
  out.add('-' * cols);
  wrap('Numero definitif attribue par la boutique au retour de la connexion.');
  if (store.footer != null && store.footer!.isNotEmpty) wrap(store.footer!);
  return [for (final line in out) stripAccents(line)];
}

/// Lignes de texte → ESC/POS (police A, titre en gras, coupe).
Uint8List offlineTicketBytes(List<String> lines) {
  final out = BytesBuilder()..add(EscPos.init());
  for (var i = 0; i < lines.length; i++) {
    final bold = i == 0;
    if (bold) out.add([EscPos.esc, 0x45, 1]);
    out.add(latin1.encode('${lines[i].replaceAll(RegExp(r'[^\x20-\x7E]'), '?')}\n'));
    if (bold) out.add([EscPos.esc, 0x45, 0]);
  }
  out.add(EscPos.feedAndCut());
  return out.toBytes();
}
