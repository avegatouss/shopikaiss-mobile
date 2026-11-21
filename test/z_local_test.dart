import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/offline/models.dart';
import 'package:shopikaiss_terminal/src/offline/x_z_report.dart';
import 'package:shopikaiss_terminal/src/restaurant/resto_interface.dart';
import 'package:shopikaiss_terminal/src/sync_v2/schema_validator.dart';

/// Lot « Z local » (contrat z-local-c3610bbb, README §12) côté calcul : fond et retours en ligne de `z.session`, bloc de
/// détail au format du contrat, pré-Z de la journée composé avec `z.journee`, contenu des audits d'édition, interface
/// restaurant.
const _root = 'test/fixtures/contrat-v2';
final _validator = SchemaValidator((file) => File('$_root/schemas/$file').readAsStringSync());
Map<String, dynamic> _fixture(String name) => Map<String, dynamic>.from(jsonDecode(File('$_root/fixtures/valides/$name.json').readAsStringSync()) as Map);

const _terminal = '11111111-2222-4333-8444-555555555555';
const _otherTerminal = '11111111-2222-4333-8444-666666666666';
const _session = '5e55a0d1-0000-4000-8000-000000000001';
const _localSession = '5e55a0d1-0000-4000-8000-0000000000aa';

Map<String, dynamic> _op(String uuid, String type, String at, Map<String, dynamic> content, {int operator = 7}) =>
    {'uuid': uuid, 'type': type, 'cree_le': at, 'operateur_id': '$operator', 'contenu': content};

Map<String, dynamic> _line(String uuid, String product, String label, String quantity, int price) {
  final total = (double.parse(quantity) * price).round();
  return {'ligne_uuid': uuid, 'produit_uuid': product, 'conditionnement_uuid': null, 'libelle': label, 'quantite': quantity, 'quantite_base': quantity, 'prix_unitaire': price, 'remise': 0, 'total': total};
}

Map<String, dynamic> _sale(String uuid, String number, String at, String session, List<Map<String, dynamic>> lines, String method) {
  final payable = lines.fold<int>(0, (sum, l) => sum + (l['total'] as int));
  final vat = (payable * 18 / 118).round();
  return _op(uuid, 'vente', at, {
    'numero_local': number,
    'session_uuid': session,
    'tva': {'taux': '18.000000', 'incluse': true},
    'lignes': lines,
    'remise_globale': 0,
    'livraison': 0,
    'totaux': {'brut': payable, 'remises': 0, 'base_ht': payable - vat, 'tva': vat, 'a_payer': payable},
    'paiements': [
      {'moyen': method, 'montant': payable, 'ecart_arrondi': 0},
    ],
  });
}

final _context = ZContext(
  storeName: 'Boutique',
  terminalName: 'Comptoir 1',
  methods: [
    PaymentMethodInfo({'code': 'especes', 'nom': 'Espèces', 'especes': true}),
    PaymentMethodInfo({'code': 'wave', 'nom': 'Wave'}),
  ],
  operatorName: (id) => switch (id) {
    7 => 'Awa Koné',
    _ => '',
  },
);

final _now = DateTime(2026, 11, 19, 18, 0);

/// Session ouverte EN LIGNE (aucune ouverture dans la file) : deux ventes du terminal et un retour local.
List<Map> _onlineSessionOperations() => [
  _sale('a0000000-0000-4000-8000-000000000101', 'HL1-0001', '2026-11-19T09:00:00Z', _session, [_line('l1', 'p-riz', 'Riz parfumé 1 kg', '2', 1000)], 'especes'),
  _sale('a0000000-0000-4000-8000-000000000102', 'HL1-0002', '2026-11-19T10:00:00Z', _session, [_line('l2', 'p-sachet', 'Sachet', '1', 500)], 'wave'),
  _op('a0000000-0000-4000-8000-000000000103', 'retour', '2026-11-19T11:00:00Z', {
    'vente_ref': {'operation_uuid': 'a0000000-0000-4000-8000-000000000101'},
    'lignes': [
      {'ligne_uuid': 'l1', 'quantite': '1'},
    ],
    'montant': 1000,
    'remboursement': 'especes',
    'motif': 'Sac percé',
  }),
];

/// `z.session` du fixture, adaptée à la session ci-dessus : fond 30 000, un retour en ligne remboursé en espèces, et le
/// retour du terminal republié à tort (même UUID) qui ne doit jamais être compté deux fois.
Map<String, dynamic> _zSession({int? fund = 30000}) {
  final z = _fixture('donnees-z-local--z-session');
  final online = Map<String, dynamic>.from((z['retours'] as List).first as Map);
  return {
    ...z,
    'session_uuid': _session,
    'terminal_uuid': _terminal,
    'fond_initial': fund,
    'retours': [
      online,
      {...online, 'retour_uuid': 'a0000000-0000-4000-8000-000000000103', 'vente_numero': 'HL1-0001'},
    ],
  };
}

ClosureFacts _facts({Map? zSession, Map? zDay, bool stale = false, List<Map>? operations, String? open = _session}) {
  final sessions = sessionsFromOperations(operations ?? _onlineSessionOperations(), openSession: open == null ? null : {'session_uuid': open, 'operateur_id': '7', 'ouverte_le': null});
  applyZSession(sessions, zSession);
  return ClosureFacts(
    sessions: sessions,
    openSessionUuid: open,
    categories: const {'p-riz': 'Épicerie'},
    productNames: const {'p-riz': 'Riz parfumé 1 kg', 'p-sachet': 'Sachet'},
    zDay: zDay,
    terminalUuid: _terminal,
    journalStale: stale,
  );
}

String _flat(ZPrintout printout) => printout.lines.map((l) => l.trim()).join(' ');

void main() {
  group('Fond et retours saisis en ligne (z.session, README §12.3)', () {
    test('session ouverte en ligne : fond publié, retour en ligne ajouté, retour du terminal jamais en double', () {
      final facts = _facts(zSession: _zSession());
      final session = facts.openSession!;
      expect(session.float, 30000);
      expect(session.onlineReturns, hasLength(1), reason: 'le retour de même UUID que celui de la file est écarté');
      final detail = sessionDetail(facts, session, _context);
      final summary = detail['summary'] as Map;
      final online = (_zSession()['retours'] as List).first as Map;
      expect(summary['returns_count'], 2);
      expect(summary['returns_amount'], 1000 + (online['montant'] as int));
      final returns = (detail['returns'] as List).cast<Map>();
      expect(returns.map((r) => r['sale']), containsAll(['HL1-0001', online['vente_numero']]));
      final mapped = returns.firstWhere((r) => r['sale'] == online['vente_numero']);
      expect([mapped['kind'], mapped['reason'], mapped['destination'], (mapped['lines'] as List).length],
          [online['type'] == 'annulation' ? 'cancellation' : 'return', online['motif'], online['destination'], (online['lignes'] as List).length]);
      final text = _flat(buildClosureDocument(facts, _context, kind: ZKind.preX, version: ZVersion.detailed, now: _now).layout(paperWidth: 80));
      expect(text, contains('Fond initial'));
      expect(text, contains('30 000 FCFA'));
      expect(text, isNot(contains('Fond initial inconnu')));
    });

    test('fond inconnu du serveur (null) : le ticket garde « — »', () {
      final facts = _facts(zSession: _zSession(fund: null));
      expect(facts.openSession!.float, isNull);
      final printout = buildClosureDocument(facts, _context, kind: ZKind.preX, version: ZVersion.detailed, now: _now).layout(paperWidth: 80);
      expect(printout.lines.where((l) => l.startsWith('Fond initial') && l.trimRight().endsWith('-')), hasLength(1));
      expect(_flat(printout), contains('Fond initial inconnu'));
    });

    test('remboursement en ligne par un moyen espèces non local : compté en espèces (booléen publié, réponse 19)', () {
      final z = _zSession();
      final online = Map<String, dynamic>.from((z['retours'] as List).first as Map);
      online['remboursements'] = [
        {'moyen': 'especes_bar', 'montant': online['montant']},
      ];
      final facts = _facts(zSession: {...z, 'retours': [online]});
      String? refunds(ZContext context) {
        final model = buildClosureDocument(facts, context, kind: ZKind.preX, version: ZVersion.detailed, now: _now).model;
        return (model['especes'] as List).cast<Map>().where((l) => l['libelle'] == 'Remboursements').firstOrNull?['montant'] as String?;
      }

      final published = ZContext(
        storeName: _context.storeName,
        terminalName: _context.terminalName,
        methods: _context.methods,
        operatorName: _context.operatorName,
        publishedCashCodes: const {'especes_bar'},
      );
      expect(refunds(_context), '-1000', reason: 'seul le retour du terminal, sans le booléen publié');
      expect(refunds(published), '${-1000 - (online['montant'] as int)}');
    });

    test('pied des documents locaux : « Ventes de ce terminal seulement » (réponse 16)', () {
      final printout = buildClosureDocument(_facts(zSession: _zSession()), _context, kind: ZKind.preX, version: ZVersion.detailed, now: _now).layout(paperWidth: 80);
      expect(_flat(printout), contains('Ventes de ce terminal seulement'));
    });

    test('z.session d’une autre session : rien n’est ajouté', () {
      final facts = _facts(zSession: {..._zSession(), 'session_uuid': '5e55a0d1-0000-4000-8000-0000000000ff'});
      expect([facts.openSession!.float, facts.openSession!.onlineReturns], [null, isEmpty]);
    });
  });

  group('Bloc de détail au format du contrat (DetailCloture v1)', () {
    test('le détail d’une session (retours en ligne, caissiers, nombre de paiements) est conforme au schéma', () {
      final facts = _facts(zSession: _zSession());
      final contract = detailToContract(sessionDetail(facts, facts.openSession!, _context));
      final errors = _validator.validate(contract, r'donnees-z-local-1.json#/$defs/detail_cloture');
      expect(errors, isEmpty, reason: errors.join(' ; '));
      expect(contract['payments_count'], 2);
      expect([for (final c in contract['cashiers'] as List) c['label']], ['Awa Koné']);
      expect(contract.containsKey('families'), isFalse, reason: 'familles de rapport inconnues du terminal : rubrique omise');
      expect((contract['summary'] as Map)['revenue'], '2500');
      // Retour local : montant par ligne réparti, la somme égale le montant du retour.
      final local = (contract['returns'] as List).cast<Map>().firstWhere((r) => r['sale'] == 'HL1-0001' && r['destination'] == 'cash' && r['reason'] == 'Sac percé');
      expect((local['lines'] as List).single, {'label': 'Riz parfumé 1 kg', 'quantity': '1.000000', 'amount': '1000'});
    });

    test('aller-retour : un bloc publié relu puis réécrit est identique', () {
      final published = _fixture('donnees-z-local--detail-cloture');
      expect(detailToContract(detailFromContract(published)), published);
    });

    test('rubriques facultatives du 19/11 acceptées en lecture', () {
      final published = {
        ..._fixture('donnees-z-local--detail-cloture'),
        'payments_count': 3,
        'families': [
          {'key': 'family:2', 'label': 'Boissons', 'lines': 1, 'quantity': '1.000000', 'amount': '500'},
        ],
      };
      expect(_validator.validate(published, r'donnees-z-local-1.json#/$defs/detail_cloture'), isEmpty);
      final internal = detailFromContract(published);
      expect((internal['families'] as List).single['quantity'], BigInt.from(1000000));
      expect(detailToContract(internal), published);
    });
  });

  group('Pré-Z de la journée (README §12.4)', () {
    Map<String, dynamic> day({List<Map>? open, int omitted = 0, String status = 'ouverte', List<Map>? closed}) {
      final z = _fixture('donnees-z-local--z-journee');
      return {
        ...z,
        'terminaux': [_terminal, _otherTerminal],
        'statut': status,
        'sessions_closes': closed ?? z['sessions_closes'],
        'sessions_omises': omitted,
        'sessions_ouvertes': open ?? <Map>[],
      };
    }

    /// Session locale ouverte, vendue puis close sur ce terminal, pas encore synchronisée.
    List<Map> localClosed() => [
      _op(_localSession, 'ouverture_session', '2026-11-19T13:00:00Z', {'fond': 10000}),
      _sale('a0000000-0000-4000-8000-000000000201', 'HL1-0003', '2026-11-19T14:00:00Z', _localSession, [_line('l3', 'p-riz', 'Riz parfumé 1 kg', '3', 1000)], 'especes'),
      _op('a0000000-0000-4000-8000-000000000202', 'cloture_session', '2026-11-19T15:00:00Z', {'session_uuid': _localSession, 'compte': 13000, 'comptage': null, 'commentaire': null}),
    ];

    test('sessions closes publiées + session locale : sommes, panier moyen et top recalculés, jamais de numéro', () {
      final facts = _facts(operations: localClosed(), open: null, zDay: day());
      final document = buildClosureDocument(facts, _context, kind: ZKind.preZ, version: ZVersion.detailed, now: _now);
      final summary = document.model['synthese'] as Map;
      // Publiée : 2 tickets, 5 000 ; locale : 1 ticket, 3 000.
      expect([summary['tickets'], summary['revenue'], summary['average_basket']], [3, 8000, 2667]);
      expect(document.model['numero'], isNull);
      expect(document.ticket['numero'], isNull);
      expect(document.partial, isFalse);
      // Riz 1 kg sans conditionnement : 3 publiés + 3 locaux ; « Riz parfumé 1 kg (Sac de 5) » reste à part.
      final top = (document.model['top'] as List).cast<Map>();
      expect(top.first['label'], 'Riz parfumé 1 kg');
      expect(top.first['quantity'], BigInt.from(6000000));
      expect(top.map((t) => t['label']), contains('Riz parfumé 1 kg (Sac de 5)'));
      final categories = ((document.model['articles'] as Map)['categories'] as List).cast<Map>();
      expect(categories.map((c) => c['label']), ['Épicerie', 'Sans catégorie'], reason: 'même libellé : une seule catégorie, « Sans catégorie » en dernier');
      // Espèces : fonds 10 000 + 10 000, comptés 14 000 + 13 000.
      final cash = (document.model['especes'] as List).cast<Map>();
      expect([for (final l in cash) l['montant']], ['20000', '27000', '27000', '0']);
      expect(document.edition, {
        'point_de_vente_uuid': '8b000000-0000-4000-8000-000000000001',
        'date_exploitation': '2026-11-19',
        'sessions': ['5e55a0d1-0000-4000-8000-000000000002'],
        'sessions_locales': [_localSession],
        'partielle': false,
        'version': 'detailed',
        'resume': {'tickets': 3, 'chiffre_affaires': 8000},
      });
      final text = _flat(document.layout(paperWidth: 80));
      expect(text, contains('PRE-Z'));
      expect(text, isNot(contains('Journee partielle')));
      expect(text, contains('Comptoir 2 - Yao Kouassi'));
    });

    test('session locale déjà publiée (même session_uuid) : comptée une fois, avec le détail publié', () {
      final published = Map<String, dynamic>.from((_fixture('donnees-z-local--z-journee')['sessions_closes'] as List).single as Map);
      final facts = _facts(operations: localClosed(), open: null, zDay: day(closed: [{...published, 'session_uuid': _localSession}]));
      final document = buildClosureDocument(facts, _context, kind: ZKind.preZ, version: ZVersion.short, now: _now);
      expect((document.model['synthese'] as Map)['revenue'], 5000);
      expect(document.edition!['sessions_locales'], isEmpty);
    });

    test('« Journée partielle » : journal ancien, sessions omises ou session ouverte d’un autre terminal', () {
      // Le fixture publie la session ouverte de ce terminal (Comptoir 1) ; la même sur Comptoir 2 est « un autre ».
      final ownOpen = (_fixture('donnees-z-local--z-journee')['sessions_ouvertes'] as List).cast<Map>();
      final otherOpen = [
        {...ownOpen.single, 'terminal_uuid': _otherTerminal, 'terminal_nom': 'Comptoir 2'},
      ];
      for (final (label, facts, partial) in [
        ('complète', _facts(zDay: day(open: ownOpen)), false),
        ('journal ancien', _facts(zDay: day(), stale: true), true),
        ('sessions omises', _facts(zDay: day(omitted: 3)), true),
        ('autre terminal ouvert', _facts(zDay: day(open: otherOpen)), true),
      ]) {
        final document = buildClosureDocument(facts, _context, kind: ZKind.preZ, version: ZVersion.detailed, now: _now);
        expect(document.partial, partial, reason: label);
        expect(document.edition!['partielle'], partial, reason: label);
        final printout = document.layout(paperWidth: 58);
        final title = printout.lines.indexWhere((l) => l.contains('PRE-Z'));
        if (partial) {
          // Sous le titre, avant toute rubrique.
          expect(printout.lines.sublist(title + 1, title + 4).join(' '), contains('Journee partielle'), reason: label);
        } else {
          expect(_flat(printout), isNot(contains('Journee partielle')), reason: label);
        }
      }
    });

    test('session ouverte du terminal : signalée « non clôturée », sans montant', () {
      final facts = _facts(zSession: _zSession(), zDay: day());
      final document = buildClosureDocument(facts, _context, kind: ZKind.preZ, version: ZVersion.detailed, now: _now);
      expect((document.model['synthese'] as Map)['revenue'], 5000, reason: 'les ventes de la session ouverte ne sont pas comptées');
      final text = _flat(document.layout(paperWidth: 80));
      expect(text, contains('non cloturee'));
      expect(document.edition!['sessions_locales'], [_session]);
    });

    test('journée close au serveur : sessions locales seulement, dernier Z rappelé', () {
      final z = _fixture('donnees-z-local--z-journee-close');
      final facts = _facts(operations: localClosed(), open: null, zDay: {...z, 'terminaux': [_terminal]});
      final document = buildClosureDocument(facts, _context, kind: ZKind.preZ, version: ZVersion.detailed, now: _now);
      expect((document.model['synthese'] as Map)['revenue'], 3000);
      expect(_flat(document.layout(paperWidth: 80)), contains('Dernier Z journalier'));
      expect(document.ticket['numero'], isNull);
    });

    test('sans z.journee : pré-Z de ce terminal seul, audit marqué partiel', () {
      final document = buildClosureDocument(_facts(operations: localClosed(), open: null), _context, kind: ZKind.preZ, version: ZVersion.short, now: _now);
      expect(_flat(document.layout(paperWidth: 80)), contains('Ce terminal seulement'));
      expect([document.edition!['point_de_vente_uuid'], document.edition!['partielle'], document.edition!['sessions_locales']], [null, true, [_localSession]]);
    });
  });

  group('Audits d’édition (README §12.5)', () {
    Map<String, dynamic> operation(String type, Map<String, dynamic> content) => {
      'uuid': 'a0000000-0000-4000-8000-000000000999',
      'type': type,
      'appareil': {'uuid': '0d4c3b2a-1f0e-4d9c-8b7a-6a5b4c3d2e1f', 'epoque': 1},
      'sequence': 60,
      'cree_le': '2026-11-19T12:00:00Z',
      'operateur_id': '7',
      'versions': {'politiques': '12', 'calcul': '1', 'curseur_catalogue': null},
      'contenu': content,
      'empreinte': '0' * 64,
    };

    test('pré-X et pré-Z : contenu conforme à operation.json ; Z de session : aucun audit', () {
      final facts = _facts(zSession: _zSession(), zDay: _fixture('donnees-z-local--z-journee'));
      final preX = buildClosureDocument(facts, _context, kind: ZKind.preX, version: ZVersion.short, now: _now);
      expect(preX.editionType, 'edition_pre_x');
      expect(preX.edition, {'session_uuid': _session, 'aveugle': true, 'version': 'short', 'resume': {'tickets': 2, 'chiffre_affaires': 2500}});
      expect(_validator.validate(operation('edition_pre_x', preX.edition!), 'operation.json'), isEmpty);
      final preZ = buildClosureDocument(facts, _context, kind: ZKind.preZ, version: ZVersion.detailed, now: _now);
      expect(preZ.editionType, 'edition_pre_z');
      expect(_validator.validate(operation('edition_pre_z', preZ.edition!), 'operation.json'), isEmpty);
      final closed = _facts(operations: [..._onlineSessionOperations(), _op('a0000000-0000-4000-8000-000000000104', 'cloture_session', '2026-11-19T16:00:00Z', {'session_uuid': _session, 'compte': 0, 'comptage': null, 'commentaire': null})], open: null);
      final z = buildClosureDocument(closed, _context, kind: ZKind.session, version: ZVersion.short, now: _now);
      expect([z.editionType, z.edition], [null, null]);
      expect(() => buildClosureDocument(closed, _context, kind: ZKind.preX, version: ZVersion.short, now: _now), throwsA(isA<ClosureUnavailable>()));
    });
  });

  group('Interface restaurant (restaurant.interface, README §12.8)', () {
    test('défauts sans entité ou pour une valeur inconnue ; valeurs publiées sinon', () {
      const defaults = RestoInterface.defaults;
      expect([defaults.askCovers, defaults.sendLabel, defaults.catalogNavigation], [true, 'send', 'chips']);
      expect(RestoInterface.fromJson(null).toJson(), defaults.toJson());
      expect(RestoInterface.fromJson(_fixture('donnees--restaurant-interface-defauts')).toJson(), defaults.toJson());
      final published = RestoInterface.fromJson(_fixture('donnees--restaurant-interface'));
      expect(published.toJson(), {
        'demander_couverts': _fixture('donnees--restaurant-interface')['demander_couverts'],
        'libelle_envoi': _fixture('donnees--restaurant-interface')['libelle_envoi'],
        'navigation_carte': _fixture('donnees--restaurant-interface')['navigation_carte'],
      });
      final unknown = RestoInterface.fromJson({'demander_couverts': 'oui', 'libelle_envoi': 'expedier', 'navigation_carte': 'grille'});
      expect(unknown.toJson(), defaults.toJson());
    });

    test('libellé du bouton d’envoi', () {
      expect(const RestoInterface().sendButton(production: true), 'Envoyer');
      expect(const RestoInterface().sendButton(production: false), 'Valider');
      expect(const RestoInterface(sendLabel: 'hold').sendButton(production: true), 'Mettre en attente');
      expect(const RestoInterface(sendLabel: 'hold_short').sendButton(production: false), 'Mise en attente');
    });
  });
}
