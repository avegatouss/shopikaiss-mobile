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
import 'package:shopikaiss_terminal/src/restaurant/resto_context.dart';
import 'package:shopikaiss_terminal/src/restaurant/resto_engine.dart';
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
  Future<ApiResponse> snapshot(String a, String t, {int? sinceSequence}) async => _off;
  @override
  Future<ApiResponse> synchronize(String a, String t, List<Map<String, dynamic>> o) async => _off;
  @override
  Future<ApiResponse> operationStates(String a, String t, List<String> u) async => _off;
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

/// Moteur où le caissier n'a aucun seuil de remise : seul un responsable autorise. La vente est interceptée.
class _ApprovalEngine extends OfflineEngine {
  _ApprovalEngine({required super.store, required super.transport});

  SaleExtras? recorded;

  @override
  bool get saleExtrasSupported => true;

  @override
  bool get customersSupported => true;

  int? closedCash;

  @override
  bool canCloseSession(Operator operator) => true;

  @override
  Future<OfflineOperation> closeSession(Operator operator, {required int cash, String? comment, List<SessionCount> others = const [], String? operationUuid}) async {
    if (cash == 1) throw const OfflineRefusal('Écart constaté : indiquez un commentaire.');
    closedCash = cash;
    return OfflineOperation(uuid: 'u', sequence: 1, type: 'cloture_session', number: null, date: DateTime(2026), operatorId: operator.id, content: const {});
  }

  @override
  Future<List<Customer>> searchCustomers(String query, {int limit = 30}) async =>
      [const Customer(uuid: 'c1000000-0000-4000-8000-000000000001', name: 'Bintou Traoré', phone: '+2250505050505')];

  @override
  bool hasRight(Operator operator, String right) => true;

  @override
  int maxLineDiscountFor(Operator operator, int base) => operator.approver ? super.maxLineDiscountFor(operator, base) : 0;

  @override
  Future<bool> checkApprovalCode(Operator approver, String code) async => code == '12345678';

  @override
  Future<OfflineOperation> recordSale(
    List<CartLine> lines,
    List<CartPayment> payments,
    Operator operator, {
    String? draftUuid,
    String? operationUuid,
    SaleExtras extras = const SaleExtras(),
  }) async {
    recorded = extras;
    throw const OfflineRefusal('Vente interceptée.');
  }
}

/// Caisse maîtresse d'un Service de table, en mémoire : le moteur pur du restaurant, sans file ni serveur.
class _RestaurantEngine extends OfflineEngine {
  _RestaurantEngine({required super.store, required super.transport});

  var _ids = 0;
  late final _resto = RestoEngine(newUuid: () => '00000000-0000-4000-8000-${(++_ids).toString().padLeft(12, '0')}', now: DateTime.now, stations: const {}, counters: RestoCounters(), sendToStations: false);
  final orders = <String, RestoOrder>{};
  final actions = <String>[];
  List<CartPayment>? settledWith;

  @override
  RestoContext? get restaurant => const RestoContext(
    pointOfSaleUuid: 'pdv',
    pointOfSaleName: 'Salle',
    profile: 'TABLE_SERVICE',
    master: true,
    generation: '1',
    rooms: [RestoRoom(uuid: 'r1', code: 'S', name: 'Terrasse', order: 1)],
    tables: [RestoTable(uuid: 't1', roomUuid: 'r1', name: 'T1', capacity: 4, order: 1), RestoTable(uuid: 't2', roomUuid: 'r1', name: 'T2', order: 2)],
  );

  @override
  String? restaurantBlocker(Operator operator) => null;

  @override
  bool hasRight(Operator operator, String right) => true;

  RestoOrderView _view(RestoOrder o) => RestoOrderView(order: o, payable: o.totals(const RestoVat()).payable);

  RestoOrderView _keep(RestoResult r, String action) {
    actions.add('$action:${r.event.version}');
    orders[r.order.uuid] = r.order;
    notifyListeners();
    return _view(r.order);
  }

  @override
  Future<List<RestoOrderView>> restaurantOrders({bool all = false}) async => [for (final o in orders.values) if (all || o.isOpen) _view(o)];

  @override
  Future<RestoOrderView> restoOpen(Operator operator, String tableUuid, {int? covers}) async =>
      _keep(_resto.open(prefix: 'PF', businessDay: '2026-11-17', profile: 'TABLE_SERVICE', tableUuid: tableUuid, covers: covers), 'ouverture');

  @override
  Future<RestoOrderView> restoEditLines(
    Operator operator,
    String orderUuid, {
    List<(CartLine, String?)> added = const [],
    Map<String, int> quantities = const {},
    Map<String, String?> comments = const {},
    Set<String> removed = const {},
  }) async => _keep(
    _resto.editLines(orders[orderUuid]!, added: [
      for (final (l, c) in added) RestoNewLine(productUuid: '${l.product.id}', label: l.label, quantity: l.quantity.toInt(), unitPrice: l.unitPrice, comment: c),
    ], quantities: quantities, comments: comments, removed: removed),
    'lignes',
  );

  @override
  Future<RestoOrderView> restoPrebill(Operator operator, String orderUuid) async => _keep(_resto.prebill(orders[orderUuid]!), 'prefacture');

  @override
  Future<RestoOrderView> restoSend(Operator operator, String orderUuid) async => _keep(_resto.send(orders[orderUuid]!), 'envoi');

  @override
  bool restoApprovalRequired(Operator operator) => false;

  @override
  Future<RestoOrderView> restoCancelLine(Operator operator, String orderUuid, String lineUuid, int quantity, String reason, {RestoApproval? approval}) async =>
      _keep(_resto.cancelLine(orders[orderUuid]!, lineUuid, quantity, reason), 'annulation_ligne');

  @override
  Future<List<CartLine>> restoCart(String orderUuid) async => [
    for (final l in orders[orderUuid]!.activeLines) CartLine(product: snapshot!.byId(int.parse(l.productUuid))!, quantity: BigInt.from(l.quantity), fixedPrice: l.unitPrice),
  ];

  @override
  Future<OfflineOperation> restoSettle(Operator operator, String orderUuid, List<CartLine> lines, List<CartPayment> payments, {String? draftUuid}) async {
    settledWith = payments;
    final sale = await recordSale(lines, payments, operator, draftUuid: draftUuid);
    _keep(_resto.close(orders[orderUuid]!), 'cloture');
    return sale;
  }
}

Future<TerminalSession> _session({
  required double inches,
  String layout = 'auto',
  MemoryOfflineStore? memory,
  bool permanent = false,
  bool rich = false,
  bool approver = false,
  bool restaurant = false,
}) async {
  final snapshot = _snapshot();
  if (approver) {
    (snapshot['reglages'] as Map)['remise_ligne_max_pourcent'] = 20;
    (snapshot['caissiers'] as List).add({'id': 8, 'nom': 'Chef', 'pin': null, 'approbateur': true, 'code_autorisation': 'empreinte'});
  }
  if (rich) {
    snapshot['produits'] = [
      for (var i = 1; i <= 70; i++)
        {
          'id': i,
          'nom': 'Article $i',
          'prix': 1000,
          'stock': '5.000000',
          'seuil_alerte': '10.000000',
          'categorie': i.isEven ? 'Boissons' : 'Hygiène',
          'marque': i <= 2 ? 'Dove' : null,
          'fournisseur': 'Grossiste',
          'favori': i == 1,
          'promotions': i == 1
              ? [
                  {'libelle': 'Bon de réduction au nom très long pour vérifier le débordement', 'du': null, 'au': '2099-12-31', 'exclusions': <Map>[]},
                ]
              : <Map>[],
          'conditionnements': [],
          'codes': [],
        },
    ];
  }
  if (permanent) (snapshot['reglages'] as Map)['vente_locale_permanente'] = true;
  final store = (memory ?? MemoryOfflineStore())
    ..values.addAll({
      StoreKeys.apiBase: 'https://boutique.exemple.ci/api/caisse/v1',
      StoreKeys.token: 'abcdefabcdef.secret',
      StoreKeys.snapshot: jsonEncode(snapshot),
      StoreKeys.snapshotAt: DateTime.now().toUtc().toIso8601String(),
      StoreKeys.lastContact: DateTime.now().toUtc().toIso8601String(),
    });
  final engine = restaurant
      ? _RestaurantEngine(store: store, transport: _Offline())
      : approver
      ? _ApprovalEngine(store: store, transport: _Offline())
      : OfflineEngine(store: store, transport: _Offline());
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
      expect(find.text('0 ligne(s)'), findsNothing, reason: 'le panier est dans son onglet');
      await tester.tap(find.textContaining('Article numéro 1 ').first);
      await tester.pump();
      expect(find.text('1 000 F'), findsWidgets);
      await tester.tap(find.text('Panier'));
      await tester.pump();
      expect(find.text('1 ligne(s)'), findsOneWidget);
      await tester.tap(find.text('Payer'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Valider la vente'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('catalogue complet : badges, filtres sur tout le catalogue, Afficher plus, aucun débordement', (tester) async {
      final session = await _session(inches: 4.0, rich: true);
      await _pump(tester, const Size(320, 568), session);
      expect(find.text('Stock faible'), findsWidgets);
      expect(find.textContaining('Bon de réduction'), findsOneWidget);
      expect(find.text('Afficher plus (10)'), findsOneWidget);
      await tester.tap(find.text('Marque'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dove').last);
      await tester.pumpAndSettle();
      expect(find.text('Afficher plus (10)'), findsNothing);
      expect(find.text('Article 2'), findsOneWidget);
      expect(find.text('Article 3'), findsNothing);
      await tester.ensureVisible(find.text('Effacer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Effacer'));
      await tester.pumpAndSettle();
      expect(find.text('Afficher plus (10)'), findsOneWidget);
      await tester.tap(find.text('Afficher plus (10)'));
      await tester.pump();
      expect(find.textContaining('Afficher plus'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('panier en attente : mis de côté puis repris, panier vide entre-temps', (tester) async {
      final session = await _session(inches: 8.0);
      await _pump(tester, const Size(800, 1280), session);
      await tester.tap(find.textContaining('Article numéro 1 ').first);
      await tester.pump();
      expect(find.text('1 ligne(s)'), findsOneWidget);
      await tester.tap(find.text('En attente'));
      await tester.pumpAndSettle();
      expect(find.text('0 ligne(s)'), findsOneWidget);
      await tester.tap(find.text('Suspendus (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1 article(s)'));
      await tester.pumpAndSettle();
      expect(find.text('1 ligne(s)'), findsOneWidget);
      expect(find.text('Suspendus (0)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Service de table : salle, ouverture d’une table, ajouts enregistrés en une version, préfacture, encaissement puis clôture', (tester) async {
      final session = await _session(inches: 10.1, restaurant: true);
      final engine = session.offline as _RestaurantEngine;
      await _pump(tester, const Size(1280, 800), session);
      await tester.tap(find.text('Salle'));
      await tester.pumpAndSettle();
      expect(find.text('Terrasse'), findsNothing, reason: 'une seule salle : pas d’onglets');
      expect(find.text('Libre · 4 places'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('table-t1')));
      await tester.pumpAndSettle();
      expect(find.text('4 couverts'), findsOneWidget);
      await tester.tap(find.text('Ouvrir la commande'));
      await tester.pumpAndSettle();
      expect(find.textContaining('T1 · PF-20261117-L0001'), findsOneWidget);
      await tester.tap(find.text('Article numéro 2 au nom assez long pour un petit écran').first);
      await tester.tap(find.text('Article numéro 2 au nom assez long pour un petit écran').first);
      await tester.tap(find.text('Article numéro 3 au nom assez long pour un petit écran').first);
      await tester.pump();
      expect(find.text('Préfacture'), findsNothing, reason: 'modifications à enregistrer d’abord');
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();
      expect(engine.actions, ['ouverture:1', 'lignes:2'], reason: 'trois ajouts = une seule version');
      expect(find.text('7 000 F'), findsWidgets);
      await tester.tap(find.text('Préfacture'));
      await tester.pumpAndSettle();
      expect(find.textContaining('PRÉFACTURE'), findsOneWidget, reason: 'sans imprimante, la préfacture s’affiche');
      expect(find.textContaining('n’est pas un ticket de caisse'), findsOneWidget);
      await tester.tap(find.text('Fermer'));
      await tester.pumpAndSettle();
      expect(find.text('Préfacture imprimée'), findsOneWidget);
      await tester.tap(find.text('Encaisser'));
      await tester.pumpAndSettle();
      expect(find.text('Valider la vente'), findsOneWidget);
      await tester.tap(find.text('Valider la vente'));
      await tester.pumpAndSettle();
      expect(engine.settledWith!.single.amount, 7000);
      expect(engine.actions, ['ouverture:1', 'lignes:2', 'prefacture:3', 'cloture:4']);
      expect(find.text('Commande réglée et close.'), findsOneWidget);
      await tester.tap(find.text('Retour à la salle'));
      await tester.pumpAndSettle();
      expect(find.text('Libre · 4 places'), findsOneWidget, reason: 'table libérée');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Service de table sur téléphone 5 pouces : commande et ajouts en onglets, aucun débordement', (tester) async {
      final session = await _session(inches: 5.0, restaurant: true);
      await _pump(tester, const Size(360, 640), session);
      await tester.tap(find.text('Salle'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('table-t2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ouvrir la commande'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ajouter'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Article numéro 1 au nom assez long pour un petit écran').first);
      await tester.pump();
      await tester.tap(find.text('Commande (1)'));
      await tester.pumpAndSettle();
      expect(find.text('À ajouter'), findsOneWidget);
      expect(find.text('Enregistrer'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Service de table : « Valider » fige les articles, un article validé s’annule avec un motif', (tester) async {
      final session = await _session(inches: 10.1, restaurant: true);
      final engine = session.offline as _RestaurantEngine;
      await _pump(tester, const Size(1280, 800), session);
      await tester.tap(find.text('Salle'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('table-t1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ouvrir la commande'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Article numéro 2 au nom assez long pour un petit écran').first);
      await tester.tap(find.text('Article numéro 2 au nom assez long pour un petit écran').first);
      await tester.pump();
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();
      // Envoi en production éteint : « Valider », aucun bon.
      await tester.tap(find.text('Valider'));
      await tester.pumpAndSettle();
      expect(engine.actions, ['ouverture:1', 'lignes:2', 'envoi:3']);
      // Comme « Mettre en attente » : retour à la salle, la commande reste ouverte.
      expect(find.byKey(const ValueKey('table-t1')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('table-t1')));
      await tester.pumpAndSettle();
      expect(find.text('Valider'), findsNothing, reason: 'plus rien en attente');
      expect(find.textContaining('Validé'), findsOneWidget);
      expect(find.byTooltip('Plus'), findsNothing, reason: 'un article validé ne change plus');
      await tester.tap(find.byTooltip('Annuler l’article'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Annuler l’article'));
      await tester.pumpAndSettle();
      expect(find.text('Indiquez le motif (3 caractères au moins).'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Motif (obligatoire)'), 'Client parti');
      await tester.tap(find.widgetWithText(FilledButton, 'Annuler l’article'));
      await tester.pumpAndSettle();
      expect(engine.actions.last, 'annulation_ligne:4');
      expect(engine.orders.values.single.activeLines.single.quantity, 1000000);
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
        // Deux colonnes dès que la largeur le permet, sinon catalogue et panier à onglets.
        expect(find.byKey(const ValueKey('compact-checkout-bar')), size.width < 760 ? findsOneWidget : findsNothing);
        expect(find.text('0 ligne(s)'), size.width < 760 ? findsNothing : findsOneWidget);
        expect(find.text('Reconnecter'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    for (final (label, size, inches, banner) in [
      ('téléphone 4 pouces', const Size(320, 568), 4.0, 'Connexion interrompue'),
      ('terminal 14 pouces', const Size(1366, 768), 14.0, 'Connexion interrompue — vente locale disponible'),
    ]) {
      testWidgets('vente locale permanente, $label : état réseau dit, accès à la caisse web, aucun débordement', (tester) async {
        final session = await _session(inches: inches, permanent: true);
        await _pump(tester, size, session);
        expect(find.textContaining(banner), findsOneWidget);
        expect(find.textContaining('Caisse hors ligne'), findsNothing);
        expect(find.text('Ouvrir la caisse web'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('remise au-delà du seuil du caissier : code et motif du responsable à l’encaissement', (tester) async {
      final session = await _session(inches: 8.0, approver: true);
      await _pump(tester, const Size(800, 1280), session);
      await tester.tap(find.textContaining('Article numéro 1 ').first);
      await tester.pump();
      await tester.tap(find.textContaining('Article numéro 1 ').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ajouter une remise'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Pourcentage'), '10');
      await tester.tap(find.text('Valider').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Valider').last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Payer'));
      await tester.pumpAndSettle();
      expect(find.text('Autorisation d’un responsable'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Code du responsable (8 chiffres)'), '00000000');
      await tester.enterText(find.widgetWithText(TextField, 'Motif de la remise'), 'Client fidèle');
      await tester.tap(find.text('Autoriser'));
      await tester.pumpAndSettle();
      expect(find.text('Code d’autorisation incorrect.'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Code du responsable (8 chiffres)'), '12345678');
      await tester.tap(find.text('Autoriser'));
      await tester.pumpAndSettle();
      expect(find.text('Autorisation d’un responsable'), findsNothing);

      await tester.tap(find.text('Valider la vente'));
      await tester.pumpAndSettle();
      final approval = (session.offline as _ApprovalEngine).recorded!.approval!;
      expect([approval.approverId, approval.reason], [8, 'Client fidèle']);
      expect(tester.takeException(), isNull);
    });

    for (final (name, inches, size) in const [('petit téléphone', 4.0, Size(320, 568)), ('tablette', 8.0, Size(1280, 800))]) {
      testWidgets('barre d’actions sur $name : calculatrice exacte et affichage compact, sans débordement', (tester) async {
        final session = await _session(inches: inches, approver: true);
        await _pump(tester, size, session);
        await tester.ensureVisible(find.text('Calculatrice'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Calculatrice'));
        await tester.pumpAndSettle();
        await tester.enterText(find.widgetWithText(TextField, 'Calcul'), '0,1+0,2');
        await tester.ensureVisible(find.text('='));
        await tester.pumpAndSettle();
        await tester.tap(find.text('='));
        await tester.pumpAndSettle();
        expect(find.text('0,3').evaluate().isNotEmpty || find.text('0.3').evaluate().isNotEmpty, isTrue);
        await tester.tap(find.text('Fermer'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Compacte'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Compacte'));
        await tester.pumpAndSettle();
        expect(find.byType(ListView), findsWidgets);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('logo : 5 touchers ouvrent les réglages, 4 ne les ouvrent pas ; personnalisation appliquée', (tester) async {
      final session = await _session(inches: 4.0, approver: true);
      var opened = 0;
      tester.view.physicalSize = const Size(640, 1136);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      session.settings
        ..brandColor = 0xFF1D4ED8
        ..imageMode = 'hidden'
        ..catalogList = true;
      await tester.pumpWidget(MaterialApp(theme: ThemeData(fontFamily: 'Roboto'), home: OfflineRegisterPage(engine: session.offline, session: session, onBackOnline: () {}, onOpenSettings: () async => opened++)));
      await tester.pumpAndSettle();
      final logo = find.byKey(const ValueKey('register-logo'));
      for (var i = 0; i < 4; i++) {
        await tester.tap(logo);
      }
      await tester.pump();
      expect(opened, 0);
      await tester.tap(logo);
      await tester.pumpAndSettle();
      expect(opened, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('icône % refusée par la boutique : le motif reste affiché dans une fenêtre', (tester) async {
      final session = await _session(inches: 8.0);
      await _pump(tester, const Size(800, 1280), session);
      await tester.tap(find.textContaining('Article numéro 1 ').first);
      await tester.pump();
      await tester.tap(find.byTooltip('Remise de ligne'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AlertDialog, 'Remise impossible'), findsOneWidget);
      expect(find.text('Aucune remise autorisée hors ligne par la boutique.'), findsOneWidget);
    });

    testWidgets('icône % de la ligne : ouvre la remise, pas la quantité', (tester) async {
      final session = await _session(inches: 8.0, approver: true);
      await _pump(tester, const Size(800, 1280), session);
      await tester.tap(find.textContaining('Article numéro 1 ').first);
      await tester.pump();
      await tester.tap(find.byTooltip('Remise de ligne'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Pourcentage'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Quantité'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('clôture à l’aveugle sur petit téléphone : refus affiché, aucun attendu, aucun débordement', (tester) async {
      final session = await _session(inches: 4.0, approver: true);
      await _pump(tester, const Size(320, 568), session);
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clôturer la session'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Espèces comptées (F)'), '1');
      await tester.tap(find.text('Clôturer'));
      await tester.pumpAndSettle();
      expect(find.text('Écart constaté : indiquez un commentaire.'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Espèces comptées (F)'), '5000');
      await tester.tap(find.text('Clôturer'));
      await tester.pumpAndSettle();
      expect((session.offline as _ApprovalEngine).closedCash, 5000);
      expect(tester.takeException(), isNull);
    });

    testWidgets('client de la vente : choisi dans la liste, transmis à l’encaissement', (tester) async {
      final session = await _session(inches: 8.0, approver: true);
      await _pump(tester, const Size(800, 1280), session);
      await tester.tap(find.textContaining('Article numéro 1 ').first);
      await tester.pump();
      await tester.tap(find.text('Client de passage'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bintou Traoré'));
      await tester.pumpAndSettle();
      expect(find.text('Bintou Traoré'), findsOneWidget);
      await tester.tap(find.text('Payer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Valider la vente'));
      await tester.pumpAndSettle();
      expect((session.offline as _ApprovalEngine).recorded!.customer!.name, 'Bintou Traoré');
      expect(tester.takeException(), isNull);
    });

    testWidgets('vente non enregistrée (mémoire du terminal) : dit clairement, panier conservé, aucun ticket', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final session = await _session(inches: 5.0, memory: _FullStore());
      await _pump(tester, const Size(360, 640), session);
      await tester.tap(find.textContaining('Article numéro 1 ').first);
      await tester.pump();
      await tester.tap(find.text('Payer'));
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
