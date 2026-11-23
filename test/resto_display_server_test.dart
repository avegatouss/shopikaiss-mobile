import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shopikaiss_terminal/src/offline/models.dart';
import 'package:shopikaiss_terminal/src/offline/store.dart';
import 'package:shopikaiss_terminal/src/restaurant/resto_context.dart';
import 'package:shopikaiss_terminal/src/restaurant/resto_display_server.dart';
import 'package:shopikaiss_terminal/src/restaurant/resto_engine.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_v2_server.dart';
import 'sync_v2_engine_test.dart' show serve21;

/// Page d'afficheur servie par la caisse maîtresse (lot R-6, décision R10, plan §2 et §7.5).
void main() {
  sqfliteFfiInit();
  late Directory dir;
  late SqfliteOfflineStore base;
  late FakeV2Server server;
  var uuids = 0;
  String newUuid() => 'abcdef00-0000-4000-8000-${(++uuids).toString().padLeft(12, '0')}';
  const pdv = 'b1000000-0000-4000-8000-000000000001';
  const t1 = 'b4000000-0000-4000-8000-000000000001';
  const cuisine = 'b2000000-0000-4000-8000-0000000000c1';
  const bar = 'b2000000-0000-4000-8000-0000000000b1';

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('afficheur_');
    base = await SqfliteOfflineStore.open(name: p.join(dir.path, 'caisse.db'), factory: databaseFactoryFfi);
    server = FakeV2Server.sellable();
  });
  tearDown(() async {
    await base.close();
    dir.deleteSync(recursive: true);
  });

  Future<V2Engine> master(DateTime Function() clock) async {
    Map<String, dynamic> operateur(String id, String nom, List<String> droits) => {
      'operateur_id': id, 'nom': nom, 'pin_empreinte': 'empreinte', 'droits': droits,
      'remise_max_pourcent': null, 'remise_max_montant': null, 'approbateur_remise': false,
    };
    serve21(server);
    server
      ..capabilities = [...server.capabilities, 'session.cloture', 'restaurant.v1']
      ..authorizationExpires = '2026-11-20T00:00:00Z'
      ..restaurant = {'point_de_vente_uuid': pdv, 'profil': 'TABLE_SERVICE', 'maitre': true, 'generation': '3', 'derniers_numeros': null}
      ..put('operateur', 'operateur:8', operateur('8', 'Koffi', ['caisse_service_table', 'caisse_table']), critical: true)
      ..put('restaurant.point_de_vente', pdv, {
        'code': 'SALLE', 'nom': 'Salle', 'profil': 'TABLE_SERVICE', 'actif': true, 'terminaux': [fakeTerminal], 'membres': null,
        'reglages_vente': {'changement_client_paiement': true, 'reference_plateforme_avant_envoi': false, 'verrouillage_minutes': null},
      }, critical: true)
      ..put('restaurant.maitre', 'maitre:$pdv', {
        'point_de_vente_uuid': pdv, 'generation': '3', 'terminal_uuid': fakeTerminal, 'appareil_uuid': fakeDevice, 'epoque': 3, 'designe_le': '2026-11-18T09:30:00Z',
      }, critical: true)
      ..put('restaurant.reglages', 'reglages:$pdv', {
        'point_de_vente_uuid': pdv, 'envoi_production': true, 'plusieurs_commandes_par_table': false, 'prefixe_commande': 'PF', 'motif_annulation_commande': false,
        'registre_obligatoire': false, 'prefacture_a_la_demande': true, 'retard_production_minutes': 15, 'sections_z': <String>[], 'fuseau': 'Africa/Abidjan',
        'impression_mode': 'register', 'repli_premier_poste_actif': false, 'annulation_envoye_responsable': false,
        'assistant': {'max_operations_par_jour': 0, 'max_montant_par_operation': 0, 'max_montant_par_jour': 0, 'max_remise_pourcent': 0},
      }, critical: true)
      ..put('restaurant.table', t1, {'point_de_vente_uuid': pdv, 'salle_uuid': null, 'nom': 'T1', 'code': 'T1', 'capacite': 4, 'ordre': 1, 'actif': true})
      // Cuisine : écran et papier ; bar : écran seul (flux de remise directe).
      ..put('restaurant.poste', cuisine, {'code': 'cui', 'nom': 'Cuisine', 'type': 'kitchen', 'flux': 'preparation', 'ecran': true, 'papier': true, 'ordre': 1, 'actif': true})
      ..put('restaurant.poste', bar, {'code': 'bar', 'nom': 'Bar', 'type': 'bar', 'flux': 'handover', 'ecran': true, 'papier': false, 'ordre': 2, 'actif': true})
      ..put('restaurant.routage', fakeSavon,
          {'routage': 'station', 'poste_uuid': cuisine, 'categorie_poste_uuid': null, 'poste_effectif_uuid': cuisine, 'visible': true, 'ordre': 0, 'favori': false})
      ..put('restaurant.routage', fakeService,
          {'routage': 'station', 'poste_uuid': bar, 'categorie_poste_uuid': null, 'poste_effectif_uuid': bar, 'visible': true, 'ordre': 1, 'favori': false});
    final e = V2Engine.onStore(base, transport: server, appVersion: 'essai', platform: 'android', newUuid: newUuid,
        pinVerifier: FakeV2Server.pinVerifier, contract21: true, announceRestaurant: true, clock: clock);
    await e.load('https://boutique.exemple.ci');
    expect(await e.pair('ABCD-EFGH', model: 'Essai', appVersion: 'essai'), isNull);
    await e.sync();
    expect(e.restaurant!.master, isTrue);
    return e;
  }

  test('écran relié par code, bons accusés, secours sans écran, issue inconnue sans accusé, « prêt » remonté, accès protégé', () async {
    var moment = DateTime.utc(2026, 11, 18, 19, 30);
    final e = await master(() => moment);
    final koffi = e.snapshot!.operators.firstWhere((o) => o.id == 8);
    final printed = <String>[];
    e
      ..restoStationPrinter = ((address, text) async {
        printed.add('poste ${text.first}');
        return RestoOutcome.transmis;
      })
      ..restoRegisterPrinter = ((text) async {
        printed.add('caisse ${text.first}');
        return RestoOutcome.transmis;
      });
    await e.setRestoPrinterAddress(cuisine, '192.168.1.50:9100');

    final display = RestoDisplayServer(e, read: e.v2.read, write: e.v2.write,
        ackTimeout: const Duration(milliseconds: 800), pollHold: const Duration(milliseconds: 300), clock: () => moment);
    await display.start(port: 0);
    addTearDown(display.stop);
    expect(e.restoStationScreen, isNotNull);
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final origin = 'http://127.0.0.1:${display.port}';

    Future<(int, Map)> call(String method, String path, {Object? body, String? token, String? fromOrigin}) async {
      final request = await client.openUrl(method, Uri.parse('$origin$path'));
      if (token != null) request.headers.set('authorization', 'Bearer $token');
      if (fromOrigin != null) request.headers.set('origin', fromOrigin);
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      return (response.statusCode, text.startsWith('{') ? jsonDecode(text) as Map : <String, dynamic>{'texte': text});
    }

    // Page et script servis, avec une politique de contenu stricte.
    final page = await (await client.getUrl(Uri.parse('$origin/'))).close();
    expect(page.headers.value('content-security-policy'), contains("script-src 'self'"));
    expect((await page.transform(utf8.decoder).join()), contains('/app.js'));
    expect((await call('GET', '/app.js')).$2['texte'], contains('/api/bons'));

    // Sans jeton, rien n'est lu ; un code faux ou réutilisé est refusé.
    expect((await call('GET', '/api/bons')).$1, 401);
    expect((await call('POST', '/api/appairage', body: {'code': '000000'})).$1, 401);
    final code = display.newPairingCode();
    expect((await call('POST', '/api/appairage', body: {'code': code}, fromOrigin: 'http://ailleurs.exemple')).$1, 403, reason: 'autre origine');
    final (status, paired) = await call('POST', '/api/appairage', body: {'code': code, 'nom': 'Tablette cuisine'});
    expect(status, 200);
    final token = paired['jeton'] as String;
    expect([for (final s in paired['postes'] as List) (s as Map)['nom']], ['Cuisine', 'Bar']);
    expect((await call('POST', '/api/appairage', body: {'code': code})).$1, 401, reason: 'usage unique');
    expect(display.devices.single.name, 'Tablette cuisine');
    expect(await e.v2.read(RestoDisplayServer.storageKey), isNot(contains(token)), reason: 'seule l’empreinte est gardée');

    // Aucun écran ne regarde : échec certain, la chaîne de secours imprime (cuisine sur papier, bar à la caisse).
    var view = await e.restoOpen(koffi, t1, covers: 2);
    final order = view.order.uuid;
    final savon = e.snapshot!.byCode('6190000000011')!.$1;
    final service = e.snapshot!.products.firstWhere((x) => x.name == 'Emballage');
    await e.restoEditLines(koffi, order, added: [(CartLine(product: savon, quantity: BigInt.from(2000000)), 'Sans oignon'), (CartLine(product: service, quantity: BigInt.from(1000000)), null)]);
    view = await e.restoSend(koffi, order);
    expect(printed, ['poste BON - Cuisine', 'caisse BON - Bar']);

    // L'écran regarde la cuisine et accuse tout ce qu'il reçoit.
    var acking = true;
    var running = true;
    var version = 0;
    final seen = <String>{};
    Future<void> poll() async {
      final (code, body) = await call('GET', '/api/bons?postes=$cuisine${version == 0 ? '' : '&version=$version'}', token: token);
      expect(code, 200);
      version = body['version'] as int;
      final ids = [for (final b in body['bons'] as List) (b as Map)['uuid'] as String];
      seen.addAll(ids);
      if (acking && ids.isNotEmpty) await call('POST', '/api/accuse', body: {'bons': ids}, token: token);
    }

    await poll();
    expect(seen.length, 1, reason: 'le bon déjà imprimé est montré (« déjà imprimé »), celui du bar non');
    final tablet = () async {
      while (running) {
        await poll();
      }
    }();
    await e.restoEditLines(koffi, order, added: [(CartLine(product: savon, quantity: BigInt.from(1000000)), null)]);
    view = await e.restoSend(koffi, order);
    final ajout = view.tickets.single;
    var tickets = {for (final t in await e.restoTickets()) t.ticket.uuid: t};
    expect(tickets[ajout.uuid]!.state, RestoDeliveryState.delivered);
    expect(printed.last, 'poste AJOUT - Cuisine', reason: 'le papier du poste reçoit aussi le bon');

    // L'écran reçoit le bon mais n'accuse pas : issue inconnue, jamais de secours automatique.
    acking = false;
    final before = printed.length;
    await e.restoEditLines(koffi, order, added: [(CartLine(product: savon, quantity: BigInt.from(1000000)), null)]);
    view = await e.restoSend(koffi, order);
    final silent = view.tickets.single;
    tickets = {for (final t in await e.restoTickets()) t.ticket.uuid: t};
    expect(tickets[silent.uuid]!.state, RestoDeliveryState.toCheck);
    expect(printed.length, before + 1, reason: 'seul le papier du poste, aucun secours');
    acking = true;

    // « Prêt » sur l'écran : statut noté source afficheur ; rejeu sans effet ; flux du bar : servi.
    var (code2, ready) = await call('POST', '/api/pret', body: {'bon': ajout.uuid}, token: token);
    expect([code2, (ready['bon'] as Map)['statut'], (ready['bon'] as Map)['termine']], [200, 'ready', true]);
    (code2, ready) = await call('POST', '/api/pret', body: {'bon': ajout.uuid}, token: token);
    expect(code2, 200);
    final barTicket = (await e.restoTickets()).firstWhere((t) => t.ticket.stationUuid == bar);
    (code2, ready) = await call('POST', '/api/pret', body: {'bon': barTicket.ticket.uuid}, token: token);
    expect((ready['bon'] as Map)['statut'], 'served');
    expect((await call('POST', '/api/pret', body: {'bon': 'inconnu'}, token: token)).$1, 404);

    running = false;
    await tablet;

    // Remontée : statuts conformes au contrat, source afficheur, une seule fois.
    moment = moment.add(const Duration(seconds: 30));
    await e.sync();
    final events = [
      for (final r in server.received.values)
        if ((r['operation'] as Map)['type'] == 'resto_bons_etats') ...(((r['operation'] as Map)['contenu'] as Map)['evenements'] as List).cast<Map>(),
    ];
    final statuses = [for (final ev in events) if (ev['type'] == 'statut') (ev['bon_uuid'], ev['de'], ev['vers'], ev['source'])];
    expect(statuses, [(ajout.uuid, 'new', 'ready', 'afficheur'), (barTicket.ticket.uuid, 'new', 'served', 'afficheur')]);
    expect(events.where((ev) => ev['type'] == 'livraison' && ev['cible'] == 'ecran_poste').map((ev) => ev['resultat']).toList(), containsAll(['non_envoye', 'accuse', 'a_verifier']));
    expect(server.received.values.where((r) => (r['operation'] as Map)['type'] == 'resto_bons_etats').every((r) => r['etat'] == 'integree'), isTrue);

    // Retrait de l'écran : son jeton est refusé.
    await display.revoke(display.devices.single.id);
    expect((await call('GET', '/api/bons', token: token)).$1, 401);
    await display.stop();
    expect(e.restoStationScreen, isNull);
  });

  test('réseau local seulement', () {
    bool private(String a) => RestoDisplayServer.isPrivateAddress(InternetAddress(a));
    expect(['192.168.1.20', '10.0.0.5', '172.16.4.1', '172.31.255.1', '127.0.0.1', '169.254.3.3', 'fe80::1', 'fd00::5', '::ffff:192.168.1.9'].every(private), isTrue);
    expect(['8.8.8.8', '172.32.0.1', '100.64.0.1', '2001:db8::1', '::ffff:8.8.8.8'].any(private), isFalse);
  });
}
