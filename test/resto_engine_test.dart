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
    var r = e.open(prefix: 'pf_', businessDay: '2026-11-07', profile: 'PRODUCTION', channel: 'sur_place', tableUuid: 't1', covers: 2);
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

    // Une ligne envoyée ne change plus (contrat §4.3) : le poulet de plus est une nouvelle ligne, qui part en AJOUT,
    // numéro 2 de la commande et 2 du jour.
    expect(() => e.changeQuantity(r.order, poulet, 3 * unit), throwsA(isA<RestoRefusal>()));
    r = e.addLine(r.order, productUuid: 'poulet', label: 'Poulet braisé', quantity: unit, unitPrice: 4000, routing: const RestoRouting(categoryStationUuid: 'p-cuisine'));
    r = e.send(r.order);
    final ajout = r.tickets.single;
    expect([ajout.title, ajout.number, ajout.dayNumber, ajout.lines.single.quantity], ['AJOUT', 2, 'CUI-20261107-0002', unit]);
    expect(r.event.version, 7);

    // Une autre commande du jour : numéro de commande 1 sur ce poste, mais numéro du jour 3.
    var other = e.open(prefix: 'PF', businessDay: '2026-11-07', profile: 'PRODUCTION', channel: 'emporter');
    other = e.addLine(other.order, productUuid: 'poulet', label: 'Poulet braisé', quantity: unit, unitPrice: 4000, routing: const RestoRouting(categoryStationUuid: 'p-cuisine'));
    final first = e.send(other.order).tickets.single;
    expect([first.number, first.dayNumber, first.firstSend, other.order.localNumber], [1, 'CUI-20261107-0003', true, 'PF-20261107-L0002']);
  });

  test('bon immuable : même uuid et même empreinte sur toutes les cibles', () {
    final e = engine();
    var r = e.open(prefix: 'PF', businessDay: '2026-11-07', profile: 'PRODUCTION', channel: 'emporter');
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
    // `validation` est au R-4 : un `envoi` sans bon la remplace ; l'envoyé net reste 0 (aucun bon reçu).
    expect([r.event.action, r.event.fact, r.tickets, r.order.lines.single.status, r.order.lines.single.sent], ['envoi', {'bons': <Object>[]}, isEmpty, RestoLineStatus.sent, 0]);
    expect(() => e.send(r.order), throwsA(isA<RestoRefusal>()), reason: 'une ligne figée sans bon ne repart pas');
    // Annuler une ligne figée sans bon : aucun bon (jamais annoncée).
    r = e.cancelLine(r.order, r.order.lines.single.uuid, unit, 'Erreur de saisie');
    expect([r.tickets, r.order.lines.single.status, r.event.fact['bons']], [isEmpty, RestoLineStatus.cancelled, isEmpty]);
  });

  test('R-3 : poste choisi à l’envoi (Service de table), annulation = envoyé − restant, autorisations jointes', () {
    final e = engine();
    var r = e.open(prefix: 'PF', businessDay: '2026-11-18', profile: 'TABLE_SERVICE', tableUuid: 't1');
    r = e.editLines(r.order, added: [
      const RestoNewLine(productUuid: 'pizza', label: 'Pizza', quantity: 3 * unit, unitPrice: 5000, comment: 'Bien cuite'),
      const RestoNewLine(productUuid: 'biere', label: 'Bière', quantity: 2 * unit, unitPrice: 1500),
      const RestoNewLine(productUuid: 'tarte', label: 'Tarte', quantity: unit, unitPrice: 2000),
    ]);
    final [pizza, biere, tarte] = [for (final l in r.order.lines) l.uuid];
    expect(r.order.lines.every((l) => l.stationUuid == null), isTrue, reason: 'aucun poste figé à l’ajout');
    // Routage publié : pizza → cuisine, bière → bar, tarte → pâtisserie inactive (rien ne part).
    const routes = {'pizza': 'p-cuisine', 'biere': 'p-bar', 'tarte': 'p-ferme'};
    r = e.send(r.order, route: (p) => routes[p]);
    expect([for (final t in r.tickets) (t.stationUuid, t.dayNumber, t.firstSend)], [('p-cuisine', 'CUI-20261118-0001', true), ('p-bar', 'BAR1-20261118-0001', true)]);
    expect([for (final l in r.order.lines) (l.stationUuid, l.status, l.sent)], [
      ('p-cuisine', RestoLineStatus.sent, 3 * unit),
      ('p-bar', RestoLineStatus.sent, 2 * unit),
      (null, RestoLineStatus.sent, 0),
    ]);
    expect(r.event.state['lignes'][0]['envoye'], '3.000000');
    expect(r.event.state['etape'], 'waiting', reason: 'l’envoi ne change pas l’étape');
    // Pizza 3 envoyées, on en annule 1 : il en reste 2, 3 − 2 = 1 part en ANNULATION ; autorisation jointe telle quelle.
    const auth = {'type': 'resto_modifier_envoye', 'approbateur_id': '3', 'motif': 'Renversée', 'preuve': 'code_local|2026-11-18T19:51:58Z'};
    expect(() => e.cancelLine(r.order, pizza, unit, 'ok'), throwsA(isA<RestoRefusal>()), reason: 'motif de 3 caractères au moins');
    r = e.cancelLine(r.order, pizza, unit, 'Renversée', authorizations: [auth]);
    final bon = r.tickets.single;
    expect([bon.title, bon.number, bon.stationUuid, bon.lines.single.quantity, bon.lines.single.comment, bon.lines.single.action], ['ANNULATION', 2, 'p-cuisine', unit, 'ANNULÉ : Renversée', 'cancel']);
    expect([r.event.action, r.event.reason, r.event.authorizations, r.event.fact['quantite'], r.order.line(pizza).quantity, r.order.line(pizza).sent],
        ['annulation_ligne', 'Renversée', [auth], '1.000000', 2 * unit, 2 * unit]);
    expect(() => e.cancelLine(r.order, biere, 3 * unit, 'Trop'), throwsA(isA<RestoRefusal>()), reason: 'pas plus que la quantité de la ligne');
    // Tarte figée sans bon : son annulation n'exige aucun bon.
    r = e.cancelLine(r.order, tarte, unit, 'Plus de tarte');
    expect(r.tickets, isEmpty);
    // Annulation de la commande : un bon d'ANNULATION par poste couvrant l'envoyé net, autorisation jointe.
    expect(RestoEngine.hasAnnounced(r.order), isTrue);
    r = e.cancelOrder(r.order, 'Client parti', authorizations: [auth]);
    expect([for (final t in r.tickets) (t.stationUuid, t.number, t.lines.single.quantity)], [('p-cuisine', 3, 2 * unit), ('p-bar', 2, 2 * unit)]);
    expect([r.order.status, r.event.authorizations.length, RestoEngine.hasAnnounced(r.order)], ['cancelled', 1, isFalse]);
    // Bons relus depuis la file : même empreinte.
    final again = RestoTicket.fromJson(r.order.uuid, r.tickets.first.toJson());
    expect(again.fingerprint, r.tickets.first.fingerprint);
    expect(again.printLines(stationName: 'Cuisine', orderNumber: 'PF-20261118-L0001', table: 'T1').take(3), ['ANNULATION - Cuisine', 'CUI-20261118-0003', 'Commande PF-20261118-L0001 - bon 3']);
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
      'commentaire': 'Bien cuite', 'parent_ligne_uuid': null, 'envoye': '0.000000', 'reglee': '0.000000', 'promotion_uuid': null, 'personnel_id': null,
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

  test('R-4 profil Restaurant : canal obligatoire, étape initiale null, « Valider » = `validation`, annulation avec motif, réglé protégé', () {
    final e = engine(send: false);
    expect(() => e.open(prefix: 'PF', businessDay: '2026-11-18', profile: 'PRODUCTION'), throwsA(isA<RestoRefusal>()), reason: 'canal obligatoire');
    var r = e.open(prefix: 'PF', businessDay: '2026-11-18', profile: 'PRODUCTION', channel: 'emporter', externalReference: ' UB-77 ', customerName: 'Awa');
    expect([r.event.action, r.event.state['canal'], r.event.state['etape'], r.event.state['table_uuid'], r.event.state['reference_externe'], r.event.state['client_nom']],
        ['ouverture', 'emporter', null, null, 'UB-77', 'Awa']);
    // Le Service de table garde son canal null et son étape `waiting`.
    final table = e.open(prefix: 'PF', businessDay: '2026-11-18', profile: 'TABLE_SERVICE', tableUuid: 't1', channel: 'emporter');
    expect([table.event.state['canal'], table.event.state['etape']], [null, 'waiting']);
    r = e.editLines(r.order, added: [
      const RestoNewLine(productUuid: 'pizza', label: 'Pizza', quantity: 2 * unit, unitPrice: 5000),
      const RestoNewLine(productUuid: 'biere', label: 'Bière', quantity: unit, unitPrice: 1500),
    ]);
    expect(r.event.state['etape'], isNull, reason: 'une modification ne crée pas d’étape au Restaurant');
    final [pizza, biere] = [for (final l in r.order.lines) l.uuid];
    r = e.validate(r.order);
    expect([r.event.action, r.event.fact, r.tickets, r.order.lines.every((l) => l.status == RestoLineStatus.sent && l.sent == 0)],
        ['validation', {'lignes': [pizza, biere]}, isEmpty, true]);
    expect(() => e.validate(r.order), throwsA(isA<RestoRefusal>()), reason: 'rien de nouveau à valider');
    r = e.prebill(r.order);
    expect(r.event.state['etape'], 'bill_printed');
    // Une pizza réglée (règlement par articles) : la partie réglée ne s'annule ni ne se retire.
    r.order.line(pizza).settled = unit;
    expect(() => e.cancelLine(r.order, pizza, 2 * unit, 'Erreur'), throwsA(isA<RestoRefusal>()));
    expect(() => e.cancelOrder(r.order, 'Client parti'), throwsA(isA<RestoRefusal>()));
    r = e.cancelLine(r.order, pizza, unit, 'Erreur');
    expect([r.order.line(pizza).quantity, r.event.state['lignes'][0]['reglee']], [unit, '1.000000']);
    // Annulation d'une commande du Restaurant : motif de 3 caractères toujours exigé.
    var other = e.open(prefix: 'PF', businessDay: '2026-11-18', profile: 'PRODUCTION', channel: 'sur_place', tableUuid: 't2');
    expect(() => e.cancelOrder(other.order, null), throwsA(isA<RestoRefusal>()));
    expect(() => e.cancelOrder(other.order, 'ok'), throwsA(isA<RestoRefusal>()));
    other = e.cancelOrder(other.order, 'Doublon');
    expect([other.event.reason, other.event.state['statut']], ['Doublon', 'cancelled']);
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


  // ---------------------------------------------------------------- lot R-4 : gestes sur une commande

  RestoResult tableOrder(RestoEngine e, {String table = 't1', int? covers = 2}) {
    final r = e.open(prefix: 'PF', businessDay: '2026-11-17', profile: 'TABLE_SERVICE', tableUuid: table, covers: covers, serverId: '7');
    return e.editLines(r.order, added: [
      const RestoNewLine(productUuid: 'pizza', label: 'Pizza margherita', quantity: unit, unitPrice: 5000, comment: 'Bien cuite'),
      const RestoNewLine(productUuid: 'biere', label: 'Bière 33 cl', quantity: 2 * unit, unitPrice: 1500),
    ]);
  }

  test('R-4 offert : remise = brut, quantité inchangée, motif exigé, jamais deux fois ni remisé ensuite', () {
    final e = engine(send: false);
    var r = tableOrder(e);
    final [pizza, biere] = [for (final l in r.order.lines) l.uuid];
    r = e.prebill(r.order);
    expect(() => e.offer(r.order, biere, 'ok'), throwsA(isA<RestoRefusal>()), reason: 'motif de 3 caractères au moins');
    final auth = {'type': 'resto_offrir', 'approbateur_id': '12', 'motif': 'Anniversaire du client', 'preuve': 'code_local|2026-11-17T20:03:00Z'};
    r = e.offer(r.order, biere, ' Anniversaire du client ', authorizations: [auth]);
    final state = r.event.state;
    final line = (state['lignes'] as List).last as Map;
    // Même forme que la fixture du contrat (operation--resto-commande-offert.json).
    expect([r.event.action, r.event.fact, r.event.reason, r.event.authorizations, r.event.version], ['offert', {'ligne_uuid': biere}, 'Anniversaire du client', [auth], 4]);
    expect([line['quantite'], line['remise'], line['tarif'], state['totaux'], state['etape']],
        ['2.000000', 3000, 'free', {'brut': 8000, 'remises': 3000, 'a_payer': 5000, 'regle': 0}, 'amended']);
    expect(() => e.offer(r.order, biere, 'Encore'), throwsA(isA<RestoRefusal>()), reason: 'déjà offert');
    expect(() => e.discountLine(r.order, biere, percent: true, value: 10, reason: 'Remise'), throwsA(isA<RestoRefusal>()), reason: 'un offert ne se remise pas');
    // Relu depuis la file : toujours offert.
    final again = RestoOrder.fromState(r.order.uuid, r.order.version, state);
    expect([again.line(biere).free, again.line(biere).lineDiscount, again.line(pizza).lineDiscount], [true, 3000, 0]);
    // Un article déjà en partie réglé ne s'offre plus.
    r.order.line(pizza).settled = unit;
    expect(() => e.offer(r.order, pizza, 'Cadeau'), throwsA(isA<RestoRefusal>()));
  });

  test('R-4 remise de ligne : montant ou pourcentage arrondi vers le bas, de 1 F au brut', () {
    final e = engine(send: false);
    var r = tableOrder(e);
    final [pizza, biere] = [for (final l in r.order.lines) l.uuid];
    r = e.discountLine(r.order, pizza, percent: true, value: 10, reason: 'Attente trop longue');
    expect([r.event.fact, (r.event.state['lignes'] as List).first['remise'], (r.event.state['lignes'] as List).first['tarif'], r.event.state['totaux']], [
      {'ligne_uuid': pizza, 'saisie': {'type': 'pourcentage', 'valeur': 10}},
      500,
      'manual_discount',
      {'brut': 8000, 'remises': 500, 'a_payer': 7500, 'regle': 0},
    ]);
    // 33 % de 3 000 = 990 ; 33 % de 1 999 = 659,67 → 659 (vers le bas).
    r = e.discountLine(r.order, biere, percent: true, value: 33, reason: 'Geste commercial');
    expect(r.order.line(biere).discount, 990);
    final odd = RestoLine(uuid: 'x', productUuid: 'p', label: 'Plat', quantity: unit, unitPrice: 1999);
    expect([RestoEngine.lineDiscountOf(odd, percent: true, value: 33), RestoEngine.lineDiscountOf(odd, percent: false, value: 700)], [659, 700]);
    expect(RestoEngine.percentOf(990, 3000), 33);
    expect(RestoEngine.percentOf(1001, 3000), 34, reason: 'arrondi au supérieur pour le plafond de l’assistant');
    for (final (percent, value) in [(true, 0), (true, 101), (false, 3001), (false, 0)]) {
      expect(() => e.discountLine(r.order, biere, percent: percent, value: value, reason: 'Hors bornes'), throwsA(isA<RestoRefusal>()), reason: '$percent $value');
    }
    expect(() => e.discountLine(r.order, biere, percent: false, value: 100, reason: ''), throwsA(isA<RestoRefusal>()));
    // Remise montant : remplace la précédente, quantité inchangée.
    r = e.discountLine(r.order, biere, percent: false, value: 3000, reason: 'Tout remisé');
    expect([r.order.line(biere).quantity, r.order.line(biere).discount, r.order.totals(const RestoVat()).payable], [2 * unit, 3000, 4500]);
  });

  test('R-4 remise de commande : plafond du profil sur le montant après remises de ligne, retrait sans motif, jamais après un règlement', () {
    final e = engine(send: false);
    var r = tableOrder(e);
    final pizza = r.order.lines.first.uuid;
    r = e.discountLine(r.order, pizza, percent: false, value: 1000, reason: 'Attente');
    expect([RestoEngine.orderDiscountBase(r.order), RestoEngine.orderDiscountCeiling(r.order, 20)], [7000, 1400]);
    expect(() => e.discountOrder(r.order, 1500, reason: 'Client fidèle', maxPercent: 20), throwsA(isA<RestoRefusal>()), reason: 'plafond');
    expect(() => e.discountOrder(r.order, 1000), throwsA(isA<RestoRefusal>()), reason: 'motif exigé');
    expect(() => e.discountOrder(r.order, 0), throwsA(isA<RestoRefusal>()), reason: 'rien à retirer');
    r = e.discountOrder(r.order, 1000, reason: 'Client fidèle', maxPercent: 20);
    expect([r.event.action, r.event.fact, r.event.reason, r.event.state['remise_globale'], r.event.state['totaux']],
        ['remise', {'montant': 1000}, 'Client fidèle', 1000, {'brut': 8000, 'remises': 2000, 'a_payer': 6000, 'regle': 0}]);
    r = e.discountOrder(r.order, 0);
    expect([r.event.fact, r.event.reason, r.event.authorizations, r.order.globalDiscount], [{'montant': 0}, null, isEmpty, 0]);
    r.order.lines.last.settled = unit;
    expect(() => e.discountOrder(r.order, 500, reason: 'Trop tard'), throwsA(isA<RestoRefusal>()), reason: 'commande déjà réglée en partie');
  });

  test('R-4 annulation partielle : remise proportionnelle (vers le bas), offert reste offert, annulation totale garde quantité et remise', () {
    final e = engine(send: false);
    var r = e.open(prefix: 'PF', businessDay: '2026-11-17', profile: 'TABLE_SERVICE', tableUuid: 't1');
    r = e.editLines(r.order, added: [
      const RestoNewLine(productUuid: 'plat', label: 'Plat', quantity: 3 * unit, unitPrice: 1000),
      const RestoNewLine(productUuid: 'eau', label: 'Eau', quantity: 3 * unit, unitPrice: 500),
    ]);
    final [plat, eau] = [for (final l in r.order.lines) l.uuid];
    r = e.discountLine(r.order, plat, percent: false, value: 1000, reason: 'Geste');
    r = e.offer(r.order, eau, 'Offert maison');
    r = e.send(r.order);
    r = e.cancelLine(r.order, plat, unit, 'Renversé');
    expect([r.order.line(plat).quantity, r.order.line(plat).discount], [2 * unit, 666]);
    r = e.cancelLine(r.order, eau, unit, 'Renversé');
    final eauState = (r.event.state['lignes'] as List).last as Map;
    expect([eauState['quantite'], eauState['remise'], eauState['tarif']], ['2.000000', 1000, 'free']);
    r = e.cancelLine(r.order, plat, 2 * unit, 'Plus de plat');
    final platState = (r.event.state['lignes'] as List).first as Map;
    expect([platState['statut'], platState['quantite'], platState['remise']], ['cancelled', '2.000000', 666], reason: 'le serveur ne change que le statut');
    expect(r.event.state['totaux'], {'brut': 1000, 'remises': 1000, 'a_payer': 0, 'regle': 0});
  });

  test('R-4 déplacement : opération sur la source avec version_cible, la cible ne change pas de version et reçoit les lignes', () {
    final e = engine(send: false);
    var source = tableOrder(e).order;
    var target = tableOrder(e, table: 't2').order;
    target = e.prebill(target).order;
    final [pizza, biere] = [for (final l in source.lines) l.uuid];
    expect(() => e.moveLines(source, source, {biere}), throwsA(isA<RestoRefusal>()), reason: 'même commande');
    expect(() => e.moveLines(source, target, {}), throwsA(isA<RestoRefusal>()));
    final r = e.moveLines(source, target, {biere});
    expect([r.event.action, r.event.fact, r.event.version, r.order.lines.map((l) => l.uuid).toList(), r.event.state['totaux']],
        ['deplacement_lignes', {'vers_commande_uuid': target.uuid, 'version_cible': 3, 'lignes': [biere]}, 3, [pizza], {'brut': 5000, 'remises': 0, 'a_payer': 5000, 'regle': 0}]);
    final received = RestoEngine.receive(target, source, r.event.action, r.event.fact);
    expect([received.version, received.lines.length, received.lines.last.uuid, received.stage, received.covers], [3, 3, biere, 'amended', 2]);
    // La version suivante de la cible porte les lignes reçues.
    final next = e.coversAndServer(received, covers: 4, serverId: '9');
    expect([next.event.version, (next.event.state['lignes'] as List).length, next.event.state['couverts'], next.event.state['serveur_id']], [4, 3, 4, '9']);
    // Ni réglé, ni vers une commande fermée.
    source = r.order;
    source.line(pizza).settled = unit;
    expect(() => e.moveLines(source, received, {pizza}), throwsA(isA<RestoRefusal>()));
    final cancelled = e.cancelOrder(target, 'Erreur').order;
    final other = tableOrder(e, table: 't3').order;
    expect(() => e.moveLines(other, cancelled, {other.lines.first.uuid}), throwsA(isA<RestoRefusal>()), reason: 'cible fermée');
  });

  test('R-4 fusion : source annulée sans ses lignes, couverts (≤ 500) et remises additionnés, client repris si absent', () {
    final e = engine(send: false);
    var source = tableOrder(e, covers: 300).order;
    source = e.discountOrder(source, 1000, reason: 'Client fidèle').order;
    source.comment = 'Anniversaire';
    var target = tableOrder(e, table: 't2', covers: 300).order;
    target = e.discountOrder(target, 500, reason: 'Fidélité').order;
    final r = e.merge(source, target, reason: 'Même tablée');
    expect([r.event.action, r.event.fact, r.event.reason, r.order.status, r.order.lines, r.order.globalDiscount, r.order.covers, r.event.state['etape']],
        ['fusion', {'vers_commande_uuid': target.uuid, 'version_cible': 3}, 'Même tablée', 'cancelled', isEmpty, 1000, 300, 'waiting']);
    expect(r.event.state['totaux'], {'brut': 0, 'remises': 1000, 'a_payer': 0, 'regle': 0});
    final merged = RestoEngine.receive(target, source, 'fusion', r.event.fact);
    expect([merged.version, merged.activeLines.length, merged.covers, merged.globalDiscount, merged.comment, merged.totals(const RestoVat()).payable],
        [3, 4, 500, 1500, 'Anniversaire', 14500]);
    expect(RestoEngine.receive(e.open(prefix: 'PF', businessDay: '2026-11-17', profile: 'TABLE_SERVICE', tableUuid: 't4').order,
        e.open(prefix: 'PF', businessDay: '2026-11-17', profile: 'TABLE_SERVICE', tableUuid: 't5').order, 'fusion', const {}).covers, isNull);
    // Refus : source réglée en partie ; remise de la source vers une cible déjà réglée en partie.
    final settledTarget = target.copy()..lines.first.settled = unit;
    expect(() => e.merge(source, settledTarget), throwsA(isA<RestoRefusal>()));
    final settledSource = source.copy()..lines.first.settled = unit;
    expect(() => e.merge(settledSource, target), throwsA(isA<RestoRefusal>()));
    expect(() => e.merge(source.copy()..globalDiscount = 0, settledTarget), returnsNormally);
  });

  test('R-4 validation client : Service de table, après la préfacture', () {
    final e = engine(send: false);
    var r = tableOrder(e);
    expect(() => e.validateCustomer(r.order), throwsA(isA<RestoRefusal>()), reason: 'préfacture d’abord');
    r = e.prebill(r.order);
    r = e.validateCustomer(r.order);
    expect([r.event.action, r.event.fact, r.event.state['etape'], r.event.state['prefactures']], ['validation_client', isEmpty, 'customer_validated', 1]);
    expect(() => e.validateCustomer(r.order), throwsA(isA<RestoRefusal>()));
    final production = e.open(prefix: 'PF', businessDay: '2026-11-17', profile: 'PRODUCTION', channel: 'sur_place', tableUuid: 't1').order..prebills = 1;
    expect(() => e.validateCustomer(production), throwsA(isA<RestoRefusal>()));
  });
}
