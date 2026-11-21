import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/app_settings.dart';
import 'package:shopikaiss_terminal/src/offline/api.dart';
import 'package:shopikaiss_terminal/src/offline/customer_display.dart';
import 'package:shopikaiss_terminal/src/offline/engine.dart';
import 'package:shopikaiss_terminal/src/offline/models.dart';
import 'package:shopikaiss_terminal/src/offline/offline_register_page.dart';
import 'package:shopikaiss_terminal/src/offline/payment_dialog.dart';
import 'package:shopikaiss_terminal/src/offline/store.dart';
import 'package:shopikaiss_terminal/src/terminal/terminal_channel.dart';
import 'package:shopikaiss_terminal/src/terminal/terminal_session.dart';

/// Parité Android / Windows de la caisse hors ligne (audit du 2026-11-21) : B01 paiement en lignes, B03 afficheur client,
/// B04 raccourcis clavier.

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

final _cash = PaymentMethodInfo({'code': 'especes', 'nom': 'Espèces', 'especes': true});
final _wave = PaymentMethodInfo({'code': 'wave', 'nom': 'Wave', 'reference': 'obligatoire'});
final _orange = PaymentMethodInfo({'code': 'orange', 'nom': 'Orange Money'});

Map<String, dynamic> _snapshot() => {
  'version': 1,
  'disponible': true,
  'boutique': {'nom': 'TBC Le Boulevard', 'tva_taux': '18.000000', 'tva_incluse': true, 'devise': 'FCFA'},
  'terminal': {'id': 1, 'nom': 'Comptoir', 'prefixe_tickets': 'HL-001'},
  'appareil': {'derniere_sequence': 0},
  'reglages': {'duree_max_heures': 72, 'ventes_max': 500, 'mode_caissier': 'dernier', 'remise_ligne_max_pourcent': 0},
  'session': {'uuid': 's', 'caissier_id': 7},
  'dernier_caissier_id': 7,
  'moyens': [
    {'code': 'especes', 'nom': 'Espèces', 'especes': true},
    {'code': 'wave', 'nom': 'Wave', 'reference': 'obligatoire'},
  ],
  'caissiers': [
    {'id': 7, 'nom': 'Awa Koné', 'pin': null},
  ],
  'produits': [
    {
      'id': 1,
      'nom': 'Café touba',
      'prix': 1000,
      'stock': '50.000000',
      'conditionnements': [],
      'codes': [
        {'code': '6190000000011', 'conditionnement_id': null},
      ],
    },
    {'id': 2, 'nom': 'Croissant', 'prix': 650, 'stock': '50.000000', 'conditionnements': [], 'codes': []},
  ],
  'genere_le': DateTime.now().toUtc().toIso8601String(),
};

Future<TerminalSession> _session() async {
  final store = MemoryOfflineStore()
    ..values.addAll({
      StoreKeys.apiBase: 'https://boutique.exemple.ci/api/caisse/v1',
      StoreKeys.token: 'abcdefabcdef.secret',
      StoreKeys.snapshot: jsonEncode(_snapshot()),
      StoreKeys.snapshotAt: DateTime.now().toUtc().toIso8601String(),
      StoreKeys.lastContact: DateTime.now().toUtc().toIso8601String(),
    });
  final engine = OfflineEngine(store: store, transport: _Offline());
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
  );
  return TerminalSession.forTest(settings: settings, offline: engine, info: const TerminalInfo({'screenInches': 10.1}));
}

Future<void> _pumpRegister(WidgetTester tester, TerminalSession session, {CustomerDisplayPush? display}) async {
  tester.view.physicalSize = const Size(1280, 800) * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(home: OfflineRegisterPage(engine: session.offline, session: session, onBackOnline: () {}, customerDisplay: display)),
  );
  await tester.pump();
}

/// Fenêtre de paiement seule, ouverte par un bouton : rend la répartition validée (null = annulée).
Future<List<List<CartPayment>?>> _openPayment(
  WidgetTester tester,
  double width, {
  int payable = 9650,
  String? Function(List<CartPayment>)? check,
  int Function(int)? cashDue,
}) async {
  tester.view.physicalSize = Size(width, 900) * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final results = <List<CartPayment>?>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => results.add(
              await showDialog<List<CartPayment>>(
                context: context,
                builder: (_) => OfflinePaymentDialog(methods: [_cash, _wave, _orange], payable: payable, cashDue: cashDue ?? (a) => a, check: check),
              ),
            ),
            child: const Text('ouvrir'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('ouvrir'));
  await tester.pumpAndSettle();
  return results;
}

Finder _key(String key) => find.byKey(ValueKey(key));

String _text(WidgetTester tester, String key) => tester.widget<TextField>(_key(key)).controller!.text;

void main() {
  group('B01 paiement en lignes', () {
    testWidgets('tablette 1024 : ligne sur une rangée, 9 650 = Wave 5 000 + espèces 4 650 sans calcul, montants rapides, monnaie', (tester) async {
      final checked = <List<CartPayment>>[];
      final results = await _openPayment(tester, 1024, check: (p) {
        checked.add(p);
        return null;
      });
      // Une rangée : moyen, montant et espèces reçues alignés.
      expect(tester.getTopLeft(_key('paiement-montant-0')).dy, closeTo(tester.getTopLeft(_key('paiement-recu-0')).dy, 1));
      expect(_text(tester, 'paiement-montant-0'), '9650');
      expect(find.text('Reste à répartir : 0 F'), findsOneWidget);

      // Nouvelle ligne : préremplie avec le reste (0), moyen suivant dans l'ordre configuré.
      await tester.tap(_key('paiement-ajouter'));
      await tester.pumpAndSettle();
      expect(_text(tester, 'paiement-montant-1'), '0');
      expect(find.text('Wave'), findsOneWidget);
      expect(find.text('Référence obligatoire'), findsOneWidget);
      // La saisie sur la seconde réduit d'autant la première, pleine.
      await tester.enterText(_key('paiement-montant-1'), '5000');
      await tester.pump();
      expect(_text(tester, 'paiement-montant-0'), '4650');
      expect(find.text('Reste à répartir : 0 F'), findsOneWidget);

      // Référence obligatoire du moyen : refusée tant qu'elle manque.
      await tester.tap(find.text('Valider la vente'));
      await tester.pump();
      expect(find.text('Référence obligatoire pour « Wave ».'), findsOneWidget);
      expect(checked, isEmpty);
      await tester.enterText(_key('paiement-reference-1'), 'TX-42');

      // Montants rapides sur la ligne espèces : « Exact », puis une coupure ajoutée aux espèces reçues.
      for (final note in cashQuickNotes) {
        expect(_key('paiement-coupure-0-$note'), findsOneWidget);
      }
      await tester.tap(_key('paiement-exact-0'));
      await tester.pump();
      expect(_text(tester, 'paiement-recu-0'), '4650');
      await tester.enterText(_key('paiement-recu-0'), '');
      await tester.tap(_key('paiement-coupure-0-5000'));
      await tester.pump();
      expect(_text(tester, 'paiement-recu-0'), '5000');
      expect(find.text('Monnaie à rendre : 350 F'), findsOneWidget);

      await tester.tap(find.text('Valider la vente'));
      await tester.pumpAndSettle();
      final paid = results.single!;
      expect([for (final p in paid) [p.method.code, p.amount, p.received, p.reference, p.change]], [
        ['especes', 4650, 5000, null, 350],
        ['wave', 5000, null, 'TX-42', 0],
      ]);
      expect(checked.single, same(paid), reason: 'la répartition passe par le moteur avant de fermer');
      expect(tester.takeException(), isNull);
    });

    testWidgets('téléphone 400 : ligne sur deux rangées sans débordement, 10 lignes au plus, une seule ligne d’espèces', (tester) async {
      final results = await _openPayment(tester, 400, payable: 1000);
      expect(tester.getTopLeft(_key('paiement-recu-0')).dy, greaterThan(tester.getTopLeft(_key('paiement-montant-0')).dy + 20));
      for (var i = 1; i < maxPaymentRows; i++) {
        await tester.ensureVisible(_key('paiement-ajouter'));
        await tester.tap(_key('paiement-ajouter'));
        await tester.pumpAndSettle();
      }
      expect(tester.widget<TextButton>(find.ancestor(of: find.text('Ajouter un moyen'), matching: find.byWidgetPredicate((w) => w is TextButton))).onPressed, isNull);
      expect(tester.takeException(), isNull);
      // Montants nuls sur les lignes ajoutées : refusés.
      await tester.tap(find.text('Valider la vente'));
      await tester.pumpAndSettle();
      expect(find.text('Ligne 2 : saisissez un montant positif ou retirez la ligne.'), findsOneWidget);
      while (find.byKey(const ValueKey('paiement-retirer-1')).evaluate().isNotEmpty) {
        await tester.ensureVisible(_key('paiement-retirer-1'));
        await tester.tap(_key('paiement-retirer-1'));
        await tester.pumpAndSettle();
      }
      // Seconde ligne passée en espèces : refusée comme par le moteur.
      await tester.tap(_key('paiement-ajouter'));
      await tester.pumpAndSettle();
      await tester.tap(_key('paiement-moyen-1-wave'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Espèces').last);
      await tester.pumpAndSettle();
      await tester.enterText(_key('paiement-montant-1'), '400');
      await tester.pump();
      expect(_text(tester, 'paiement-montant-0'), '600');
      await tester.tap(find.text('Valider la vente'));
      await tester.pumpAndSettle();
      expect(find.text('Une seule ligne d’espèces par vente.'), findsOneWidget);
      expect(results, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('refus du moteur affiché sur la fenêtre, qui reste ouverte ; arrondi espèces affiché', (tester) async {
      final results = await _openPayment(tester, 1024, payable: 1010, cashDue: (a) => (a + 24) ~/ 25 * 25, check: (_) => 'Refus du moteur.');
      expect(find.text('À encaisser : 1 025 F'), findsOneWidget);
      await tester.tap(find.text('Valider la vente'));
      await tester.pumpAndSettle();
      expect(find.text('Refus du moteur.'), findsOneWidget);
      expect(find.text('Valider la vente'), findsOneWidget);
      expect(results, isEmpty);
    });
  });

  group('B03 afficheur client hors ligne', () {
    testWidgets('panier, paiement, merci puis accueil poussés au format de la page web de l’afficheur', (tester) async {
      final session = await _session();
      final pushed = <Map<String, dynamic>>[];
      await _pumpRegister(tester, session, display: (state) async => pushed.add(state));
      await tester.pump();
      expect(pushed.last['phase'], 'idle', reason: 'panier vide : accueil');
      expect(pushed.last['event'], 'display.idle');

      await tester.tap(find.text('Café touba').first);
      await tester.pump();
      await tester.tap(find.text('Café touba').first);
      await tester.pump();
      await tester.pump();
      final cart = pushed.last;
      expect(cart['phase'], 'cart');
      expect(cart['event'], 'cart.updated');
      expect(cart['lines'], [
        {'name': 'Café touba', 'quantity': '2', 'unit': null, 'unit_price': 1000, 'discount': 0, 'total': 2000, 'free': false, 'promotion': null},
      ]);
      expect([cart['line_count'], cart['total'], cart['remaining'], cart['payment']], [1, 2000, 2000, null]);
      final count = pushed.length;
      await tester.pump();
      expect(pushed.length, count, reason: 'un état identique n’est pas renvoyé');

      await tester.tap(find.text('Payer'));
      await tester.pumpAndSettle();
      expect(pushed.last['phase'], 'payment');
      expect((pushed.last['payment'] as Map)['amount_due'], 2000);
      await tester.enterText(_key('paiement-recu-0'), '5000');
      await tester.pumpAndSettle();
      final payment = pushed.last['payment'] as Map;
      expect([payment['paid'], payment['received'], payment['remaining'], payment['change']], [2000, 5000, 0, 3000]);
      expect(payment['methods'], [
        {'name': 'Espèces', 'amount': 2000},
      ]);

      await tester.tap(find.text('Valider la vente'));
      await tester.pumpAndSettle();
      final done = pushed.last;
      expect(done['phase'], 'completed');
      expect(done['event'], 'payment.completed');
      expect(done['sale_number'], isNotNull);
      expect([done['total'], (done['payment'] as Map)['change']], [2000, 3000]);
      await tester.tap(find.text('Vente suivante'));
      await tester.pumpAndSettle();
      expect(pushed.last['phase'], 'completed', reason: '« Merci » reste affiché jusqu’à l’article suivant');
      await tester.pump(const Duration(seconds: 21));
      expect(pushed.last['phase'], 'idle', reason: 'puis l’accueil revient');
      for (final state in pushed) {
        expect(state.keys, containsAll(['phase', 'event', 'lines', 'line_count', 'total', 'discount', 'delivery', 'payment', 'sale_number', 'customer', 'message']));
      }
    });

    test('script : l’état est remis à ShopiKaissDisplay.push, accueil de la boutique conservé', () {
      final script = customerDisplayScript(customerDisplayState(phase: 'idle'));
      expect(script, contains('window.ShopiKaissDisplay'));
      expect(script, contains('d.push(s)'));
      expect(script, contains('s.idle=s.idle||(c&&c.idle)||{}'));
      expect(script, contains('"phase":"idle"'));
      final page = customerDisplayPage('Café <Boulevard>');
      expect(page, contains('window.ShopiKaissDisplay={push:render'));
      expect(page, contains('Café &lt;Boulevard&gt;'));
      expect(page, isNot(contains('http')), reason: 'page locale, sans réseau');
    });

    test('aucun afficheur : rien n’est envoyé', () {
      var calls = 0;
      final display = OfflineCustomerDisplay(() => null);
      display.publish(customerDisplayState(phase: 'idle'));
      final active = OfflineCustomerDisplay(() => (state) async => calls++);
      active
        ..publish(customerDisplayState(phase: 'idle'))
        ..publish(customerDisplayState(phase: 'idle'));
      expect(calls, 1);
    });
  });

  group('B04 raccourcis clavier', () {
    bool focused(WidgetTester tester, String label) =>
        tester.widget<EditableText>(find.descendant(of: find.widgetWithText(TextField, label), matching: find.byType(EditableText))).focusNode.hasFocus;

    testWidgets('F1, F2, Ctrl+F, F4, F8, F11 comme sur Windows ; douchette et fenêtres ouvertes non gênées', (tester) async {
      final session = await _session();
      final system = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        system.add(call.method);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await _pumpRegister(tester, session);

      await tester.sendKeyEvent(LogicalKeyboardKey.f1);
      await tester.pumpAndSettle();
      expect(find.text('Raccourcis de la caisse'), findsOneWidget);
      // Fenêtre ouverte : les raccourcis de la caisse ne s'appliquent pas.
      await tester.sendKeyEvent(LogicalKeyboardKey.f1);
      await tester.pumpAndSettle();
      expect(find.text('Raccourcis de la caisse'), findsOneWidget);
      await tester.tap(find.text('Fermer'));
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(focused(tester, 'Rechercher un produit'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pump();
      expect(focused(tester, 'Scanner'), isTrue);

      // Douchette : chiffres puis Entrée dans le champ Scanner, article ajouté, aucun raccourci déclenché.
      for (final key in [LogicalKeyboardKey.digit6, LogicalKeyboardKey.digit1, LogicalKeyboardKey.enter]) {
        await tester.sendKeyEvent(key);
      }
      await tester.enterText(find.widgetWithText(TextField, 'Scanner'), '6190000000011');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('1 ligne(s)'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);

      // F4 : paiement ouvert ; F8 dans la fenêtre : rien.
      await tester.sendKeyEvent(LogicalKeyboardKey.f4);
      await tester.pumpAndSettle();
      expect(find.text('Valider la vente'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.f8);
      await tester.pumpAndSettle();
      expect(find.text('Valider la vente'), findsOneWidget);
      await tester.tap(find.text('Annuler'));
      await tester.pumpAndSettle();

      // F8 : panier mis en attente.
      await tester.sendKeyEvent(LogicalKeyboardKey.f8);
      await tester.pumpAndSettle();
      expect(find.text('0 ligne(s)'), findsOneWidget);
      expect(find.text('Suspendus (1)'), findsOneWidget);
      // F4 sur panier vide : rien.
      await tester.sendKeyEvent(LogicalKeyboardKey.f4);
      await tester.pumpAndSettle();
      expect(find.text('Valider la vente'), findsNothing);

      // F11 : barres d'Android affichées puis masquées.
      system.clear();
      await tester.sendKeyEvent(LogicalKeyboardKey.f11);
      await tester.sendKeyEvent(LogicalKeyboardKey.f11);
      await tester.pump();
      expect(system.where((m) => m == 'SystemChrome.setEnabledSystemUIMode'), hasLength(2));
      expect(tester.takeException(), isNull);
    });
  });
}
