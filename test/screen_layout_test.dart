import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shopikaiss_terminal/src/app_settings.dart';
import 'package:shopikaiss_terminal/src/offline/api.dart';
import 'package:shopikaiss_terminal/src/offline/engine.dart';
import 'package:shopikaiss_terminal/src/offline/models.dart';
import 'package:shopikaiss_terminal/src/offline/offline_register_page.dart';
import 'package:shopikaiss_terminal/src/offline/store.dart';
import 'package:shopikaiss_terminal/src/terminal/terminal_channel.dart';
import 'package:shopikaiss_terminal/src/terminal/terminal_session.dart';
import 'package:shopikaiss_terminal/src/ui/screen_profile.dart';

/// Boutique injoignable : la caisse reste hors ligne pendant tout le test.
class _Offline implements RegisterTransport {
  static const _off = ApiResponse(0, {'message': 'hors ligne'});
  @override
  Future<ApiResponse> pair(String a, String c, String m, String v) async => _off;
  @override
  Future<ApiResponse> status(String a, String t) async => _off;
  @override
  Future<ApiResponse> snapshot(String a, String t) async => _off;
  @override
  Future<ApiResponse> synchronize(String a, String t, List<Map<String, dynamic>> o) async => _off;
}

Map<String, dynamic> _snapshot() => {
  'version': 1,
  'disponible': true,
  'boutique': {'nom': 'Boutique Élégance', 'tva_taux': '18.000000', 'tva_incluse': true, 'devise': 'FCFA'},
  'terminal': {'id': 1, 'nom': 'Comptoir', 'prefixe_tickets': 'HL-001'},
  'appareil': {'derniere_sequence': 0},
  'reglages': {'duree_max_heures': 72, 'ventes_max': 500, 'mode_caissier': 'dernier', 'remise_ligne_max_pourcent': 0},
  'session': {'uuid': 's', 'caissier_id': 7},
  'dernier_caissier_id': 7,
  'moyens': [
    {'code': 'especes', 'nom': 'Espèces', 'especes': true},
  ],
  'caissiers': [
    {'id': 7, 'nom': 'Awa Koné', 'pin': null},
  ],
  'produits': [
    for (var i = 1; i <= 12; i++)
      {
        'id': i,
        'nom': 'Article numéro $i au nom assez long pour un petit écran',
        'prix': 1000 * i,
        'stock': '5.000000',
        'conditionnements': [],
        'codes': [],
      },
  ],
  'genere_le': DateTime.now().toUtc().toIso8601String(),
};

/// Mémoire du terminal qui refuse toute écriture de vente (mémoire pleine, base illisible).
class _FullStore extends MemoryOfflineStore {
  @override
  Future<void> append(OfflineOperation operation) async => throw StateError('disque plein');
}

Future<TerminalSession> _session({required double inches, String layout = 'auto', MemoryOfflineStore? memory}) async {
  final store = (memory ?? MemoryOfflineStore())
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
    screenLayout: layout,
  );
  return TerminalSession.forTest(settings: settings, offline: engine, info: TerminalInfo({'screenInches': inches}));
}

Future<void> _pump(WidgetTester tester, Size size, TerminalSession session) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(fontFamily: 'Roboto'),
      home: OfflineRegisterPage(engine: session.offline, session: session, onBackOnline: () {}),
    ),
  );
  await tester.pump();
}

/// Vraie police Roboto (celle d'Android) au lieu de la police de test, plus large : les débordements mesurés sont ceux
/// d'un terminal réel.
Future<void> _loadRoboto() async {
  final root = Platform.environment['FLUTTER_ROOT'] ?? '';
  final dir = Directory('$root/bin/cache/artifacts/material_fonts');
  if (!dir.existsSync()) return;
  final loader = FontLoader('Roboto');
  for (final name in ['roboto-regular.ttf', 'roboto-medium.ttf', 'roboto-bold.ttf']) {
    final file = File('${dir.path}/$name');
    if (file.existsSync()) loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
  }
  await loader.load();
}

void main() {
  setUpAll(_loadRoboto);
  group('Choix de la disposition', () {
    test('compacte sous 6 pouces seulement ; 6 à 8 pouces et 14 pouces inchangés', () {
      ScreenLayout auto(double w, double h, double inches) => resolveScreenLayout(setting: 'auto', logicalSize: Size(w, h), nativeInches: inches);
      expect(auto(360, 640, 5.0), ScreenLayout.compact, reason: 'téléphone 5 pouces');
      expect(auto(393, 851, 5.8), ScreenLayout.compact, reason: 'téléphone 5,8 pouces');
      expect(auto(393, 873, 6.1), ScreenLayout.standard, reason: 'téléphone 6,1 pouces');
      expect(auto(412, 915, 6.7), ScreenLayout.standard, reason: 'téléphone 6,7 pouces');
      expect(auto(600, 960, 7.0), ScreenLayout.standard, reason: 'terminal 7 pouces');
      expect(auto(800, 1280, 8.0), ScreenLayout.standard, reason: 'tablette 8 pouces');
      expect(auto(1280, 800, 14.0), ScreenLayout.standard, reason: 'terminal 14 pouces');
      // Densité déclarée fausse (terminal 15 pouces qui se dit de 2 pouces) : ignorée, la taille logique décide.
      expect(auto(1366, 768, 2.0), ScreenLayout.standard);
      // Sans mesure : repli sur la largeur logique.
      expect(auto(320, 568, 0), ScreenLayout.compact);
      expect(auto(393, 851, 0), ScreenLayout.standard);
    });

    test('le réglage force la disposition', () {
      expect(resolveScreenLayout(setting: 'compact', logicalSize: const Size(1280, 800), nativeInches: 14), ScreenLayout.compact);
      expect(resolveScreenLayout(setting: 'standard', logicalSize: const Size(360, 640), nativeInches: 5), ScreenLayout.standard);
    });
  });

  group('Caisse hors ligne à l’écran', () {
    testWidgets('téléphone 5 pouces : onglets, barre de total fixe, paiement en plein écran', (tester) async {
      final session = await _session(inches: 5.0);
      await _pump(tester, const Size(360, 640), session);
      expect(find.byKey(const ValueKey('compact-checkout-bar')), findsOneWidget);
      expect(find.text('Panier (0)'), findsNothing, reason: 'le panier est dans son onglet');
      await tester.tap(find.textContaining('Article numéro 1 ').first);
      await tester.pump();
      expect(find.text('1 000 F'), findsWidgets);
      await tester.tap(find.text('Panier'));
      await tester.pump();
      expect(find.text('Panier (1)'), findsOneWidget);
      await tester.tap(find.text('Encaisser'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Valider la vente'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('téléphone 4 pouces (320 × 568) : aucun débordement', (tester) async {
      final session = await _session(inches: 4.0);
      await _pump(tester, const Size(320, 568), session);
      expect(find.byKey(const ValueKey('compact-checkout-bar')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    for (final (label, size, inches) in [
      ('téléphone 6,5 pouces', const Size(412, 892), 6.5),
      ('terminal 8 pouces', const Size(800, 1280), 8.0),
      ('terminal 14 pouces', const Size(1366, 768), 14.0),
    ]) {
      testWidgets('$label : disposition standard inchangée', (tester) async {
        final session = await _session(inches: inches);
        await _pump(tester, size, session);
        expect(find.byKey(const ValueKey('compact-checkout-bar')), findsNothing);
        expect(find.text('Panier (0)'), findsOneWidget);
        expect(find.text('Reconnecter'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('vente non enregistrée (mémoire du terminal) : dit clairement, panier conservé, aucun ticket', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final session = await _session(inches: 5.0, memory: _FullStore());
      await _pump(tester, const Size(360, 640), session);
      await tester.tap(find.textContaining('Article numéro 1 ').first);
      await tester.pump();
      await tester.tap(find.text('Encaisser'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Valider la vente'));
      await tester.pumpAndSettle();
      expect(find.text('Vente NON enregistrée'), findsOneWidget);
      await tester.tap(find.text('Compris'));
      await tester.pumpAndSettle();
      expect(find.text('1 000 F'), findsWidgets, reason: 'Le panier est conservé.');
      expect(tester.takeException(), isNull);
    });
  });
}
