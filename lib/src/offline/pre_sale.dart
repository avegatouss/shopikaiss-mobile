/// Prévente / réservations (contrat 2.1 lot 15, capacité `prevente.v1`, note A `LOT-15-PREVENTE-POUR-B-ET-C.md`).
///
/// Le client réserve, laisse un acompte ou non, et reçoit une facture de prévente avec un code. Au retrait, la prévente est
/// convertie par une vente (`prevente_uuid` + paiement technique `acompte_prevente`), ou il se désiste (remboursement
/// facultatif de l'acompte). Petite caisse isolée : l'acompte n'est pas du chiffre d'affaires avant la conversion.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../printer/escpos.dart';
import 'models.dart' show stripAccents;

/// Moyen technique de la vente de conversion : l'acompte déjà compté à sa réception, jamais proposé dans un sélecteur.
const preSaleDepositMethod = 'acompte_prevente';

/// Alphabet des 4 derniers caractères du code (sans 0, O, 1, I).
const preSaleAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

class PreSaleLine {
  const PreSaleLine({
    required this.uuid,
    required this.productUuid,
    this.packagingUuid,
    required this.label,
    required this.quantity,
    required this.unitPrice,
    this.discount = 0,
    required this.total,
  });

  factory PreSaleLine.fromJson(Map m) => PreSaleLine(
    uuid: m['ligne_uuid'] as String,
    productUuid: m['produit_uuid'] as String,
    packagingUuid: m['conditionnement_uuid'] as String?,
    label: m['libelle'] as String,
    quantity: m['quantite'] as String,
    unitPrice: (m['prix_unitaire'] as num).toInt(),
    discount: (m['remise'] as num?)?.toInt() ?? 0,
    total: (m['total'] as num).toInt(),
  );

  final String uuid;
  final String productUuid;
  final String? packagingUuid;
  final String label;

  /// Quantité au format du contrat (6 décimales).
  final String quantity;
  final int unitPrice;
  final int discount;
  final int total;

  Map<String, dynamic> toJson() => {
    'ligne_uuid': uuid,
    'produit_uuid': productUuid,
    'conditionnement_uuid': packagingUuid,
    'libelle': label,
    'quantite': quantity,
    'prix_unitaire': unitPrice,
    'remise': discount,
    'total': total,
  };
}

/// Une prévente vue par le poste : la sienne (depuis sa file) ou celle d'un autre poste (entité publiée `prevente`).
class PreSale {
  PreSale({
    required this.uuid,
    required this.code,
    required this.customerName,
    this.customerPhone,
    this.customerUuid,
    this.pickupAt,
    required this.lines,
    required this.total,
    required this.deposit,
    this.depositMethod,
    this.note,
    this.status = 'ouverte',
    this.createdAt,
    this.local = true,
    this.serverState,
    this.serverMessage,
    this.refunded = 0,
  });

  final String uuid;
  final String code;
  String customerName;
  String? customerPhone;
  String? customerUuid;
  DateTime? pickupAt;
  List<PreSaleLine> lines;
  int total;

  /// Acompte restant (après un éventuel remboursement : 0).
  int deposit;
  String? depositMethod;
  String? note;

  /// `ouverte`, `retiree` (convertie) ou `desistee` (annulée).
  String status;
  DateTime? createdAt;

  /// Créée sur ce poste (file locale) ; sinon publiée par la boutique (web ou autre poste).
  final bool local;

  /// État de l'opération de création au serveur (`a_envoyer`, `recue`…), et raison d'une attente.
  String? serverState;
  String? serverMessage;
  int refunded;

  bool get open => status == 'ouverte';

  /// Reste à payer au retrait.
  int get due => total - deposit;

  Map<String, dynamic> toJson() => {
    'id': uuid,
    'code': code,
    'customer': {'name': customerName, 'phone': customerPhone, 'uuid': customerUuid},
    'pickup_at': pickupAt?.toUtc().toIso8601String(),
    'lines': [for (final l in lines) l.toJson()],
    'total': total,
    'deposit': deposit,
    'deposit_method': depositMethod,
    'due': due,
    'note': note,
    'status': status,
    'created_at': createdAt?.toUtc().toIso8601String(),
    'local': local,
    'server_state': serverState,
    'server_message': serverMessage,
    'refunded': refunded,
  };
}

/// Conversion d'une prévente par la vente en cours : uuid et acompte restant déduit (paiement `acompte_prevente`).
class PreSaleUse {
  const PreSaleUse({required this.uuid, required this.code, required this.deposit});
  final String uuid;
  final String code;
  final int deposit;
}

/// Préfixe de 2 caractères propre au poste, stable, jamais « W » (réservé au web) : tiré de l'uuid de l'appareil.
String preSalePrefix(String deviceUuid) {
  var hash = 0;
  for (final c in deviceUuid.codeUnits) {
    hash = (hash * 31 + c) & 0x7fffffff;
  }
  const first = 'ABCDEFGHJKLMNPQRSTUVXYZ23456789'; // sans W
  return '${first[hash % first.length]}${preSaleAlphabet[(hash ~/ first.length) % preSaleAlphabet.length]}';
}

/// Code de prévente : préfixe du poste + 4 caractères tirés au hasard, différent de ceux déjà connus.
String newPreSaleCode(String prefix, Set<String> known, {Random? random}) {
  final r = random ?? Random.secure();
  for (var i = 0; i < 200; i++) {
    final code = '$prefix${List.generate(4, (_) => preSaleAlphabet[r.nextInt(preSaleAlphabet.length)]).join()}';
    if (!known.contains(code)) return code;
  }
  throw StateError('Plus de code de prévente disponible pour ce poste.');
}

/// Lignes de la facture de prévente (ticket), code mis en valeur : « FACTURE DE PRÉVENTE », code, client, retrait prévu,
/// lignes, total réservé, acompte versé, reste à payer, note, mention.
List<String> preSaleTicketLines(PreSale p, {required int columns, required String Function(int) money, String? operatorName, String title = 'FACTURE DE PRÉVENTE'}) {
  String row(String left, String right) {
    final space = columns - left.length - right.length;
    if (space >= 1) return '$left${' ' * space}$right';
    return '${left.substring(0, max(0, columns - right.length - 1))} $right';
  }

  String two(int v) => v.toString().padLeft(2, '0');
  String date(DateTime d) {
    final l = d.toLocal();
    return '${two(l.day)}/${two(l.month)}/${l.year} ${two(l.hour)}:${two(l.minute)}';
  }

  final rule = '-' * columns;
  return [
    title,
    'CODE : ${p.code}',
    rule,
    'Client : ${p.customerName}',
    if ((p.customerPhone ?? '').isNotEmpty) 'Tél. : ${p.customerPhone}',
    if (p.createdAt != null) 'Le ${date(p.createdAt!)}',
    if (p.pickupAt != null) 'Retrait prévu : ${date(p.pickupAt!)}',
    rule,
    for (final l in p.lines) ...[
      l.label,
      row('  ${l.quantity.replaceFirst(RegExp(r'\.?0+$'), '')} x ${money(l.unitPrice)}', money(l.total)),
    ],
    rule,
    row('Total réservé', money(p.total)),
    row('Acompte versé', money(p.deposit)),
    row('Reste à payer au retrait', money(p.due)),
    if ((p.note ?? '').isNotEmpty) 'Note : ${p.note}',
    if (operatorName != null && operatorName.isNotEmpty) 'Servi par : $operatorName',
    rule,
    'Présentez ce code au retrait.',
    'Document de réservation : ce n’est pas un ticket de vente.',
  ];
}

/// Octets ESC/POS de la facture de prévente : titre en gras, **code en double taille** centré, puis le reste.
Uint8List preSaleTicketBytes(List<String> lines) {
  final out = BytesBuilder()..add(EscPos.init());
  for (var i = 0; i < lines.length; i++) {
    final text = latin1.encode('${stripAccents(lines[i]).replaceAll(RegExp(r'[^\x20-\x7E]'), '?')}\n');
    if (i == 0) {
      out
        ..add([EscPos.esc, 0x61, 1, EscPos.esc, 0x45, 1])
        ..add(text)
        ..add([EscPos.esc, 0x45, 0]);
    } else if (i == 1) {
      out
        ..add([EscPos.gs, 0x21, 0x11, EscPos.esc, 0x45, 1])
        ..add(text)
        ..add([EscPos.gs, 0x21, 0x00, EscPos.esc, 0x45, 0, EscPos.esc, 0x61, 0]);
    } else {
      out.add(text);
    }
  }
  out.add(EscPos.feedAndCut(3));
  return out.toBytes();
}
