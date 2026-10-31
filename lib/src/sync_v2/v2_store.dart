import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';

import 'canonical_json.dart';
import 'decimal6.dart';
import 'schema_validator.dart';
import 'v2_sale.dart' show V2Vat;

/// Tables du protocole v2 (schéma local 4), créées à côté des tables v1 sans les modifier.
///
/// - `v2_entites` : projection centrale (instantané + journal), une ligne par (type, clé), révision en chaîne ; une
///   suppression garde la ligne (`donnees` NULL) pour qu'une révision plus ancienne ne la ressuscite pas.
/// - `v2_operations` : opérations figées (texte canonique avec empreinte), jamais réécrites ; état local et serveur.
/// - `v2_mouvements` : mouvements de stock locaux, couverts un par un (contrat-v2/README.md §6).
/// - `v2_paniers_consommes` : un brouillon ne donne qu'une vente.
Future<void> createV2SyncTables(DatabaseExecutor db) async {
  await db.execute('CREATE TABLE v2_entites (type TEXT NOT NULL, cle TEXT NOT NULL, revision TEXT NOT NULL, donnees TEXT, PRIMARY KEY (type, cle))');
  await db.execute(
    'CREATE TABLE v2_operations (uuid TEXT PRIMARY KEY, epoque INTEGER NOT NULL, sequence INTEGER NOT NULL, type TEXT NOT NULL, '
    'operation TEXT NOT NULL, etat TEXT NOT NULL, version_etat TEXT NOT NULL, raison TEXT, numero_serveur TEXT, couverture_curseur TEXT, '
    'cree_le TEXT NOT NULL, envoyee_le TEXT, maj_le TEXT NOT NULL, UNIQUE (epoque, sequence))',
  );
  await db.execute('CREATE INDEX v2_operations_etat ON v2_operations (etat, sequence)');
  await db.execute(
    'CREATE TABLE v2_mouvements (uuid TEXT PRIMARY KEY, operation_uuid TEXT NOT NULL, cle TEXT NOT NULL, variation_micros INTEGER NOT NULL, '
    'couvert_le TEXT)',
  );
  await db.execute('CREATE INDEX v2_mouvements_non_couverts ON v2_mouvements (couvert_le, cle)');
  await db.execute('CREATE INDEX v2_mouvements_operation ON v2_mouvements (operation_uuid)');
  await db.execute('CREATE TABLE v2_paniers_consommes (brouillon_uuid TEXT PRIMARY KEY, operation_uuid TEXT NOT NULL UNIQUE)');
}

/// États locaux d'une opération v2 : ceux du serveur (§7), plus deux états propres au terminal.
class V2OperationState {
  /// Jamais envoyée.
  static const toSend = 'a_envoyer';

  /// Envoyée sans réponse exploitable : à renvoyer À L'IDENTIQUE (le serveur rend l'état courant, sans doublon).
  static const sendUnknown = 'envoi_inconnu';
  static const received = 'recue';
  static const integrated = 'integree';
  static const arbitration = 'a_arbitrer';
  static const resolved = 'resolue';

  /// Quarantaine : jamais supprimée, jamais renvoyée, jamais reprise avec un nouvel UUID.
  static const rejected = 'rejet_protocole';

  static const unsent = {toSend, sendUnknown};

  /// États à interroger par `/operations/etats` (la résolution d'un arbitrage arrive aussi par le journal).
  static const awaitingServer = {received, arbitration};
}

class V2Keys {
  static const token = 'v2.jeton';
  static const installation = 'v2.installation';
  static const device = 'v2.appareil';
  static const epoch = 'v2.epoque';
  static const nextSequence = 'v2.sequence_suivante';
  static const cursor = 'v2.curseur';
  static const policiesVersion = 'v2.version_politiques';
  static const serverState = 'v2.etat_serveur';
  static const blocked = 'v2.blocage';
  static const revoked = 'v2.revocation';
  static const origin = 'v2.origine';
  static const nextLocalId = 'v2.id_suivant';

  /// Ouverture de session locale (UUID de l'opération `ouverture_session`) en attente de la session du serveur.
  static const localSession = 'v2.session_locale';
  static const lastContact = 'v2.dernier_contact';
  static const snapshotAt = 'v2.catalogue_le';

  /// Révision des formes de données de la projection (`2.0` ou `2.1`) : un changement impose un nouvel instantané.
  static const contractRevision = 'v2.revision_contrat';

  /// Dernière `cloture_session` émise par ce terminal.
  static const closingOperation = 'v2.cloture_operation';

  /// Préfixe du Z rendu par le serveur pour une clôture (`details.z`).
  static const zPrefix = 'v2.z.';
}

/// Types de changement connus de ce client (donnees.json, révision 2.0.1 : `boutique` ajouté, B-REQ-005).
const knownV2Types = {
  'boutique', 'produit', 'conditionnement', 'code_barre', 'moyen_paiement', 'operateur', 'stock.projection', //
  'politique', 'autorisation', 'revocation', 'session', 'operation_etat',
};

/// Types ajoutés par la révision 2.1 (donnees-2.1.json), connus seulement quand la forme 2.1 est active.
const knownV2Types21 = {'categorie', 'client', 'panier'};

/// Résultat de l'application d'une page du journal.
class V2ApplyResult {
  const V2ApplyResult(this.groups, {this.blockedBy});

  final int groups;

  /// Type critique inconnu (ou données invalides) qui a arrêté l'avancement : mise à jour du client requise.
  final String? blockedBy;
}

/// Donnée critique que ce client ne sait pas appliquer : rien n'est appliqué, mise à jour de l'application requise.
class V2Incompatible implements Exception {
  const V2Incompatible(this.what);

  final String what;

  @override
  String toString() => 'Donnée du serveur non prise en charge par cette version ($what) : mettez l’application à jour.';
}

/// Une vente refusée avant toute écriture.
class V2SaleRefused implements Exception {
  const V2SaleRefused(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Projection centrale, file d'opérations et couverture du stock du protocole v2, sur la base SQLite du terminal.
class V2Store {
  V2Store(this.db, this.validator);

  final Database db;
  final SchemaValidator validator;

  /// Forme 2.1 active (capacité `contrat.2_1` annoncée et rendue) : données validées par donnees-2.1.json.
  bool contract21 = false;

  Set<String> get knownTypes => contract21 ? {...knownV2Types, ...knownV2Types21} : knownV2Types;

  static String _now() => DateTime.now().toUtc().toIso8601String();

  // ---------------------------------------------------------------- clés/valeurs

  Future<String?> read(String key, [DatabaseExecutor? txn]) async {
    final rows = await (txn ?? db).query('kv', where: 'cle = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['valeur'] as String?;
  }

  Future<void> write(String key, String? value, [DatabaseExecutor? txn]) async {
    final executor = txn ?? db;
    if (value == null) {
      await executor.delete('kv', where: 'cle = ?', whereArgs: [key]);
    } else {
      await executor.insert('kv', {'cle': key, 'valeur': value}, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  /// Appairage v2 : nouvelle époque, séquence reprise après celle connue du serveur. Si la boutique change, la
  /// projection et le curseur sont effacés (jamais les opérations).
  Future<void> savePairing({required String token, required int epoch, required Map<String, dynamic> device}) => db.transaction((txn) async {
    final previous = await read(V2Keys.device, txn);
    final previousShop = previous == null ? null : (jsonDecode(previous) as Map)['boutique_uuid'];
    if (previousShop != null && previousShop != device['boutique_uuid']) {
      await txn.delete('v2_entites');
      await write(V2Keys.cursor, null, txn);
      await write(V2Keys.policiesVersion, null, txn);
    }
    await write(V2Keys.token, token, txn);
    await write(V2Keys.epoch, '$epoch', txn);
    await write(V2Keys.device, jsonEncode(device), txn);
    await write(V2Keys.nextSequence, '${(device['derniere_sequence'] as int) + 1}', txn);
    await write(V2Keys.revoked, null, txn);
  });

  // ---------------------------------------------------------------- projection

  /// Bootstrap : remplace la projection et le curseur dans UNE transaction (pages déjà vérifiées). Les opérations
  /// reflétées dans les projections de l'instantané (`couverture.integrees`) voient leurs mouvements couverts ; celles
  /// reçues non intégrées gardent leur consommation. Ventes, brouillons et file ne sont pas touchés.
  Future<void> replaceProjection(List<Map<String, dynamic>> entities, Map<String, dynamic> manifest) => db.transaction((txn) async {
    for (final e in entities) {
      if (!knownTypes.contains(e['type']) && e['critique'] == true) throw V2Incompatible(e['type'] as String);
      final error = _invalidData(e);
      if (error != null) throw V2Incompatible(error);
    }
    await txn.delete('v2_entites');
    final batch = txn.batch();
    for (final e in entities) {
      if (!knownTypes.contains(e['type'])) continue;
      batch.insert('v2_entites', {'type': e['type'], 'cle': e['cle'], 'revision': e['revision'], 'donnees': jsonEncode(e['donnees'])},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
    final coverage = Map<String, dynamic>.from(manifest['couverture'] as Map);
    final now = _now();
    for (final uuid in (coverage['integrees'] as List).cast<String>()) {
      await txn.update('v2_mouvements', {'couvert_le': now}, where: 'operation_uuid = ? AND couvert_le IS NULL', whereArgs: [uuid]);
    }
    await write(V2Keys.cursor, manifest['curseur_base'] as String, txn);
    await write(V2Keys.policiesVersion, (manifest['versions'] as Map)['politiques'] as String, txn);
    await write(V2Keys.blocked, null, txn);
  });

  /// Applique une page du journal, groupe par groupe ; le curseur suivant n'est enregistré, dans la même transaction,
  /// que si TOUS les groupes de la page sont appliqués. Un type critique inconnu arrête avant son groupe : les groupes
  /// déjà appliqués seront relus et ignorés (révisions), jamais sautés.
  Future<V2ApplyResult> applyChanges(Map<String, dynamic> page) => db.transaction((txn) async {
    var applied = 0;
    for (final rawGroup in page['groupes'] as List) {
      final changes = [for (final c in (rawGroup as Map)['changements'] as List) Map<String, dynamic>.from(c as Map)];
      String? blocker;
      for (final c in changes) {
        if (!knownTypes.contains(c['type'])) {
          if (c['critique'] == true) blocker = c['type'] as String;
        } else if (_invalidData(c) != null) {
          blocker = c['type'] as String;
        }
        if (blocker != null) break;
      }
      if (blocker != null) {
        await write(V2Keys.blocked, blocker, txn);
        return V2ApplyResult(applied, blockedBy: blocker);
      }
      for (final c in changes) {
        if (knownTypes.contains(c['type'])) await _applyChange(txn, c);
      }
      applied++;
    }
    await write(V2Keys.cursor, page['curseur_suivant'] as String, txn);
    await write(V2Keys.blocked, null, txn);
    return V2ApplyResult(applied);
  });

  String? _invalidData(Map<String, dynamic> change) {
    final type = change['type'] as String;
    if (!knownTypes.contains(type)) return null;
    if (change['action'] == 'suppression') return null;
    final errors = validator.validate(change['donnees'], '${contract21 ? 'donnees-2.1.json' : 'donnees.json'}#/\$defs/$type');
    return errors.isEmpty ? null : '$type ${change['cle']} : ${errors.first}';
  }

  Future<void> _applyChange(Transaction txn, Map<String, dynamic> c) async {
    final type = c['type'] as String;
    final key = c['cle'] as String;
    final revision = c['revision'] as String;
    final rows = await txn.query('v2_entites', columns: ['revision'], where: 'type = ? AND cle = ?', whereArgs: [type, key], limit: 1);
    final newer = rows.isEmpty || BigInt.parse(revision) > BigInt.parse(rows.first['revision'] as String);
    if (newer) {
      await txn.insert('v2_entites', {'type': type, 'cle': key, 'revision': revision, 'donnees': c['action'] == 'suppression' ? null : jsonEncode(c['donnees'])},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    // Couverture appliquée même pour une révision déjà dépassée : la projection plus récente inclut a fortiori ces
    // mouvements ; l'ignorer laisserait une consommation comptée deux fois.
    if (type == 'stock.projection') {
      final now = _now();
      for (final op in (c['operations_couvertes'] as List? ?? const []).cast<String>()) {
        await txn.update('v2_mouvements', {'couvert_le': now}, where: 'operation_uuid = ? AND cle = ? AND couvert_le IS NULL', whereArgs: [op, key]);
      }
      for (final m in (c['mouvements_couverts'] as List? ?? const []).cast<String>()) {
        await txn.update('v2_mouvements', {'couvert_le': now}, where: 'uuid = ? AND couvert_le IS NULL', whereArgs: [m]);
      }
    }
    if (type == 'operation_etat' && c['action'] != 'suppression') {
      final d = Map<String, dynamic>.from(c['donnees'] as Map);
      await _applyState(txn, {...d, 'uuid': d['operation_uuid']});
    }
  }

  /// Entités en vigueur d'un type (suppressions exclues), indexées par clé.
  Future<Map<String, Map<String, dynamic>>> entities(String type) async {
    final rows = await db.query('v2_entites', where: 'type = ? AND donnees IS NOT NULL', whereArgs: [type]);
    return {for (final r in rows) r['cle'] as String: Map<String, dynamic>.from(jsonDecode(r['donnees'] as String) as Map)};
  }

  /// TVA de la boutique de l'appairage (entité `boutique`, contrat 2.0.1). Null si le serveur ne la publie pas encore
  /// (serveur 2.0.0) : l'appelant ne doit alors vendre que dans une boutique sans TVA connue, jamais deviner un taux.
  Future<V2Vat?> shopVat() async {
    final device = await read(V2Keys.device);
    final shopUuid = device == null ? null : (jsonDecode(device) as Map)['boutique_uuid'] as String?;
    final shop = shopUuid == null ? null : (await entities('boutique'))[shopUuid];
    if (shop == null) return null;
    return V2Vat(rate: shop['tva_taux'] as String, included: shop['tva_incluse'] as bool);
  }

  /// Révisions en vigueur d'un type (pour `revision_prix` des lignes figées), indexées par clé.
  Future<Map<String, String>> revisions(String type) async {
    final rows = await db.query('v2_entites', columns: ['cle', 'revision'], where: 'type = ? AND donnees IS NOT NULL', whereArgs: [type]);
    return {for (final r in rows) r['cle'] as String: r['revision'] as String};
  }

  /// Identifiants entiers locaux des UUID (produits, conditionnements) : attribués une fois, jamais réutilisés ni
  /// renumérotés, pour les écrans et le protocole de l'hôte Windows qui désignent un article par un entier.
  Future<Map<String, int>> localIds(Iterable<String> uuids) => db.transaction((txn) async {
    final ids = <String, int>{};
    for (final r in await txn.rawQuery("SELECT cle, valeur FROM kv WHERE cle LIKE 'v2.id.%'")) {
      ids[(r['cle'] as String).substring(6)] = int.parse(r['valeur'] as String);
    }
    var next = int.parse(await read(V2Keys.nextLocalId, txn) ?? '1');
    final start = next;
    for (final uuid in uuids) {
      if (ids.containsKey(uuid)) continue;
      ids[uuid] = next;
      await write('v2.id.$uuid', '${next++}', txn);
    }
    if (next != start) await write(V2Keys.nextLocalId, '$next', txn);
    return ids;
  });

  /// Opérations du terminal, plus récentes d'abord (historique, réimpression).
  Future<List<Map<String, dynamic>>> operationRows({int? limit}) async {
    final rows = await db.query('v2_operations', orderBy: 'epoque DESC, sequence DESC', limit: limit);
    return [for (final r in rows) _operationRow(r)];
  }

  Map<String, dynamic> _operationRow(Map<String, Object?> r) => {
    'operation': jsonDecode(r['operation'] as String),
    'etat': r['etat'],
    'version_etat': r['version_etat'],
    'raison': r['raison'] == null ? null : jsonDecode(r['raison'] as String),
    'numero_serveur': r['numero_serveur'],
    'couverture_curseur': r['couverture_curseur'],
    'maj_le': r['maj_le'],
  };

  /// Nombre d'opérations par (type, état local).
  Future<Map<(String, String), int>> stateCounts() async {
    final rows = await db.rawQuery('SELECT type, etat, COUNT(*) AS n FROM v2_operations GROUP BY type, etat');
    return {for (final r in rows) (r['type'] as String, r['etat'] as String): r['n'] as int};
  }

  Future<Map<String, int>> counts() async {
    final rows = await db.rawQuery('SELECT type, COUNT(*) AS n FROM v2_entites WHERE donnees IS NOT NULL GROUP BY type');
    return {for (final r in rows) r['type'] as String: r['n'] as int};
  }

  /// Stock estimé par clé (micro-unités) = projection appliquée + mouvements locaux non couverts (§6).
  Future<Map<String, int>> estimatedStock() async {
    final out = <String, int>{};
    for (final entry in (await entities('stock.projection')).entries) {
      out[entry.key] = Decimal6.parseSigned(entry.value['quantite'] as String);
    }
    final rows = await db.rawQuery('SELECT cle, SUM(variation_micros) AS v FROM v2_mouvements WHERE couvert_le IS NULL GROUP BY cle');
    for (final r in rows) {
      out[r['cle'] as String] = (out[r['cle'] as String] ?? 0) + (r['v'] as int);
    }
    return out;
  }

  /// Mouvements locaux non couverts, cumulés par clé de stock (micro-unités, négatif pour une vente).
  Future<Map<String, int>> uncoveredStock() async {
    final rows = await db.rawQuery('SELECT cle, SUM(variation_micros) AS v FROM v2_mouvements WHERE couvert_le IS NULL GROUP BY cle');
    return {for (final r in rows) r['cle'] as String: r['v'] as int};
  }

  // ---------------------------------------------------------------- file

  /// Enregistre une vente v2 : séquence réservée, opération figée (empreinte calculée sur la séquence réservée),
  /// validée contre le contrat, mouvements et consommation du brouillon — tout ou rien.
  ///
  /// [build] reçoit la séquence et rend l'opération complète SANS empreinte.
  Future<Map<String, dynamic>> recordOperation(Map<String, dynamic> Function(int sequence) build, {String? draftUuid}) =>
      db.transaction((txn) async {
        final epoch = int.parse(await read(V2Keys.epoch, txn) ?? (throw const V2SaleRefused('Terminal non appairé en v2.')));
        final sequence = int.parse(await read(V2Keys.nextSequence, txn) ?? '1');
        final operation = build(sequence);
        if ((operation['appareil'] as Map)['epoque'] != epoch || operation['sequence'] != sequence) {
          throw const V2SaleRefused('Opération construite pour une autre époque ou séquence.');
        }
        operation['empreinte'] = CanonicalJson.operationFingerprint(operation);
        final errors = validator.validate(operation, 'operation.json');
        if (errors.isNotEmpty) throw V2SaleRefused('Vente non conforme au contrat v2 : ${errors.first}');
        final uuid = operation['uuid'] as String;
        if ((await txn.query('v2_operations', columns: ['uuid'], where: 'uuid = ?', whereArgs: [uuid], limit: 1)).isNotEmpty) {
          throw V2SaleRefused('Opération $uuid déjà enregistrée.');
        }
        if (draftUuid != null) {
          if ((await txn.query('v2_paniers_consommes', where: 'brouillon_uuid = ?', whereArgs: [draftUuid], limit: 1)).isNotEmpty) {
            throw const V2SaleRefused('Ce panier a déjà été encaissé.');
          }
          await txn.insert('v2_paniers_consommes', {'brouillon_uuid': draftUuid, 'operation_uuid': uuid});
        }
        final now = _now();
        await txn.insert('v2_operations', {
          'uuid': uuid,
          'epoque': epoch,
          'sequence': sequence,
          'type': operation['type'],
          'operation': CanonicalJson.encode(operation),
          'etat': V2OperationState.toSend,
          'version_etat': '0',
          'cree_le': now,
          'maj_le': now,
        });
        if (operation['type'] == 'vente') {
          for (final m in ((operation['contenu'] as Map)['mouvements'] as List).cast<Map>()) {
            final lot = m['lot_uuid'] as String?;
            await txn.insert('v2_mouvements', {
              'uuid': m['mouvement_uuid'],
              'operation_uuid': uuid,
              'cle': lot == null ? m['produit_uuid'] : '${m['produit_uuid']}:$lot',
              'variation_micros': Decimal6.parseSigned(m['variation'] as String),
            });
          }
        }
        await write(V2Keys.nextSequence, '${sequence + 1}', txn);
        return operation;
      }, exclusive: true);

  /// Opérations à (re)transmettre, dans l'ordre des séquences : jamais envoyées ou d'issue inconnue — renvoyées à
  /// l'identique (texte figé).
  Future<List<Map<String, dynamic>>> unsent({int limit = 50}) async {
    final rows = await db.query('v2_operations', columns: ['operation'], where: 'etat IN (?, ?)', whereArgs: V2OperationState.unsent.toList(),
        orderBy: 'epoque, sequence', limit: limit);
    return [for (final r in rows) Map<String, dynamic>.from(jsonDecode(r['operation'] as String) as Map)];
  }

  Future<List<String>> awaitingServer() async {
    final rows = await db.query('v2_operations', columns: ['uuid'], where: 'etat IN (?, ?)', whereArgs: V2OperationState.awaitingServer.toList(),
        orderBy: 'epoque, sequence');
    return [for (final r in rows) r['uuid'] as String];
  }

  Future<void> markSendUnknown(List<String> uuids) => db.transaction((txn) async {
    for (final uuid in uuids) {
      await txn.update('v2_operations', {'etat': V2OperationState.sendUnknown, 'envoyee_le': _now(), 'maj_le': _now()},
          where: 'uuid = ? AND etat IN (?, ?)', whereArgs: [uuid, ...V2OperationState.unsent]);
    }
  });

  /// Résultats de `/operations` ou `/operations/etats`, appliqués ensemble.
  Future<void> applyResults(List<Map<String, dynamic>> results) => db.transaction((txn) async {
    for (final r in results) {
      await _applyState(txn, r);
    }
  });

  Future<void> _applyState(Transaction txn, Map<String, dynamic> r) async {
    final uuid = r['uuid'] as String;
    final rows = await txn.query('v2_operations', where: 'uuid = ?', whereArgs: [uuid], limit: 1);
    if (rows.isEmpty) return; // opération d'un autre terminal
    final row = rows.first;
    final state = r['etat'] as String;
    final now = _now();
    if (state == 'inconnue') {
      // Absente du serveur : renvoi tel quel (jamais pour une quarantaine).
      if (row['etat'] != V2OperationState.rejected) {
        await txn.update('v2_operations', {'etat': V2OperationState.toSend, 'maj_le': now}, where: 'uuid = ?', whereArgs: [uuid]);
      }
      return;
    }
    final version = r['version_etat'] as String;
    final known = row['etat'] as String;
    if (!V2OperationState.unsent.contains(known) && BigInt.parse(version) < BigInt.parse(row['version_etat'] as String)) return;
    final sale = r['vente'] as Map?;
    final cursor = (r['couverture'] as Map?)?['curseur'] as String?;
    final z = (r['details'] as Map?)?['z'];
    if (z != null) await write('${V2Keys.zPrefix}$uuid', jsonEncode(z), txn);
    await txn.update(
      'v2_operations',
      {
        'etat': state,
        'version_etat': version,
        'raison': r['raison'] == null ? null : jsonEncode(r['raison']),
        if (sale != null) 'numero_serveur': sale['numero'],
        'couverture_curseur': ?cursor,
        'envoyee_le': row['envoyee_le'] ?? now,
        'maj_le': now,
      },
      where: 'uuid = ?',
      whereArgs: [uuid],
    );
    // Résolue sans mouvement serveur (équivalent v2 de l'« écartée ») : la consommation locale est retirée ; une sortie
    // réelle de marchandise revient par une projection de stock.
    if (state == V2OperationState.resolved) {
      await txn.update('v2_mouvements', {'couvert_le': now}, where: 'operation_uuid = ? AND couvert_le IS NULL', whereArgs: [uuid]);
    }
  }

  Future<Map<String, dynamic>?> operation(String uuid) async {
    final rows = await db.query('v2_operations', where: 'uuid = ?', whereArgs: [uuid], limit: 1);
    return rows.isEmpty ? null : _operationRow(rows.first);
  }

  Future<List<Map<String, Object?>>> movements(String operationUuid) =>
      db.query('v2_mouvements', where: 'operation_uuid = ?', whereArgs: [operationUuid], orderBy: 'uuid');

  /// État de la file pour `POST /accuses` (`file`).
  Future<Map<String, dynamic>> queueStats() async {
    final rows = await db.rawQuery('SELECT etat, COUNT(*) AS n, MIN(cree_le) AS plus_ancienne FROM v2_operations GROUP BY etat');
    var unsent = 0, unreconciled = 0, arbitration = 0;
    String? oldest;
    for (final r in rows) {
      final n = r['n'] as int;
      switch (r['etat']) {
        case V2OperationState.toSend:
        case V2OperationState.sendUnknown:
          unsent += n;
          final at = r['plus_ancienne'] as String?;
          if (at != null && (oldest == null || at.compareTo(oldest) < 0)) oldest = at;
        case V2OperationState.received:
          unreconciled += n;
        case V2OperationState.arbitration:
          arbitration += n;
      }
    }
    return {
      'non_envoyees': unsent,
      'envoyees_non_reconciliees': unreconciled,
      'a_arbitrer': arbitration,
      'plus_ancienne_non_envoyee_le': oldest == null ? null : '${oldest.substring(0, 19)}Z',
    };
  }
}
