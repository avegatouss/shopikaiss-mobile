/// Faux serveur v2 partagé par les tests du client, du moteur v2 et de l'hôte Windows.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/sync_v2/canonical_json.dart';
import 'package:shopikaiss_terminal/src/sync_v2/decimal6.dart';
import 'package:shopikaiss_terminal/src/sync_v2/schema_validator.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_transport.dart';

const fakeSavon = '11111111-1111-4111-8111-111111111111';
const fakePack = '22222222-2222-4222-8222-222222222222';
const fakeService = '33333333-3333-4333-8333-333333333333';
const fakeDevice = '44444444-4444-4444-8444-444444444444';
const fakeTerminal = '55555555-5555-4555-8555-555555555555';
const fakeShop = '66666666-6666-4666-8666-666666666666';
const fakeSession = '77777777-7777-4777-8777-777777777777';

final fakeValidator = SchemaValidator((file) => File('test/fixtures/contrat-v2/schemas/$file').readAsStringSync());

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

  /// `details` du résultat d'une opération intégrée.
  Map<String, dynamic>? Function(Map<String, dynamic> op)? resultDetails;
  bool corruptPage = false;
  int? failStatus;
  String failCode = 'indisponible';

  /// Clé web rendue à l'appairage (révision 2.0.2) ; null : serveur 2.0.1.
  String? webKey = 'ClefWeb0123456789abcdefghijklmnopqrstuvwxyzABCDE';

  /// Règles commerciales de la boutique pour le recoupement 2.1 (comme `CoherenceVente` avec `$regles`).
  String percentRounding = 'down';
  ({int step, String mode})? cashRounding;

  /// Capacités rendues à l'appairage et par `/etat`.
  List<String> capabilities = ['instantane.v1', 'stock.couverture', 'vente.especes'];

  /// Autorisation de vente locale rendue par `/etat`.
  bool authorized = true;
  // The default sellable fixture stays valid regardless of the calendar day.
  // Expiry scenarios override this value explicitly.
  String authorizationExpires = '${DateTime.now().toUtc().add(const Duration(days: 1)).toIso8601String().substring(0, 19)}Z';

  /// Entité de l'instantané (avant l'appairage du client).
  void put(String type, String key, Map<String, dynamic> data, {bool critical = false}) =>
      entities['$type|$key'] = {'type': type, 'critique': critical, 'cle': key, 'revision': '1', 'action': 'upsert', 'donnees': data};

  FakeV2Server() {
    put('produit', fakeSavon, {'nom': 'Savon', 'reference': 'SAV', 'categorie': null, 'prix': 500, 'stock_illimite': false, 'actif': true, 'vente_locale': true});
    put('produit', fakeService, {'nom': 'Emballage', 'reference': null, 'categorie': null, 'prix': 100, 'stock_illimite': true, 'actif': true, 'vente_locale': true});
    put('conditionnement', fakePack, {'produit_uuid': fakeSavon, 'nom': 'Carton de 12', 'coefficient': '12.000000', 'prix': 5500, 'defaut': false, 'actif': true});
    put('stock.projection', fakeSavon, {'produit_uuid': fakeSavon, 'lot_uuid': null, 'quantite': '10.000000'});
    put('moyen_paiement', 'moyen:especes', {'code': 'especes', 'nom': 'Espèces', 'especes': true, 'local': true});
    put('operateur', 'operateur:7', {'operateur_id': '7', 'nom': 'Awa', 'pin_empreinte': null, 'droits': ['vente']}, critical: true);
    put('boutique', fakeShop, {'nom': 'Boutique', 'devise': 'FCFA', 'tva_taux': '18.000000', 'tva_incluse': true}, critical: true);
    put('session', 'session:$fakeTerminal', {'session_uuid': fakeSession, 'ouverte': true, 'ouverte_le': '2026-10-29T07:00:00Z', 'operateur_id': '7'});
  }

  /// Boutique prête pour la vente locale : espèces autorisées localement, ouverture de session locale, code-barres du
  /// savon, caissière Awa (7) avec une empreinte de PIN (« 1234 » avec le vérificateur des tests), opérateur sans droit.
  factory FakeV2Server.sellable() => FakeV2Server()
    ..put('politique', 'paiements.moyens_locaux', {'cle_politique': 'paiements.moyens_locaux', 'valeur': ['especes'], 'source': 'defaut', 'verrouillee': false})
    ..put('politique', 'session.ouverture_locale', {'cle_politique': 'session.ouverture_locale', 'valeur': true, 'source': 'defaut', 'verrouillee': false})
    ..put('code_barre', '6190000000011', {'code': '6190000000011', 'produit_uuid': fakeSavon, 'conditionnement_uuid': null})
    ..put('operateur', 'operateur:7', {'operateur_id': '7', 'nom': 'Awa', 'pin_empreinte': 'empreinte', 'droits': ['vente', 'ouverture_session']}, critical: true)
    ..put('operateur', 'operateur:8', {'operateur_id': '8', 'nom': 'Stagiaire', 'pin_empreinte': null, 'droits': <String>[]});

  /// Vérificateur de PIN des tests, assorti à [FakeV2Server.sellable].
  static Future<bool> pinVerifier(String pin, String hash) async => pin == '1234' && hash == 'empreinte';

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
    final errors = fakeValidator.validate(body, schema);
    if (errors.isNotEmpty) throw StateError('Le faux serveur rend une réponse non conforme : $errors');
    return V2Response(status, jsonDecode(jsonEncode(body)));
  }

  void _requireBody(Object? body, String schema) {
    final errors = fakeValidator.validate(body, schema);
    if (errors.isNotEmpty) throw StateError('Requête non conforme au contrat ($schema) : $errors');
  }

  /// Images servies par `GET /images/{uuid}` ; statut forcé par [imageStatus].
  final images = <String, List<int>>{};
  int? imageStatus;

  @override
  Future<V2Response> fetchBytes(String apiBase, String path, {Map<String, String> headers = const {}, Duration? timeout}) async {
    requests.add((method: 'GET', path: path, headers: headers, body: null));
    final status = imageStatus;
    if (status != null) return V2Response(status, null, retryAfter: status == 429 ? 30 : null);
    final bytes = images[path.substring('/images/'.length)];
    return bytes == null ? const V2Response(404, null) : V2Response(200, null, bytes: bytes);
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
    if (method == 'POST' && uri.path.startsWith('/paniers/')) {
      _requireBody(payload, 'paniers.json#/\$defs/demande');
      final uuid = uri.pathSegments[1];
      if (uri.pathSegments[2] == 'liberation') {
        released.add(uuid);
        return const V2Response(204, null);
      }
      if (takenElsewhere.contains(uuid)) return _error(409, 'panier_deja_repris');
      final cart = entities['panier|$uuid'];
      if (cart == null) return _error(404, 'requete_invalide');
      taken.add(uuid);
      final data = cart['donnees'] as Map;
      return _ok({'panier_uuid': uuid, 'libelle': data['libelle'], 'expire_le': '2026-10-29T08:30:00Z', 'contenu': data['contenu']}, 'paniers.json#/\$defs/reprise');
    }
    switch ((method, uri.path)) {
      case ('POST', '/appairage'):
        _requireBody(payload, 'appairage.json#/\$defs/demande');
        if ((payload as Map)['code'] != 'ABCD-EFGH') return _error(422, 'requete_invalide');
        return _ok({
          'jeton': 'jeton-appareil-0123456789',
          'epoque': 3,
          'appareil': {'uuid': fakeDevice, 'nom': 'Poste', 'terminal_uuid': fakeTerminal, 'terminal_nom': 'Caisse 2', 'boutique_uuid': fakeShop, 'boutique_nom': 'Boutique', 'derniere_sequence': 0},
          'capacites_serveur': capabilities,
          'cle_web': ?webKey,
        }, 'appairage.json#/\$defs/reponse');
      case ('GET', '/etat'):
        return _ok({
          'heure_serveur': '2026-10-29T08:00:00Z',
          'protocole': {'courant': 2, 'minimum': 2, 'maximum': 2},
          'capacites_serveur': capabilities,
          'fonctions_restreintes': [],
          'autorisation': {
            'vente_locale': authorized,
            'version': '5',
            'expire_le': authorizationExpires,
            'raison': authorized ? null : {'code': 'vente_locale.desactivee', 'message': 'Désactivée par la boutique', 'details': null},
          },
          'versions': {'politiques': '$sequence', 'calcul': '1', 'schema_instantane': '1'},
          'delais': {'changements_secondes': 10, 'reprise_max_secondes': 60},
          'notifications': {'mode': 'sondage', 'url': null},
        }, 'etat.json');
      case ('POST', '/instantanes'):
        _requireBody(payload, 'instantanes.json#/\$defs/demande');
        final all = entities.values.where((e) => e['action'] == 'upsert').map((e) => {...e}..remove('operations_couvertes')).toList();
        _snapshot = all;
        snapshotReasons.add((payload as Map)['raison'] as String);
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
  final snapshotReasons = <String>[];
  final taken = <String>[];
  final released = <String>[];
  final takenElsewhere = <String>{};
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
      'vente': integrated && r['operation']['type'] == 'vente' ? {'uuid': uuid, 'numero': r['numero']} : null,
      'mouvements': integrated && r['operation']['type'] == 'vente' ? [for (final m in r['operation']['contenu']['mouvements'] as List) m['mouvement_uuid']] : [],
      'couverture': {'curseur': integrated ? _cursor(sequence) : null},
      if (integrated) ...?switch (resultDetails?.call(Map<String, dynamic>.from(r['operation'] as Map))) {
        final details? => {'details': details},
        _ => null,
      },
    };
  }

  Map<String, dynamic> _receive(Map<String, dynamic> op) {
    final uuid = op['uuid'] as String;
    Map<String, dynamic> reject(String code) =>
        {'uuid': uuid, 'etat': 'rejet_protocole', 'version_etat': '1', 'raison': {'code': code, 'message': code, 'details': null}, 'vente': null, 'mouvements': [], 'couverture': {'curseur': null}};
    if (fakeValidator.validate(op, 'operation.json').isNotEmpty) return reject('schema_invalide');
    if (CanonicalJson.operationFingerprint(op) != op['empreinte']) return reject('empreinte_invalide');
    if (op['type'] == 'vente' && coherenceGaps(op, percentRounding: percentRounding, cashRounding: cashRounding).isNotEmpty) return reject('calcul_incoherent');
    final existing = received[uuid];
    if (existing != null) return existing['operation']['empreinte'] == op['empreinte'] ? _result(uuid) : reject('conflit_contenu');
    final state = verdict?.call(op) ?? 'integree';
    received[uuid] = {'operation': op, 'etat': state, 'version': 1, 'numero': 'V-20261029-${(++saleNumber).toString().padLeft(4, '0')}',
      'raison': state == 'a_arbitrer' ? {'code': 'stock.negatif', 'message': 'Stock insuffisant', 'details': null} : null};
    return _result(uuid);
  }
}

/// Recoupement de la référence serveur `CoherenceVente` (lot 1b de la 2.1, 4bb14454) : lignes, quantités de base, brut,
/// remises (saisies comprises), remise globale bornée, TVA, base HT, à payer (livraison), paiements, écart d'arrondi des
/// espèces, mouvements. Écrit indépendamment du moteur (aucune fonction de lib/), comme le serveur PHP.
List<String> coherenceGaps(Map<String, dynamic> op, {String percentRounding = 'down', ({int step, String mode})? cashRounding}) {
  final content = op['contenu'] as Map;
  final gaps = <String>[];
  var gross = 0, lineDiscounts = 0;
  final bases = <String, int>{};
  int entered(Map entry, int base) {
    if (entry['type'] != 'pourcentage') return int.parse(entry['valeur'] as String);
    final parts = (entry['valeur'] as String).split('.');
    final hundredths = int.parse(parts[0]) * 100 + int.parse('${parts.length > 1 ? parts[1] : ''}00'.substring(0, 2));
    final raw = base * hundredths;
    final amount = percentRounding == 'nearest' ? (raw + 5000) ~/ 10000 : raw ~/ 10000;
    return amount > base ? base : amount;
  }

  for (final l in (content['lignes'] as List).cast<Map>()) {
    final q = Decimal6.parse(l['quantite'] as String);
    final amount = Decimal6.amount(l['prix_unitaire'] as int, q);
    if (amount - (l['remise'] as int) != l['total']) gaps.add('total');
    if (l['remise_saisie'] != null && entered(l['remise_saisie'] as Map, amount) != l['remise']) gaps.add('remise_saisie');
    if (Decimal6.multiply(q, Decimal6.parse(l['coefficient'] as String)) != Decimal6.parse(l['quantite_base'] as String)) gaps.add('base');
    gross += amount;
    lineDiscounts += l['remise'] as int;
    bases[l['produit_uuid'] as String] = (bases[l['produit_uuid']] ?? 0) + Decimal6.parse(l['quantite_base'] as String);
  }
  final global = content['remise_globale'] as int;
  final totals = content['totaux'] as Map;
  if (gross != totals['brut']) gaps.add('brut');
  if (lineDiscounts + global != totals['remises']) gaps.add('remises');
  if (global > gross - lineDiscounts) gaps.add('remise_globale');
  if (content['remise_globale_saisie'] != null && entered(content['remise_globale_saisie'] as Map, gross - lineDiscounts) != global) {
    gaps.add('remise_globale_saisie');
  }
  final after = gross - lineDiscounts - global < 0 ? 0 : gross - lineDiscounts - global;
  final tva = content['tva'] as Map;
  final rateMicros = Decimal6.parse(tva['taux'] as String);
  final included = tva['incluse'] == true;
  final numerator = BigInt.from(after) * BigInt.from(rateMicros);
  final denominator = included ? BigInt.from(rateMicros + 100000000) : BigInt.from(100000000);
  final vat = rateMicros == 0 ? 0 : ((numerator * BigInt.two + denominator) ~/ (denominator * BigInt.two)).toInt();
  final net = included ? after : after + vat;
  if (totals['tva'] != vat) gaps.add('tva');
  if (totals['base_ht'] != net - vat) gaps.add('base_ht');
  if (totals['a_payer'] != net + (content['livraison'] as int)) gaps.add('a_payer');
  final payments = (content['paiements'] as List).cast<Map>();
  if (payments.fold<int>(0, (s, p) => s + (p['montant'] as int)) != totals['a_payer']) gaps.add('paiements');
  for (final p in payments) {
    if (p['ecart_arrondi'] == null) continue;
    final amount = p['montant'] as int;
    var expected = 0;
    if (p['moyen'] == 'especes' && cashRounding != null) {
      final r = amount % cashRounding.step;
      final rounded = r == 0
          ? amount
          : switch (cashRounding.mode) {
              'up' => amount - r + cashRounding.step,
              'nearest' => 2 * r > cashRounding.step ? amount - r + cashRounding.step : amount - r,
              _ => amount - r,
            };
      expected = rounded - amount;
    }
    if (p['ecart_arrondi'] != expected) gaps.add('ecart_arrondi');
  }
  final variations = <String, int>{};
  for (final m in (content['mouvements'] as List).cast<Map>()) {
    variations[m['produit_uuid'] as String] = (variations[m['produit_uuid']] ?? 0) + Decimal6.parseSigned(m['variation'] as String);
  }
  variations.forEach((product, v) {
    if (v != -(bases[product] ?? 0)) gaps.add('mouvements');
  });
  return gaps;
}
