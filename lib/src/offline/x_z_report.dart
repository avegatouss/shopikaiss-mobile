/// Documents de clôture imprimés par la caisse hors ligne, sans réseau : pré-X, Z de session (détaillé ou court) et
/// pré-Z du terminal. Même mise en page que le web (docs/mobile/IMPRESSION-X-Z.md §3 et §5 ; `DetailCloture`, `ModeleZ`,
/// `TicketZ` et `layoutTicket` de shopikaiss-web) : un bloc de détail calculé sur les opérations du terminal, un modèle,
/// une structure « ticket » (`kind`, `titre`, `version`, `provisoire`, `duplicata`, `rubriques`, `mentions`) rendue en
/// texte à 32 ou 48 colonnes.
///
/// Rien n'est envoyé au serveur : l'audit des éditions et la remontée du détail figé ne sont pas encore au contrat.
/// Le Z journalier (`z-jour`) n'est pas produit ici : la journée de caisse est un objet de la boutique (sessions de tous
/// les postes, numéro, clôture par le responsable) qu'aucune donnée du terminal ne décrit.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../printer/escpos.dart';
import 'models.dart';
import 'money.dart';

/// Types de document (`data-ticket-kind`).
abstract final class ZKind {
  static const preX = 'pre-x';
  static const preZ = 'pre-z';
  static const session = 'z-session';
  static const day = 'z-jour';

  /// Titres imprimés (`ModeleZ::TITRES`).
  static const titles = {
    session: 'Z — CLÔTURE DE SESSION',
    day: 'Z JOURNALIER',
    preX: 'PRÉ-X — DOCUMENT PROVISOIRE, NON CLÔTURÉ',
    preZ: 'PRÉ-Z — DOCUMENT PROVISOIRE, NON CLÔTURÉ',
  };
}

/// Versions imprimées (`TicketZ::VERSIONS`).
abstract final class ZVersion {
  static const detailed = 'detailed';
  static const short = 'short';
  static const labels = {detailed: 'Détaillé', short: 'Court'};
}

/// Nombre d'articles du classement des meilleures ventes (Z court).
const zTop = 5;

/// Une session de caisse telle que la file du terminal la décrit : ouverture (locale ou du serveur), ventes, retours et
/// clôture éventuelle. Les opérations sont au format v2 (`type`, `cree_le`, `operateur_id`, `contenu`).
class ClosureSession {
  ClosureSession({this.uuid, this.openedAt, this.openerId, this.float});

  String? uuid;
  DateTime? openedAt;
  int? openerId;

  /// Fond initial : connu seulement si la session a été ouverte sur ce terminal.
  int? float;
  final List<Map> sales = [];
  final List<Map> returns = [];

  /// Annulation d'une vente restaurant (`resto_remboursement`, lot R-5) : rendue sur les moyens de la vente, par uuid de
  /// l'opération puis par moyen. Un retour (de la caisse ou restaurant) est rendu en espèces.
  final Map<String, Map<String, int>> refundMethods = {};

  /// Opération de clôture (`cloture_session`), ou null tant que la session est ouverte.
  Map? closure;

  bool get closed => closure != null;
  DateTime? get closedAt => closure == null ? null : _date(closure!['cree_le']);
  int? get closerId => closure == null ? null : int.tryParse('${closure!['operateur_id']}');
  bool get isEmpty => sales.isEmpty && returns.isEmpty && closure == null && float == null;

  /// Dates des opérations de la session (ouverture comprise).
  Iterable<DateTime> get dates sync* {
    if (openedAt != null) yield openedAt!;
    for (final o in [...sales, ...returns, ?closure]) {
      if (_date(o['cree_le']) case final d?) yield d;
    }
  }
}

/// Faits de clôture lus par le moteur : sessions du terminal dans l'ordre chronologique, session ouverte, et ce qu'il
/// faut du catalogue pour classer les articles.
class ClosureFacts {
  ClosureFacts({required this.sessions, this.openSessionUuid, this.categories = const {}, this.productNames = const {}});

  final List<ClosureSession> sessions;

  /// Session ouverte du terminal (null : aucune).
  final String? openSessionUuid;

  /// Catégorie par produit (UUID) ; absente : « Sans catégorie ».
  final Map<String, String> categories;

  /// Nom du produit (UUID), pour les lignes de retour (quantités en unité de base, sans conditionnement).
  final Map<String, String> productNames;

  ClosureSession? get openSession => openSessionUuid == null ? null : sessions.where((s) => !s.closed && s.uuid == openSessionUuid).lastOrNull;

  /// Dernière session clôturée sur ce terminal.
  ClosureSession? get lastClosed => sessions.where((s) => s.closed).lastOrNull;

  /// Sessions touchées le jour [day] (date locale), plus la session ouverte.
  List<ClosureSession> sessionsOn(DateTime day) => [
    for (final s in sessions)
      if (s == openSession || s.dates.any((d) => d.year == day.year && d.month == day.month && d.day == day.day)) s,
  ];

  Map<String, Map> get _salesByUuid => {for (final s in sessions) for (final sale in s.sales) '${sale['uuid']}': sale};
}

DateTime? _date(Object? raw) => raw is String ? DateTime.tryParse(raw)?.toLocal() : null;

/// Découpe les opérations du terminal (ordre chronologique, opérations rejetées exclues) en sessions : une ouverture ou
/// une vente d'une autre session commence une session, une clôture la termine. [openSession] : session ouverte du
/// terminal (`session_uuid`, `operateur_id`, `ouverte_le`), ajoutée vide si aucune opération ne la porte encore.
List<ClosureSession> sessionsFromOperations(List<Map> operations, {Map? openSession}) {
  final sessions = <ClosureSession>[];
  ClosureSession? current;
  ClosureSession start({String? uuid, DateTime? at, int? opener, int? float}) {
    final session = ClosureSession(uuid: uuid, openedAt: at, openerId: opener, float: float);
    sessions.add(session);
    return session;
  }

  final sales = <Object?, Map>{};
  for (final o in operations) {
    final content = (o['contenu'] as Map?) ?? const {};
    if (o['type'] == 'vente') sales[o['uuid']] = o;
    switch (o['type']) {
      case 'ouverture_session':
        current = start(uuid: '${o['uuid']}', at: _date(o['cree_le']), opener: int.tryParse('${o['operateur_id']}'), float: content['fond'] as int?);
      case 'vente':
        final uuid = content['session_uuid'] as String?;
        if (current == null || current.closed || (uuid != null && current.uuid != null && current.uuid != uuid)) current = start(uuid: uuid);
        current.uuid ??= uuid;
        current.sales.add(o);
      case 'retour' || 'resto_remboursement':
        if (current == null || current.closed) current = start();
        current.returns.add(o);
        final sale = content['type'] == 'annulation' ? sales[(content['vente_ref'] as Map?)?['operation_uuid']] : null;
        if (sale != null) {
          final methods = current.refundMethods['${o['uuid']}'] = <String, int>{};
          for (final p in ((sale['contenu'] as Map)['paiements'] as List? ?? const []).cast<Map>()) {
            methods.update('${p['moyen']}', (v) => v + _int(p['montant']), ifAbsent: () => _int(p['montant']));
          }
        }
      case 'cloture_session':
        final uuid = content['session_uuid'] as String?;
        if (current == null || current.closed || (uuid != null && current.uuid != null && current.uuid != uuid)) current = start(uuid: uuid);
        current.uuid ??= uuid;
        current.closure = o;
    }
  }
  final open = openSession?['session_uuid'] as String?;
  if (open != null) {
    var session = sessions.where((s) => !s.closed && s.uuid == open).lastOrNull;
    session ??= start(uuid: open);
    session.openedAt ??= _date(openSession!['ouverte_le']);
    session.openerId ??= int.tryParse('${openSession!['operateur_id'] ?? ''}');
  }
  return sessions;
}

// ---------------------------------------------------------------------------------------------------------------------
// Bloc de détail (DetailCloture, version 1)
// ---------------------------------------------------------------------------------------------------------------------

/// Quantité lisible (`QuantiteLibelle::affiche`) : « 2 », « 1,25 », « 2 500 ».
String zQuantity(BigInt micros) {
  final text = formatMicros(micros.abs());
  final parts = text.split('.');
  return '${micros.isNegative ? '-' : ''}${_group(parts[0])}${parts.length > 1 ? ',${parts[1]}' : ''}';
}

String _group(String digits) {
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(' ');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// Montant entier groupé par milliers (`Fcfa::format`), signe moins ASCII.
String zAmount(int amount) => '${amount < 0 ? '-' : ''}${_group(amount.abs().toString())}';

int _int(Object? v) => (v as num?)?.toInt() ?? 0;

/// Vente retenue au chiffre d'affaires : une vente réglée par pass est « hors chiffre d'affaires ».
bool _counted(Map sale) => ((sale['contenu'] as Map)['passages'] as List? ?? const []).isEmpty;

/// Bloc de détail des ventes et retours de [sessions] : synthèse, encaissements par moyen, articles par catégorie,
/// top 5, retours détaillés, remboursements par moyen, TVA par taux. [methodNames] : nom des moyens par code ;
/// [cashCode] : code du moyen espèces (remboursement des retours hors ligne).
Map<String, dynamic> closureDetail(ClosureFacts facts, List<ClosureSession> sessions, {required Map<String, String> methodNames, String cashCode = 'especes'}) {
  final sales = [for (final s in sessions) for (final sale in s.sales) if (_counted(sale)) sale];
  final lines = <Map<String, dynamic>>[];
  for (final sale in sales) {
    for (final l in ((sale['contenu'] as Map)['lignes'] as List).cast<Map>()) {
      final amount = _int(l['total']);
      final discount = _int(l['remise']);
      final value = amount + discount;
      final product = '${l['produit_uuid']}';
      lines.add({
        'key': '$product|${l['conditionnement_uuid'] ?? ''}',
        'label': '${l['libelle']}',
        'category': facts.categories[product],
        'quantity': parseMicros('${l['quantite']}') ?? BigInt.zero,
        'unit_price': _int(l['prix_unitaire']),
        'value': value,
        'discount': discount,
        'amount': amount,
        'offered': l['offert'] == true || (amount == 0 && value > 0),
      });
    }
  }
  final articles = _articles(lines);
  final returns = _returns(facts, sessions);
  final payments = <String, Map<String, dynamic>>{};
  for (final sale in sales) {
    for (final p in ((sale['contenu'] as Map)['paiements'] as List? ?? const []).cast<Map>()) {
      final code = '${p['moyen']}';
      final row = payments.putIfAbsent(code, () => {'code': code, 'label': methodNames[code] ?? code, 'sales': <String>{}, 'amount': 0});
      (row['sales'] as Set<String>).add('${sale['uuid']}');
      row['amount'] = (row['amount'] as int) + _int(p['montant']);
    }
  }
  final refunds = <String, Map<String, dynamic>>{};
  for (final s in sessions) {
    for (final r in s.returns) {
      final content = r['contenu'] as Map;
      final code = content['remboursement'] == 'especes' || content['remboursement'] == null ? cashCode : '${content['remboursement']}';
      // Annulation restaurant (R-5) : sur les moyens de la vente ; sinon en espèces.
      for (final e in (s.refundMethods['${r['uuid']}'] ?? {code: _int(content['montant'])}).entries) {
        final row = refunds.putIfAbsent(e.key, () => {'code': e.key, 'label': methodNames[e.key] ?? e.key, 'amount': 0});
        row['amount'] = (row['amount'] as int) + e.value;
      }
    }
  }
  final vat = <String, Map<String, dynamic>>{};
  for (final sale in sales) {
    final content = sale['contenu'] as Map;
    final totals = content['totaux'] as Map;
    if (_int(totals['tva']) == 0) continue;
    final rate = formatMicros(parseMicros('${(content['tva'] as Map?)?['taux'] ?? '0'}') ?? BigInt.zero);
    final row = vat.putIfAbsent(rate, () => {'rate': rate, 'base': 0, 'vat': 0, 'ttc': 0});
    row['base'] = (row['base'] as int) + _int(totals['base_ht']);
    row['vat'] = (row['vat'] as int) + _int(totals['tva']);
    row['ttc'] = (row['ttc'] as int) + _int(totals['a_payer']) - _int(content['livraison']);
  }
  final vatRows = vat.values.toList()..sort((a, b) => (parseMicros(a['rate'] as String) ?? BigInt.zero).compareTo(parseMicros(b['rate'] as String) ?? BigInt.zero));
  return {
    'version': 1,
    'summary': _summary(sales, articles, returns.totals),
    'payments': [for (final row in payments.values) {'code': row['code'], 'label': row['label'], 'count': (row['sales'] as Set).length, 'amount': row['amount']}],
    'articles': articles,
    'top': _top(lines),
    'returns': returns.rows,
    'refunds': refunds.values.toList(),
    'vat': vatRows,
  };
}

/// Montant décroissant, puis quantité décroissante, puis libellé.
int _best(Map a, Map b) {
  final byAmount = (b['amount'] as int).compareTo(a['amount'] as int);
  if (byAmount != 0) return byAmount;
  final byQuantity = (b['quantity'] as BigInt).compareTo(a['quantity'] as BigInt);
  return byQuantity != 0 ? byQuantity : (a['label'] as String).compareTo(b['label'] as String);
}

Map<String, dynamic> _articles(List<Map<String, dynamic>> lines) {
  final categories = <String, Map<String, dynamic>>{};
  for (final line in lines) {
    final name = line['category'] as String?;
    final key = name == null || name.isEmpty ? 'none' : 'category:$name';
    final category = categories.putIfAbsent(
      key,
      () => {'key': key, 'label': key == 'none' ? 'Sans catégorie' : name, 'rows': <String, Map<String, dynamic>>{}, 'lines': 0, 'quantity': BigInt.zero, 'value': 0, 'discount': 0, 'amount': 0},
    );
    final rowKey = '${line['key']}|${line['unit_price']}|${line['offered'] == true ? 'o' : ''}|${line['label']}';
    final row = (category['rows'] as Map<String, Map<String, dynamic>>).putIfAbsent(
      rowKey,
      () => {'label': line['label'], 'packaging': null, 'quantity': BigInt.zero, 'unit_price': line['unit_price'], 'value': 0, 'discount': 0, 'amount': 0, 'offered': line['offered']},
    );
    row['quantity'] = (row['quantity'] as BigInt) + (line['quantity'] as BigInt);
    category['quantity'] = (category['quantity'] as BigInt) + (line['quantity'] as BigInt);
    for (final field in ['value', 'discount', 'amount']) {
      row[field] = (row[field] as int) + (line[field] as int);
      category[field] = (category[field] as int) + (line[field] as int);
    }
    category['lines'] = (category['lines'] as int) + 1;
  }
  final totals = <String, dynamic>{'lines': 0, 'quantity': BigInt.zero, 'value': 0, 'discount': 0, 'amount': 0, 'offered_count': 0, 'offered_value': 0};
  final list = <Map<String, dynamic>>[];
  for (final category in categories.values) {
    final rows = (category['rows'] as Map<String, Map<String, dynamic>>).values.toList()..sort(_best);
    for (final row in rows) {
      if (row['offered'] == true) {
        totals['offered_count'] = (totals['offered_count'] as int) + 1;
        totals['offered_value'] = (totals['offered_value'] as int) + (row['value'] as int);
      }
    }
    totals['lines'] = (totals['lines'] as int) + (category['lines'] as int);
    totals['quantity'] = (totals['quantity'] as BigInt) + (category['quantity'] as BigInt);
    for (final field in ['value', 'discount', 'amount']) {
      totals[field] = (totals[field] as int) + (category[field] as int);
    }
    list.add({...category, 'rows': rows});
  }
  list.sort((a, b) {
    final none = (a['key'] == 'none' ? 1 : 0).compareTo(b['key'] == 'none' ? 1 : 0);
    return none != 0 ? none : (a['label'] as String).toLowerCase().compareTo((b['label'] as String).toLowerCase());
  });
  return {'categories': list, 'totals': totals};
}

/// Meilleures ventes : par article et conditionnement, tous prix confondus.
List<Map<String, dynamic>> _top(List<Map<String, dynamic>> lines) {
  final rows = <String, Map<String, dynamic>>{};
  for (final line in lines) {
    final row = rows.putIfAbsent('${line['key']}|${line['label']}', () => {'label': line['label'], 'quantity': BigInt.zero, 'amount': 0});
    row['quantity'] = (row['quantity'] as BigInt) + (line['quantity'] as BigInt);
    row['amount'] = (row['amount'] as int) + (line['amount'] as int);
  }
  return (rows.values.toList()..sort(_best)).take(zTop).toList();
}

({List<Map<String, dynamic>> rows, Map<String, int> totals}) _returns(ClosureFacts facts, List<ClosureSession> sessions) {
  final sales = facts._salesByUuid;
  final rows = <Map<String, dynamic>>[];
  final totals = {'returns_count': 0, 'returns_amount': 0, 'cancellations_count': 0, 'cancellations_amount': 0};
  for (final r in [for (final s in sessions) ...s.returns]) {
    final content = r['contenu'] as Map;
    final sale = sales['${(content['vente_ref'] as Map?)?['operation_uuid']}'];
    final saleLines = {for (final l in (((sale?['contenu'] as Map?)?['lignes'] as List?) ?? const []).cast<Map>()) '${l['ligne_uuid']}': l};
    // Annulation d'une vente restaurant (R-5) : toute la vente, ses lignes détaillées (DetailCloture::retours du web).
    final cancellation = r['type'] == 'resto_remboursement' && content['type'] == 'annulation';
    if (cancellation) {
      rows.add({
        'kind': 'cancellation',
        'sale': (sale?['contenu'] as Map?)?['numero_local'],
        'at': r['cree_le'],
        'amount': _int(content['montant']),
        'reason': '${content['motif'] ?? ''}',
        'lines': [
          for (final l in saleLines.values) {'label': '${l['libelle']}', 'quantity': parseMicros('${l['quantite']}') ?? BigInt.zero, 'amount': _int(l['total'])},
        ],
      });
      totals['cancellations_count'] = totals['cancellations_count']! + 1;
      totals['cancellations_amount'] = totals['cancellations_amount']! + _int(content['montant']);
      continue;
    }
    rows.add({
      'kind': 'return',
      'sale': (sale?['contenu'] as Map?)?['numero_local'],
      'at': r['cree_le'],
      'amount': _int(content['montant']),
      'reason': '${content['motif'] ?? ''}',
      'lines': [
        for (final l in ((content['lignes'] as List?) ?? const []).cast<Map>())
          {
            'label': facts.productNames['${saleLines['${l['ligne_uuid']}']?['produit_uuid']}'] ?? '${saleLines['${l['ligne_uuid']}']?['libelle'] ?? 'Article'}',
            'quantity': parseMicros('${l['quantite']}') ?? BigInt.zero,
            // Montant par ligne non archivé par le retour hors ligne (seul le total l'est) : rien à droite.
            'amount': null,
          },
      ],
    });
    totals['returns_count'] = totals['returns_count']! + 1;
    totals['returns_amount'] = totals['returns_amount']! + _int(content['montant']);
  }
  return (rows: rows, totals: totals);
}

Map<String, dynamic> _summary(List<Map> sales, Map<String, dynamic> articles, Map<String, int> returns) {
  int sum(int Function(Map content) of) => sales.fold(0, (total, sale) => total + of(sale['contenu'] as Map));
  final tickets = sales.length;
  final revenue = sum((c) => _int((c['totaux'] as Map)['a_payer']) - _int(c['livraison']));
  final totals = articles['totals'] as Map;
  final lineDiscounts = totals['discount'] as int;
  final globalDiscounts = sum((c) => _int(c['remise_globale']));
  final returned = returns['returns_amount'] ?? 0;
  final cancelled = returns['cancellations_amount'] ?? 0;
  return {
    'tickets': tickets,
    'revenue': revenue,
    'delivery_fees': sum((c) => _int(c['livraison'])),
    'payable': sum((c) => _int((c['totaux'] as Map)['a_payer'])),
    'credit': 0,
    'average_basket': tickets == 0 ? 0 : divideHalfUp(BigInt.from(revenue), BigInt.from(tickets)).toInt(),
    'lines': totals['lines'],
    'quantity': totals['quantity'],
    'gross_value': totals['value'],
    'line_discounts': lineDiscounts,
    'global_discounts': globalDiscounts,
    'discounts': lineDiscounts + globalDiscounts,
    'offered_count': totals['offered_count'],
    'offered_value': totals['offered_value'],
    'ht': sum((c) => _int((c['totaux'] as Map)['base_ht'])),
    'vat': sum((c) => _int((c['totaux'] as Map)['tva'])),
    'returns_count': returns['returns_count'] ?? 0,
    'returns_amount': returned,
    'cancellations_count': returns['cancellations_count'] ?? 0,
    'cancellations_amount': cancelled,
    'net_after_returns': revenue - returned - cancelled,
  };
}

// ---------------------------------------------------------------------------------------------------------------------
// Modèle (ModeleZ) et structure ticket (TicketZ)
// ---------------------------------------------------------------------------------------------------------------------

/// Ligne « libellé … valeur » ; [value] affiché tel quel.
Map<String, dynamic> zValue(String label, String value, {bool bold = false}) => {'libelle': label, 'valeur': value, if (bold) 'gras': true};

/// Ligne « libellé … montant » (`montant` en chaîne d'entier) ; [sign] : un montant positif s'imprime « +… ».
Map<String, dynamic> zMoney(String label, int amount, {bool bold = false, bool sign = false}) =>
    {'libelle': label, 'montant': '$amount', if (bold) 'gras': true, if (sign) 'signe': true};

Map<String, dynamic> _moneyOrDash(String label, int? amount, {bool bold = false, bool sign = false}) =>
    amount == null ? zValue(label, '—', bold: bold) : zMoney(label, amount, bold: bold, sign: sign);

/// « 26/10/2026 à 08:00 » (`StoreClock::display`).
String zDate(DateTime? date) {
  if (date == null) return '—';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(date.day)}/${two(date.month)}/${date.year} à ${two(date.hour)}:${two(date.minute)}';
}

String _day(DateTime date) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(date.day)}/${two(date.month)}/${date.year}';
}

/// Contexte d'impression tiré du référentiel : boutique, terminal, moyens, caissiers.
class ZContext {
  ZContext({required this.storeName, required this.terminalName, required this.methods, required this.operatorName, this.currency = 'FCFA'});

  /// Contexte depuis le référentiel du terminal.
  factory ZContext.of(Snapshot snapshot) => ZContext(
    storeName: snapshot.store.name.isNotEmpty ? snapshot.store.name : snapshot.store.legalName,
    terminalName: snapshot.terminal.name,
    methods: snapshot.methods,
    operatorName: (id) => snapshot.operatorById(id)?.name ?? '',
    currency: snapshot.store.currency,
  );

  final String storeName;
  final String terminalName;
  final List<PaymentMethodInfo> methods;
  final String Function(int? id) operatorName;
  final String currency;

  Map<String, String> get methodNames => {for (final m in methods) m.code: m.name};
  Set<String> get cashCodes => {for (final m in methods) if (m.isCash) m.code};
  String get cashCode => cashCodes.firstOrNull ?? 'especes';
}

/// Espèces d'une session : fond, ventes espèces (arrondi de caisse compris), remboursements, attendu, compté, écart.
({int? float, int salesCash, int refunds, int? expected, int? counted, int? difference}) _cash(ClosureSession s, ZContext context) {
  final cash = context.cashCodes.isEmpty ? {'especes'} : context.cashCodes;
  var salesCash = 0;
  for (final sale in s.sales) {
    for (final p in ((sale['contenu'] as Map)['paiements'] as List? ?? const []).cast<Map>()) {
      if (cash.contains(p['moyen'])) salesCash += _int(p['montant']) + _int(p['ecart_arrondi']);
    }
  }
  // Retours en espèces ; annulation restaurant (R-5) : la part espèces des paiements de la vente.
  final refunds = s.returns.fold<int>(0, (sum, r) {
    final methods = s.refundMethods['${r['uuid']}'];
    if (methods == null) return sum + _int((r['contenu'] as Map)['montant']);
    return sum + methods.entries.where((e) => cash.contains(e.key)).fold<int>(0, (t, e) => t + e.value);
  });
  final expected = s.float == null ? null : s.float! + salesCash - refunds;
  final counted = (s.closure?['contenu'] as Map?)?['compte'] as int?;
  return (float: s.float, salesCash: salesCash, refunds: refunds, expected: expected, counted: counted, difference: counted == null || expected == null ? null : counted - expected);
}

/// Contrôle par moyen (hors espèces) d'une session clôturée : théorique, constaté, écart.
List<Map<String, dynamic>> _methodControl(List<ClosureSession> sessions, ZContext context) {
  final theoretical = <String, int>{};
  final counted = <String, int>{};
  for (final s in sessions) {
    for (final sale in s.sales) {
      for (final p in ((sale['contenu'] as Map)['paiements'] as List? ?? const []).cast<Map>()) {
        final code = '${p['moyen']}';
        if (context.cashCodes.contains(code) || !_counted(sale)) continue;
        theoretical[code] = (theoretical[code] ?? 0) + _int(p['montant']) + _int(p['ecart_arrondi']);
      }
    }
    for (final c in (((s.closure?['contenu'] as Map?)?['comptage'] as List?) ?? const []).cast<Map>()) {
      final code = '${c['moyen']}';
      theoretical.putIfAbsent(code, () => 0);
      counted[code] = (counted[code] ?? 0) + _int(c['montant']);
    }
  }
  final names = context.methodNames;
  return [
    for (final e in theoretical.entries) ...[
      zMoney('${names[e.key] ?? e.key} théorique', e.value),
      if (counted[e.key] case final c?) ...[zMoney('${names[e.key] ?? e.key} constaté', c), zMoney('${names[e.key] ?? e.key} écart', c - e.value, bold: true, sign: true)],
    ],
  ];
}

const _localMention = 'Caisse locale : chiffres de ce terminal. Le Z de la boutique fait foi après synchronisation.';

/// Modèle d'un pré-X ([ZKind.preX], session ouverte, à l'aveugle) ou d'un Z de session ([ZKind.session], session
/// clôturée sur ce terminal ; [duplicate] pour une réimpression).
Map<String, dynamic> sessionZModel(ClosureFacts facts, ClosureSession session, ZContext context, {required String kind, required DateTime now, bool duplicate = false}) {
  final blind = kind == ZKind.preX;
  final opener = context.operatorName(session.openerId);
  final closer = session.closerId == null ? null : context.operatorName(session.closerId);
  final header = <Map<String, dynamic>>[
    if (context.terminalName.isNotEmpty) zValue('Terminal', context.terminalName),
    zValue('Caissier', opener),
    if (closer != null && closer.isNotEmpty && closer != opener) zValue('Clôturé par', closer),
    zValue('Ouverte', zDate(session.openedAt)),
    if (session.closedAt != null) zValue('Clôturée', zDate(session.closedAt)),
  ];
  final cash = _cash(session, context);
  final lines = <Map<String, dynamic>>[_moneyOrDash('Fond initial', cash.float), zMoney('Ventes espèces', cash.salesCash)];
  if (cash.refunds != 0) lines.add(zMoney('Remboursements', -cash.refunds));
  if (!blind) lines.add(_moneyOrDash('Théorique', cash.expected, bold: true));
  if (cash.counted != null) {
    lines.add(zMoney('Compté', cash.counted!, bold: true));
    lines.add(_moneyOrDash('Écart', cash.difference, bold: true, sign: true));
  }
  final comment = (session.closure?['contenu'] as Map?)?['commentaire'] as String?;
  final detail = closureDetail(facts, [session], methodNames: context.methodNames, cashCode: context.cashCode);
  return _assemble(kind, context.storeName, null, header, detail, now: now, duplicate: duplicate, parts: {
    'especes': lines,
    'ecart': cash.difference,
    'controle_moyens': blind ? <Map<String, dynamic>>[] : _methodControl([session], context),
  }, mentions: [
    if (blind) 'Comptage à l’aveugle : l’attendu en caisse et l’écart figurent au Z de clôture.',
    if (comment != null && comment.isNotEmpty) 'Commentaire : $comment',
    if (cash.float == null) 'Fond initial inconnu de ce terminal (session ouverte en ligne) : attendu et écart au Z de la boutique.',
    _localMention,
  ]);
}

/// Modèle d'un pré-Z du terminal pour le jour [day] : ses sessions du jour (la session ouverte comprise, comptée à
/// l'aveugle), détail des ventes de toutes, espèces totalisées sur les sessions clôturées.
Map<String, dynamic> dayZModel(ClosureFacts facts, ZContext context, {required DateTime day, required DateTime now}) {
  final sessions = facts.sessionsOn(day);
  final closed = [for (final s in sessions) if (s.closed) s];
  final header = <Map<String, dynamic>>[
    if (context.terminalName.isNotEmpty) zValue('Point de vente', context.terminalName),
    zValue('Journée du', _day(day)),
    zValue('Sessions', '${sessions.length}'),
  ];
  final blocks = <Map<String, dynamic>>[];
  int? total(int? Function(({int? float, int salesCash, int refunds, int? expected, int? counted, int? difference}) c) of) {
    if (closed.isEmpty) return null;
    var sum = 0;
    for (final s in closed) {
      final v = of(_cash(s, context));
      if (v == null) return null;
      sum += v;
    }
    return sum;
  }

  for (final s in sessions) {
    final cash = _cash(s, context);
    final who = [context.terminalName, context.operatorName(s.openerId)].where((t) => t.isNotEmpty).join(' · ');
    blocks.add({
      'titre': 'Session $who'.trim(),
      'lignes': [
        zValue('Ouverture', zDate(s.openedAt)),
        zValue('Clôture', s.closed ? zDate(s.closedAt) : 'en cours'),
        _moneyOrDash('Fond', cash.float),
        _moneyOrDash('Théorique', s.closed ? cash.expected : null),
        _moneyOrDash('Compté', cash.counted),
        _moneyOrDash('Écart', cash.difference, bold: true, sign: true),
      ],
    });
  }
  final difference = total((c) => c.difference);
  final open = [for (final s in sessions) if (!s.closed) s];
  final detail = closureDetail(facts, sessions, methodNames: context.methodNames, cashCode: context.cashCode);
  return _assemble(ZKind.preZ, context.storeName, null, header, detail, now: now, parts: {
    'especes': [
      _moneyOrDash('Fond', total((c) => c.float)),
      _moneyOrDash('Théorique', total((c) => c.expected), bold: true),
      _moneyOrDash('Compté', total((c) => c.counted), bold: true),
      _moneyOrDash('Écart', difference, bold: true, sign: true),
    ],
    'ecart': difference,
    'sessions': blocks,
    'controle_moyens': _methodControl(closed, context),
  }, mentions: [
    if (open.isNotEmpty)
      '${open.length} session(s) encore ouverte(s), non comptée(s) ici : ${[for (final s in open) '${[context.terminalName, context.operatorName(s.openerId)].where((t) => t.isNotEmpty).join(' · ')} depuis le ${zDate(s.openedAt)}'].join(', ')}.',
    'Ce terminal seulement : le Z journalier de la boutique regroupe tous les postes.',
    _localMention,
  ]);
}

Map<String, dynamic> _assemble(
  String kind,
  String store,
  String? number,
  List<Map<String, dynamic>> header,
  Map<String, dynamic> detail, {
  required DateTime now,
  bool duplicate = false,
  required Map<String, dynamic> parts,
  required List<String> mentions,
}) {
  final provisional = kind == ZKind.preX || kind == ZKind.preZ;
  final summary = {...detail['summary'] as Map<String, dynamic>, 'cash_difference': parts['ecart']};
  final edited = zDate(now);
  return {
    'type': kind,
    'titre': '${ZKind.titles[kind]}${duplicate ? ' — DUPLICATA' : ''}',
    'boutique': store,
    'numero': number,
    'provisoire': provisional,
    'duplicata': duplicate,
    'edite_le': edited,
    'entete': [zValue(provisional ? 'Édité le' : (duplicate ? 'Réimprimé le' : 'Imprimé le'), edited, bold: provisional), ...header],
    'synthese': summary,
    'paiements': detail['payments'],
    'remboursements': detail['refunds'],
    'especes': parts['especes'] ?? const [],
    'sessions': parts['sessions'] ?? const [],
    'controle_moyens': parts['controle_moyens'] ?? const [],
    'articles': detail['articles'],
    'top': detail['top'],
    'retours': detail['returns'],
    'tva': detail['vat'],
    'mentions': [
      if (provisional) 'Document provisoire : rien n’est clôturé ni figé. Les chiffres définitifs sont ceux du Z.',
      if (duplicate) 'Duplicata : réimpression d’un Z déjà clôturé, chiffres figés à la clôture.',
      ...mentions,
      'Montants en FCFA',
    ],
  };
}

/// Structure « ticket » d'un document de clôture (`TicketZ::structure`), version [ZVersion.detailed] ou [ZVersion.short].
Map<String, dynamic> closureTicket(Map<String, dynamic> model, String version) {
  final short = version == ZVersion.short;
  final summary = model['synthese'] as Map<String, dynamic>;
  final sections = <Map<String, dynamic>>[
    {'titre': null, 'lignes': model['entete']},
  ];
  final payments = (model['paiements'] as List).cast<Map>();
  List<Map<String, dynamic>> paymentLines(bool total) {
    if (payments.isEmpty) return [zValue('Aucun encaissement', '')];
    return [
      for (final p in payments) zMoney('${p['label']} (${p['count']})', p['amount'] as int),
      if (total) zMoney('Total encaissé', payments.fold(0, (sum, p) => sum + (p['amount'] as int)), bold: true),
    ];
  }

  if (short) {
    sections.add({'titre': 'Résumé', 'lignes': _resume(summary)});
    sections.add({'titre': 'Par moyen de paiement', 'lignes': paymentLines(false)});
    final top = [for (final (i, row) in (model['top'] as List).cast<Map>().indexed) zMoney('${i + 1}. ${row['label']} x${zQuantity(row['quantity'] as BigInt)}', row['amount'] as int)];
    sections.add({'titre': 'Top $zTop des articles', 'lignes': top.isEmpty ? [zValue('Aucune vente', '')] : top});
  } else {
    sections.add({'titre': 'Synthèse', 'lignes': _synthesis(summary)});
    sections.add({'titre': 'Encaissements par moyen', 'lignes': paymentLines(true)});
    final refunds = (model['remboursements'] as List).cast<Map>();
    if (refunds.isNotEmpty) sections.add({'titre': 'Remboursements par moyen', 'lignes': [for (final r in refunds) zMoney('${r['label']}', -(r['amount'] as int))]});
    if ((model['especes'] as List).isNotEmpty) sections.add({'titre': 'Espèces', 'lignes': model['especes']});
    sections.addAll((model['sessions'] as List).cast<Map<String, dynamic>>());
    if ((model['controle_moyens'] as List).isNotEmpty) sections.add({'titre': 'Contrôle par moyen', 'lignes': model['controle_moyens']});
    final articles = model['articles'] as Map;
    final categories = (articles['categories'] as List).cast<Map>();
    for (final category in categories) {
      sections.add({'titre': (category['label'] as String).toUpperCase(), 'lignes': _category(category)});
    }
    if (categories.isNotEmpty) {
      final totals = articles['totals'] as Map;
      sections.add({
        'titre': 'Total des articles',
        'lignes': [
          zValue('Quantité vendue', zQuantity(totals['quantity'] as BigInt)),
          zMoney('Valeur avant remises', totals['value'] as int),
          zMoney('Remises sur articles', -(totals['discount'] as int)),
          zMoney('Total des articles', totals['amount'] as int, bold: true),
        ],
      });
    }
    sections.add({
      'titre': 'Remises et offerts',
      'lignes': [
        zMoney('Remises sur articles', -(summary['line_discounts'] as int)),
        zMoney('Remises sur ticket', -(summary['global_discounts'] as int)),
        zMoney('Articles offerts (${summary['offered_count']})', summary['offered_value'] as int),
      ],
    });
    final returns = (model['retours'] as List).cast<Map>();
    if (returns.isNotEmpty) sections.add({'titre': 'Retours et annulations', 'lignes': _returnLines(returns)});
    final vat = (model['tva'] as List).cast<Map>();
    if (vat.isNotEmpty) {
      sections.add({
        'titre': 'TVA',
        'lignes': [
          for (final row in vat) ...[zMoney('Base HT ${row['rate']} %', row['base'] as int), zMoney('TVA ${row['rate']} %', row['vat'] as int, bold: true)],
        ],
      });
    }
  }
  return {
    'kind': model['type'],
    'titre': model['titre'],
    'version': version,
    'boutique': {'nom': model['boutique']},
    'numero': model['numero'],
    'provisoire': model['provisoire'],
    'duplicata': model['duplicata'],
    'rubriques': sections,
    'mentions': [...(model['mentions'] as List).cast<String>(), 'Version ${ZVersion.labels[version]!.toLowerCase()}'],
    'devise': 'FCFA',
  };
}

List<Map<String, dynamic>> _resume(Map<String, dynamic> s) => [
  zMoney('Chiffre d’affaires TTC', s['revenue'] as int, bold: true),
  zValue('Nombre de ventes', '${s['tickets']}'),
  zMoney('Panier moyen', s['average_basket'] as int),
  zMoney('Retours (${s['returns_count']})', -(s['returns_amount'] as int)),
  zMoney('Annulations (${s['cancellations_count']})', -(s['cancellations_amount'] as int)),
  zMoney('Remises', -(s['discounts'] as int)),
  _moneyOrDash('Écart de caisse', s['cash_difference'] as int?, bold: true, sign: true),
];

List<Map<String, dynamic>> _synthesis(Map<String, dynamic> s) => [
  zValue('Nombre de ventes (tickets)', '${s['tickets']}'),
  zMoney('Chiffre d’affaires TTC', s['revenue'] as int, bold: true),
  if (s['delivery_fees'] != 0) zMoney('Livraison facturée', s['delivery_fees'] as int),
  if (s['payable'] != s['revenue']) zMoney('Montant des ventes', s['payable'] as int),
  zMoney('Panier moyen TTC', s['average_basket'] as int),
  zMoney('Valeur avant remises', s['gross_value'] as int),
  zMoney('Remises', -(s['discounts'] as int)),
  if ((s['offered_count'] as int) > 0) zMoney('Offerts (${s['offered_count']})', s['offered_value'] as int),
  zMoney('Retours (${s['returns_count']})', -(s['returns_amount'] as int)),
  zMoney('Annulations (${s['cancellations_count']})', -(s['cancellations_amount'] as int)),
  zMoney('Net après retours', s['net_after_returns'] as int, bold: true),
  if ((s['credit'] as int) > 0) zMoney('Dont à crédit', s['credit'] as int),
  if (s['vat'] != 0) ...[zMoney('Total HT', s['ht'] as int), zMoney('Total TVA', s['vat'] as int)],
  if (s['cash_difference'] != null) zMoney('Écart de caisse', s['cash_difference'] as int, bold: true, sign: true),
];

/// Un article sur deux lignes : nom (OFFERT le cas échéant), puis « quantité x prix unitaire … montant ».
List<Map<String, dynamic>> _category(Map category) => [
  for (final row in (category['rows'] as List).cast<Map>()) ...[
    zValue('${row['label']}', row['offered'] == true ? 'OFFERT' : ''),
    zMoney('  ${zQuantity(row['quantity'] as BigInt)} x ${zAmount(row['unit_price'] as int)}', row['amount'] as int),
    if ((row['discount'] as int) > 0 && row['offered'] != true) zMoney('  remise', -(row['discount'] as int)),
  ],
  zMoney('Sous-total (${zQuantity(category['quantity'] as BigInt)})', category['amount'] as int, bold: true),
];

List<Map<String, dynamic>> _returnLines(List<Map> returns) => [
  for (final r in returns) ...[
    zMoney('${r['kind'] == 'cancellation' ? 'Annulation' : 'Retour'}${r['sale'] != null ? ' ${r['sale']}' : ''}', -(r['amount'] as int), bold: true),
    for (final l in (r['lines'] as List).cast<Map>())
      l['amount'] == null
          ? zValue('  ${zQuantity(l['quantity'] as BigInt)} x ${l['label']}', '')
          : zMoney('  ${zQuantity(l['quantity'] as BigInt)} x ${l['label']}', l['amount'] as int),
    if ('${r['reason'] ?? ''}'.trim().isNotEmpty) zValue('  Motif', '${r['reason']}'),
  ],
];

// ---------------------------------------------------------------------------------------------------------------------
// Mise en page texte (layoutTicket du web) et ESC/POS
// ---------------------------------------------------------------------------------------------------------------------

/// Ticket mis en page : lignes sans accents à la largeur du rouleau ; [bold] et [large] (double taille) par indice.
class ZPrintout {
  const ZPrintout(this.lines, {this.bold = const {}, this.large = const {}});

  final List<String> lines;
  final Set<int> bold;
  final Set<int> large;

  String get text => lines.join('\n');

  /// Octets ESC/POS (police A, gras et double taille, coupe ; pas d'impulsion de tiroir).
  Uint8List bytes() {
    final out = BytesBuilder()..add(EscPos.init());
    for (var i = 0; i < lines.length; i++) {
      if (bold.contains(i)) out.add([EscPos.esc, 0x45, 1]);
      if (large.contains(i)) out.add([EscPos.gs, 0x21, 0x11]);
      out.add(latin1.encode('${lines[i].replaceAll(RegExp(r'[^\x20-\x7E]'), '?')}\n'));
      if (large.contains(i)) out.add([EscPos.gs, 0x21, 0x00]);
      if (bold.contains(i)) out.add([EscPos.esc, 0x45, 0]);
    }
    out.add(EscPos.feedAndCut(3));
    return out.toBytes();
  }
}

/// Texte imprimable en police ASCII : accents retirés, séparateurs typographiques du web remplacés.
String _ascii(String text) => stripAccents(text).replaceAll('·', '-').replaceAll('×', 'x').replaceAll('°', 'o').replaceAll('→', '->');

String _clean(Object? text) => '${text ?? ''}'.replaceAll(RegExp(r'[\r\n\t]+'), ' ').replaceAll(RegExp(r'\s{2,}'), ' ').trim();

String _truncate(String text, int size) {
  final chars = _clean(text).runes.toList();
  if (chars.length <= size) return String.fromCharCodes(chars);
  if (size <= 1) return String.fromCharCodes(chars.take(size));
  return '${String.fromCharCodes(chars.take(size - 1)).trimRight()}.';
}

String _labelValue(String label, String value, int columns) {
  final right = _clean(value);
  final room = columns - right.length - 1 < 0 ? 0 : columns - right.length - 1;
  final left = _truncate(label, room);
  final gap = columns - left.length - right.length;
  return '$left${' ' * (gap < 1 ? 1 : gap)}$right';
}

List<String> _wrap(String text, int columns) {
  final out = <String>[];
  for (final paragraph in text.split(RegExp(r'\r?\n'))) {
    var line = '';
    for (final word in _clean(paragraph).split(' ').where((w) => w.isNotEmpty)) {
      var rest = word;
      while (rest.length > columns) {
        if (line.isNotEmpty) {
          out.add(line);
          line = '';
        }
        out.add(rest.substring(0, columns));
        rest = rest.substring(columns);
      }
      if (rest.isEmpty) continue;
      if (line.isEmpty) {
        line = rest;
      } else if (line.length + 1 + rest.length <= columns) {
        line += ' $rest';
      } else {
        out.add(line);
        line = rest;
      }
    }
    if (line.isNotEmpty) out.add(line);
  }
  return out;
}

/// Ticket texte d'une structure de clôture (§3) : nom de la boutique en double taille, titre en gras, rubriques
/// séparées par des tirets, « libellé … valeur » (valeur jamais tronquée), mentions centrées. Accents retirés.
ZPrintout layoutClosureTicket(Map<String, dynamic> ticket, {required int paperWidth}) {
  final columns = EscPos.columnsFor(paperWidth);
  final currency = _clean(ticket['devise'] ?? 'FCFA').isEmpty ? 'FCFA' : _clean(ticket['devise']);
  final lines = <String>[];
  final bold = <int>{};
  final large = <int>{};
  void add(String text, {bool strong = false, bool big = false, bool center = false, int? width}) {
    final room = width ?? columns;
    final value = _ascii(text);
    if (strong) bold.add(lines.length);
    if (big) large.add(lines.length);
    lines.add(center ? '${' ' * ((room - value.length) ~/ 2).clamp(0, room)}$value' : value);
  }

  final name = _clean((ticket['boutique'] as Map?)?['nom']);
  if (name.isNotEmpty) {
    for (final l in _wrap(_ascii(name), columns ~/ 2)) {
      add(l, strong: true, big: true, center: true, width: columns ~/ 2);
    }
  }
  add('=' * columns);
  for (final l in _wrap(_ascii(_clean(ticket['titre'])), columns)) {
    add(l, strong: true, center: true);
  }
  final number = _clean(ticket['numero']);
  if (number.isNotEmpty) add(_labelValue('No', _ascii(number), columns));
  for (final section in ((ticket['rubriques'] as List?) ?? const []).cast<Map>()) {
    add('-' * columns);
    if (section['titre'] case final String title when title.isNotEmpty) add(_truncate(_ascii(title), columns), strong: true);
    for (final row in ((section['lignes'] as List?) ?? const []).cast<Map>()) {
      final amount = row['montant'];
      String value;
      if (amount != null) {
        final n = int.parse('$amount');
        value = '${row['signe'] == true && n > 0 ? '+' : ''}${zAmount(n)} $currency';
      } else {
        value = _clean(row['valeur']);
      }
      add(_labelValue(_ascii('${row['libelle']}'), _ascii(value), columns), strong: row['gras'] == true);
    }
  }
  for (final mention in ((ticket['mentions'] as List?) ?? const []).cast<String>()) {
    for (final l in _wrap(_ascii(mention), columns)) {
      add(l, center: true);
    }
  }
  return ZPrintout(lines, bold: bold, large: large);
}
