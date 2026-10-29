import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shopikaiss_terminal/src/offline/store.dart';
import 'package:shopikaiss_terminal/src/sync_v2/canonical_json.dart';
import 'package:shopikaiss_terminal/src/sync_v2/contract_schemas.dart';
import 'package:shopikaiss_terminal/src/sync_v2/decimal6.dart';
import 'package:shopikaiss_terminal/src/sync_v2/schema_validator.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_client.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_sale.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_store.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_sync.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_transport.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _savon = '11111111-1111-4111-8111-111111111111';
const _pack = '22222222-2222-4222-8222-222222222222';
const _service = '33333333-3333-4333-8333-333333333333';
const _device = '44444444-4444-4444-8444-444444444444';
const _terminal = '55555555-5555-4555-8555-555555555555';
const _shop = '66666666-6666-4666-8666-666666666666';
const _session = '77777777-7777-4777-8777-777777777777';

final _validator = SchemaValidator((file) => File('test/fixtures/contrat-v2/schemas/$file').readAsStringSync());

/// Faux serveur v2 au comportement de la référence A (ReceptionOperations, CoherenceVente, Instantanes, LectureJournal) :
/// chaque requête est validée contre le contrat, chaque réponse est conforme ; pannes injectables.
class FakeV2Server implements V2Transport {
  final requests = <({String method, String path, Map<String, String> headers, Object? body})>[];
  final entities = <String, Map<String, dynamic>>{}; // « type|cle » → changement
  final journal = <({int seq, String group, List<Map<String, dynamic>> changes})>[];
  final received = <String, Map<String, dynamic>>{}; // uuid → {operation, etat, numero}
  var sequence = 10;
  var saleNumber = 0;
  var prunedThrough = 0;

  /// Réponse perdue APRÈS traitement (le serveur a COMMIT, le client ne le sait pas).
  bool loseNextOperationsResponse = false;
  String Function(Map<String, dynamic> op)? verdict;
  bool corruptPage = false;
  int? failStatus;
  String failCode = 'indisponible';

  FakeV2Server() {
    void put(String type, String key, Map<String, dynamic> data, {bool critical = false}) =>
        entities['$type|$key'] = {'type': type, 'critique': critical, 'cle': key, 'revision': '1', 'action': 'upsert', 'donnees': data};
    put('produit', _savon, {'nom': 'Savon', 'reference': 'SAV', 'categorie': null, 'prix': 500, 'stock_illimite': false, 'actif': true, 'vente_locale': true});
    put('produit', _service, {'nom': 'Emballage', 'reference': null, 'categorie': null, 'prix': 100, 'stock_illimite': true, 'actif': true, 'vente_locale': true});
    put('conditionnement', _pack, {'produit_uuid': _savon, 'nom': 'Carton de 12', 'coefficient': '12.000000', 'prix': 5500, 'defaut': false, 'actif': true});
    put('stock.projection', _savon, {'produit_uuid': _savon, 'lot_uuid': null, 'quantite': '10.000000'});
    put('moyen_paiement', 'moyen:especes', {'code': 'especes', 'nom': 'Espèces', 'especes': true, 'local': true});
    put('operateur', 'operateur:7', {'operateur_id': '7', 'nom': 'Awa', 'pin_empreinte': null, 'droits': ['vente']}, critical: true);
    put('session', 'session:$_terminal', {'session_uuid': _session, 'ouverte': true, 'ouverte_le': '2026-10-29T07:00:00Z', 'operateur_id': '7'});
  }

  String _cursor(int seq) => 'c-$seq';

  void publish(List<Map<String, dynamic>> changes) {
    sequence++;
    for (final c in changes) {
      entities['${c['type']}|${c['cle']}'] = c;
    }
    journal.add((seq: sequence, group: _uuid(sequence), changes: changes));
  }

  static String _uuid(int n) => '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';

  V2Response _error(int status, String code, [int? retry]) =>
      V2Response(status, {'erreur': {'code': code, 'message': 'Erreur $code', 'reessayer_apres_secondes': retry, 'details': null}}, retryAfter: retry);

  V2Response _ok(Object body, String schema, [int status = 200]) {
    final errors = _validator.validate(body, schema);
    if (errors.isNotEmpty) throw StateError('Le faux serveur rend une réponse non conforme : $errors');
    return V2Response(status, jsonDecode(jsonEncode(body)));
  }

  void _requireBody(Object? body, String schema) {
    final errors = _validator.validate(body, schema);
    if (errors.isNotEmpty) throw StateError('Requête non conforme au contrat ($schema) : $errors');
  }

  @override
  Future<V2Response> send(String method, String apiBase, String path, {Map<String, String> headers = const {}, Object? body, Duration? timeout}) async {
    final payload = body == null ? null : jsonDecode(jsonEncode(body));
    requests.add((method: method, path: path, headers: headers, body: payload));
    if (path != '/appairage') {
      expect(headers['X-Caisse-Protocole'], '2');
      expect(headers['X-Caisse-Application'], isNotEmpty);
      expect(headers['X-Caisse-Schema-Local'], '4');
      if (headers['Authorization'] != 'Bearer jeton-appareil-0123456789') return _error(401, 'appareil_non_reconnu');
    }
    if (failStatus != null) {
      final status = failStatus!;
      return status == 0 ? const V2Response(0, null) : _error(status, failCode, status == 429 ? 3 : null);
    }
    final uri = Uri.parse('http://x$path');
    switch ((method, uri.path)) {
      case ('POST', '/appairage'):
        _requireBody(payload, 'appairage.json#/\$defs/demande');
        if ((payload as Map)['code'] != 'ABCD-EFGH') return _error(422, 'requete_invalide');
        return _ok({
          'jeton': 'jeton-appareil-0123456789',
          'epoque': 3,
          'appareil': {'uuid': _device, 'nom': 'Poste', 'terminal_uuid': _terminal, 'terminal_nom': 'Caisse 2', 'boutique_uuid': _shop, 'boutique_nom': 'Boutique', 'derniere_sequence': 0},
          'capacites_serveur': ['instantane.v1', 'stock.couverture', 'vente.especes'],
        }, 'appairage.json#/\$defs/reponse');
      case ('GET', '/etat'):
        return _ok({
          'heure_serveur': '2026-10-29T08:00:00Z',
          'protocole': {'courant': 2, 'minimum': 2, 'maximum': 2},
          'capacites_serveur': ['instantane.v1', 'stock.couverture', 'vente.especes'],
          'fonctions_restreintes': [],
          'autorisation': {'vente_locale': true, 'version': '5', 'expire_le': '2026-10-30T08:00:00Z', 'raison': null},
          'versions': {'politiques': '$sequence', 'calcul': '1', 'schema_instantane': '1'},
          'delais': {'changements_secondes': 10, 'reprise_max_secondes': 60},
          'notifications': {'mode': 'sondage', 'url': null},
        }, 'etat.json');
      case ('POST', '/instantanes'):
        _requireBody(payload, 'instantanes.json#/\$defs/demande');
        final all = entities.values.where((e) => e['action'] == 'upsert').map((e) => {...e}..remove('operations_couvertes')).toList();
        _snapshot = all;
        final integrated = [for (final e in received.entries) if (e.value['etat'] == 'integree') e.key];
        return _ok({
          'uuid': '99999999-9999-4999-8999-999999999999',
          'schema': '1',
          'curseur_base': _cursor(sequence),
          'cree_le': '2026-10-29T08:00:00Z',
          'expire_le': '2026-10-29T08:30:00Z',
          'devise': 'FCFA',
          'versions': {'politiques': '$sequence', 'calcul': '1'},
          'pages': {'nombre': 1, 'empreintes': [CanonicalJson.sha256Of(all)]},
          'couverture': {'epoque': 3, 'depuis_sequence': 1, 'integrees': integrated, 'recues_non_integrees': <String>[], 'tronque': false},
        }, 'instantanes.json#/\$defs/manifeste', 201);
      case ('GET', '/instantanes/99999999-9999-4999-8999-999999999999/pages/1'):
        final page = _snapshot!;
        final shown = corruptPage ? [...page.take(page.length - 1)] : page;
        return _ok({'instantane_uuid': '99999999-9999-4999-8999-999999999999', 'page': 1, 'entites': shown, 'empreinte': CanonicalJson.sha256Of(page)},
            'instantanes.json#/\$defs/page');
      case ('GET', '/changements'):
        final since = int.parse(uri.queryParameters['curseur']!.substring(2));
        if (since < prunedThrough) return _error(410, 'curseur_expire');
        final groups = journal.where((g) => g.seq > since).toList();
        return _ok({
          'version': 2,
          'curseur_suivant': _cursor(groups.isEmpty ? since : groups.last.seq),
          'suite': false,
          'groupes': [for (final g in groups) {'uuid': g.group, 'changements': g.changes}],
        }, 'changements.json#/\$defs/page');
      case ('POST', '/operations'):
        _requireBody(payload, 'operations.json#/\$defs/demande');
        final results = [for (final op in (payload as Map)['operations'] as List) _receive(Map<String, dynamic>.from(op as Map))];
        if (loseNextOperationsResponse) {
          loseNextOperationsResponse = false;
          return const V2Response(0, null);
        }
        return _ok({'recu_le': '2026-10-29T08:00:01Z', 'resultats': results}, 'operations.json#/\$defs/reponse');
      case ('POST', '/operations/etats'):
        _requireBody(payload, 'operations.json#/\$defs/demande_etats');
        return _ok({'etats': [for (final u in ((payload as Map)['uuids'] as List).cast<String>()) _result(u)]}, 'operations.json#/\$defs/reponse_etats');
      case ('POST', '/accuses'):
        _requireBody(payload, 'accuses.json#/\$defs/demande');
        lastAck = Map<String, dynamic>.from(payload as Map);
        return const V2Response(204, null);
    }
    return _error(404, 'requete_invalide');
  }

  List<Map<String, dynamic>>? _snapshot;
  Map<String, dynamic>? lastAck;

  Map<String, dynamic> _result(String uuid) {
    final r = received[uuid];
    if (r == null) return {'uuid': uuid, 'etat': 'inconnue', 'version_etat': '0', 'raison': null, 'vente': null, 'mouvements': [], 'couverture': {'curseur': null}};
    final integrated = r['etat'] == 'integree';
    return {
      'uuid': uuid,
      'etat': r['etat'],
      'version_etat': '${r['version']}',
      'raison': r['raison'],
      'vente': integrated ? {'uuid': uuid, 'numero': r['numero']} : null,
      'mouvements': integrated ? [for (final m in r['operation']['contenu']['mouvements'] as List) m['mouvement_uuid']] : [],
      'couverture': {'curseur': integrated ? _cursor(sequence) : null},
    };
  }

  Map<String, dynamic> _receive(Map<String, dynamic> op) {
    final uuid = op['uuid'] as String;
    Map<String, dynamic> reject(String code) =>
        {'uuid': uuid, 'etat': 'rejet_protocole', 'version_etat': '1', 'raison': {'code': code, 'message': code, 'details': null}, 'vente': null, 'mouvements': [], 'couverture': {'curseur': null}};
    if (_validator.validate(op, 'operation.json').isNotEmpty) return reject('schema_invalide');
    if (CanonicalJson.operationFingerprint(op) != op['empreinte']) return reject('empreinte_invalide');
    if (coherenceGaps(op).isNotEmpty) return reject('calcul_incoherent');
    final existing = received[uuid];
    if (existing != null) return existing['operation']['empreinte'] == op['empreinte'] ? _result(uuid) : reject('conflit_contenu');
    final state = verdict?.call(op) ?? 'integree';
    received[uuid] = {'operation': op, 'etat': state, 'version': 1, 'numero': 'V-20261029-${(++saleNumber).toString().padLeft(4, '0')}',
      'raison': state == 'a_arbitrer' ? {'code': 'stock.negatif', 'message': 'Stock insuffisant', 'details': null} : null};
    return _result(uuid);
  }
}

/// Recoupement de la référence serveur `CoherenceVente` (lignes, quantités de base, brut, remises, paiements, mouvements).
List<String> coherenceGaps(Map<String, dynamic> op) {
  final content = op['contenu'] as Map;
  final gaps = <String>[];
  var gross = 0, discounts = content['remise_globale'] as int;
  final bases = <String, int>{};
  for (final l in (content['lignes'] as List).cast<Map>()) {
    final q = Decimal6.parse(l['quantite'] as String);
    final amount = Decimal6.amount(l['prix_unitaire'] as int, q);
    if (amount - (l['remise'] as int) != l['total']) gaps.add('total');
    if (Decimal6.multiply(q, Decimal6.parse(l['coefficient'] as String)) != Decimal6.parse(l['quantite_base'] as String)) gaps.add('base');
    gross += amount;
    discounts += l['remise'] as int;
    bases[l['produit_uuid'] as String] = (bases[l['produit_uuid']] ?? 0) + Decimal6.parse(l['quantite_base'] as String);
  }
  final totals = content['totaux'] as Map;
  if (gross != totals['brut']) gaps.add('brut');
  if (discounts != totals['remises']) gaps.add('remises');
  if ((content['paiements'] as List).fold<int>(0, (s, p) => s + ((p as Map)['montant'] as int)) != totals['a_payer']) gaps.add('paiements');
  final variations = <String, int>{};
  for (final m in (content['mouvements'] as List).cast<Map>()) {
    variations[m['produit_uuid'] as String] = (variations[m['produit_uuid']] ?? 0) + Decimal6.parseSigned(m['variation'] as String);
  }
  variations.forEach((product, v) {
    if (v != -(bases[product] ?? 0)) gaps.add('mouvements');
  });
  return gaps;
}

void main() {
  sqfliteFfiInit();
  late Directory dir;
  late SqfliteOfflineStore base;
  late V2Store store;
  late FakeV2Server server;
  late CaisseV2Client client;
  late V2Sync sync;
  var ids = 0;
  String uuid() => 'abcdef00-0000-4000-8000-${(ids++).toString().padLeft(12, '0')}';

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('sync_v2_');
    base = await SqfliteOfflineStore.open(name: p.join(dir.path, 'caisse.db'), factory: databaseFactoryFfi);
    store = V2Store(base.database, _validator);
    server = FakeV2Server();
    client = CaisseV2Client(apiBase: 'https://boutique.exemple.ci/api/caisse/v2', transport: server, appVersion: '1.2.0', localSchema: offlineSchemaVersion);
    sync = V2Sync(client, store);
    await sync.pair('ABCD-EFGH', platform: 'android', model: 'Essai', newUuid: uuid);
  });
  tearDown(() async {
    await base.close();
    dir.deleteSync(recursive: true);
  });

  /// Vente locale v2 de [quantity] savons (ou d'un carton), payée en espèces.
  Future<Map<String, dynamic>> sell(String quantity, {String? packaging, String? operationUuid, String? draft}) async {
    final products = await store.entities('produit');
    final packs = await store.entities('conditionnement');
    final builder = V2SaleBuilder(products: products, packagings: packs, revisions: const {}, newUuid: uuid);
    final cart = [V2CartLine(productUuid: _savon, packagingUuid: packaging, quantityMicros: Decimal6.parseInput(quantity)!)];
    final payable = builder.payable(cart);
    final device = jsonDecode((await store.read(V2Keys.device))!) as Map;
    final epoch = int.parse((await store.read(V2Keys.epoch))!);
    final opUuid = operationUuid ?? uuid();
    final draftUuid = draft ?? uuid();
    final cursor = await store.read(V2Keys.cursor);
    final policies = await store.read(V2Keys.policiesVersion) ?? '0';
    return store.recordOperation(
      (seq) => v2Operation(
        uuid: opUuid,
        type: 'vente',
        deviceUuid: device['uuid'] as String,
        epoch: epoch,
        sequence: seq,
        createdAt: DateTime.utc(2026, 10, 29, 8),
        operatorId: '7',
        policiesVersion: policies,
        catalogueCursor: cursor,
        content: builder.content(
          numberLocal: 'HL2-3-${seq.toString().padLeft(6, '0')}',
          draftUuid: draftUuid,
          sessionUuid: _session,
          cart: cart,
          payment: V2Payment(method: 'especes', amount: payable, received: payable),
        ),
      ),
      draftUuid: draftUuid,
    );
  }

  Future<int> stock() async => (await store.estimatedStock())[_savon]!;

  test('les schémas embarqués sont exactement ceux du contrat (copie de A)', () {
    for (final f in Directory('test/fixtures/contrat-v2/schemas').listSync().whereType<File>()) {
      expect(contractV2Schemas[p.basename(f.path)], f.readAsStringSync(), reason: p.basename(f.path));
    }
    expect(contractV2Schemas, hasLength(10));
  });

  test('Decimal6 : format du contrat, arrondi demi supérieur comme Brick\\Math', () {
    expect(Decimal6.format(2500000), '2.500000');
    expect(Decimal6.format(-12000000), '-12.000000');
    expect(Decimal6.parseInput('0,5'), 500000);
    expect(Decimal6.parseInput('1.1234567'), isNull);
    expect(Decimal6.amount(333, 1500000), 500); // 499,5 → 500
    expect(Decimal6.multiply(333333, 3000000), 999999);
    expect(Decimal6.label(1500000), '1,5');
  });

  test('premier démarrage : instantané vérifié, projection et curseur posés ensemble, accusé envoyé', () async {
    final report = await sync.run();
    expect(report.complete, isTrue, reason: '$report');
    expect(report.bootstrapped, isTrue);
    expect(await store.read(V2Keys.cursor), 'c-10');
    expect((await store.counts())['produit'], 2);
    expect(await stock(), 10000000);
    expect(server.lastAck!['curseur_applique'], 'c-10');
    expect(server.requests.first.path, '/appairage');
    expect(server.requests[1].headers['X-Caisse-Capacites'], 'vente.especes,stock.couverture,instantane.v1');
  });

  test('page d’instantané altérée : rien n’est appliqué, ni projection ni curseur', () async {
    server.corruptPage = true;
    final report = await sync.run();
    expect(report.failure?.code, 'empreinte_page');
    expect(await store.read(V2Keys.cursor), isNull);
    expect(await store.counts(), isEmpty);
  });

  test('vente v2 : conforme au contrat, recoupée comme CoherenceVente, empreinte vérifiable', () async {
    await sync.run();
    final op = await sell('2', packaging: _pack);
    expect(_validator.validate(op, 'operation.json'), isEmpty);
    expect(coherenceGaps(op), isEmpty);
    expect(CanonicalJson.operationFingerprint(op), op['empreinte']);
    final line = (op['contenu']['lignes'] as List).single as Map;
    expect(line['quantite_base'], '24.000000');
    expect(line['total'], 11000);
    expect((op['contenu']['mouvements'] as List).single['variation'], '-24.000000');
    expect(op['sequence'], 1, reason: 'séquence reprise après derniere_sequence du serveur');
    expect(await stock(), 10000000 - 24000000, reason: 'stock estimé négatif autorisé et visible');
  });

  test('un brouillon ne donne qu’une vente ; rien n’est écrit si la vente est refusée', () async {
    await sync.run();
    await sell('1', draft: 'dddddddd-0000-4000-8000-000000000001');
    await expectLater(sell('1', draft: 'dddddddd-0000-4000-8000-000000000001'), throwsA(isA<V2SaleRefused>()));
    expect((await store.queueStats())['non_envoyees'], 1);
    expect(await store.read(V2Keys.nextSequence), '2', reason: 'séquence non consommée par le refus');
  });

  test('couverture (exemple du doc 01) : 10 → vente de 3 → 7 ; intégrée → 7 ; projection 7 couvrante → 7, jamais 4 ni 10', () async {
    await sync.run();
    final op = await sell('3');
    expect(await stock(), 7000000);
    await sync.run();
    expect((await store.operation(op['uuid'] as String))!['etat'], 'integree');
    expect(await stock(), 7000000, reason: 'l’acquittement « integree » ne couvre rien');
    server.publish([
      {'type': 'stock.projection', 'critique': false, 'cle': _savon, 'revision': '2', 'action': 'upsert',
        'donnees': {'produit_uuid': _savon, 'lot_uuid': null, 'quantite': '7.000000'}, 'operations_couvertes': [op['uuid']]},
    ]);
    await sync.run();
    expect(await stock(), 7000000);
    expect((await store.movements(op['uuid'] as String)).single['couvert_le'], isNotNull);
  });

  test('réponse perdue après COMMIT serveur : « envoi inconnu », renvoi identique, une seule vente côté serveur', () async {
    await sync.run();
    final op = await sell('1');
    server.loseNextOperationsResponse = true;
    final first = await sync.run();
    expect(first.failure?.outcomeUnknown, isTrue);
    expect((await store.operation(op['uuid'] as String))!['etat'], V2OperationState.sendUnknown);
    final second = await sync.run();
    expect(second.complete, isTrue);
    expect(server.received, hasLength(1));
    final sent = server.requests.where((r) => r.path == '/operations').map((r) => ((r.body as Map)['operations'] as List).single).toList();
    expect(sent, hasLength(2));
    expect(CanonicalJson.encode(sent[0]), CanonicalJson.encode(sent[1]), reason: 'renvoi octet pour octet identique');
    expect((await store.operation(op['uuid'] as String))!['numero_serveur'], 'V-20261029-0001');
  });

  test('rejet_protocole : quarantaine conservée, jamais renvoyée ; les autres ventes passent', () async {
    await sync.run();
    final bad = await sell('1');
    final good = await sell('1');
    server.verdict = null;
    // Altération après coup (défaut simulé) : le serveur rejette l'empreinte.
    await base.database.update('v2_operations', {'operation': CanonicalJson.encode({...bad, 'cree_le': '2026-10-29T09:00:00Z'})},
        where: 'uuid = ?', whereArgs: [bad['uuid']]);
    final report = await sync.run();
    expect(report.rejected, 1);
    expect(report.integrated, 1);
    final quarantined = await store.operation(bad['uuid'] as String);
    expect(quarantined!['etat'], V2OperationState.rejected);
    expect((quarantined['raison'] as Map)['code'], 'empreinte_invalide');
    expect((await store.operation(good['uuid'] as String))!['etat'], 'integree');
    await sync.run();
    expect(server.requests.where((r) => r.path == '/operations'), hasLength(1), reason: 'la quarantaine n’est pas renvoyée');
  });

  test('à arbitrer : consommation gardée, état relu par /operations/etats sans renvoi ; résolue → consommation retirée', () async {
    await sync.run();
    server.verdict = (_) => 'a_arbitrer';
    final op = await sell('2');
    await sync.run();
    expect(await stock(), 8000000);
    await sync.run();
    expect(server.requests.where((r) => r.path == '/operations'), hasLength(1));
    expect(server.requests.where((r) => r.path == '/operations/etats'), hasLength(2));
    server.publish([
      {'type': 'operation_etat', 'critique': false, 'cle': op['uuid'], 'revision': '2', 'action': 'upsert',
        'donnees': {'operation_uuid': op['uuid'], 'etat': 'resolue', 'version_etat': '2', 'raison': null}},
    ]);
    server.received[op['uuid']]!['etat'] = 'resolue';
    server.received[op['uuid']]!['version'] = 2;
    await sync.run();
    expect((await store.operation(op['uuid'] as String))!['etat'], 'resolue');
    expect(await stock(), 10000000);
  });

  test('type critique inconnu : arrêt avant son groupe, curseur non avancé ; les groupes déjà vus restent idempotents', () async {
    await sync.run();
    server.publish([
      {'type': 'produit', 'critique': false, 'cle': _savon, 'revision': '2', 'action': 'upsert',
        'donnees': {'nom': 'Savon noir', 'reference': 'SAV', 'categorie': null, 'prix': 600, 'stock_illimite': false, 'actif': true, 'vente_locale': true}},
    ]);
    server.publish([{'type': 'credit.solde', 'critique': true, 'cle': 'client:1', 'revision': '1', 'action': 'upsert', 'donnees': {'solde': 1}}]);
    final report = await sync.run();
    expect(report.blockedBy, 'credit.solde');
    expect(await store.read(V2Keys.cursor), 'c-10');
    expect((await store.entities('produit'))[_savon]!['prix'], 600, reason: 'groupe précédent appliqué');
    expect(await store.read(V2Keys.blocked), 'credit.solde');
    server.publish([{'type': 'notes.internes', 'critique': false, 'cle': 'n1', 'revision': '1', 'action': 'upsert', 'donnees': {'x': 1}}]);
    expect((await sync.run()).blockedBy, 'credit.solde', reason: 'jamais sauté silencieusement');
  });

  test('révision dépassée ignorée ; suppression gardée en pierre tombale', () async {
    await sync.run();
    server.publish([
      {'type': 'produit', 'critique': false, 'cle': _service, 'revision': '5', 'action': 'suppression', 'donnees': null},
    ]);
    server.publish([
      {'type': 'produit', 'critique': false, 'cle': _service, 'revision': '4', 'action': 'upsert',
        'donnees': {'nom': 'Ancien', 'reference': null, 'categorie': null, 'prix': 1, 'stock_illimite': true, 'actif': true, 'vente_locale': true}},
    ]);
    await sync.run();
    expect((await store.entities('produit')).containsKey(_service), isFalse);
  });

  test('curseur expiré (410) : nouvel instantané avec réconciliation, file conservée', () async {
    await sync.run();
    await sell('1');
    await sell('2');
    await sync.run();
    final kept = await sell('1'); // pas encore envoyée
    server.publish([{'type': 'moyen_paiement', 'critique': false, 'cle': 'moyen:om', 'revision': '1', 'action': 'upsert',
      'donnees': {'code': 'om', 'nom': 'Orange Money', 'especes': false, 'local': false}}]);
    server.prunedThrough = 100;
    // L'envoi passe d'abord, puis le journal répond 410 : instantané.
    final report = await sync.run();
    expect(report.bootstrapped, isTrue, reason: '$report');
    expect((await store.operation(kept['uuid'] as String))!['etat'], 'integree');
    expect((await store.entities('moyen_paiement')).containsKey('moyen:om'), isTrue);
    expect(await store.read(V2Keys.cursor), 'c-11');
    // Les trois ventes sont « integrees » dans la couverture du manifeste : reflétées par sa projection (10 dans ce
    // faux serveur), leur consommation locale est retirée — pas de double décompte.
    expect(await stock(), 10000000);
  });

  test('401 : révocation notée, file conservée, aucune donnée effacée', () async {
    await sync.run();
    final op = await sell('1');
    client.token = 'jeton-revoque-0000000000';
    final report = await sync.run();
    expect(report.failure?.kind, V2FailureKind.unauthorized);
    expect(await store.read(V2Keys.revoked), 'appareil_non_reconnu');
    expect((await store.operation(op['uuid'] as String))!['etat'], V2OperationState.toSend);
    expect(await stock(), 9000000);
  });

  test('429 et 5xx : Retry-After rendu, résultat inconnu pour 5xx, rien de perdu', () async {
    await sync.run();
    await sell('1');
    server.failStatus = 429;
    server.failCode = 'trop_de_requetes';
    var report = await sync.run();
    expect(report.failure?.kind, V2FailureKind.throttled);
    expect(report.failure?.retryAfter, const Duration(seconds: 3));
    server.failStatus = 503;
    server.failCode = 'indisponible';
    report = await sync.run();
    expect(report.failure?.outcomeUnknown, isTrue);
    server.failStatus = null;
    expect((await sync.run()).integrated, 1);
    final delay = CaisseV2Client.backoff(3, retryAfter: const Duration(seconds: 3));
    expect(delay.inSeconds, inInclusiveRange(3, 5));
  });

  test('migration 3 → 4 : tables v2 ajoutées, file v1 intacte', () async {
    final path = p.join(dir.path, 'ancienne.db');
    final old = await SqfliteOfflineStore.open(name: path, factory: databaseFactoryFfi);
    await old.database.insert('kv', {'cle': 'jeton', 'valeur': 'v1'});
    for (final t in ['v2_entites', 'v2_operations', 'v2_mouvements', 'v2_paniers_consommes']) {
      await old.database.execute('DROP TABLE $t');
    }
    await old.database.setVersion(3);
    await old.close();
    final reopened = await SqfliteOfflineStore.open(name: path, factory: databaseFactoryFfi);
    expect(await reopened.database.getVersion(), 4);
    expect(await reopened.read('jeton'), 'v1');
    expect(await reopened.database.query('v2_operations'), isEmpty);
    await reopened.close();
  });
}
