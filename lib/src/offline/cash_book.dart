/// Livre de caisse sur le poste (contrat 2.1 lot 14, note A `LOT-14-LIVRE-CAISSE-POUR-B-ET-C.md`).
///
/// Deux livres, montrés côte à côte et jamais additionnés :
/// - le **livre local**, calculé depuis la file du poste (sessions, ventes, retours, clôtures), sans réseau ;
/// - le **livre en ligne** (`GET /livre-caisse`, gérants : droit `livre_caisse_voir`), toute la boutique, gardé 30 jours.
///
/// Les colonnes et les libellés sont ceux du « Livre de caisse journalier » des rapports web.
library;

import 'x_z_report.dart';

/// Une ligne du livre (colonnes du web, noms du contrat `livre-caisse.json#/$defs/mouvement`).
class CashBookRow {
  const CashBookRow({
    required this.day,
    required this.date,
    required this.sessionUuid,
    required this.terminal,
    required this.nature,
    required this.method,
    this.cashIn = 0,
    this.cashOut = 0,
    this.others = 0,
    this.expected,
    this.counted,
    this.difference,
  });

  factory CashBookRow.fromJson(Map m) => CashBookRow(
    day: m['jour'] as String,
    date: DateTime.parse(m['date'] as String),
    sessionUuid: m['session_uuid'] as String?,
    terminal: '${m['terminal'] ?? ''}',
    nature: m['nature'] as String,
    method: '${m['moyen'] ?? ''}',
    cashIn: m['entree_especes'] as int? ?? 0,
    cashOut: m['sortie_especes'] as int? ?? 0,
    others: m['autres'] as int? ?? 0,
    expected: m['attendu'] as int?,
    counted: m['compte'] as int?,
    difference: m['ecart'] as int?,
  );

  final String day;
  final DateTime date;
  final String? sessionUuid;
  final String terminal;
  final String nature;
  final String method;
  final int cashIn;
  final int cashOut;
  final int others;
  final int? expected;
  final int? counted;
  final int? difference;

  bool get isClosure => expected != null || counted != null;

  Map<String, dynamic> toJson() => {
    'jour': day,
    'date': date.toUtc().toIso8601String(),
    'session_uuid': sessionUuid,
    'terminal': terminal,
    'nature': nature,
    'moyen': method,
    'entree_especes': cashIn,
    'sortie_especes': cashOut,
    'autres': others,
    'attendu': expected,
    'compte': counted,
    'ecart': difference,
  };
}

/// Totaux par moyen (« Livre de caisse » du poste web) : ventes datées de la vente, remboursements à leur date.
class CashBookMethod {
  const CashBookMethod(this.method, this.collected, this.refunded);
  final String method;
  final int collected;
  final int refunded;
  int get net => collected - refunded;

  Map<String, dynamic> toJson() => {'moyen': method, 'encaisse': collected, 'rembourse': refunded, 'net': net};
}

class CashBook {
  CashBook({
    required this.from,
    required this.to,
    required this.rows,
    required this.methods,
    required this.salesCount,
    required this.salesAmount,
    this.credit = 0,
    this.cancellationsCount = 0,
    this.cancellationsAmount = 0,
    this.online = false,
    this.generatedAt,
    this.storeWide = false,
  });

  /// Réponse du serveur (pages réunies) : lignes et totaux tels quels.
  factory CashBook.fromOnline(Map response) {
    final totals = response['totaux_par_moyen'] as Map;
    return CashBook(
      from: response['du'] as String,
      to: response['au'] as String,
      rows: [for (final m in (response['mouvements'] as List).cast<Map>()) CashBookRow.fromJson(m)],
      methods: [for (final m in (totals['moyens'] as List).cast<Map>()) CashBookMethod('${m['moyen']}', m['encaisse'] as int, m['rembourse'] as int)],
      salesCount: totals['ventes_nombre'] as int,
      salesAmount: totals['ventes_montant'] as int,
      credit: totals['credit'] as int? ?? 0,
      cancellationsCount: totals['annulations_nombre'] as int? ?? 0,
      cancellationsAmount: totals['annulations_montant'] as int? ?? 0,
      online: true,
      generatedAt: DateTime.tryParse('${response['genere_le']}'),
      storeWide: true,
    );
  }

  final String from;
  final String to;
  final List<CashBookRow> rows;
  final List<CashBookMethod> methods;
  final int salesCount;
  final int salesAmount;
  final int credit;
  final int cancellationsCount;
  final int cancellationsAmount;

  /// Livre en ligne (toute la boutique, opérations intégrées seulement) ; sinon livre local du poste.
  final bool online;
  final DateTime? generatedAt;

  /// Toutes les caisses de la boutique (livre en ligne) ou ce poste seul.
  final bool storeWide;

  int get cashIn => rows.fold(0, (s, r) => s + r.cashIn);
  int get cashOut => rows.fold(0, (s, r) => s + r.cashOut);
  int get others => rows.fold(0, (s, r) => s + r.others);
  int get collected => methods.fold(0, (s, m) => s + m.collected);
  int get refunded => methods.fold(0, (s, m) => s + m.refunded);

  /// Journées présentes, de la plus récente à la plus ancienne.
  List<String> get days => {for (final r in rows) r.day}.toList()..sort((a, b) => b.compareTo(a));

  Map<String, dynamic> toJson() => {
    'du': from,
    'au': to,
    'en_ligne': online,
    'toute_la_boutique': storeWide,
    'genere_le': generatedAt?.toUtc().toIso8601String(),
    'mouvements': [for (final r in rows) r.toJson()],
    'totaux_page': {'entree_especes': cashIn, 'sortie_especes': cashOut, 'autres': others},
    'totaux_par_moyen': {
      'ventes_nombre': salesCount,
      'ventes_montant': salesAmount,
      'credit': credit,
      'annulations_nombre': cancellationsCount,
      'annulations_montant': cancellationsAmount,
      'moyens': [for (final m in methods) m.toJson()],
      'encaisse': collected,
      'rembourse': refunded,
      'net': collected - refunded,
    },
  };
}

int _int(Object? v) => (v as num?)?.toInt() ?? 0;

/// Livre local du poste sur `from..to` (jours `AAAA-MM-JJ` de la boutique, inclus) : une session compte pour le jour
/// de son ouverture ; dans chaque session, l'ordre du web (ouverture, flux espèces, autres moyens, clôture).
/// [onlyOpener] : livre d'un caissier sans le droit `livre_caisse_voir`, limité aux sessions qu'il a ouvertes.
CashBook buildLocalCashBook(
  ClosureFacts facts,
  ZContext context, {
  required String from,
  required String to,
  required String Function(DateTime date) dayOf,
  int? onlyOpener,
}) {
  final names = context.methodNames;
  final cashCodes = context.cashCodes.isEmpty ? {'especes'} : context.cashCodes;
  final cashName = names[context.cashCode] ?? 'Espèces';
  bool inPeriod(String day) => day.compareTo(from) >= 0 && day.compareTo(to) <= 0;
  final rows = <CashBookRow>[];
  final collected = <String, int>{};
  final refunded = <String, int>{};
  var salesCount = 0, salesAmount = 0, cancellations = 0, cancelled = 0;

  for (final s in facts.sessions) {
    if (onlyOpener != null && s.openerId != onlyOpener) continue;
    final opened = s.openedAt ?? s.dates.firstOrNull;
    // Ventes et remboursements aux dates de leurs opérations (totaux par moyen), même si la session est hors période.
    for (final sale in s.sales) {
      final date = DateTime.tryParse('${sale['cree_le']}');
      if (date == null || !inPeriod(dayOf(date))) continue;
      salesCount++;
      final content = sale['contenu'] as Map;
      salesAmount += _int((content['totaux'] as Map?)?['a_payer']);
      for (final p in ((content['paiements'] as List?) ?? const []).cast<Map>()) {
        final code = '${p['moyen']}';
        collected[code] = (collected[code] ?? 0) + _int(p['montant']) + _int(p['ecart_arrondi']);
      }
    }
    for (final r in s.returns) {
      final date = DateTime.tryParse('${r['cree_le']}');
      if (date == null || !inPeriod(dayOf(date))) continue;
      final byMethod = s.refundMethods['${r['uuid']}'] ?? {context.cashCode: _int((r['contenu'] as Map)['montant'])};
      if ((r['contenu'] as Map)['type'] == 'annulation') {
        cancellations++;
        cancelled += byMethod.values.fold(0, (a, b) => a + b);
      }
      byMethod.forEach((code, amount) => refunded[code] = (refunded[code] ?? 0) + amount);
    }

    if (opened == null) continue;
    final day = dayOf(opened);
    if (!inPeriod(day)) continue;
    final session = s.uuid;
    CashBookRow row(String nature, String method, {int cashIn = 0, int cashOut = 0, int others = 0, DateTime? at, int? expected, int? counted, int? difference}) =>
        CashBookRow(day: day, date: at ?? opened, sessionUuid: session, terminal: context.terminalName, nature: nature, method: method,
            cashIn: cashIn, cashOut: cashOut, others: others, expected: expected, counted: counted, difference: difference);

    if (s.float != null) rows.add(row('Ouverture de session (fond de caisse)', cashName, cashIn: s.float!));
    // Ventes par moyen : espèces au tiroir, autres moyens hors tiroir.
    final sold = <String, int>{};
    for (final sale in s.sales) {
      for (final p in (((sale['contenu'] as Map)['paiements'] as List?) ?? const []).cast<Map>()) {
        final code = '${p['moyen']}';
        sold[code] = (sold[code] ?? 0) + _int(p['montant']) + _int(p['ecart_arrondi']);
      }
    }
    final back = <String, int>{};
    for (final r in s.returns) {
      final byMethod = s.refundMethods['${r['uuid']}'] ?? {context.cashCode: _int((r['contenu'] as Map)['montant'])};
      byMethod.forEach((code, amount) => back[code] = (back[code] ?? 0) + amount);
    }
    for (final e in sold.entries.where((e) => cashCodes.contains(e.key))) {
      if (e.value != 0) rows.add(row('Ventes encaissées', names[e.key] ?? e.key, cashIn: e.value));
    }
    for (final e in back.entries.where((e) => cashCodes.contains(e.key))) {
      if (e.value != 0) rows.add(row('Remboursements de retours et annulations', names[e.key] ?? e.key, cashOut: e.value));
    }
    for (final e in sold.entries.where((e) => !cashCodes.contains(e.key))) {
      if (e.value != 0) rows.add(row('Ventes encaissées', names[e.key] ?? e.key, others: e.value));
    }
    for (final e in back.entries.where((e) => !cashCodes.contains(e.key))) {
      if (e.value != 0) rows.add(row('Remboursements de retours et annulations', names[e.key] ?? e.key, others: -e.value));
    }
    // Transferts de fin de journée (lot 16) : sortie du moyen, entrée des espèces.
    for (final t in s.transfers) {
      final at = DateTime.tryParse('${t['cree_le']}');
      for (final l in ((((t['contenu'] as Map)['lignes']) as List?) ?? const []).cast<Map>()) {
        final name = names['${l['moyen']}'] ?? '${l['moyen']}';
        rows.add(row('Transfert vers les espèces ($name)', cashName, cashIn: _int(l['montant']), at: at));
        rows.add(row('Transfert vers les espèces', name, others: -_int(l['montant']), at: at));
      }
    }
    if (s.closed) {
      final cashSold = sold.entries.where((e) => cashCodes.contains(e.key)).fold(0, (a, e) => a + e.value);
      final cashBack = back.entries.where((e) => cashCodes.contains(e.key)).fold(0, (a, e) => a + e.value);
      final expected = s.float == null ? null : s.float! + cashSold - cashBack + s.transferredToCash;
      final counted = (s.closure!['contenu'] as Map)['compte'] as int?;
      rows.add(row('Clôture (poste)', cashName,
          at: s.closedAt, expected: expected, counted: counted, difference: expected == null || counted == null ? null : counted - expected));
    } else {
      rows.add(row('Session ouverte : aucune clôture archivée', cashName));
    }
  }
  final codes = {...collected.keys, ...refunded.keys};
  return CashBook(
    from: from,
    to: to,
    rows: rows,
    methods: [for (final c in codes) CashBookMethod(names[c] ?? c, collected[c] ?? 0, refunded[c] ?? 0)],
    salesCount: salesCount,
    salesAmount: salesAmount,
    cancellationsCount: cancellations,
    cancellationsAmount: cancelled,
  );
}

/// Contrôle d'une période du livre : `du` ≤ `au`, au plus [maxDays] jours inclus ; pour le livre en ligne, pas plus
/// de 30 jours en arrière ni dans le futur. Null si correcte, sinon le message à afficher.
String? cashBookPeriodError(String from, String to, String today, {bool online = false, int maxDays = 30}) {
  DateTime d(String s) => DateTime.utc(int.parse(s.substring(0, 4)), int.parse(s.substring(5, 7)), int.parse(s.substring(8, 10)));
  final start = d(from), end = d(to), now = d(today);
  if (end.isBefore(start)) return 'La date de fin précède la date de début.';
  if (online) {
    if (end.difference(start).inDays + 1 > maxDays) return 'Période de $maxDays jours au plus pour le livre en ligne.';
    if (now.difference(start).inDays > maxDays) return 'Le livre en ligne remonte à $maxDays jours au plus.';
    if (end.isAfter(now)) return 'La période ne peut pas finir après aujourd’hui.';
  }
  return null;
}

/// Jour `AAAA-MM-JJ` décalé de [days] jours.
String shiftDay(String day, int days) {
  final d = DateTime.utc(int.parse(day.substring(0, 4)), int.parse(day.substring(5, 7)), int.parse(day.substring(8, 10))).add(Duration(days: days));
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}
