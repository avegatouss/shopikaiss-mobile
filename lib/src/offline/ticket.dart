import 'dart:convert';
import 'dart:typed_data';

import '../printer/escpos.dart';
import 'models.dart';
import 'money.dart';

/// Ticket d'une vente hors ligne, en lignes de texte à la largeur du rouleau (32 ou 48 colonnes).
///
/// Il porte le numéro du ticket hors ligne (préfixe du terminal + séquence) : le numéro définitif de la vente est
/// attribué par la boutique à la synchronisation, et le numéro hors ligne y reste en commentaire.
///
/// [model] : modèle de ticket connu à la vente (ordre des blocs, blocs masqués, titre, compact, textes) ; null pour la
/// disposition d'origine. Les articles et les totaux restent fixes entre le haut et le bas.
List<String> offlineTicketLines({
  required Snapshot snapshot,
  required OfflineOperation operation,
  required List<CartLine> lines,
  required List<CartPayment> payments,
  required String operatorName,
  required int paperWidth,
  bool duplicate = false,
  TicketModel? model,
}) {
  final cols = EscPos.columnsFor(paperWidth);
  final store = snapshot.store;
  final compact = model?.compact ?? false;
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

  void filled(String? text, [String prefix = '']) {
    if (text != null && text.isNotEmpty) wrap('$prefix$text');
  }

  final d = operation.date;
  String two(int v) => v.toString().padLeft(2, '0');
  // Blocs du ticket hors ligne ; ceux du web sans équivalent ici (logo, restaurant, avantages, QR…) n'impriment rien.
  final blocks = <String, void Function()>{
    'nom': () => wrap(store.legalName),
    'adresse': () => filled(store.address),
    'telephone': () => filled(store.phone, 'Tel : '),
    'ncc': () => filled(store.taxId),
    'entete': () => filled(model?.header ?? store.header),
    'document': () {
      out.add('-' * cols);
      final title = model?.title ?? 'VENTE';
      out.add(center('${duplicate ? 'REIMPRESSION - ' : ''}$title HORS LIGNE'));
      out.add(pair('Ticket', operation.number ?? ''));
      out.add(pair('Date', '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}'));
      if (operation.content['tarif'] case final String tier when tier != 'detail') out.add(tier == 'gros' ? 'Tarif gros' : 'Tarif gros par quantite');
    },
    'vendeur': () {
      out.add(pair('Caisse', snapshot.terminal.name));
      out.add(pair('Caissier', operatorName));
    },
    'client': () {
      if (operation.content['client_nom'] case final String customer when customer.isNotEmpty) out.add(pair('Client', customer));
    },
    'paiements': () {
      for (final payment in payments) {
        out.add(pair(payment.method.name, money(payment.method.isCash ? (payment.received ?? payment.amount) : payment.amount)));
        if (payment.change > 0) out.add(pair('Monnaie rendue', money(payment.change)));
      }
    },
    'operations': () {
      out.add('-' * cols);
      wrap('Numero definitif attribue par la boutique au retour de la connexion.');
    },
    'pied': () => filled(model?.footer ?? store.footer),
  };
  for (final block in model?.top ?? TicketModel.originTop) {
    blocks[block]?.call();
  }
  out.add('-' * cols);
  for (final line in lines) {
    final quantity = formatMicros(line.quantity);
    if (compact) {
      // Une ligne par article : quantité, libellé, montant remise déduite.
      out.add(pair('$quantity x ${line.label}', money(line.total)));
      continue;
    }
    wrap(line.label, centered: false);
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
  for (final block in model?.bottom ?? TicketModel.originBottom) {
    blocks[block]?.call();
  }
  return [for (final line in out) stripAccents(line)];
}

/// Bon de caisse (retour, Z) à la largeur du rouleau : en-tête de la boutique, [title], lignes libellé / valeur.
List<String> offlineSlipLines({
  required Snapshot snapshot,
  required String title,
  required DateTime date,
  required String operatorName,
  required int paperWidth,
  required List<(String, String)> rows,
}) {
  final cols = EscPos.columnsFor(paperWidth);
  final store = snapshot.store;
  String cut(String text) => text.length > cols ? text.substring(0, cols) : text;
  String center(String text) => '${' ' * ((cols - cut(text).length) ~/ 2)}${cut(text)}';
  String pair(String left, String right) {
    final room = cols - right.length - 1;
    if (right.isEmpty) return cut(left);
    final l = left.length > room ? left.substring(0, room < 0 ? 0 : room) : left;
    return '$l${' ' * (cols - l.length - right.length)}$right';
  }

  String two(int v) => v.toString().padLeft(2, '0');
  final out = [
    center(store.legalName),
    '-' * cols,
    center(title),
    pair('Date', '${two(date.day)}/${two(date.month)}/${date.year} ${two(date.hour)}:${two(date.minute)}'),
    pair('Caisse', snapshot.terminal.name),
    pair('Caissier', operatorName),
    '-' * cols,
    for (final (left, right) in rows) pair(left, right),
    '-' * cols,
  ];
  return [for (final line in out) stripAccents(line)];
}

/// Lignes de texte → ESC/POS (police A, titre en gras, coupe) ; avance avant coupe : 2 lignes en compact, 3 sinon.
Uint8List offlineTicketBytes(List<String> lines, {bool compact = false}) {
  final out = BytesBuilder()..add(EscPos.init());
  for (var i = 0; i < lines.length; i++) {
    final bold = i == 0;
    if (bold) out.add([EscPos.esc, 0x45, 1]);
    out.add(latin1.encode('${lines[i].replaceAll(RegExp(r'[^\x20-\x7E]'), '?')}\n'));
    if (bold) out.add([EscPos.esc, 0x45, 0]);
  }
  out.add(EscPos.feedAndCut(compact ? 2 : 3));
  return out.toBytes();
}
