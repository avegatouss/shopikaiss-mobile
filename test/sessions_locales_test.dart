import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shopikaiss_terminal/src/offline/engine.dart';
import 'package:shopikaiss_terminal/src/offline/models.dart';
import 'package:shopikaiss_terminal/src/offline/store.dart';
import 'package:shopikaiss_terminal/src/offline/x_z_report.dart';
import 'package:shopikaiss_terminal/src/register/register_adapter.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_v2_server.dart';
import 'sync_v2_engine_test.dart' show serve21;

/// Sessions locales séparées et journée de caisse hors connexion (contrat 2.1 lot 12, A `1ba7dc61`, note
/// LOT-12-SESSIONS-POUR-B-ET-C.md). Scénario du PEA : clôture restée à arbitrer, nouvelle session hors connexion.
void main() {
  sqfliteFfiInit();
  late Directory dir;
  late SqfliteOfflineStore base;
  late FakeV2Server server;
  var uuids = 0;
  String newUuid() => 'abcdef00-0000-4000-8000-${(++uuids).toString().padLeft(12, '0')}';
  const serverSession2 = '5e55a0d1-0000-4000-8000-000000000002';

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('sessions_locales_');
    base = await SqfliteOfflineStore.open(name: p.join(dir.path, 'caisse.db'), factory: databaseFactoryFfi);
    server = FakeV2Server.sellable();
  });
  tearDown(() async {
    await base.close();
    dir.deleteSync(recursive: true);
  });

  void serve({bool multiple = true, int max = 2}) {
    serve21(server, rules: {if (multiple) 'sessions_locales': {'max': max}});
    server
      ..capabilities = ['instantane.v1', 'stock.couverture', 'vente.especes', 'vente.paiement_declare', 'contrat.2_1', 'session.cloture', if (multiple) 'session.multiple']
      ..put('operateur', 'operateur:7', {
        'operateur_id': '7', 'nom': 'Awa', 'pin_empreinte': 'empreinte', 'droits': ['caisse_cloturer', 'ouverture_session', 'remise', 'vente'],
        'remise_max_pourcent': null, 'remise_max_montant': null, 'approbateur_remise': false,
      }, critical: true)
      ..put('politique', 'session.ouverture_locale', {'cle_politique': 'session.ouverture_locale', 'valeur': true, 'source': 'boutique', 'verrouillee': false});
  }

  Future<V2Engine> engine() async {
    final e = V2Engine.onStore(base, transport: server, appVersion: 'essai', platform: 'windows', newUuid: newUuid,
        pinVerifier: (pin, hash) async => pin == '1234' && hash == 'empreinte', declaredPayments: true, contract21: true);
    await e.load('https://boutique.exemple.ci');
    expect(await e.pair('ABCD-EFGH', model: 'Essai', appVersion: 'essai'), isNull);
    expect((await e.sync()).reachable, isTrue);
    return e;
  }

  Operator awa(V2Engine e) => e.snapshot!.operators.firstWhere((o) => o.name == 'Awa');
  Product savon(V2Engine e) => e.snapshot!.products.firstWhere((p) => p.name == 'Savon');
  CartPayment cash(V2Engine e, int amount) => CartPayment(method: e.snapshot!.methods.firstWhere((m) => m.isCash), amount: amount, received: amount);
  Matcher refused(String text) => throwsA(isA<OfflineRefusal>().having((r) => r.message, 'message', contains(text)));

  test('capacité annoncée ; règle et délai lus ; sans la capacité, le refus d’ouvrir après une clôture à arbitrer reste', () async {
    serve(multiple: false);
    var e = await engine();
    expect(e.multipleSessionsSupported, isFalse);
    await e.closeSession(awa(e), cash: 0);
    server.verdict = (op) => op['type'] == 'cloture_session' ? 'a_arbitrer' : 'integree';
    await e.sync();
    expect(await e.sessionOpeningBlocker(), contains('arbitrage'));
    await expectLater(e.openSession(0, awa(e)), refused('arbitrage'));
    expect(await e.dayClosureBlocker(awa(e)), contains('non disponible'));

    serve(max: 7);
    e = await engine();
    expect((e.multipleSessionsSupported, e.localSessionsMax, e.syncIntervalSeconds), (true, 7, 10));
  });

  test('PEA : ouverture malgré la clôture à arbitrer, attentes non refusées, plafond, rejeu, correspondance, Z de journée', () async {
    serve();
    final e = await engine();
    expect(e.sessionOpen, isTrue, reason: 'session ouverte en ligne, reprise');
    // 1. La session du web est clôturée ici avec un écart, la boutique la met à arbitrer.
    await e.closeSession(awa(e), cash: 0);
    server.verdict = (op) => op['type'] == 'cloture_session' ? 'a_arbitrer' : 'integree';
    await e.sync();
    expect(e.sessionOpen, isFalse, reason: 'la session serveur reste ouverte, mais ce poste l’a clôturée');

    // 2. Nouvelle session hors connexion (refusée avant le lot 12), vente, clôture.
    await e.openSession(1000, awa(e));
    expect(e.sessionOpen, isTrue);
    final local2 = e.snapshot!.session!['session_uuid'] as String;
    await e.recordSale([CartLine(product: savon(e))], [cash(e, 500)], awa(e));
    await e.closeSession(awa(e), cash: 1500);
    // Le serveur attend : ouverture derrière la clôture précédente, vente et clôture derrière leur ouverture.
    server
      ..verdict = ((op) => const {'ouverture_session', 'vente', 'cloture_session'}.contains(op['type']) ? 'recue' : 'integree')
      ..reasonFor = ((op) => op['type'] == 'ouverture_session'
          ? {'code': 'session.cloture_precedente', 'message': 'La clôture précédente attend un arbitrage.', 'details': null}
          : {'code': 'session.ouverture_en_attente', 'message': 'Ouverture pas encore intégrée.', 'details': null});
    await e.sync();
    expect((e.waitingCount, e.localArbitrationCount, e.refusedCount), (3, 1, 0), reason: 'recue n’est pas un refus');
    final status = e.syncStatus;
    expect(status.label(), allOf(contains('3 en attente de session'), contains('1 à arbitrer')));
    expect((status.level, status.secondsLeft(e.now) <= 60, e.syncDue), ('alerte', true, false));
    expect(status.toJson(e.now)['next_attempt'], isA<String>());

    var sessions = await e.localSessions();
    expect([for (final s in sessions) (s.uuid, s.closed, s.awaitingServer)], [(fakeSession, true, true), (local2, true, true)]);
    expect(sessions.first.serverLabel, 'À arbitrer par la boutique');
    expect(sessions.last.serverLabel, 'Attend l’ouverture de sa session au serveur');

    // 3. Plafond (2) : la troisième ouverture attend une connexion.
    expect(await e.sessionOpeningBlocker(), 'Connectez le poste pour synchroniser : 2 sessions attendent la boutique.');
    await expectLater(e.openSession(0, awa(e)), refused('2 sessions attendent la boutique'));

    // 4. Arbitrage au web (« Clôturer avec l'écart constaté »), puis rejeu en chaîne : session serveur distincte.
    void settle(String type, String state) {
      for (final r in server.received.values.where((r) => (r['operation'] as Map)['type'] == type)) {
        r
          ..['etat'] = state
          ..['version'] = (r['version'] as int) + 1
          ..['raison'] = null;
      }
    }

    settle('cloture_session', 'integree');
    settle('ouverture_session', 'integree');
    settle('vente', 'integree');
    server.resultDetails = (op) => op['type'] == 'ouverture_session' ? {'session_serveur': {'session_uuid': serverSession2}} : null;
    server.publish([
      {'type': 'session', 'critique': false, 'cle': 'session:$fakeTerminal', 'revision': '20', 'action': 'upsert',
       'donnees': {'session_uuid': serverSession2, 'ouverte': false, 'ouverte_le': '2026-10-29T09:00:00Z', 'operateur_id': '7'}},
    ]);
    await e.sync();
    sessions = await e.localSessions();
    expect([for (final s in sessions) s.awaitingServer], [false, false]);
    expect(sessions.last.serverUuid, serverSession2, reason: 'correspondance id local ↔ id serveur gardée');
    expect((e.waitingCount, e.localArbitrationCount), (0, 0));
    expect(await e.sessionOpeningBlocker(), isNull);

    // 5. Z de journée du terminal : les deux sessions en un document, opération conforme au contrat.
    expect(await e.dayClosureBlocker(awa(e)), isNull);
    final today = e.today;
    final day = await e.closeDay(awa(e), operationUuid: 'abcdef00-0000-4000-8000-00000000da01');
    expect(day.type, 'cloture_journee');
    final sent = (await e.v2.operation(day.uuid))!['operation'] as Map;
    expect(fakeValidator.validate(sent, 'operation.json'), isEmpty);
    final content = sent['contenu'] as Map;
    expect((content['jour'], content['tickets'], content['chiffre_affaires']), (today, 1, 500));
    expect(content['sessions'], [fakeSession, local2]);
    expect(content['totaux'], [{'moyen': 'especes', 'theorique': 1500, 'compte': 1500}]);
    expect((await e.closeDay(awa(e), operationUuid: day.uuid)).uuid, day.uuid, reason: 'rejeu : même opération');
    final document = (await e.closureDocument(ZKind.terminalDay, ZVersion.detailed))!;
    expect(document.model['titre'], 'Z DE JOURNÉE DU TERMINAL');
    expect((document.model['sessions'] as List).length, 2);
    expect(document.ticket, isNotNull);
    expect(await e.dayClosureBlocker(awa(e)), 'Aucune session clôturée depuis le dernier Z de journée.');
    expect(await e.businessDay(), isNot(today), reason: 'jour clos : la session suivante compte pour le lendemain');
    sessions = await e.localSessions();
    expect([for (final s in sessions) s.day], [today, today]);

    // 6. Journée intégrée, rapprochement rendu par le serveur.
    server.resultDetails = (op) => op['type'] == 'cloture_journee' ? {'journee': {'jour': today, 'sessions': 2, 'ecart': 0}} : null;
    await e.sync();
    expect((await e.v2.operation(day.uuid))!['etat'], 'integree');

    // 7. Session suivante : ouverte, Z de journée refusé tant qu'elle l'est.
    await e.openSession(0, awa(e));
    expect(await e.dayClosureBlocker(awa(e)), 'Clôturez d’abord la session en cours.');
  });

  test('adaptateur : état de synchro, sessions locales, plafond au statut, closeDay et Z de journée', () async {
    serve(max: 1);
    final e = await engine();
    final adapter = LocalRegisterAdapter(e, newUuid: newUuid);
    await adapter.start();
    await adapter.execute('login', {'operator_id': 7, 'pin': '1234'}, null);
    var status = await adapter.execute('status', {}, null);
    expect((status['sync'] as Map)['label'], 'À jour');
    expect(((status['capabilities'] as Map)['close_day'] as Map)['allowed'], isFalse);

    await adapter.execute('closeSession', {'cash': 0}, null);
    status = await adapter.execute('status', {}, null);
    expect(((status['capabilities'] as Map)['open_session'] as Map)['reason'], 'Connectez le poste pour synchroniser : 1 sessions attendent la boutique.');
    expect(((status['capabilities'] as Map)['close_day'] as Map)['allowed'], isTrue);
    final listed = await adapter.execute('localSessions', {}, null);
    expect(((listed['sessions'] as List).single as Map)['awaiting_server'], isTrue);
    expect(listed['max'], 1);

    final closed = await adapter.execute('closeDay', {}, 'abcdef00-0000-4000-8000-00000000da02');
    expect((closed['operation_id'], closed['day']), ('abcdef00-0000-4000-8000-00000000da02', e.today));
    final again = await adapter.execute('closeDay', {}, 'abcdef00-0000-4000-8000-00000000da02');
    expect(again['operation_id'], closed['operation_id'], reason: 'idempotent');
    final document = await adapter.execute('closureDocument', {'kind': ZKind.terminalDay, 'version': ZVersion.short, 'duplicate': false}, null);
    expect(document['lines'], isNotEmpty);
    await adapter.close();
  });
}
