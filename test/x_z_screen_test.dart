import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/app_settings.dart';
import 'package:shopikaiss_terminal/src/offline/api.dart';
import 'package:shopikaiss_terminal/src/offline/engine.dart';
import 'package:shopikaiss_terminal/src/offline/models.dart';
import 'package:shopikaiss_terminal/src/offline/offline_register_page.dart';
import 'package:shopikaiss_terminal/src/offline/store.dart';
import 'package:shopikaiss_terminal/src/offline/x_z_report.dart';
import 'package:shopikaiss_terminal/src/terminal/terminal_channel.dart';
import 'package:shopikaiss_terminal/src/terminal/terminal_session.dart';

/// Boutique injoignable : la caisse reste hors ligne pendant tout le test.
class _Offline implements RegisterTransport {
  static const _off = ApiResponse(0, {'message': 'hors ligne'});
  @override
  Future<ApiResponse> pair(String a, String c, String m, String v) async => _off;
  @override
  Future<ApiResponse> status(String a, String t) async => _off;
  @override
  Future<ApiResponse> snapshot(String a, String t, {int? sinceSequence}) async => _off;
  @override
  Future<ApiResponse> synchronize(String a, String t, List<Map<String, dynamic>> o) async => _off;
  @override
  Future<ApiResponse> operationStates(String a, String t, List<String> u) async => _off;
}

/// Caisse dont la file porte une session ouverte avec deux ventes (espèces et Glovo) ; la clôture s'y ajoute.
class _ClosureEngine extends OfflineEngine {
  _ClosureEngine({required super.store, required super.transport});

  final operations = <Map>[
    {'uuid': 'ouv-1', 'type': 'ouverture_session', 'cree_le': '2026-11-21T07:00:00Z', 'operateur_id': '7', 'contenu': {'fond': 5000}},
    for (final (uuid, code, amount) in [('v1', 'especes', 2000), ('v2', 'glovo', 3000)])
      {
        'uuid': uuid,
        'type': 'vente',
        'cree_le': '2026-11-21T09:00:00Z',
        'operateur_id': '7',
        'contenu': {
          'numero_local': 'HL2-$uuid',
          'session_uuid': 'ouv-1',
          'lignes': [
            {'ligne_uuid': 'l$uuid', 'produit_uuid': 'p1', 'libelle': 'Garba poulet', 'quantite': '1', 'prix_unitaire': amount, 'remise': 0, 'total': amount},
          ],
          'remise_globale': 0,
          'livraison': 0,
          'totaux': {'base_ht': amount, 'tva': 0, 'a_payer': amount},
          'paiements': [
            {'moyen': code, 'montant': amount},
          ],
        },
      },
  ];
  int? closedCash;

  @override
  bool canCloseSession(Operator operator) => true;

  @override
  bool hasRight(Operator operator, String right) => true;

  @override
  Future<OfflineOperation> closeSession(Operator operator, {required int cash, String? comment, List<SessionCount> others = const [], String? operationUuid}) async {
    closedCash = cash;
    operations.add({
      'uuid': 'c1',
      'type': 'cloture_session',
      'cree_le': '2026-11-21T16:00:00Z',
      'operateur_id': '${operator.id}',
      'contenu': {'session_uuid': 'ouv-1', 'compte': cash, 'comptage': null, 'commentaire': comment},
    });
    return OfflineOperation(uuid: 'c1', sequence: 9, type: 'cloture_session', number: null, date: DateTime(2026), operatorId: operator.id, content: const {});
  }

  @override
  Future<ClosureFacts?> closureFacts() async {
    final sessions = sessionsFromOperations(operations);
    return ClosureFacts(sessions: sessions, openSessionUuid: sessions.last.closed ? null : 'ouv-1', categories: const {'p1': 'Plats'});
  }
}

Future<TerminalSession> _session({double inches = 8.0}) async {
  final snapshot = {
    'version': 1,
    'disponible': true,
    'boutique': {'nom': 'TBC Le Boulevard', 'tva_taux': '0', 'tva_incluse': true, 'devise': 'FCFA'},
    'terminal': {'id': 1, 'nom': 'Caisse 1', 'prefixe_tickets': 'HL-001'},
    'appareil': {'derniere_sequence': 0},
    'reglages': {'duree_max_heures': 72, 'ventes_max': 500, 'mode_caissier': 'dernier'},
    'session': {'uuid': 'ouv-1', 'caissier_id': 7},
    'dernier_caissier_id': 7,
    'moyens': [
      {'code': 'especes', 'nom': 'Espèces', 'especes': true},
      {'code': 'glovo', 'nom': 'Glovo'},
    ],
    'caissiers': [
      {'id': 7, 'nom': 'Awa Koné', 'pin': null},
    ],
    'produits': [
      {'id': 1, 'nom': 'Garba poulet', 'prix': 2000, 'stock': '5.000000', 'conditionnements': [], 'codes': []},
    ],
    'genere_le': DateTime.now().toUtc().toIso8601String(),
  };
  final store = MemoryOfflineStore()
    ..values.addAll({
      StoreKeys.apiBase: 'https://boutique.exemple.ci/api/caisse/v1',
      StoreKeys.token: 'abcdefabcdef.secret',
      StoreKeys.snapshot: jsonEncode(snapshot),
      StoreKeys.snapshotAt: DateTime.now().toUtc().toIso8601String(),
      StoreKeys.lastContact: DateTime.now().toUtc().toIso8601String(),
    });
  final engine = _ClosureEngine(store: store, transport: _Offline());
  await engine.load('https://boutique.exemple.ci');
  final settings = AppSettings(
    shopUrl: 'https://boutique.exemple.ci/caisse',
    driver: 'none',
    paperWidth: 58,
    serialPath: '',
    serialBaud: 115200,
    bluetoothAddress: '',
    usbDevice: '',
    adminCode: '',
    screenLayout: 'auto',
  );
  return TerminalSession.forTest(settings: settings, offline: engine, info: TerminalInfo({'screenInches': inches}));
}

Future<void> _pump(WidgetTester tester, Size size, TerminalSession session) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: OfflineRegisterPage(engine: session.offline, session: session, onBackOnline: () {})));
  await tester.pump();
}

/// Texte du ticket montré sans imprimante (fenêtre « Ticket (aucune imprimante) »).
String _preview(WidgetTester tester) {
  final dialog = find.ancestor(of: find.text('Ticket (aucune imprimante)'), matching: find.byType(AlertDialog));
  return tester.widgetList<Text>(find.descendant(of: dialog, matching: find.byType(Text))).map((t) => t.data ?? '').join('\n');
}

void main() {
  testWidgets('menu de session : pré-X sans clôturer, puis clôture et Z court imprimés sur le terminal', (tester) async {
    final session = await _session();
    final engine = session.offline as _ClosureEngine;
    await _pump(tester, const Size(1280, 800), session);

    await tester.ensureVisible(find.text('Session de caisse'));
    await tester.tap(find.text('Session de caisse'));
    await tester.pumpAndSettle();
    for (final entry in ['Imprimer un pré-X', 'Clôturer la session', 'Imprimer un pré-Z du jour', 'Réimprimer le dernier Z']) {
      expect(find.text(entry), findsOneWidget, reason: entry);
    }
    await tester.tap(find.text('Imprimer un pré-X'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Z détaillé'));
    await tester.pumpAndSettle();
    var ticket = _preview(tester);
    expect(ticket, contains('PRE-X'));
    expect(ticket, contains('Especes (1)'));
    expect(ticket, contains('Glovo (1)'));
    expect(ticket, contains('PLATS'));
    expect(ticket, isNot(contains('Theorique')));
    expect(engine.closedCash, isNull, reason: 'le pré-X ne clôture rien');
    await tester.tap(find.text('Fermer'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Session de caisse'));
    await tester.tap(find.text('Session de caisse'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clôturer la session'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Espèces comptées (F)'), '7000');
    await tester.tap(find.text('Clôturer'));
    await tester.pumpAndSettle();
    expect(engine.closedCash, 7000);
    expect(find.text('Imprimer le Z de session de ce terminal ?'), findsOneWidget);
    await tester.tap(find.text('Z court'));
    await tester.pumpAndSettle();
    ticket = _preview(tester);
    expect(ticket, contains('Z - CLOTURE DE SESSION'));
    expect(ticket, contains('Par moyen de paiement'));
    expect(ticket, contains('Version court'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('petit téléphone : le menu « Pré-X, pré-Z et Z » ouvre les documents, sans débordement', (tester) async {
    final session = await _session(inches: 4.0);
    await _pump(tester, const Size(320, 568), session);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pré-X, pré-Z et Z'));
    await tester.pumpAndSettle();
    expect(find.text('Imprimer un pré-X'), findsOneWidget);
    await tester.tap(find.text('Réimprimer le dernier Z'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Z détaillé'));
    await tester.pumpAndSettle();
    expect(find.text('Aucune session clôturée sur ce terminal.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
