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
    var r = e.open(prefix: 'PF', businessDay: '2026-11-07', profile: 'TABLE_SERVICE', tableUuid: 't9');
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
    expect([r.order.line(plat).quantity, r.order.line(plat).sent, r.order.totals(const RestoVat()).payable], [unit, unit, 3000]);
    // Annulation de la commande : le reste annoncé part en annulation, la commande est close.
    expect(() => e.cancelOrder(r.order, null), throwsA(isA<RestoRefusal>()));
    r = e.cancelOrder(r.order, 'Erreur de table');
    expect([r.order.status, r.tickets.single.lines.single.quantity, r.order.totals(const RestoVat()).payable], ['cancelled', unit, 0]);
    expect(() => e.addLine(r.order, productUuid: 'p', label: 'Plat', quantity: unit, unitPrice: 1, routing: const RestoRouting()), throwsA(isA<RestoRefusal>()));
  });

  test('envoi éteint : « Valider » fige la commande sans aucun bon', () {
    final e = engine(send: false);
    var r = e.open(prefix: 'ST', businessDay: '2026-11-07', profile: 'TABLE_SERVICE', tableUuid: 't9');
    r = e.addLine(r.order, productUuid: 'p', label: 'Plat', quantity: unit, unitPrice: 1000, routing: const RestoRouting(categoryStationUuid: 'p-cuisine'));
    r = e.send(r.order);
    expect([r.event.action, r.tickets, r.order.lines.single.status], ['validation', isEmpty, RestoLineStatus.sent]);
  });

  test('Service de table (R-2) : une version par validation, étapes du web, clôture après règlement, état relu à l’identique', () {
    final e = engine();
    expect(() => e.open(prefix: 'PF', businessDay: '2026-11-07', profile: 'TABLE_SERVICE'), throwsA(isA<RestoRefusal>()), reason: 'table obligatoire');
    var r = e.open(prefix: 'pf_salle', businessDay: '2026-11-07', profile: 'TABLE_SERVICE', tableUuid: 't1', covers: 2, serverId: '7');
    expect([r.event.version, r.event.state['etape'], r.event.state['lignes'], r.event.state['canal']], [1, 'waiting', isEmpty, isNull]);
    r = e.editLines(r.order, added: const [
      RestoNewLine(productUuid: 'pizza', label: 'Pizza margherita', quantity: unit, unitPrice: 5000, comment: ' Bien cuite '),
      RestoNewLine(productUuid: 'biere', label: 'Bière 33 cl', quantity: 2 * unit, unitPrice: 1500),
    ]);
    final pizza = r.order.lines.first.uuid, biere = r.order.lines.last.uuid;
    expect([r.event.version, r.event.action, (r.event.fact['ajoutees'] as List).length, r.event.state['totaux']], [2, 'lignes', 2, {'brut': 8000, 'remises': 0, 'a_payer': 8000, 'regle': 0}]);
    expect(r.event.state['lignes'][0], {
      'ligne_uuid': pizza, 'produit_uuid': 'pizza', 'conditionnement_uuid': null, 'lot_uuid': null, 'libelle': 'Pizza margherita', 'quantite': '1.000000',
      'coefficient': '1.000000', 'prix_unitaire': 5000, 'remise': 0, 'tarif': 'standard', 'statut': 'pending', 'poste_uuid': null,
      'commentaire': 'Bien cuite', 'parent_ligne_uuid': null, 'envoye': '0.000000', 'reglee': '0.000000',
    });
    expect(() => e.editLines(r.order), throwsA(isA<RestoRefusal>()), reason: 'aucune version vide');
    r = e.prebill(r.order);
    expect([r.event.state['etape'], r.event.state['prefactures'], r.event.fact], ['bill_printed', 1, {'numero_local': 'PFSALLE-20261107-L0001'}]);
    // Modifiée après la préfacture : « amended » ; une nouvelle préfacture la garde.
    r = e.editLines(r.order, quantities: {biere: 3 * unit}, removed: {pizza});
    expect([r.event.state['etape'], r.event.fact, r.event.reason], ['amended', {'ajoutees': [], 'modifiees': [biere], 'retirees': [pizza]}, 'Retiré de la commande']);
    expect(r.order.line(pizza).status, RestoLineStatus.cancelled, reason: 'une ligne retirée reste dans l’état');
    r = e.prebill(r.order);
    expect(r.event.state['etape'], 'amended');
    expect(() => e.transfer(r.order, 't1'), throwsA(isA<RestoRefusal>()));
    r = e.transfer(r.order, 't2');
    expect([r.event.fact, r.event.state['table_uuid']], [{'table_uuid_source': 't1', 'table_uuid_cible': 't2'}, 't2']);
    final reread = RestoOrder.fromState(r.order.uuid, r.event.version, r.event.state);
    expect([reread.state(const RestoVat()), reread.version], [r.event.state, 6]);
    r = e.close(reread);
    expect([r.event.version, r.event.action, r.order.status, r.event.state['lignes'][1]['reglee'], r.event.state['lignes'][0]['reglee'], (r.event.state['totaux'] as Map)['regle']],
        [7, 'cloture', 'settled', '3.000000', '0.000000', 4500]);
    expect(() => e.prebill(r.order), throwsA(isA<RestoRefusal>()));
  });

  test('totaux : règle du web avec la TVA de la boutique ; motif d’annulation exigé selon le réglage', () {
    ids = 0;
    final e = RestoEngine(
      newUuid: () => 'u${++ids}',
      now: () => DateTime.utc(2026, 11, 7),
      stations: const {},
      counters: RestoCounters({'commande|20261107': 11}),
      vat: const RestoVat(rate: '18.000000', included: false),
      cancellationReasonRequired: true,
    );
    var r = e.open(prefix: 'PF', businessDay: '2026-11-07', profile: 'TABLE_SERVICE', tableUuid: 't1');
    expect(r.order.localNumber, 'PF-20261107-L0012', reason: 'reprise après le dernier numéro connu');
    expect(RestoEngine.parseLocalNumber('PF-20261107-L0012'), ('20261107', 12));
    r = e.addLine(r.order, productUuid: 'p', label: 'Plat', quantity: unit, unitPrice: 1000, routing: const RestoRouting());
    expect(r.event.state['totaux'], {'brut': 1000, 'remises': 0, 'a_payer': 1180, 'regle': 0});
    expect(() => e.cancelOrder(r.order, ' '), throwsA(isA<RestoRefusal>()));
    r = e.cancelOrder(r.order, 'Client parti');
    expect([r.event.reason, r.event.state['statut'], r.event.state['totaux']], ['Client parti', 'cancelled', {'brut': 0, 'remises': 0, 'a_payer': 0, 'regle': 0}]);
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
