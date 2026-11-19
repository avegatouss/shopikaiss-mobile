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
import 'package:shopikaiss_terminal/src/restaurant/resto_promotions.dart';
import 'package:shopikaiss_terminal/src/sync_v2/decimal6.dart';
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
  late final _resto = RestoEngine(newUuid: () => '00000000-0000-4000-8000-${(++_ids).toString().padLeft(12, '0')}', now: DateTime.now, stations: const {}, counters: RestoCounters(), sendToStations: false, promotions: _promotionBook);

  /// Promotions publiées (R-5) ; aucune par défaut.
  RestoPromotions? get _promotionBook => null;
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
  Future<RestoOrderView> restoOpen(Operator operator, String tableUuid, {int? covers, Customer? customer}) async =>
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
  bool restoNeedsApproval(Operator operator, String type) => false;

  @override
  Future<RestoOrderView> restoOffer(Operator operator, String orderUuid, String lineUuid, String reason, {RestoApproval? approval}) async =>
      _keep(_resto.offer(orders[orderUuid]!, lineUuid, reason), 'offert');

  @override
  Future<RestoOrderView> restoDiscountLine(Operator operator, String orderUuid, String lineUuid, {required bool percent, required int value, required String reason, RestoApproval? approval}) async =>
      _keep(_resto.discountLine(orders[orderUuid]!, lineUuid, percent: percent, value: value, reason: reason), 'remise_ligne');

  @override
  Future<RestoOrderView> restoDiscountOrder(Operator operator, String orderUuid, int amount, {String? reason, RestoApproval? approval}) async =>
      _keep(_resto.discountOrder(orders[orderUuid]!, amount, reason: reason), 'remise');

  @override
  int restoOrderDiscountCeiling(RestoOrder order) => RestoEngine.orderDiscountCeiling(order, 100);

  @override
  Future<RestoOrderView> restoMoveLines(Operator operator, String orderUuid, String targetUuid, Set<String> lineUuids) async {
    final r = _resto.moveLines(orders[orderUuid]!, orders[targetUuid]!, lineUuids);
    orders[targetUuid] = RestoEngine.receive(orders[targetUuid]!, orders[orderUuid]!, r.event.action, r.event.fact);
    return _keep(r, 'deplacement_lignes');
  }

  @override
  Future<RestoOrderView> restoMerge(Operator operator, String orderUuid, String targetUuid, {String? reason}) async {
    final r = _resto.merge(orders[orderUuid]!, orders[targetUuid]!, reason: reason);
    orders[targetUuid] = RestoEngine.receive(orders[targetUuid]!, orders[orderUuid]!, r.event.action, r.event.fact);
    return _keep(r, 'fusion');
  }

  @override
  Future<RestoOrderView> restoCoversAndServer(Operator operator, String orderUuid, {int? covers, String? serverId}) async =>
      _keep(_resto.coversAndServer(orders[orderUuid]!, covers: covers, serverId: serverId), 'couverts_serveur');

  @override
  Future<RestoOrderView> restoValidateCustomer(Operator operator, String orderUuid) async => _keep(_resto.validateCustomer(orders[orderUuid]!), 'validation_client');

  @override
  Future<List<CartLine>> restoCart(String orderUuid) async => [
    for (final l in orders[orderUuid]!.activeLines) CartLine(product: snapshot!.byId(int.parse(l.productUuid))!, quantity: BigInt.from(l.quantity), fixedPrice: l.unitPrice),
  ];

  @override
  Future<OfflineOperation> restoSettle(Operator operator, String orderUuid, List<CartLine> lines, List<CartPayment> payments, {String? draftUuid, List<RestoShare>? shares, String? operationUuid}) async {
    settledWith = payments;
    final sale = await recordSale(lines, payments, operator, draftUuid: draftUuid);
    _keep(_resto.close(orders[orderUuid]!), 'cloture');
    return sale;
  }
}

/// Caisse maîtresse d'un point de vente Restaurant (profil `PRODUCTION`, R-4) : canaux, « Valider », règlements par
/// articles et par parts, registre ouvert.
class _ProductionEngine extends _RestaurantEngine {
  _ProductionEngine({required super.store, required super.transport});

  final _cartLines = Map<CartLine, String>.identity();
  List<RestoShare>? settledShares;

  @override
  RestoContext? get restaurant => const RestoContext(
    pointOfSaleUuid: 'pdv',
    pointOfSaleName: 'Restaurant',
    profile: 'PRODUCTION',
    master: true,
    generation: '1',
    tables: [RestoTable(uuid: 't1', name: 'T1', capacity: 4, order: 1)],
    channels: [
      RestoChannel(uuid: 'c1', code: 'sur_place', name: 'Sur place', kind: 'dine_in', requiresTable: true, order: 1),
      RestoChannel(uuid: 'c2', code: 'emporter', name: 'Emporter', kind: 'takeaway', order: 2),
      RestoChannel(uuid: 'c3', code: 'livraison', name: 'Livraison', kind: 'delivery', requiresReference: true, order: 3),
    ],
    promotions: [_staffPromotion],
  );

  static const _staffPromotion = RestoPromotion(uuid: 'promo-staff', name: 'Repas du personnel', category: 'staff', type: 'pourcentage', percent: 50000000);

  // Tarif du personnel : même moteur de promotions que l'engine réel (catégorie `staff`).
  @override
  RestoPromotions? get _promotionBook => RestoPromotions(promotions: const [_staffPromotion]);

  // ---------------------------------------------------------------- lot R-5

  final refunds = <String>[];

  static int _half(CartLine l) => Decimal6.amount(l.unitPrice, l.quantity.toInt()) ~/ 2;

  @override
  Future<int> restoStaffDiscount(String orderUuid, int staffId, List<(CartLine, String?)> added) async => added.fold<int>(0, (sum, a) => sum + _half(a.$1));

  @override
  Future<RestoOrderView> restoStaffLines(Operator operator, String orderUuid, int staffId, List<(CartLine, String?)> added, {required String reason, RestoApproval? approval}) async {
    final r = _resto.editLines(orders[orderUuid]!, reason: reason, added: [
      for (final (l, c) in added)
        RestoNewLine(productUuid: '${l.product.id}', label: l.label, quantity: l.quantity.toInt(), unitPrice: l.unitPrice, comment: c, staffId: '$staffId'),
    ]);
    actions.add('personnel:${r.event.reason}');
    return _keep(r, 'lignes');
  }

  @override
  Future<List<RestoSettledSale>> restoSettledSales() async => [
    RestoSettledSale(
      saleUuid: 'v1',
      number: 'HL-001-000001',
      orderUuid: 'o1',
      orderNumber: 'PF-20261118-L0009',
      at: DateTime(2026, 11, 18, 20),
      total: 3000,
      lines: const [RestoSaleLine(lineUuid: 'l1', label: 'Article numéro 3', sold: 1000000, remaining: 1000000)],
      refunds: [
        if (refunds.isNotEmpty)
          const RestoRefundView(uuid: 'r1', type: 'retour', amount: 3000, reason: 'Boisson renversée', state: 'recue', message: 'La vente remboursée n’est pas encore intégrée.', waiting: true),
      ],
    ),
  ];

  @override
  String? restoRefundBlocker(Operator operator) => null;

  @override
  bool restoRefundNeedsApproval(Operator operator, String type) => false;

  @override
  Future<int> restoRefundAmount(String saleUuid, String type, Map<String, int> quantities) async => type == 'annulation' ? 3000 : (quantities['l1'] ?? 0) * 3000 ~/ 1000000;

  @override
  Future<OfflineOperation> restoRefund(Operator operator, String saleUuid, String type, Map<String, int> quantities, String reason, {RestoApproval? approval, String? operationUuid}) async {
    refunds.add('$type:$reason:$quantities');
    return OfflineOperation(uuid: 'r1', sequence: 2, type: 'resto_remboursement', number: null, date: DateTime(2026), operatorId: operator.id, content: const {});
  }

  @override
  Future<RestoOrderView> restoOpenOnChannel(Operator operator, String channelCode, {String? tableUuid, String? reference, String? customerName, int? covers, String? customerUuid}) async =>
      _keep(_resto.open(prefix: 'PF', businessDay: '2026-11-18', profile: 'PRODUCTION', channel: channelCode, tableUuid: tableUuid, externalReference: reference, customerName: customerName), 'ouverture');

  @override
  Future<RestoOrderView> restoSend(Operator operator, String orderUuid) async => _keep(_resto.validate(orders[orderUuid]!), 'validation');

  @override
  Future<RestoRegisterView?> restoRegister() async => RestoRegisterView(uuid: 'r', businessDay: '2026-11-18', openedAt: DateTime(2026, 11, 18, 17), salesTotal: 0);

  @override
  String? restoRegisterBlocker(Operator operator) => null;

  List<CartLine> _cart(String orderUuid, Map<String, int>? quantities) {
    final cart = <CartLine>[];
    for (final l in orders[orderUuid]!.activeLines) {
      final quantity = quantities == null ? l.quantity - l.settled : quantities[l.uuid] ?? 0;
      if (quantity <= 0) continue;
      final line = CartLine(product: snapshot!.byId(int.parse(l.productUuid))!, quantity: BigInt.from(quantity), fixedPrice: l.unitPrice);
      _cartLines[line] = l.uuid;
      cart.add(line);
    }
    return cart;
  }

  @override
  Future<List<CartLine>> restoCart(String orderUuid) async => _cart(orderUuid, null);

  @override
  Future<List<CartLine>> restoCartItems(String orderUuid, Map<String, int> quantities) async => _cart(orderUuid, quantities);

  @override
  Future<OfflineOperation> restoSettle(Operator operator, String orderUuid, List<CartLine> lines, List<CartPayment> payments, {String? draftUuid, List<RestoShare>? shares, String? operationUuid}) async {
    settledWith = payments;
    settledShares = shares;
    final sale = await recordSale(lines, payments, operator, draftUuid: draftUuid);
    final order = orders[orderUuid]!;
    for (final c in lines) {
      order.line(_cartLines[c]!).settled += c.quantity.toInt();
    }
    actions.add(shares != null ? 'vente:shares' : 'vente');
    if (order.activeLines.every((l) => l.settled >= l.quantity)) {
      _keep(_resto.close(order), 'cloture');
    } else {
      notifyListeners();
    }
    return sale;
  }
}

/// Restaurant (R-5) avec des promotions publiées : « 2 achetés, 1 offert » sur l'article 2, 10 % sur l'article 3.
class _PromotionEngine extends _ProductionEngine {
  _PromotionEngine({required super.store, required super.transport});

  static const _promotions = [
    RestoPromotion(uuid: 'b0000000-0000-4000-8000-000000000502', name: 'Deux achetés, un offert', category: 'promotion', type: 'x_achetes_y_offerts', buy: 2, free: 1, products: {'2'}),
    RestoPromotion(uuid: 'b0000000-0000-4000-8000-000000000503', name: 'Promo du jour', category: 'promotion', type: 'pourcentage', percent: 10000000, products: {'3'}),
  ];

  @override
  RestoPromotions? get _promotionBook => RestoPromotions(promotions: _promotions);

  @override
  RestoContext? get restaurant => RestoContext(
    pointOfSaleUuid: 'pdv',
    pointOfSaleName: 'Restaurant',
    profile: 'PRODUCTION',
    master: true,
    generation: '1',
    channels: const [RestoChannel(uuid: 'c2', code: 'emporter', name: 'Emporter', kind: 'takeaway', order: 2)],
    promotions: _promotions,
  );
}

Future<TerminalSession> _session({
  required double inches,
  String layout = 'auto',
  MemoryOfflineStore? memory,
  bool permanent = false,
  bool rich = false,
  bool approver = false,
  bool restaurant = false,
  bool production = false,
  bool promotions = false,
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
  final engine = promotions
      ? _PromotionEngine(store: store, transport: _Offline())
      : production
      ? _ProductionEngine(store: store, transport: _Offline())
      : restaurant
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

    testWidgets('Service de table (R-4) : offrir, remise d’article et de commande, couverts, fusion avec une autre table', (tester) async {
      final session = await _session(inches: 10.1, restaurant: true);
      final engine = session.offline as _RestaurantEngine;
      final awa = engine.snapshot!.operators.first;
      // Une commande déjà ouverte à la table 2, cible de la fusion.
      final other = (await engine.restoOpen(awa, 't2')).order.uuid;
      await _pump(tester, const Size(1280, 800), session);
      await tester.tap(find.text('Salle'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('table-t1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ouvrir la commande'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Article numéro 2 au nom assez long pour un petit écran').first);
      await tester.tap(find.text('Article numéro 2 au nom assez long pour un petit écran').first);
      await tester.tap(find.text('Article numéro 3 au nom assez long pour un petit écran').first);
      await tester.pump();
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();
      // Offrir le second article : motif obligatoire.
      await tester.tap(find.byTooltip('Offrir ou remiser').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Offrir').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('3 000 F de remise'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Offrir'));
      await tester.pumpAndSettle();
      expect(find.text('Indiquez le motif (3 caractères au moins).'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Motif (obligatoire)'), 'Anniversaire');
      await tester.tap(find.widgetWithText(FilledButton, 'Offrir'));
      await tester.pumpAndSettle();
      expect(engine.actions.last, 'offert:3');
      expect(find.textContaining('Offert'), findsOneWidget);
      expect(tester.widgetList<PopupMenuButton<String>>(find.byType(PopupMenuButton<String>)).where((m) => m.tooltip == 'Offrir ou remiser' && m.enabled).length, 1,
          reason: 'un offert ne se remise plus');
      // Remise de 10 % sur le premier article.
      await tester.tap(find.byTooltip('Offrir ou remiser').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remise').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pourcentage'));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('gesture-value')), '10');
      await tester.enterText(find.widgetWithText(TextField, 'Motif (obligatoire)'), 'Attente');
      await tester.tap(find.widgetWithText(FilledButton, 'Appliquer la remise'));
      await tester.pumpAndSettle();
      expect(engine.actions.last, 'remise_ligne:4');
      expect(find.textContaining('Remise 400 F'), findsOneWidget);
      // Remise sur la commande, plafonnée au montant après remises de ligne.
      await tester.tap(find.byTooltip('Plus d’actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remise sur la commande'));
      await tester.pumpAndSettle();
      expect(find.text('Plafond : 3 600 F'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('gesture-value')), '5000');
      await tester.enterText(find.widgetWithText(TextField, 'Motif (obligatoire)'), 'Client fidèle');
      await tester.tap(find.widgetWithText(FilledButton, 'Appliquer la remise'));
      await tester.pumpAndSettle();
      expect(find.textContaining('plafonnée'), findsWidgets);
      await tester.enterText(find.byKey(const ValueKey('gesture-value')), '500');
      await tester.tap(find.widgetWithText(FilledButton, 'Appliquer la remise'));
      await tester.pumpAndSettle();
      expect(engine.actions.last, 'remise:5');
      expect(find.text('Remise 500 F'), findsOneWidget);
      expect(find.text('3 100 F'), findsWidgets);
      // Couverts et serveur.
      await tester.tap(find.byTooltip('Plus d’actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Couverts et serveur'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.add).last);
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Enregistrer'));
      await tester.pumpAndSettle();
      expect(engine.actions.last, 'couverts_serveur:6');
      expect(find.text('5 couverts'), findsOneWidget);
      // Fusion avec la table 2 : la commande est annulée, retour à la salle.
      await tester.tap(find.byTooltip('Plus d’actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fusionner avec une table'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('T2 ·'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Fusionner'));
      await tester.pumpAndSettle();
      expect(engine.actions.last, 'fusion:7');
      final merged = engine.orders[other]!;
      expect([merged.version, merged.activeLines.length, merged.globalDiscount, merged.covers], [1, 2, 500, 5]);
      expect(find.byKey(const ValueKey('table-t1')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Service de table (R-4) sur téléphone 6,5 pouces : gestes de ligne et de commande sans débordement', (tester) async {
      final session = await _session(inches: 6.5, restaurant: true);
      await _pump(tester, const Size(412, 892), session);
      await tester.tap(find.text('Salle'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('table-t1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ouvrir la commande'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ajouter'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Article numéro 1 au nom assez long pour un petit écran').first);
      await tester.pump();
      await tester.tap(find.text('Commande (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Offrir ou remiser'), findsOneWidget);
      expect(find.byTooltip('Plus d’actions'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
    testWidgets('Restaurant (R-4) : commandes par canal dès la connexion, nouvelle commande, « Valider », réglée par articles puis par parts', (tester) async {
      final session = await _session(inches: 10.1, production: true);
      final engine = session.offline as _ProductionEngine;
      await _pump(tester, const Size(1280, 800), session);
      await tester.pumpAndSettle();
      // Écran restaurant ouvert directement : commandes ouvertes, registre, nouvelle commande.
      expect(find.byKey(const ValueKey('resto-nouvelle-commande')), findsOneWidget);
      expect(find.text('Aucune commande ouverte.'), findsOneWidget);
      expect(find.textContaining('Registre du 2026-11-18 ouvert'), findsOneWidget);
      expect(find.text('Commandes'), findsOneWidget, reason: 'bascule Commandes / Caisse');
      await tester.tap(find.byKey(const ValueKey('resto-nouvelle-commande')));
      await tester.pumpAndSettle();
      // Sur place exige une table ; Emporter n'en prend pas.
      await tester.tap(find.byKey(const ValueKey('canal-sur_place')));
      await tester.pumpAndSettle();
      expect(find.text('Table'), findsOneWidget);
      await tester.tap(find.text('Ouvrir la commande'));
      await tester.pumpAndSettle();
      expect(find.text('Choisissez la table.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('canal-emporter')));
      await tester.pumpAndSettle();
      expect(find.text('Table'), findsNothing);
      await tester.tap(find.text('Ouvrir la commande'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Emporter · PF-20261118-L0001'), findsOneWidget);
      await tester.tap(find.text('Article numéro 2 au nom assez long pour un petit écran').first);
      await tester.tap(find.text('Article numéro 2 au nom assez long pour un petit écran').first);
      await tester.tap(find.text('Article numéro 3 au nom assez long pour un petit écran').first);
      await tester.pump();
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Valider'));
      await tester.pumpAndSettle();
      expect(engine.actions, ['ouverture:1', 'lignes:2', 'validation:3']);
      // Retour à la liste : la commande est rangée sous son canal.
      expect(find.text('Emporter (1)'), findsOneWidget);
      await tester.tap(find.text('PF-20261118-L0001'));
      await tester.pumpAndSettle();

      // Par articles : un article 2 réglé, la commande reste ouverte.
      await tester.tap(find.text('Encaisser'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Articles'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Plus').first);
      await tester.pumpAndSettle();
      expect(find.text('Sélection : 2 000 F'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('resto-encaisser-suite')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Valider la vente'));
      await tester.pumpAndSettle();
      expect([engine.settledWith!.single.amount, engine.settledShares], [2000, null]);
      expect(find.text('Règlement enregistré : il reste à payer.'), findsOneWidget);
      await tester.tap(find.text('Retour à la commande'));
      await tester.pumpAndSettle();
      expect(find.text('Réglée en partie'), findsOneWidget);

      // Par parts : le reste (5 000 F) en deux parts payées l'une après l'autre, puis clôture.
      await tester.tap(find.text('Encaisser'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Parts'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Part 1 : 2 500 F'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('resto-encaisser-suite')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Valider la vente'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Valider la vente'));
      await tester.pumpAndSettle();
      expect([for (final s in engine.settledShares!) [s.label, s.amount, s.payments]], [['Part 1', 2500, [0]], ['Part 2', 2500, [1]]]);
      expect([for (final p in engine.settledWith!) p.amount], [2500, 2500]);
      expect(engine.actions, ['ouverture:1', 'lignes:2', 'validation:3', 'vente', 'vente:shares', 'cloture:4']);
      expect(find.text('Commande réglée et close.'), findsOneWidget);
      await tester.tap(find.text('Retour à la salle'));
      await tester.pumpAndSettle();
      expect(find.text('Aucune commande ouverte.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Restaurant (R-5) : promotion appliquée à la saisie, affichée sur la ligne, offert lié sans quantité propre', (tester) async {
      final session = await _session(inches: 10.1, promotions: true);
      final engine = session.offline as _PromotionEngine;
      await _pump(tester, const Size(1280, 800), session);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('resto-nouvelle-commande')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('canal-emporter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ouvrir la commande'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Article numéro 2 au nom assez long pour un petit écran').first);
      await tester.tap(find.text('Article numéro 2 au nom assez long pour un petit écran').first);
      await tester.tap(find.text('Article numéro 3 au nom assez long pour un petit écran').first);
      await tester.pump();
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();
      expect(engine.actions, ['ouverture:1', 'lignes:2']);
      final order = engine.orders.values.single;
      expect([for (final l in order.lines) (l.productUuid, l.quantity, l.lineDiscount, l.free)], [
        ('2', 2000000, 0, false),
        ('2', 1000000, 2000, true),
        ('3', 1000000, 300, false),
      ]);
      // La promotion se lit sur la ligne ; l'offert lié porte « Offert » et le nom de la promotion.
      expect(find.textContaining('Deux achetés, un offert'), findsNWidgets(2));
      expect(find.textContaining('Offert · Deux achetés, un offert'), findsOneWidget);
      expect(find.textContaining('Remise 300 F · Promo du jour'), findsOneWidget);
      // Ni « Plus » ni « Moins » sur l'offert lié : il suit l'article acheté.
      expect(find.byTooltip('Plus'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('Restaurant (R-4) sur téléphone 5 pouces : liste, nouvelle commande, choix d’encaissement et registre sans débordement', (tester) async {
      final session = await _session(inches: 5.0, production: true);
      await _pump(tester, const Size(360, 640), session);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('resto-nouvelle-commande')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('canal-livraison')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ouvrir la commande'));
      await tester.pumpAndSettle();
      expect(find.text('Saisissez la référence de la commande.'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Référence (obligatoire)'), 'GLV-1234');
      await tester.tap(find.text('Ouvrir la commande'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Livraison · PF-20261118-L0001'), findsOneWidget);
      expect(find.text('Réf. GLV-1234'), findsOneWidget);
      await tester.tap(find.text('Ajouter'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Article numéro 1 au nom assez long pour un petit écran').first);
      await tester.pump();
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Encaisser'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Articles'));
      await tester.pumpAndSettle();
      expect(find.textContaining('1 à régler'), findsOneWidget);
      await tester.tap(find.text('Annuler'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Livraison (1)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('resto-registre')));
      await tester.pumpAndSettle();
      expect(find.text('Clôturer le registre'), findsOneWidget);
      expect(find.textContaining('Clôturez d’abord la session'), findsOneWidget);
      await tester.tap(find.text('Fermer'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('Restaurant (R-5) : remboursement d’une vente réglée (retour, motif, attente du serveur), tarif du personnel au motif prérempli', (tester) async {
      final session = await _session(inches: 10.1, production: true);
      final engine = session.offline as _ProductionEngine;
      await _pump(tester, const Size(1280, 800), session);
      await tester.pumpAndSettle();

      // Ventes réglées : retour d'un article en espèces, motif obligatoire, puis l'attente du serveur affichée.
      await tester.tap(find.byKey(const ValueKey('resto-remboursements')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Vente HL-001-000001'), findsOneWidget);
      await tester.tap(find.text('Rembourser'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('remboursement-annulation')), findsOneWidget);
      await tester.tap(find.byTooltip('Plus').last);
      await tester.pumpAndSettle();
      expect(find.text('À rendre : 3 000 F'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('remboursement-suite')));
      await tester.pumpAndSettle();
      expect(find.text('3 000 F à rendre en espèces.'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Rembourser'));
      await tester.pumpAndSettle();
      expect(find.text('Indiquez le motif (3 caractères au moins).'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Motif (obligatoire)'), 'Boisson renversée');
      await tester.tap(find.widgetWithText(FilledButton, 'Rembourser'));
      await tester.pumpAndSettle();
      expect(engine.refunds, ['retour:Boisson renversée:{l1: 1000000}']);
      expect(find.textContaining('En attente : La vente remboursée n’est pas encore intégrée.'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      // Tarif du personnel : l'employé d'abord, puis les articles ; motif « Vente personnel pour … » prérempli.
      await tester.tap(find.byKey(const ValueKey('resto-nouvelle-commande')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('canal-emporter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ouvrir la commande'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Plus d’actions'));
      await tester.pumpAndSettle();
      expect(find.text('Remise client'), findsNothing, reason: 'aucun client cité à l’ouverture');
      await tester.tap(find.text('Tarif personnel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Awa Koné'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('resto-vente-personnel')), findsOneWidget);
      await tester.tap(find.text('Article numéro 2 au nom assez long pour un petit écran').first);
      await tester.pump();
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();
      expect(find.text('Vente personnel pour Awa Koné'), findsWidgets);
      expect(find.textContaining('1 000 F de remise'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Appliquer le tarif'));
      await tester.pumpAndSettle();
      expect(engine.actions, ['ouverture:1', 'personnel:Vente personnel pour Awa Koné', 'lignes:2']);
      expect(find.textContaining('Tarif personnel −1 000 F'), findsOneWidget);
      expect(find.text('1 000 F'), findsWidgets);
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
