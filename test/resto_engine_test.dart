import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/restaurant/resto_engine.dart';

void main() {
  const cuisine = RestoStation(uuid: 'p-cuisine', code: 'cui', name: 'Cuisine', paper: true, order: 1);
  const bar = RestoStation(uuid: 'p-bar', code: 'bar_1', name: 'Bar', screen: true, paper: true, order: 2);
  const ferme = RestoStation(uuid: 'p-ferme', code: 'pat', name: 'Pâtisserie', active: false, order: 0);
  const unit = 1000000;

  late int ids;
  RestoEngine engine({bool send = true}) {
    ids = 0;
    return RestoEngine(
      newUuid: () => 'u${++ids}',
      now: () => DateTime.utc(2026, 11, 7, 12, 30),
      stations: {for (final s in [cuisine, bar, ferme]) s.uuid: s},
      counters: RestoCounters(),
      sendToStations: send,
    );
  }

  test('routage : produit, sinon catégorie ; poste inactif = niveau suivant ; « premier poste actif » éteint par défaut', () {
    final stations = {for (final s in [cuisine, bar, ferme]) s.uuid: s};
    expect(const RestoRouting(mode: 'station', stationUuid: 'p-bar', categoryStationUuid: 'p-cuisine').resolve(stations)?.uuid, 'p-bar');
    expect(const RestoRouting(mode: 'station', stationUuid: 'p-ferme', categoryStationUuid: 'p-cuisine').resolve(stations)?.uuid, 'p-cuisine');
    expect(const RestoRouting(mode: 'inherit', categoryStationUuid: 'p-cuisine').resolve(stations)?.uuid, 'p-cuisine');
    expect(const RestoRouting(mode: 'none', categoryStationUuid: 'p-cuisine').resolve(stations), isNull);
    expect(const RestoRouting().resolve(stations), isNull, reason: 'sans poste, rien ne part');
    expect(const RestoRouting().resolve(stations, firstActiveFallback: true)?.uuid, 'p-cuisine');
  });

  test('envoi par différence : un bon par poste, AJOUT ensuite, numéros par commande et du jour', () {
    final e = engine();
    var r = e.open(prefix: 'pf_', businessDay: '2026-11-07', profile: 'PRODUCTION', tableUuid: 't1', covers: 2);
    expect(r.order.localNumber, 'PF-20261107-L0001');
    r = e.addLine(r.order, productUuid: 'poulet', label: 'Poulet braisé', quantity: 2 * unit, unitPrice: 4000, routing: const RestoRouting(categoryStationUuid: 'p-cuisine'), comment: 'sans piment');
    final poulet = r.order.lines.single.uuid;
    r = e.addLine(r.order, productUuid: 'biere', label: 'Bière', quantity: 3 * unit, unitPrice: 1000, routing: const RestoRouting(mode: 'station', stationUuid: 'p-bar'));
    r = e.addLine(r.order, productUuid: 'eau', label: 'Eau', quantity: unit, unitPrice: 500, routing: const RestoRouting(mode: 'none'));
    r = e.send(r.order);
    expect(r.event.action, 'envoi');
    expect(r.tickets.map((t) => (t.stationUuid, t.number, t.dayNumber, t.title)), [
      ('p-cuisine', 1, 'CUI-20261107-0001', 'BON'),
      ('p-bar', 1, 'BAR1-20261107-0001', 'BON'),
    ]);
    expect(r.tickets.first.lines.single.toJson(), {'ligne_uuid': poulet, 'libelle': 'Poulet braisé', 'quantite': '2.000000', 'commentaire': 'sans piment', 'action': 'add'});
    expect(r.order.lines.every((l) => l.status == RestoLineStatus.sent), isTrue, reason: 'l’eau sans poste est figée sans bon');
    expect(() => e.send(r.order), throwsA(isA<RestoRefusal>()), reason: 'rien de nouveau : aucun bon en double');

    // Un poulet de plus : seul le surplus part, en AJOUT, numéro 2 de la commande et 2 du jour.
    r = e.changeQuantity(r.order, poulet, 3 * unit);
    r = e.send(r.order);
    final ajout = r.tickets.single;
    expect([ajout.title, ajout.number, ajout.dayNumber, ajout.lines.single.quantity], ['AJOUT', 2, 'CUI-20261107-0002', unit]);
    expect(r.event.version, 7);

    // Une autre commande du jour : numéro de commande 1 sur ce poste, mais numéro du jour 3.
    var other = e.open(prefix: 'PF', businessDay: '2026-11-07', profile: 'PRODUCTION');
    other = e.addLine(other.order, productUuid: 'poulet', label: 'Poulet braisé', quantity: unit, unitPrice: 4000, routing: const RestoRouting(categoryStationUuid: 'p-cuisine'));
    final first = e.send(other.order).tickets.single;
    expect([first.number, first.dayNumber, first.firstSend, other.order.localNumber], [1, 'CUI-20261107-0003', true, 'PF-20261107-L0002']);
  });

  test('bon immuable : même uuid et même empreinte sur toutes les cibles', () {
    final e = engine();
    var r = e.open(prefix: 'PF', businessDay: '2026-11-07', profile: 'PRODUCTION');
    r = e.addLine(r.order, productUuid: 'p', label: 'Plat', quantity: unit, unitPrice: 1000, routing: const RestoRouting(categoryStationUuid: 'p-cuisine'));
    final bon = e.send(r.order).tickets.single;
    expect(bon.toJson()['empreinte_contenu'], bon.fingerprint);
    expect(bon.fingerprint, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(bon.toJson()..remove('empreinte_contenu'), isNot(contains('empreinte_contenu')));
  });

  test('annulation : motif exigé, bon d’ANNULATION seulement pour ce qui avait été annoncé', () {
    final e = engine();
    var r = e.open(prefix: 'PF', businessDay: '2026-11-07', profile: 'TABLE_SERVICE');
    r = e.addLine(r.order, productUuid: 'p', label: 'Plat', quantity: 2 * unit, unitPrice: 3000, routing: const RestoRouting(categoryStationUuid: 'p-cuisine'));
    final plat = r.order.lines.single.uuid;
    expect(() => e.cancelLine(r.order, plat, unit, 'x'), throwsA(isA<RestoRefusal>()));
    // Jamais envoyé : retrait simple, sans bon ; une ligne envoyée ne se retire pas, elle s'annule.
    r = e.send(r.order);
    expect(() => e.removeLine(r.order, plat), throwsA(isA<RestoRefusal>()));
    expect(() => e.changeQuantity(r.order, plat, unit), throwsA(isA<RestoRefusal>()));
    r = e.cancelLine(r.order, plat, unit, 'Client parti');
    final annulation = r.tickets.single;
    expect([annulation.title, annulation.number, annulation.lines.single.action, annulation.lines.single.comment], ['ANNULATION', 2, 'cancel', 'ANNULÉ : Client parti']);
    expect([r.order.line(plat).quantity, r.order.line(plat).sent, r.order.payable], [unit, unit, 3000]);
    // Annulation de la commande : le reste annoncé part en annulation, la commande est close.
    expect(() => e.cancelOrder(r.order, null), throwsA(isA<RestoRefusal>()));
    r = e.cancelOrder(r.order, 'Erreur de table');
    expect([r.order.status, r.tickets.single.lines.single.quantity, r.order.payable], ['cancelled', unit, 0]);
    expect(() => e.addLine(r.order, productUuid: 'p', label: 'Plat', quantity: unit, unitPrice: 1, routing: const RestoRouting()), throwsA(isA<RestoRefusal>()));
  });

  test('envoi éteint : « Valider » fige la commande sans aucun bon', () {
    final e = engine(send: false);
    var r = e.open(prefix: 'ST', businessDay: '2026-11-07', profile: 'TABLE_SERVICE');
    r = e.addLine(r.order, productUuid: 'p', label: 'Plat', quantity: unit, unitPrice: 1000, routing: const RestoRouting(categoryStationUuid: 'p-cuisine'));
    r = e.send(r.order);
    expect([r.event.action, r.tickets, r.order.lines.single.status], ['validation', isEmpty, RestoLineStatus.sent]);
  });

  test('règlement partiel puis clôture ; état complet sérialisé et relu à l’identique', () {
    final e = engine();
    var r = e.open(prefix: 'PF', businessDay: '2026-11-07', profile: 'PRODUCTION', tableUuid: 't1');
    r = e.addLine(r.order, productUuid: 'a', label: 'A', quantity: 2 * unit, unitPrice: 1500, routing: const RestoRouting());
    final a = r.order.lines.single.uuid;
    r = e.settle(r.order, {a: unit});
    expect([r.order.status, r.event.state['totaux']], ['open', {'brut': 3000, 'remises': 0, 'a_payer': 3000, 'regle': 1500}]);
    final reread = RestoOrder.fromJson(r.order.toJson());
    expect(reread.toJson(), r.order.toJson());
    r = e.settle(r.order, {a: unit});
    expect([r.order.status, r.event.action], ['settled', 'cloture']);
  });

  test('livraison : toutes les cibles du poste, secours seulement sur échec certain, jamais de relance « à vérifier »', () {
    expect(RestoDelivery.next(bar, const []), [(RestoTarget.ecranPoste, false), (RestoTarget.imprimantePoste, false)]);
    // L'écran accuse, l'imprimante a été tentée : livré, plus rien à faire.
    expect(RestoDelivery.next(bar, const [RestoAttempt(RestoTarget.ecranPoste, RestoOutcome.accuse), RestoAttempt(RestoTarget.imprimantePoste, RestoOutcome.nonEnvoye)]), isEmpty);
    // Imprimante du poste en échec certain : secours sur l'imprimante de la caisse (pas d'écran à ce poste).
    expect(RestoDelivery.next(cuisine, const [RestoAttempt(RestoTarget.imprimantePoste, RestoOutcome.nonEnvoye)]), [(RestoTarget.imprimanteCaisse, true)]);
    const allFailed = [RestoAttempt(RestoTarget.imprimantePoste, RestoOutcome.nonEnvoye), RestoAttempt(RestoTarget.imprimanteCaisse, RestoOutcome.nonEnvoye, fallback: true)];
    expect(RestoDelivery.next(cuisine, allFailed), isEmpty, reason: 'plus de secours : le bon reste non livré, signalé');
    // Bar : écran et imprimante en échec certain : secours sur l'imprimante de la caisse.
    expect(
      RestoDelivery.next(bar, const [RestoAttempt(RestoTarget.ecranPoste, RestoOutcome.nonEnvoye), RestoAttempt(RestoTarget.imprimantePoste, RestoOutcome.nonEnvoye)]),
      [(RestoTarget.imprimanteCaisse, true)],
    );
    // Issue inconnue : gelé, vérification humaine.
    const unknown = [RestoAttempt(RestoTarget.imprimantePoste, RestoOutcome.aVerifier)];
    expect([RestoDelivery.next(cuisine, unknown), RestoDelivery.needsCheck(unknown), RestoDelivery.delivered(unknown)], [isEmpty, true, false]);
    // Afficheur : un même bon reçu deux fois ne s'affiche qu'une fois.
    final screen = RestoReceivedTickets();
    expect([screen.accept('b1'), screen.accept('b1'), screen.accept('b2')], [true, false, true]);
  });
}
