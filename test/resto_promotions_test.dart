import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/restaurant/resto_engine.dart';
import 'package:shopikaiss_terminal/src/restaurant/resto_promotions.dart';

import 'support/fake_v2_server.dart' show fakeValidator;

/// Promotions et happy hour de la caisse maîtresse (RESTAURANT-1 §3.12, lot R-5) : reprise de PromotionEngine du web.
void main() {
  const unit = 1000000;
  const fixtures = 'test/fixtures/contrat-v2/fixtures/valides';
  Map<String, dynamic> fixture(String name) => jsonDecode(File('$fixtures/$name.json').readAsStringSync()) as Map<String, dynamic>;

  // Happy hour publié (fixture) : 20 %, priorité 10, vendredi et samedi, 17:00 → 02:00, sur place, catégorie « bar ».
  const happyUuid = 'b0000000-0000-4000-8000-000000000501';
  const bxgyUuid = 'b0000000-0000-4000-8000-000000000502';
  const bar = 'ca000000-0000-4000-8000-000000000002';
  const croissant = 'c0000000-0000-4000-8000-000000000103';
  const table = '7ab1e000-0000-4000-8000-0000000000e1';
  final happy = RestoPromotion.fromJson(happyUuid, fixture('donnees--restaurant-promotion'), rank: BigInt.from(10));
  final bxgy = RestoPromotion.fromJson(bxgyUuid, fixture('donnees--restaurant-promotion-x-achetes-y-offerts'), rank: BigInt.from(11));
  RestoPromotion promo(String uuid, String type, {String category = 'promotion', String? percent, int? amount, int priority = 0, BigInt? rank, Set<String> products = const {}}) =>
      RestoPromotion(uuid: uuid, name: uuid, category: category, type: type, percent: percent == null ? null : int.parse(percent) * unit, amount: amount, priority: priority, rank: rank, products: products);

  // 2026-11-20 est un vendredi ; Abidjan = UTC.
  DateTime at(int day, int hour, [int minute = 0]) => DateTime.utc(2026, 11, day, hour, minute);

  test('fenêtre horaire : jours ISO, passage de minuit compté au jour où elle commence, bornes comprises', () {
    bool active(DateTime t) => happy.activeAt(RestoPromotions.localTime(t, 'Africa/Abidjan'));
    expect(active(at(20, 19, 12)), isTrue, reason: 'vendredi soir');
    expect(active(at(20, 17)), isTrue, reason: 'début compris');
    expect(active(at(20, 16, 59)), isFalse);
    expect(active(at(21, 1, 30)), isTrue, reason: 'samedi 01:30 : fenêtre ouverte vendredi');
    expect(active(at(22, 1, 30)), isTrue, reason: 'dimanche 01:30 : fenêtre ouverte samedi');
    expect(active(at(22, 2, 0)), isTrue, reason: 'fin comprise');
    expect(active(at(22, 2, 1)), isFalse);
    expect(active(at(23, 1, 30)), isFalse, reason: 'lundi 01:30 : fenêtre ouverte dimanche, jour exclu');
    expect(active(at(20, 1)), isFalse, reason: 'vendredi 01:00 : fenêtre ouverte jeudi');
    expect(active(at(22, 19)), isFalse, reason: 'dimanche soir');
    // Fuseau à décalage fixe : 16:30 UTC = 17:30 à Douala.
    expect(happy.activeAt(RestoPromotions.localTime(at(20, 16, 30), 'Africa/Douala')), isTrue);
    expect(happy.activeAt(RestoPromotions.localTime(at(20, 16, 30), 'Africa/Abidjan')), isFalse);
    // Période du–au, bornes comprises.
    expect(bxgy.activeAt(at(1, 8)), isTrue);
    expect(bxgy.activeAt(at(30, 23, 59)), isTrue);
    expect(bxgy.activeAt(DateTime.utc(2026, 12, 1, 0, 0)), isFalse);
    expect(bxgy.activeAt(DateTime.utc(2026, 10, 31, 23, 59)), isFalse);
    // Fenêtre ordinaire, ou une seule borne.
    const lunch = RestoPromotion(uuid: 'l', name: 'Midi', category: 'promotion', type: 'pourcentage', start: '12:00:00', end: '14:00:00');
    expect([lunch.activeAt(at(18, 12)), lunch.activeAt(at(18, 14)), lunch.activeAt(at(18, 14, 1)), lunch.activeAt(at(18, 11, 59))], [true, true, false, false]);
    const evening = RestoPromotion(uuid: 's', name: 'Soir', category: 'promotion', type: 'pourcentage', start: '18:00:00');
    expect([evening.activeAt(at(18, 18)), evening.activeAt(at(18, 17, 59))], [true, false]);
  });

  test('lieu et cibles : canaux, salles (vide = toutes), produit, catégorie ou catégorie parente', () {
    expect(happy.placeMatches(channel: 'sur_place'), isTrue);
    expect(happy.placeMatches(channel: 'emporter'), isFalse);
    expect(happy.placeMatches(), isFalse, reason: 'canal exigé');
    const terrace = RestoPromotion(uuid: 't', name: 'Terrasse', category: 'promotion', type: 'pourcentage', rooms: {'s1'});
    expect([terrace.placeMatches(room: 's1'), terrace.placeMatches(room: 's2'), terrace.placeMatches()], [true, false, false]);
    expect(bxgy.placeMatches(), isTrue, reason: 'aucune salle ni canal : toutes, même sans table');

    expect(happy.targets('mojito', categoryUuid: bar), isTrue);
    expect(happy.targets('mojito', categoryUuid: 'cocktails', parentCategoryUuid: bar), isTrue, reason: 'catégorie parente restaurant');
    expect(happy.targets('mojito', categoryUuid: 'cuisine'), isFalse);
    expect(happy.targets('mojito'), isFalse);
    expect(bxgy.targets(croissant), isTrue);
    expect(bxgy.targets('pain', categoryUuid: bar), isFalse);
    expect(const RestoPromotion(uuid: 'x', name: 'Tout', category: 'promotion', type: 'pourcentage').targets('n’importe'), isTrue);

    // Choix complet par RestoPromotions : salle de la table, catégorie parente.
    final book = RestoPromotions(promotions: [happy], timezone: 'Africa/Abidjan', categoryParents: {'cocktails': bar}, tableRooms: {'t1': 's1'});
    RestoPromotionLine line({String? channel = 'sur_place', String category = 'cocktails'}) =>
        RestoPromotionLine(productUuid: 'mojito', categoryUuid: category, unitPrice: 3000, quantity: 2 * unit, channel: channel, tableUuid: 't1');
    expect(book.best(line(), at(20, 19, 12))?.uuid, happyUuid);
    expect(book.best(line(channel: 'emporter'), at(20, 19, 12)), isNull);
    expect(book.best(line(category: 'plats'), at(20, 19, 12)), isNull);
    expect(book.best(line(), at(20, 12)), isNull, reason: 'hors fenêtre');
    expect(book.best(line(), at(20, 19, 12), categories: const ['staff']), isNull, reason: 'catégorie de tarif demandée');
  });

  test('remises : pourcentage arrondi vers le bas, montant et prix spécial par article, X achetés Y offerts', () {
    expect(happy.discountFor(1999, 3 * unit), 1199, reason: '20 % de 5997 = 1199,4');
    final odd = RestoPromotion.fromJson('o', {...fixture('donnees--restaurant-promotion'), 'pourcentage': '12.345678'});
    expect(odd.discountFor(1000, unit), 123, reason: '123,45678 arrondi vers le bas');
    const amount = RestoPromotion(uuid: 'm', name: 'Moins 300', category: 'promotion', type: 'montant', amount: 300);
    expect(amount.discountFor(2000, unit, coefficient: 6 * unit), 1800, reason: '300 par article, carton de 6');
    expect(amount.discountFor(1000, unit, coefficient: 6 * unit), 1000, reason: 'au plus le brut');
    expect(amount.discountFor(1000, 1500000), 450);
    const special = RestoPromotion(uuid: 'p', name: 'Prix spécial', category: 'promotion', type: 'prix_special', amount: 333);
    expect(special.discountFor(700, 1500000), 550, reason: '1050 − arrondi(499,5) = 1050 − 500');
    expect(special.discountFor(300, unit), 0, reason: 'jamais négatif');
    expect([bxgy.freeQuantity(unit), bxgy.freeQuantity(2 * unit), bxgy.freeQuantity(5 * unit), bxgy.freeQuantity(2500000)], [0, unit, 2 * unit, unit]);
    expect(bxgy.discountFor(500, 5 * unit), 1000, reason: 'valeur des 2 offerts');
    expect(bxgy.lineDiscount(500, 5 * unit), 0, reason: 'l’article acheté ne porte pas de remise');
    // Conditions figées : relues telles quelles.
    expect(RestoPromotion.fromJson(happyUuid, happy.toJson()).toJson(), happy.toJson());
    expect(fakeValidator.validate(happy.toJson(), 'donnees-restaurant-1.json#/\$defs/restaurant.promotion'), isEmpty);
  });

  test('départage : priorité, puis plus forte remise, puis la plus ancienne ; sans remise, pas candidate', () {
    RestoPromotionLine line() => const RestoPromotionLine(productUuid: 'plat', unitPrice: 1000, quantity: unit);
    RestoPromotion? best(List<RestoPromotion> list) => RestoPromotions(promotions: list).best(line(), at(18, 12));
    final low = promo('faible', 'pourcentage', percent: '50', priority: 0);
    final high = promo('prioritaire', 'pourcentage', percent: '10', priority: 5);
    expect(best([low, high])!.uuid, 'prioritaire', reason: 'priorité d’abord, même si elle remise moins');
    final ten = promo('dix', 'pourcentage', percent: '10'), twenty = promo('vingt', 'pourcentage', percent: '20');
    expect(best([ten, twenty])!.uuid, 'vingt');
    final older = promo('b-ancienne', 'pourcentage', percent: '10', rank: BigInt.from(3)), newer = promo('a-recente', 'pourcentage', percent: '10', rank: BigInt.from(9));
    expect(best([newer, older])!.uuid, 'b-ancienne');
    expect(best([promo('zero', 'pourcentage', percent: '0')]), isNull, reason: 'remise nulle : pas candidate');
    expect(best([promo('happy', 'pourcentage', percent: '10', category: 'happy_hour')])!.category, 'happy_hour');
  });

  // ------------------------------------------------------------------ moteur de commande

  // Compteur partagé : un second moteur sur la même commande ne réutilise aucun uuid.
  var ids = 0;
  RestoEngine engine({List<RestoPromotion>? promotions, Map<String, RestoPromotion>? terms, DateTime? now}) {
    return RestoEngine(
      newUuid: () => 'e1000000-0000-4000-8000-${(++ids).toString().padLeft(12, '0')}',
      now: () => now ?? at(20, 19, 12),
      stations: const {},
      counters: RestoCounters(),
      promotions: RestoPromotions(promotions: promotions ?? [happy, bxgy], timezone: 'Africa/Abidjan', entryTerms: terms),
    );
  }

  RestoNewLine mojito(int quantity) => RestoNewLine(productUuid: 'c0000000-0000-4000-8000-000000000102', label: 'Mojito', quantity: quantity, unitPrice: 3000, categoryUuid: bar);
  RestoNewLine croissants(int quantity) => RestoNewLine(productUuid: croissant, label: 'Croissant', quantity: quantity, unitPrice: 500);

  void valid(RestoResult r) {
    expect(fakeValidator.validate(r.event.state, 'operation.json#/\$defs/etat_commande'), isEmpty, reason: 'état conforme au contrat');
  }

  test('saisie (profil Restaurant) : happy hour sur la ligne, « 2 achetés, 1 offert » avec son offert lié, comme la fixture', () {
    final e = engine();
    var r = e.open(prefix: 'PF', businessDay: '2026-11-20', profile: 'PRODUCTION', channel: 'sur_place', tableUuid: table, covers: 2);
    r = e.editLines(r.order, added: [mojito(2 * unit), croissants(2 * unit)]);
    valid(r);
    final lines = (r.event.state['lignes'] as List).cast<Map>();
    final expected = (fixture('operation--resto-commande-lignes-promotions')['contenu']['etat']['lignes'] as List).cast<Map>();
    expect(lines.length, 3);
    for (var i = 0; i < 3; i++) {
      for (final k in ['quantite', 'prix_unitaire', 'remise', 'tarif', 'promotion_uuid', 'personnel_id']) {
        expect(lines[i][k], expected[i][k], reason: 'ligne $i, $k');
      }
    }
    expect(lines[2]['parent_ligne_uuid'], lines[1]['ligne_uuid'], reason: 'offert lié à l’article acheté');
    expect(r.event.fact['ajoutees'], [for (final l in lines) l['ligne_uuid']]);
    expect(r.event.state['remise_globale_source'], isNull);
    expect(r.event.promotionTerms.keys, [lines[0]['ligne_uuid'], lines[1]['ligne_uuid']], reason: 'conditions figées des lignes promues');
    expect((r.event.state['totaux'] as Map)['remises'], 1700);

    // Une ligne sans promotion envoie quand même les champs R-5 à null.
    r = e.editLines(r.order, added: [const RestoNewLine(productUuid: 'c0000000-0000-4000-8000-000000000104', label: 'Eau', quantity: unit, unitPrice: 500)]);
    expect((r.event.state['lignes'] as List).last, allOf(containsPair('promotion_uuid', null), containsPair('personnel_id', null), containsPair('tarif', 'standard')));
    valid(r);
  });

  test('quantité changée : conditions de la saisie gardées, offert lié redimensionné, retiré puis recréé', () {
    var e = engine();
    var r = e.open(prefix: 'PF', businessDay: '2026-11-20', profile: 'PRODUCTION', channel: 'sur_place', tableUuid: table);
    r = e.editLines(r.order, added: [mojito(2 * unit), croissants(2 * unit)]);
    final terms = r.event.promotionTerms;
    final mojitoLine = r.order.lines[0].uuid, bought = r.order.lines[1].uuid, offered = r.order.lines[2].uuid;

    // Relue depuis l'état (la file fait foi), puis la promotion change sur le serveur et la fenêtre est passée : la
    // ligne garde 20 %.
    var order = RestoOrder.fromState(r.order.uuid, r.order.version, r.event.state);
    expect([order.line(mojitoLine).promotionUuid, order.line(mojitoLine).tariff, order.line(offered).free], [happyUuid, 'happy_hour', true]);
    final changed = RestoPromotion.fromJson(happyUuid, {...happy.toJson(), 'pourcentage': '50.000000'});
    e = engine(promotions: [changed, bxgy], terms: {...terms}, now: at(21, 12));
    r = e.editLines(order, quantities: {mojitoLine: 3 * unit, bought: 4 * unit});
    valid(r);
    expect([r.order.line(mojitoLine).discount, r.order.line(mojitoLine).tariff], [1800, 'happy_hour'], reason: '20 % de 9000, pas 50 %');
    expect([r.order.line(offered).quantity, r.order.line(offered).lineDiscount], [2 * unit, 1000]);
    expect(r.event.fact, {'ajoutees': [], 'modifiees': [mojitoLine, bought, offered], 'retirees': []});

    // Une seule viennoiserie : plus d'offert ; deux de nouveau : un nouvel offert lié.
    r = e.editLines(r.order, quantities: {bought: unit});
    expect([r.order.line(offered).status, r.event.fact['retirees']], [RestoLineStatus.cancelled, [offered]]);
    r = e.editLines(r.order, quantities: {bought: 2 * unit});
    final again = r.order.lines.last;
    expect([again.parentLineUuid, again.free, again.quantity, again.promotionUuid, r.event.fact['ajoutees']], [bought, true, unit, bxgyUuid, [again.uuid]]);
    valid(r);

    // L'offert lié ne se change ni ne se retire seul ; il part avec l'article acheté.
    expect(() => e.editLines(r.order, quantities: {again.uuid: 2 * unit}), throwsA(isA<RestoRefusal>()));
    expect(() => e.editLines(r.order, removed: {again.uuid}), throwsA(isA<RestoRefusal>()));
    r = e.editLines(r.order, removed: {bought});
    expect([r.order.line(again.uuid).status, r.event.fact['retirees']], [RestoLineStatus.cancelled, [bought, again.uuid]]);

    // Sans conditions figées ni promotion publiée : refus (comme le web).
    final lost = engine(promotions: const [], terms: {}, now: at(21, 12));
    expect(() => lost.editLines(r.order, quantities: {mojitoLine: unit}), throwsA(isA<RestoRefusal>()));
  });

  test('Service de table, hors fenêtre ou hors canal : aucune promotion ; offert et remise manuelle la retirent', () {
    final e = engine();
    var r = e.open(prefix: 'PF', businessDay: '2026-11-20', profile: 'TABLE_SERVICE', tableUuid: table);
    r = e.editLines(r.order, added: [mojito(2 * unit), croissants(2 * unit)]);
    expect(r.order.lines.every((l) => l.promotionUuid == null && l.discount == 0), isTrue, reason: 'le Service de table n’a pas de promotions');
    expect(r.order.lines.length, 2);

    r = e.open(prefix: 'PF', businessDay: '2026-11-20', profile: 'PRODUCTION', channel: 'emporter');
    r = e.editLines(r.order, added: [mojito(2 * unit)]);
    expect(r.order.lines.single.promotionUuid, isNull, reason: 'happy hour sur place seulement');

    r = e.open(prefix: 'PF', businessDay: '2026-11-20', profile: 'PRODUCTION', channel: 'sur_place', tableUuid: table);
    r = e.editLines(r.order, added: [mojito(2 * unit), mojito(unit)]);
    final first = r.order.lines.first.uuid, second = r.order.lines.last.uuid;
    r = e.offer(r.order, first, 'Client fidèle');
    expect([r.order.line(first).promotionUuid, (r.event.state['lignes'] as List).first['tarif']], [null, 'free']);
    r = e.discountLine(r.order, second, percent: false, value: 100, reason: 'Geste commercial');
    expect([r.order.line(second).promotionUuid, (r.event.state['lignes'] as List).last['tarif'], (r.event.state['lignes'] as List).last['remise']], [null, 'manual_discount', 100]);
    valid(r);

    // Remise de commande (fait `remise`) : source `manual` par défaut, gardée tant qu'elle existe.
    r = e.discountOrder(r.order, 200, reason: 'Geste commercial');
    expect(r.event.state['remise_globale_source'], 'manual');
    valid(r);

    final late = engine(now: at(20, 12));
    var o = late.open(prefix: 'PF', businessDay: '2026-11-20', profile: 'PRODUCTION', channel: 'sur_place', tableUuid: table);
    o = late.editLines(o.order, added: [mojito(2 * unit)]);
    expect(o.order.lines.single.promotionUuid, isNull, reason: 'avant 17:00');
  });
}
