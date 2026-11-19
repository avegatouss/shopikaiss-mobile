import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/offline/models.dart';
import 'package:shopikaiss_terminal/src/offline/x_z_report.dart';

/// Opérations v2 d'une journée de restaurant (TBC) : session ouverte sur le terminal, ventes en espèces, Glovo et Yango,
/// un retour, une vente par pass (hors chiffre d'affaires), puis la clôture comptée.
Map<String, dynamic> _op(String uuid, String type, String at, Map<String, dynamic> content, {int operator = 7}) =>
    {'uuid': uuid, 'type': type, 'cree_le': at, 'operateur_id': '$operator', 'contenu': content};

Map<String, dynamic> _line(String uuid, String product, String label, String quantity, int price, {int discount = 0}) {
  final total = (double.parse(quantity) * price).round() - discount;
  return {'ligne_uuid': uuid, 'produit_uuid': product, 'conditionnement_uuid': null, 'libelle': label, 'quantite': quantity, 'quantite_base': quantity, 'prix_unitaire': price, 'remise': discount, 'total': total};
}

Map<String, dynamic> _sale(String uuid, String number, String at, List<Map<String, dynamic>> lines, List<(String, int)> payments, {String session = 'ouv-1', int globalDiscount = 0, List<Map>? passes}) {
  final payable = lines.fold<int>(0, (sum, l) => sum + (l['total'] as int)) - globalDiscount;
  final vat = (payable * 18 / 118).round();
  return _op(uuid, 'vente', at, {
    'numero_local': number,
    'session_uuid': session,
    'tva': {'taux': '18.000000', 'incluse': true},
    'lignes': lines,
    'remise_globale': globalDiscount,
    'livraison': 0,
    'totaux': {'brut': payable + globalDiscount, 'remises': globalDiscount, 'base_ht': payable - vat, 'tva': vat, 'a_payer': payable},
    'paiements': [for (final (code, amount) in payments) {'moyen': code, 'montant': amount, 'ecart_arrondi': 0}],
    'passages': ?passes,
  });
}

List<Map> _operations({bool closed = true}) => [
  _op('ouv-1', 'ouverture_session', '2026-11-21T07:00:00Z', {'fond': 5000}),
  _sale('v1', 'HL2-1-0001', '2026-11-21T08:00:00Z', [_line('l1', 'p-garba', 'Garba poulet', '2', 3500), _line('l2', 'p-jus', 'Jus de bissap', '1', 1000)], [('especes', 8000)]),
  _sale('v2', 'HL2-1-0002', '2026-11-21T09:00:00Z', [_line('l3', 'p-garba', 'Garba poulet', '1', 3500, discount: 500)], [('glovo', 3000)]),
  _sale('v3', 'HL2-1-0003', '2026-11-21T10:00:00Z', [_line('l4', 'p-croissant', 'Croissant', '3', 800)], [('yango', 2400)]),
  _sale('v4', 'HL2-1-0004', '2026-11-21T10:30:00Z', [_line('l5', 'p-jus', 'Jus de bissap', '1', 1000)], [('pass', 1000)], passes: [{'pass_uuid': 'x'}]),
  _op('r1', 'retour', '2026-11-21T11:00:00Z', {
    'vente_ref': {'operation_uuid': 'v1'},
    'lignes': [
      {'ligne_uuid': 'l2', 'quantite': '1'},
    ],
    'montant': 1000,
    'remboursement': 'especes',
    'motif': 'Jus renversé',
  }),
  if (closed)
    _op('c1', 'cloture_session', '2026-11-21T16:00:00Z', {
      'session_uuid': 'ouv-1',
      'compte': 11500,
      'comptage': [
        {'moyen': 'glovo', 'montant': 3000, 'justification': null},
      ],
      'commentaire': 'Écart de monnaie',
    }, operator: 8),
];

ClosureFacts _facts({bool closed = true}) => ClosureFacts(
  sessions: sessionsFromOperations(_operations(closed: closed)),
  openSessionUuid: closed ? null : 'ouv-1',
  categories: const {'p-garba': 'Plats', 'p-jus': 'Boissons'},
  productNames: const {'p-garba': 'Garba poulet', 'p-jus': 'Jus de bissap', 'p-croissant': 'Croissant'},
);

final _context = ZContext(
  storeName: 'TBC Le Boulevard',
  terminalName: 'Caisse 1',
  methods: [
    PaymentMethodInfo({'code': 'especes', 'nom': 'Espèces', 'especes': true}),
    PaymentMethodInfo({'code': 'glovo', 'nom': 'Glovo'}),
    PaymentMethodInfo({'code': 'yango', 'nom': 'Yango'}),
  ],
  operatorName: (id) => switch (id) {
    7 => 'Awa Koné',
    8 => 'Responsable Été',
    _ => '',
  },
);

final _now = DateTime(2026, 11, 21, 18, 5);

ZPrintout _print(String kind, String version, int paper, {bool closed = true, bool duplicate = false}) {
  final facts = _facts(closed: closed);
  final model = kind == ZKind.preZ
      ? dayZModel(facts, _context, day: DateTime(2026, 11, 21), now: _now)
      : sessionZModel(facts, kind == ZKind.preX ? facts.openSession! : facts.lastClosed!, _context, kind: kind, now: _now, duplicate: duplicate);
  return layoutClosureTicket(closureTicket(model, version), paperWidth: paper);
}

/// Lignes mises bout à bout (titres et mentions coupés à la largeur du rouleau).
String _flat(ZPrintout printout) => printout.lines.map((l) => l.trim()).join(' ');

void _expectPrintable(ZPrintout printout, int columns) {
  for (final line in printout.lines) {
    expect(RegExp(r'^[\x20-\x7E]*$').hasMatch(line), isTrue, reason: 'caractère non imprimable : « $line »');
    expect(line.length, lessThanOrEqualTo(columns), reason: 'ligne trop large : « $line »');
  }
}

void main() {
  group('Faits de clôture lus dans la file', () {
    test('une session : ouverture, ventes, retour, clôture ; la session ouverte suivante commence vide', () {
      final sessions = sessionsFromOperations([
        ..._operations(),
        _sale('v9', 'HL2-1-0009', '2026-11-21T17:00:00Z', [_line('l9', 'p-jus', 'Jus de bissap', '1', 1000)], [('especes', 1000)], session: 'srv-2'),
      ], openSession: {'session_uuid': 'srv-2', 'operateur_id': '7', 'ouverte_le': '2026-11-21T16:30:00Z'});
      expect(sessions, hasLength(2));
      expect([sessions[0].uuid, sessions[0].float, sessions[0].sales.length, sessions[0].returns.length, sessions[0].closed], ['ouv-1', 5000, 4, 1, true]);
      expect([sessions[1].uuid, sessions[1].float, sessions[1].sales.length, sessions[1].closed, sessions[1].openerId], ['srv-2', null, 1, false, 7]);
    });
  });

  group('Bloc de détail', () {
    test('ventes par pass hors chiffre d’affaires ; moyens séparés ; articles par catégorie, sans catégorie en dernier', () {
      final facts = _facts();
      final detail = closureDetail(facts, facts.sessions, methodNames: _context.methodNames);
      final summary = detail['summary'] as Map;
      expect([summary['tickets'], summary['revenue'], summary['average_basket'], summary['line_discounts'], summary['returns_amount'], summary['net_after_returns']], [3, 13400, 4467, 500, 1000, 12400]);
      expect([for (final p in detail['payments'] as List) '${p['label']}:${p['count']}:${p['amount']}'], ['Espèces:1:8000', 'Glovo:1:3000', 'Yango:1:2400']);
      final categories = (detail['articles'] as Map)['categories'] as List;
      expect([for (final c in categories) c['label']], ['Boissons', 'Plats', 'Sans catégorie']);
      // Une ligne par (article, conditionnement, prix unitaire) : les deux ventes de Garba se cumulent, remise comprise.
      final plats = (categories[1] as Map)['rows'] as List;
      expect([for (final r in plats) '${r['label']}:${r['quantity']}:${r['amount']}:${r['discount']}'], ['Garba poulet:3000000:10000:500']);
    });
  });

  group('Documents imprimés', () {
    for (final paper in [58, 80]) {
      final columns = paper == 58 ? 32 : 48;

      test('Z de session détaillé en $columns colonnes : détail par produit, moyens séparés, espèces, accents retirés', () {
        final printout = _print(ZKind.session, ZVersion.detailed, paper);
        _expectPrintable(printout, columns);
        final text = _flat(printout);
        expect(text, contains('Z - CLOTURE DE SESSION'));
        expect(text, contains('Imprime le'));
        expect(text, contains('Cloture par'));
        for (final method in ['Especes (1)', 'Glovo (1)', 'Yango (1)']) {
          expect(printout.lines.where((l) => l.startsWith(method)), hasLength(1), reason: method);
        }
        expect(text, contains('PLATS'));
        expect(text, contains('SANS CATEGORIE'));
        expect(printout.lines.where((l) => l.startsWith('3 x 3 500') && l.endsWith('10 000 FCFA')), hasLength(1));
        expect(printout.lines.where((l) => l.startsWith('remise') && l.endsWith('-500 FCFA')), hasLength(1));
        expect(printout.lines.where((l) => l.startsWith('Sous-total (3)') && l.endsWith('10 000 FCFA')), hasLength(1));
        // Fond 5 000 + espèces 8 000 − remboursement 1 000 = 12 000 attendus ; 11 500 comptés.
        expect(printout.lines.where((l) => l.startsWith('Theorique') && l.endsWith('12 000 FCFA')), hasLength(1));
        expect(printout.lines.where((l) => l.startsWith('Ecart ') && !l.startsWith('Ecart de') && l.endsWith('-500 FCFA')), hasLength(1));
        expect(printout.lines.where((l) => l.startsWith('Glovo ecart') && l.endsWith(' 0 FCFA')), hasLength(1));
        expect(printout.lines.where((l) => l.startsWith('Yango theorique') && l.endsWith('2 400 FCFA')), hasLength(1));
        expect(text, contains('Retour HL2-1-0001'));
        expect(text, contains('Motif'));
        expect(text, contains('Version detaille'));
        expect(text, isNot(contains('Jus de bissap x1')), reason: 'le top 5 est réservé au Z court');
        // Nom de la boutique en double taille et en gras ; titre en gras.
        expect(printout.large, contains(0));
        expect(printout.bold, contains(printout.lines.indexWhere((l) => l.contains('Z - CLOTURE'))));
      });

      test('Z court en $columns colonnes : résumé, moyens, top 5, aucun détail par catégorie', () {
        final printout = _print(ZKind.session, ZVersion.short, paper);
        _expectPrintable(printout, columns);
        final text = _flat(printout);
        expect(text, contains('Resume'));
        expect(text, contains('Par moyen de paiement'));
        expect(text, contains('Top 5 des articles'));
        expect(text, contains('1. Garba poulet x3'));
        expect(text, isNot(contains('Sous-total')));
        expect(text, isNot(contains('PLATS')));
        expect(printout.lines.where((l) => l.startsWith('Ecart de caisse') && l.endsWith('-500 FCFA')), hasLength(1));
        expect(text, contains('Version court'));
      });

      test('pré-X en $columns colonnes : provisoire, à l’aveugle (ni théorique ni écart), session non clôturée', () {
        final printout = _print(ZKind.preX, ZVersion.detailed, paper, closed: false);
        _expectPrintable(printout, columns);
        final text = _flat(printout);
        expect(text, contains('PRE-X'));
        expect(text, contains('NON CLOTURE'));
        expect(printout.bold, contains(printout.lines.indexWhere((l) => l.startsWith('Edite le'))));
        expect(text, isNot(contains('Theorique')));
        expect(text, isNot(contains('Controle par moyen')));
        expect(text, isNot(contains('Ecart')));
        expect(text, contains('Comptage a l\'aveugle'));
        expect(text, contains('Document provisoire'));
      });

      test('pré-Z du jour en $columns colonnes : sessions du terminal, session ouverte comptée à l’aveugle', () {
        final printout = _print(ZKind.preZ, ZVersion.detailed, paper, closed: false);
        _expectPrintable(printout, columns);
        final text = _flat(printout);
        expect(text, contains('PRE-Z'));
        expect(text, contains('Journee du'));
        expect(text, contains('en cours'));
        expect(text, contains('encore ouverte'));
        expect(text, contains('Ce terminal seulement'));
        expect(text, isNot(contains('12 000 FCFA')), reason: 'attendu de la session ouverte jamais imprimé');
      });
    }

    test('duplicata : titre et en-tête de réimpression', () {
      final text = _flat(_print(ZKind.session, ZVersion.short, 80, duplicate: true));
      expect(text, contains('Z - CLOTURE DE SESSION - DUPLICATA'));
      expect(text, contains('Reimprime le'));
      expect(text, contains('Duplicata : reimpression'));
    });

    test('structure ticket du contrat : kind, version, provisoire, duplicata, devise', () {
      final facts = _facts(closed: false);
      final ticket = closureTicket(sessionZModel(facts, facts.openSession!, _context, kind: ZKind.preX, now: _now), ZVersion.short);
      expect([ticket['kind'], ticket['version'], ticket['provisoire'], ticket['duplicata'], ticket['devise']], ['pre-x', 'short', true, false, 'FCFA']);
      expect(ticket['titre'], 'PRÉ-X — DOCUMENT PROVISOIRE, NON CLÔTURÉ');
      expect((ticket['mentions'] as List).last, 'Version court');
    });

    test('ESC/POS : double taille du nom, coupe finale, aucune impulsion de tiroir', () {
      final bytes = _print(ZKind.session, ZVersion.detailed, 58).bytes();
      bool has(List<int> seq) {
        for (var i = 0; i + seq.length <= bytes.length; i++) {
          var ok = true;
          for (var j = 0; j < seq.length && ok; j++) {
            ok = bytes[i + j] == seq[j];
          }
          if (ok) return true;
        }
        return false;
      }

      expect(has([0x1D, 0x21, 0x11]), isTrue);
      expect(has([0x1D, 0x56, 66, 0]), isTrue);
      expect(has([0x1B, 0x70]), isFalse);
    });
  });
}
