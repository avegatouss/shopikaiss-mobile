import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shopikaiss_terminal/src/offline/store.dart';
import 'package:shopikaiss_terminal/src/register/register_adapter.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_v2_server.dart';
import 'sync_v2_engine_test.dart' show serve21;

/// Commandes restaurant de l'adaptateur (version 2) pour l'hôte Windows, sur le moteur v2 réel et SQLite : caissier
/// identifié, identifiant d'opération, rejeu sans double, pont d'impression des bons vers l'interface.
void main() {
  sqfliteFfiInit();
  late Directory dir;
  late SqfliteOfflineStore base;
  late FakeV2Server server;
  var uuids = 0;
  String newUuid() => 'abcdef00-0000-4000-8000-${(++uuids).toString().padLeft(12, '0')}';
  var operations = 0;
  String op() => '0a000000-0000-4000-8000-${(++operations).toString().padLeft(12, '0')}';

  const pdv = 'b1000000-0000-4000-8000-000000000001';
  const t1 = 'b4000000-0000-4000-8000-000000000001';
  const t2 = 'b4000000-0000-4000-8000-000000000002';
  const cuisine = 'b2000000-0000-4000-8000-0000000000c1';
  const bar = 'b2000000-0000-4000-8000-0000000000b1';
  final codeHash = r'$2y$12$' + 'b' * 53;
  final moment = DateTime.utc(2026, 11, 19, 19, 30);

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('adaptateur_resto_');
    base = await SqfliteOfflineStore.open(name: p.join(dir.path, 'caisse.db'), factory: databaseFactoryFfi);
    server = FakeV2Server.sellable();
  });
  tearDown(() async {
    await base.close();
    dir.deleteSync(recursive: true);
  });

  Map<String, dynamic> operateur(String id, String nom, List<String> droits, {String? approbateur}) => {
    'operateur_id': id, 'nom': nom, 'pin_empreinte': 'empreinte', 'droits': droits,
    'remise_max_pourcent': null, 'remise_max_montant': null, 'approbateur_remise': false,
    if (approbateur != null) ...{'approbateur_restaurant': approbateur, 'code_autorisation_empreinte': codeHash},
  };

  /// Caisse maîtresse : Service de table (postes Cuisine papier et Bar écran) ou Restaurant (canaux, registre obligatoire).
  Future<V2Engine> master({bool production = false}) async {
    serve21(server);
    final profile = production ? 'PRODUCTION' : 'TABLE_SERVICE';
    server
      ..capabilities = [...server.capabilities, 'session.cloture', 'restaurant.v1']
      ..authorizationExpires = '2026-11-21T00:00:00Z'
      ..restaurant = {'point_de_vente_uuid': pdv, 'profil': profile, 'maitre': true, 'generation': '3', 'derniers_numeros': {'commande': null, 'bons': <Map<String, dynamic>>[]}}
      ..put('operateur', 'operateur:7', operateur('7', 'Awa', ['caisse_restaurant', 'caisse_service_table', 'caisse_table', 'ouverture_session', 'resto_registre', 'vente']), critical: true)
      ..put('operateur', 'operateur:3', operateur('3', 'Marie', ['caisse_table', 'resto_modifier_envoye', 'resto_offrir', 'remise', 'vente'], approbateur: 'manager'), critical: true)
      ..put('restaurant.point_de_vente', pdv, {
        'code': 'SALLE', 'nom': 'Salle', 'profil': profile, 'actif': true, 'terminaux': [fakeTerminal], 'membres': null,
        'reglages_vente': {'changement_client_paiement': true, 'reference_plateforme_avant_envoi': false, 'verrouillage_minutes': null},
      }, critical: true)
      ..put('restaurant.maitre', 'maitre:$pdv', {
        'point_de_vente_uuid': pdv, 'generation': '3', 'terminal_uuid': fakeTerminal, 'appareil_uuid': fakeDevice, 'epoque': 3, 'designe_le': '2026-11-19T09:30:00Z',
      }, critical: true)
      ..put('restaurant.reglages', 'reglages:$pdv', {
        'point_de_vente_uuid': pdv, 'envoi_production': !production, 'plusieurs_commandes_par_table': false, 'prefixe_commande': 'PF', 'motif_annulation_commande': false,
        'registre_obligatoire': production, 'prefacture_a_la_demande': true, 'retard_production_minutes': 15, 'sections_z': <String>[], 'fuseau': 'Africa/Abidjan',
        'impression_mode': 'register', 'repli_premier_poste_actif': false, 'annulation_envoye_responsable': false,
        'assistant': {'max_operations_par_jour': 0, 'max_montant_par_operation': 0, 'max_montant_par_jour': 0, 'max_remise_pourcent': 0},
      }, critical: true)
      ..put('restaurant.table', t1, {'point_de_vente_uuid': pdv, 'salle_uuid': null, 'nom': 'T1', 'code': 'T1', 'capacite': 4, 'ordre': 1, 'actif': true})
      ..put('restaurant.table', t2, {'point_de_vente_uuid': pdv, 'salle_uuid': null, 'nom': 'T2', 'code': 'T2', 'capacite': 2, 'ordre': 2, 'actif': true});
    if (production) {
      server
        ..put('restaurant.canal', 'c4000000-0000-4000-8000-000000000002', {
          'code': 'emporter', 'nom': 'Emporter', 'type': 'takeaway', 'exige_table': false, 'exige_reference': false, 'suivi_livraison': false, 'ordre': 20, 'actif': true,
        })
        ..put('moyen_paiement', 'moyen:wave', {'code': 'wave', 'nom': 'Wave', 'especes': false, 'local': true, 'reference': 'aucune'})
        ..put('politique', 'paiements.moyens_locaux', {'cle_politique': 'paiements.moyens_locaux', 'valeur': ['especes', 'wave'], 'source': 'boutique', 'verrouillee': false});
    } else {
      server
        ..put('restaurant.poste', cuisine, {'code': 'cui', 'nom': 'Cuisine', 'type': 'kitchen', 'flux': 'preparation', 'ecran': false, 'papier': true, 'ordre': 1, 'actif': true})
        ..put('restaurant.poste', bar, {'code': 'bar', 'nom': 'Bar', 'type': 'bar', 'flux': 'handover', 'ecran': true, 'papier': false, 'ordre': 2, 'actif': true})
        ..put('restaurant.routage', fakeSavon,
            {'routage': 'inherit', 'poste_uuid': null, 'categorie_poste_uuid': cuisine, 'poste_effectif_uuid': cuisine, 'visible': true, 'ordre': 0, 'favori': false})
        ..put('restaurant.routage', fakeService,
            {'routage': 'station', 'poste_uuid': bar, 'categorie_poste_uuid': null, 'poste_effectif_uuid': bar, 'visible': true, 'ordre': 1, 'favori': false});
    }
    final e = V2Engine.onStore(base, transport: server, appVersion: 'essai', platform: 'windows', newUuid: newUuid,
        pinVerifier: (secret, hash) async => hash == codeHash ? secret == '12345678' : FakeV2Server.pinVerifier(secret, hash),
        contract21: true, announceRestaurant: true, declaredPayments: true, clock: () => moment);
    await e.load('https://boutique.exemple.ci');
    expect(await e.pair('ABCD-EFGH', model: 'Windows', appVersion: 'essai'), isNull);
    await e.sync();
    expect(e.restaurant!.master, isTrue);
    return e;
  }

  Matcher failure(String code, {bool notCommitted = true}) =>
      throwsA(isA<AdapterFailure>().having((f) => f.code, 'code', code).having((f) => f.notCommitted, 'notCommitted', notCommitted));

  int savonId(V2Engine e) => e.snapshot!.byCode('6190000000011')!.$1.id;
  int emballageId(V2Engine e) => e.snapshot!.products.firstWhere((p) => p.name == 'Emballage').id;

  test('service de table : caissier et identifiant exigés, ouvrir/éditer/envoyer/régler, rejeu sans double', () async {
    final e = await master();
    final adapter = LocalRegisterAdapter(e, newUuid: newUuid);
    await adapter.start();
    final events = <String>[];
    adapter.committedChanges.listen((c) => events.add(c['reason'] as String));
    Future<Map<String, dynamic>> run(String command, [Map<String, dynamic> args = const {}, String? operation]) => adapter.execute(command, args, operation);

    expect((await run('status'))['version'], 2);
    // Sans caissier : rien ne s'écrit, la salle ne se lit pas.
    await expectLater(run('restoOpen', {'table_uuid': t1}, op()), failure('caissier_requis'));
    await expectLater(run('restaurantView'), failure('caissier_requis'));
    await run('login', {'operator_id': 7, 'pin': '1234'});
    // Sans identifiant d'opération : refus certain.
    await expectLater(run('restoOpen', {'table_uuid': t1}), failure('identifiant_requis'));
    expect(await e.restaurantOrders(), isEmpty);

    var view = await run('restaurantView');
    expect([view['available'], view['profile'], view['master'], [for (final t in view['tables'] as List) (t['name'], t['state'])]],
        [true, 'TABLE_SERVICE', true, [('T1', 'free'), ('T2', 'free')]]);
    // Libellé et réglages publiés par `restaurant.interface` (défauts ici) : Windows n'a pas à lire le moteur.
    expect([view['send_label'], view['interface']], ['Envoyer', {'demander_couverts': true, 'libelle_envoi': 'send', 'navigation_carte': 'chips'}]);

    // Ouvrir : rejouée avec le même identifiant (réponse perdue), la même commande, aucune seconde.
    final opening = op();
    final opened = await run('restoOpen', {'table_uuid': t1, 'covers': 2}, opening);
    final order = (opened['order'] as Map)['order_uuid'] as String;
    final replay = await run('restoOpen', {'table_uuid': t1, 'covers': 2}, opening);
    expect([(replay['order'] as Map)['order_uuid'], replay['replayed'], (await e.restaurantOrders()).length], [order, true, 1]);
    await expectLater(run('restoSend', {'order_uuid': order}, opening), failure('identifiant_reutilise'));

    // Éditer : une version ; rejouée, pas de seconde version.
    final editing = op();
    var edited = await run('restoEditLines', {
      'order_uuid': order,
      'added': [
        {'product_id': savonId(e), 'quantity': '3', 'comment': 'Bien emballé'},
        {'product_id': emballageId(e), 'quantity': '2'},
      ],
    }, editing);
    expect([(edited['order'] as Map)['version'], ((edited['order'] as Map)['lines'] as List).length, (edited['order'] as Map)['payable']], [2, 2, 1700]);
    edited = await run('restoEditLines', {'order_uuid': order, 'added': [{'product_id': savonId(e)}]}, editing);
    expect([(edited['order'] as Map)['version'], edited['replayed'], (await e.restaurantOrders()).single.order.version], [2, true, 2]);

    // Envoyer : deux bons ; sans imprimante joignable par l'hôte, ils sont confiés à l'interface (file durable).
    final sending = op();
    final sent = await run('restoSend', {'order_uuid': order}, sending);
    expect([((sent['order'] as Map)['tickets'] as List).length, (sent['print_jobs'] as List).length], [2, 2]);
    expect(events, contains('resto_impression'));
    final again = await run('restoSend', {'order_uuid': order}, sending);
    expect([again['replayed'], again['print_jobs']], [true, sent['print_jobs']]);
    expect((await run('restoPrintJobs'))['jobs'] as List, hasLength(2), reason: 'rejeu : aucun bon en double');

    // Préfacture : texte local.
    final prebill = await run('restoPrebill', {'order_uuid': order}, op());
    expect([(prebill['order'] as Map)['prebills'], (prebill['prebill_lines'] as List).last], [1, 'Ce document n’est pas un ticket de caisse.']);

    // Régler : préparé puis encaissé, la vente porte l'identifiant ; rejouée, la même vente.
    await expectLater(run('restoSettle', {'order_uuid': order, 'payments': []}, op()), failure('reglement_a_preparer'));
    final prepared = await run('restoPrepareSettlement', {'order_uuid': order});
    expect([prepared['mode'], prepared['payable']], ['full', 1700]);
    await expectLater(run('restoPrepareSettlement', {'order_uuid': order, 'mode': 'items', 'items': {}}), failure('reglement_refuse'));
    await run('restoPrepareSettlement', {'order_uuid': order});
    final settling = op();
    final settled = await run('restoSettle', {'order_uuid': order, 'payments': [{'method': 'especes', 'amount': 1700, 'received': 2000}]}, settling);
    expect([settled['state'], settled['sale_id'], settled['change'], settled['closed']], ['committed', settling, 300, true]);
    final sales = (await e.history()).where((o) => o.isSale).length;
    final replayed = await run('restoSettle', {'order_uuid': order, 'payments': [{'method': 'especes', 'amount': 1700, 'received': 2000}]}, settling);
    expect([replayed['sale_id'], replayed['replayed'], (await e.history()).where((o) => o.isSale).length], [settling, true, sales]);
    expect((await run('saleStatus', {}, settling))['state'], 'committed');
    expect(await e.restaurantOrders(), isEmpty);
    await adapter.close();
  });

  test('gestes autorisés : responsable exigé, informations d’autorisation, code jamais gardé', () async {
    final e = await master();
    final adapter = LocalRegisterAdapter(e, newUuid: newUuid);
    await adapter.start();
    Future<Map<String, dynamic>> run(String command, [Map<String, dynamic> args = const {}, String? operation]) => adapter.execute(command, args, operation);
    await run('login', {'operator_id': 7, 'pin': '1234'});
    final order = ((await run('restoOpen', {'table_uuid': t2}, op()))['order'] as Map)['order_uuid'] as String;
    final line = (((await run('restoEditLines', {'order_uuid': order, 'added': [{'product_id': savonId(e), 'quantity': '2'}]}, op()))['order'] as Map)['lines'] as List)
        .single['line_uuid'] as String;
    await run('restoSend', {'order_uuid': order}, op());

    final info = await run('restoApprovalInfo', {'gesture': 'cancel_line', 'order_uuid': order, 'line_uuid': line, 'quantity': '1'});
    expect([info['required'], info['amount'], [for (final a in info['approvers'] as List) a['name']]], [true, 500, ['Marie']]);
    final cancel = {'order_uuid': order, 'line_uuid': line, 'quantity': '1', 'reason': 'Cassé'};
    await expectLater(run('restoCancelLine', cancel, op()), failure('autorisation_requise'));
    await expectLater(run('restoCancelLine', {...cancel, 'reason': 'x', 'approval': {'approver_id': 3, 'code': '12345678'}}, op()), failure('motif_requis'));
    await expectLater(run('restoCancelLine', {...cancel, 'approval': {'approver_id': 3, 'code': '00000000'}}, op()), failure('autorisation_refusee'));
    final cancelling = op();
    final done = await run('restoCancelLine', {...cancel, 'approval': {'approver_id': 3, 'code': '12345678'}}, cancelling);
    expect([((done['order'] as Map)['lines'] as List).single['quantity'], ((done['order'] as Map)['tickets'] as List).single['title']], ['1.000000', 'ANNULATION']);
    final stored = (await e.v2.operationsOfType('resto_commande')).last['operation']['contenu'] as Map;
    expect([stored['action'], (stored['autorisations'] as List).single['approbateur_id']], ['annulation_ligne', '3']);
    expect(jsonEncode(stored), isNot(contains('12345678')));
    expect(await base.read('resto_operation.$cancelling'), allOf(contains('"etat":"fait"'), isNot(contains('12345678'))),
        reason: 'le code d’autorisation n’est jamais conservé');

    // Remise de ligne : droit Remise absent, responsable exigé ; montant au-delà du brut refusé avant écriture.
    await expectLater(run('restoDiscountLine', {'order_uuid': order, 'line_uuid': line, 'value': 900, 'reason': 'Geste'}, op()), failure('remise_invalide'));
    final discount = await run('restoDiscountLine',
        {'order_uuid': order, 'line_uuid': line, 'percent': true, 'value': 10, 'reason': 'Fidèle', 'approval': {'approver_id': 3, 'code': '12345678'}}, op());
    expect(((discount['order'] as Map)['lines'] as List).single['discount'], 50);
    await adapter.close();
  });

  test('profil Restaurant : registre, canal, règlement par articles puis du reste, rejeu de la vente partielle', () async {
    final e = await master(production: true);
    final adapter = LocalRegisterAdapter(e, newUuid: newUuid);
    await adapter.start();
    Future<Map<String, dynamic>> run(String command, [Map<String, dynamic> args = const {}, String? operation]) => adapter.execute(command, args, operation);
    await run('login', {'operator_id': 7, 'pin': '1234'});
    await expectLater(run('restoOpenOnChannel', {'channel': 'emporter'}, op()), failure('restaurant_refuse'));
    final registering = op();
    final register = await run('restoRegisterOpen', {'note': 'Soir'}, registering);
    expect((register['register'] as Map)['open'], isTrue);
    expect((await run('restoRegisterOpen', {'note': 'Soir'}, registering))['replayed'], isTrue, reason: 'pas de « déjà ouvert » au rejeu');

    final order = ((await run('restoOpenOnChannel', {'channel': 'emporter'}, op()))['order'] as Map)['order_uuid'] as String;
    final line = (((await run('restoEditLines', {'order_uuid': order, 'added': [{'product_id': savonId(e), 'quantity': '4'}]}, op()))['order'] as Map)['lines'] as List)
        .single['line_uuid'] as String;
    final validated = await run('restoSend', {'order_uuid': order}, op());
    expect([((validated['order'] as Map)['tickets'] as List), validated['print_jobs']], [isEmpty, isNull]);

    final items = await run('restoPrepareSettlement', {'order_uuid': order, 'mode': 'items', 'items': {line: '1'}});
    expect(items['payable'], 500);
    final partial = op();
    final first = await run('restoSettle', {'order_uuid': order, 'payments': [{'method': 'especes', 'amount': 500}]}, partial);
    expect([first['closed'], (((first['order'] as Map)['lines'] as List).single)['settled']], [false, '1.000000']);
    final replay = await run('restoSettle', {'order_uuid': order, 'payments': [{'method': 'especes', 'amount': 500}]}, partial);
    expect([replay['sale_id'], replay['replayed'], (await e.restaurantOrders()).single.order.line(line).settled], [partial, true, 1000000]);

    final rest = await run('restoPrepareSettlement', {'order_uuid': order, 'mode': 'shares', 'shares': 2});
    expect([for (final s in rest['shares'] as List) s['amount']], [750, 750]);
    await expectLater(run('restoSettle', {'order_uuid': order, 'payments': [{'method': 'especes', 'amount': 1500}]}, op()), failure('paiement_invalide'));
    await run('restoPrepareSettlement', {'order_uuid': order, 'mode': 'shares', 'shares': 2});
    final last = await run('restoSettle', {
      'order_uuid': order,
      'payments': [{'method': 'especes', 'amount': 750, 'share': 0}, {'method': 'wave', 'amount': 750, 'share': 1}],
    }, op());
    expect(last['closed'], isTrue);
    await adapter.close();
  });

  test('pont d’impression : file durable, une seule impression par travail, acquittement durable, a_verifier jamais relancé', () async {
    final e = await master();
    var adapter = LocalRegisterAdapter(e, newUuid: newUuid);
    await adapter.start();
    Future<Map<String, dynamic>> run(String command, [Map<String, dynamic> args = const {}, String? operation]) => adapter.execute(command, args, operation);
    await run('login', {'operator_id': 7, 'pin': '1234'});
    final order = ((await run('restoOpen', {'table_uuid': t1}, op()))['order'] as Map)['order_uuid'] as String;
    await run('restoEditLines', {'order_uuid': order, 'added': [{'product_id': savonId(e), 'comment': 'Très épicé, à part'}, {'product_id': emballageId(e)}]}, op());
    await run('restoSend', {'order_uuid': order}, op());

    var jobs = ((await run('restoPrintJobs'))['jobs'] as List).cast<Map>();
    expect([for (final j in jobs) (j['station_name'], j['target'], j['state'])], [('Cuisine', 'imprimante_caisse', 'en_attente'), ('Bar', 'imprimante_caisse', 'en_attente')]);
    expect((jobs.first['lines'] as List).first, 'BON - Cuisine');
    // Accents retirés par le moteur comme pour l'imprimante réseau (l'encodeur ESC/POS ne sort que l'ASCII).
    final printed = [for (final j in jobs) ...(j['lines'] as List).cast<String>()];
    expect(printed.where((l) => l.codeUnits.any((c) => c > 127)), isEmpty);
    expect(printed.join(' '), contains('Tres epice, a part'));
    var tickets = ((await run('restoTickets', {'order_uuid': order}))['tickets'] as List).cast<Map>();
    expect({for (final t in tickets) t['state']}, {'en_impression'}, reason: 'aucun résultat inventé avant l’impression');

    // Cuisine : imprimée une seule fois, acquittée transmis ; le rejeu rend la même réponse, un autre résultat est refusé.
    final kitchen = jobs.first['job_id'] as String;
    expect((await run('restoPrintStart', {'job_id': kitchen}))['print'], isTrue);
    expect((await run('restoPrintStart', {'job_id': kitchen}))['print'], isFalse, reason: 'déjà commencé : jamais réimprimé');
    final ack = await run('restoPrintResult', {'job_id': kitchen, 'result': 'transmis'});
    expect([ack['state'], ack['journalized']], ['termine', true]);
    expect((await run('restoPrintResult', {'job_id': kitchen, 'result': 'transmis'}))['replayed'], isTrue);
    await expectLater(run('restoPrintResult', {'job_id': kitchen, 'result': 'a_verifier'}), failure('resultat_deja_enregistre'));

    // Bar : issue inconnue ; le bon est à vérifier sur place, jamais relancé ni secouru.
    final barJob = jobs.last['job_id'] as String;
    await run('restoPrintStart', {'job_id': barJob});
    await run('restoPrintResult', {'job_id': barJob, 'result': 'a_verifier'});
    expect((await run('restoPrintJobs'))['jobs'], isEmpty);
    tickets = ((await run('restoTickets', {'order_uuid': order}))['tickets'] as List).cast<Map>();
    expect({for (final t in tickets) t['station_name']: t['state']}, {'Cuisine': 'livre', 'Bar': 'a_verifier'});
    // Journal : échecs certains des cibles du poste (sans adresse, sans afficheur), puis secours caisse confié à l'interface.
    final journal = [for (final j in jsonDecode((await e.v2.read('v2.resto_bons_journal'))!) as List) (j as Map)['e'] as Map];
    expect([for (final j in journal) (j['cible'], j['resultat'])],
        [('imprimante_poste', 'non_envoye'), ('ecran_poste', 'non_envoye'), ('imprimante_poste', 'non_envoye'), ('imprimante_caisse', 'transmis'), ('imprimante_caisse', 'a_verifier')]);
    expect([for (final j in journal.skip(3)) (j['tentative_uuid'], j['secours'])], [(kitchen, true), (barJob, true)], reason: 'tentative = travail de l’interface');

    // Vérification humaine, puis duplicata confié à l'interface.
    final barTicket = tickets.firstWhere((t) => t['station_name'] == 'Bar')['ticket_uuid'] as String;
    await run('restoVerifyTicket', {'ticket_uuid': barTicket, 'printed': false}, op());
    final duplicate = await run('restoDuplicateTicket', {'ticket_uuid': barTicket, 'reason': 'Bon non sorti'}, op());
    expect([duplicate['result'], (duplicate['print_jobs'] as List).length], ['delegue', 1]);
    jobs = ((await run('restoPrintJobs'))['jobs'] as List).cast<Map>();
    expect([jobs.single['kind'], (jobs.single['lines'] as List).first], ['duplicata', '*** DUPLICATA ***']);

    // Hôte arrêté après l'acquittement durable, avant le journal : repassé au démarrage, une seule fois.
    final stored = (jsonDecode((await base.read('resto_impression.travaux'))!) as List).cast<Map>();
    stored.last
      ..['state'] = 'termine'
      ..['result'] = 'transmis'
      ..['journalized'] = false;
    await base.write('resto_impression.travaux', jsonEncode(stored));
    await adapter.close();
    adapter = LocalRegisterAdapter(e, newUuid: newUuid);
    await adapter.start();
    await run('login', {'operator_id': 7, 'pin': '1234'});
    tickets = ((await run('restoTickets', {'order_uuid': order}))['tickets'] as List).cast<Map>();
    expect(tickets.firstWhere((t) => t['station_name'] == 'Bar')['state'], 'livre', reason: 'duplicata transmis');
    final saved = (jsonDecode((await base.read('resto_impression.travaux'))!) as List).cast<Map>();
    expect(saved.every((j) => j['journalized'] == true), isTrue);
    await adapter.close();
  });

  test('échec certain : non_envoye noté, aucune nouvelle cible après la caisse ; opération interrompue jamais rejouée', () async {
    final e = await master();
    final adapter = LocalRegisterAdapter(e, newUuid: newUuid);
    await adapter.start();
    Future<Map<String, dynamic>> run(String command, [Map<String, dynamic> args = const {}, String? operation]) => adapter.execute(command, args, operation);
    await run('login', {'operator_id': 7, 'pin': '1234'});
    final order = ((await run('restoOpen', {'table_uuid': t1}, op()))['order'] as Map)['order_uuid'] as String;
    await run('restoEditLines', {'order_uuid': order, 'added': [{'product_id': savonId(e)}]}, op());
    await run('restoSend', {'order_uuid': order}, op());
    final job = (((await run('restoPrintJobs'))['jobs'] as List).single as Map)['job_id'] as String;
    final ack = await run('restoPrintResult', {'job_id': job, 'result': 'non_envoye'});
    expect([ack['journalized'], ack['print_jobs']], [true, isNull], reason: 'imprimante de la caisse : dernier secours de la chaîne');
    final ticket = (((await run('restoTickets', {'order_uuid': order}))['tickets'] as List).single as Map);
    expect(ticket['state'], 'echec');

    // L'hôte s'est arrêté pendant une écriture (marqueur « en cours ») : le rejeu ne refait rien, issue à vérifier.
    final interrupted = op();
    await base.write('resto_operation.$interrupted', jsonEncode({'commande': 'restoPrebill', 'etat': 'en_cours'}));
    final version = (await e.restaurantOrders()).single.order.version;
    await expectLater(run('restoPrebill', {'order_uuid': order}, interrupted), failure('resultat_incertain', notCommitted: false));
    expect((await e.restaurantOrders()).single.order.version, version);

    // Encaissement interrompu après la vente : le rejeu la retrouve dans la file et rend la même vente.
    await run('restoPrepareSettlement', {'order_uuid': order});
    final settling = op();
    await run('restoSettle', {'order_uuid': order, 'payments': [{'method': 'especes', 'amount': 500}]}, settling);
    await base.write('resto_operation.$settling', jsonEncode({'commande': 'restoSettle', 'etat': 'en_cours'}));
    final recovered = await run('restoSettle', {'order_uuid': order, 'payments': [{'method': 'especes', 'amount': 500}]}, settling);
    expect([recovered['sale_id'], recovered['replayed'], recovered['closed']], [settling, true, true]);
    await adapter.close();
  });
}
