import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/uuid.dart';

import 'models.dart';

/// Mémoire durable de la caisse hors ligne sur le terminal : appairage, dernier référentiel, file des opérations.
///
/// Une vente hors ligne est écrite ici, avec son numéro de ticket, AVANT l'impression : si le terminal s'éteint, elle
/// est retrouvée au redémarrage et part à la prochaine connexion.
///
/// Schéma 2 (caisse autonome, lot B) : la vente, ses mouvements de stock (conversion figée) et la consommation de son
/// panier sont écrits dans UNE transaction, numéro de séquence réservé dans cette même transaction. Une opération dont
/// le serveur n'a pas donné le sort définitif n'est jamais purgée.
abstract class OfflineStore {
  Future<String?> read(String key);
  Future<void> write(String key, String? value);

  /// Ajoute une opération et réserve son numéro de séquence en une seule écriture.
  Future<void> append(OfflineOperation operation);

  /// Enregistre une opération en une transaction : séquence réservée (au-dessus de [sequenceFloor] et de toutes les
  /// séquences déjà utilisées), opération, mouvements de stock et consommation du panier [draftUuid].
  ///
  /// Lève [DraftAlreadyConsumed] si ce panier a déjà été encaissé : rien n'est écrit.
  Future<OfflineOperation> appendAtomic({
    required int sequenceFloor,
    required OfflineOperation Function(int sequence) build,
    List<StockMovement> Function(OfflineOperation operation)? movements,
    String? draftUuid,
  });

  Future<void> update(OfflineOperation operation);
  Future<List<OfflineOperation>> operations({String? status, int? limit});

  /// Opérations reçues par le serveur mais encore à arbitrer, les plus anciennes d'abord.
  Future<List<OfflineOperation>> awaitingArbitration({int limit = 50});

  /// Compteurs de la file (requêtes d'agrégat, sans charger les opérations).
  Future<QueueCounts> counts();

  /// Somme des mouvements non couverts par produit (millionièmes de l'unité de base, signée).
  Future<Map<int, int>> uncoveredStock();

  /// Mouvements de stock d'une opération.
  Future<List<StockMovement>> movements(String operationUuid);

  /// Remplace le référentiel et couvre, dans la même transaction, les mouvements que son stock reflète.
  ///
  /// Avec [coverage] (serveur B-REQ-002) : exactement les ventes `integrees`, plus les `ecartees` (sort définitif décidé
  /// par la boutique ; une correction de stock éventuelle y passe par un mouvement serveur) ; leur statut local est
  /// aligné. Sans [coverage] (serveur antérieur) : les opérations au sort définitif connu avant [coverResolvedBefore].
  Future<void> saveSnapshot({required String json, required DateTime at, required DateTime coverResolvedBefore, StockCoverage? coverage});

  /// Séquence de la plus ancienne vente dont la consommation n'est pas couverte, ou null.
  Future<int?> oldestUncoveredSequence();

  /// Retire les opérations au sort définitif, transmises depuis plus de [keep] et dont le stock est couvert.
  Future<void> purgeSent(Duration keep);
}

/// Clés de [OfflineStore.read].
class StoreKeys {
  static const token = 'jeton';
  static const webToken = 'cle_web';
  static const deviceName = 'appareil';
  static const apiBase = 'api';
  static const snapshot = 'referentiel';
  static const snapshotAt = 'referentiel_le';
  static const lastContact = 'dernier_contact';
  static const lastSequence = 'derniere_sequence';
  static const offlineSince = 'hors_ligne_depuis';
  static const localSession = 'session_locale';

  /// Préfixe des échecs de PIN hors ligne d'un caissier (`pin_echecs_<id>` = `nombre|fin du blocage`).
  static const pinFailures = 'pin_echecs_';
}

/// Version du schéma SQLite local. Les migrations sont additives : aucune donnée existante n'est réécrite.
const offlineSchemaVersion = 2;

/// Espace de noms des identifiants de mouvements : `v5(espace, "<uuid opération>:<rang de ligne>")`, recalculable à
/// l'identique (migration, reprise) sans dépendre d'un tirage aléatoire.
const _movementNamespace = '6f1c2f0e-4f7b-4d3a-9a8e-5b2d7c9e1a30';

String movementUuid(String operationUuid, int index) => const Uuid().v5(_movementNamespace, '$operationUuid:$index');

Map<String, Object?> _row(OfflineOperation o) => {
  'uuid': o.uuid,
  'sequence': o.sequence,
  'type': o.type,
  'numero': o.number,
  'date': o.date.toUtc().toIso8601String(),
  'caissier_id': o.operatorId,
  'contenu': jsonEncode(o.content),
  'statut': o.status,
  'statut_serveur': o.serverStatus,
  'numero_serveur': o.serverNumber,
  'message': o.message,
  'resolue_le': o.resolvedAt?.toUtc().toIso8601String(),
};

OfflineOperation _operation(Map<String, Object?> r) => OfflineOperation(
  uuid: r['uuid'] as String,
  sequence: r['sequence'] as int,
  type: r['type'] as String,
  number: r['numero'] as String?,
  date: DateTime.parse(r['date'] as String).toLocal(),
  operatorId: r['caissier_id'] as int,
  content: Map<String, dynamic>.from(jsonDecode(r['contenu'] as String) as Map),
  status: r['statut'] as String,
  serverStatus: r['statut_serveur'] as String?,
  serverNumber: r['numero_serveur'] as String?,
  message: r['message'] as String?,
  resolvedAt: DateTime.tryParse(r['resolue_le'] as String? ?? '')?.toLocal(),
);

StockMovement _movement(Map<String, Object?> r) => StockMovement(
  uuid: r['uuid'] as String,
  operationUuid: r['operation_uuid'] as String,
  productId: r['produit_id'] as int,
  quantityMicros: r['quantite_micros'] as int,
  coveredAt: DateTime.tryParse(r['couvert_le'] as String? ?? '')?.toLocal(),
);

Future<void> _createV2Tables(DatabaseExecutor db) async {
  await db.execute(
    'CREATE TABLE mouvements_stock (uuid TEXT PRIMARY KEY, operation_uuid TEXT NOT NULL, produit_id INTEGER NOT NULL, '
    'quantite_micros INTEGER NOT NULL, couvert_le TEXT, cree_le TEXT NOT NULL)',
  );
  await db.execute('CREATE INDEX mouvements_non_couverts ON mouvements_stock (couvert_le, produit_id)');
  await db.execute('CREATE INDEX mouvements_operation ON mouvements_stock (operation_uuid)');
  await db.execute('CREATE TABLE paniers_consommes (brouillon_uuid TEXT PRIMARY KEY, operation_uuid TEXT NOT NULL UNIQUE, consomme_le TEXT NOT NULL)');
  await db.execute('CREATE INDEX operations_serveur ON operations (statut_serveur, sequence)');
}

/// Migration 1 → 2 : colonnes et tables ajoutées, mouvements reconstitués pour les ventes déjà présentes.
///
/// Les ventes encore en attente gardent leur consommation (non couverte) ; les ventes déjà transmises sont marquées
/// couvertes, exactement comme la version 1 les comptait. UUID, séquences, contenus et statuts ne sont pas modifiés.
Future<void> _migrateTo2(DatabaseExecutor db) async {
  await db.execute('ALTER TABLE operations ADD COLUMN resolue_le TEXT');
  await _createV2Tables(db);
  await db.execute("UPDATE operations SET resolue_le = transmise_le WHERE statut_serveur IN ('integree', 'ecartee')");

  final coefficients = <int, Map<int, BigInt>>{};
  final rawSnapshot = await db.query('kv', where: 'cle = ?', whereArgs: [StoreKeys.snapshot], limit: 1);
  if (rawSnapshot.isNotEmpty) {
    try {
      final snapshot = jsonDecode(rawSnapshot.first['valeur'] as String) as Map;
      for (final product in (snapshot['produits'] as List? ?? const [])) {
        final id = ((product as Map)['id'] as num).toInt();
        coefficients[id] = {
          for (final pack in (product['conditionnements'] as List? ?? const []))
            ((pack as Map)['id'] as num).toInt(): _micros('${pack['coefficient'] ?? '1'}') ?? BigInt.from(1000000),
        };
      }
    } catch (_) {
      // Référentiel illisible : coefficient 1, comme la version 1.
    }
  }
  final now = DateTime.now().toUtc().toIso8601String();
  for (final row in await db.query('operations', where: 'type = ?', whereArgs: ['vente'])) {
    final operation = _operation(row);
    final movements = saleMovements(operation, (productId, packagingId) => packagingId == null ? null : coefficients[productId]?[packagingId]);
    for (final m in movements) {
      await db.insert('mouvements_stock', {
        'uuid': m.uuid,
        'operation_uuid': m.operationUuid,
        'produit_id': m.productId,
        'quantite_micros': m.quantityMicros,
        'couvert_le': operation.status == OperationStatus.pending ? null : now,
        'cree_le': now,
      });
    }
  }
}

BigInt? _micros(String value) {
  final match = RegExp(r'^(\d+)(?:\.(\d{0,6}))?$').firstMatch(value.trim());
  if (match == null) return null;
  final fraction = (match.group(2) ?? '').padRight(6, '0');
  return BigInt.parse(match.group(1)!) * BigInt.from(1000000) + BigInt.parse(fraction);
}

/// Mouvements (négatifs) d'une vente, en unité de base. [coefficient] donne le coefficient en millionièmes d'un
/// conditionnement (null = 1 unité de base, comme la version 1 pour un conditionnement inconnu).
List<StockMovement> saleMovements(OfflineOperation operation, BigInt? Function(int productId, int? packagingId) coefficient) {
  if (!operation.isSale) return const [];
  final million = BigInt.from(1000000);
  final out = <StockMovement>[];
  final lines = operation.content['lignes'] as List? ?? const [];
  for (var i = 0; i < lines.length; i++) {
    final m = Map<String, dynamic>.from(lines[i] as Map);
    final productId = (m['produit_id'] as num).toInt();
    final quantity = _micros('${m['quantite']}') ?? BigInt.zero;
    final factor = coefficient(productId, (m['conditionnement_id'] as num?)?.toInt()) ?? million;
    out.add(
      StockMovement(uuid: movementUuid(operation.uuid, i), operationUuid: operation.uuid, productId: productId, quantityMicros: -(quantity * factor ~/ million).toInt()),
    );
  }
  return out;
}

class SqfliteOfflineStore implements OfflineStore {
  SqfliteOfflineStore._(this._db);

  final Database _db;

  /// [factory] : `databaseFactory` de sqflite sur Android, `databaseFactoryFfi` sur Windows et dans les tests. Le
  /// stockage ne dépend pas de Flutter : le même moteur sert l'application et un hôte Dart pur.
  static Future<SqfliteOfflineStore> open({String name = 'caisse_hors_ligne.db', required DatabaseFactory factory}) async {
    final dbFactory = factory;
    final path = name == inMemoryDatabasePath || p.isAbsolute(name) ? name : p.join(await dbFactory.getDatabasesPath(), name);
    final db = await dbFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: offlineSchemaVersion,
        // Journal par défaut (rollback, synchronisation complète) volontairement conservé : une vente confirmée doit
        // survivre à une coupure de courant ; le mode WAL d'Android synchronise moins et pourrait perdre la dernière.
        onCreate: (db, version) async {
          await db.execute('CREATE TABLE kv (cle TEXT PRIMARY KEY, valeur TEXT)');
          await db.execute(
            'CREATE TABLE operations (uuid TEXT PRIMARY KEY, sequence INTEGER NOT NULL UNIQUE, type TEXT NOT NULL, '
            'numero TEXT, date TEXT NOT NULL, caissier_id INTEGER NOT NULL, contenu TEXT NOT NULL, statut TEXT NOT NULL, '
            'statut_serveur TEXT, numero_serveur TEXT, message TEXT, transmise_le TEXT, resolue_le TEXT)',
          );
          await db.execute('CREATE INDEX operations_statut ON operations (statut, sequence)');
          await _createV2Tables(db);
        },
        // sqflite exécute la migration dans une transaction : interrompue, elle est annulée et rejouée au prochain
        // démarrage, sans effacement.
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) await _migrateTo2(db);
        },
        onDowngrade: (db, oldVersion, newVersion) async {
          // Une application plus ancienne ne doit pas lire un schéma qu'elle ne comprend pas, ni l'effacer.
          throw StateError('Base de la caisse hors ligne en version $oldVersion : cette application (version $newVersion) est trop ancienne.');
        },
      ),
    );
    return SqfliteOfflineStore._(db);
  }

  Future<void> close() => _db.close();

  @override
  Future<String?> read(String key) async {
    final rows = await _db.query('kv', where: 'cle = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['valeur'] as String?;
  }

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      await _db.delete('kv', where: 'cle = ?', whereArgs: [key]);
    } else {
      await _db.insert('kv', {'cle': key, 'valeur': value}, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  @override
  Future<void> append(OfflineOperation operation) => _db.transaction((txn) async {
    await txn.insert('operations', _row(operation));
    await txn.insert('kv', {'cle': StoreKeys.lastSequence, 'valeur': '${operation.sequence}'}, conflictAlgorithm: ConflictAlgorithm.replace);
  });

  @override
  Future<OfflineOperation> appendAtomic({
    required int sequenceFloor,
    required OfflineOperation Function(int sequence) build,
    List<StockMovement> Function(OfflineOperation operation)? movements,
    String? draftUuid,
  }) => _db.transaction((txn) async {
    if (draftUuid != null) {
      final consumed = await txn.query('paniers_consommes', where: 'brouillon_uuid = ?', whereArgs: [draftUuid], limit: 1);
      if (consumed.isNotEmpty) throw DraftAlreadyConsumed(consumed.first['operation_uuid'] as String);
    }
    final stored = int.tryParse(
          (await txn.query('kv', where: 'cle = ?', whereArgs: [StoreKeys.lastSequence], limit: 1)).firstOrNull?['valeur'] as String? ?? '',
        ) ??
        0;
    final used = (await txn.rawQuery('SELECT MAX(sequence) AS s FROM operations')).first['s'] as int? ?? 0;
    final sequence = [stored, used, sequenceFloor].reduce((a, b) => a > b ? a : b) + 1;
    final operation = build(sequence);
    await txn.insert('operations', _row(operation));
    await txn.insert('kv', {'cle': StoreKeys.lastSequence, 'valeur': '$sequence'}, conflictAlgorithm: ConflictAlgorithm.replace);
    final now = DateTime.now().toUtc().toIso8601String();
    for (final m in movements?.call(operation) ?? const <StockMovement>[]) {
      await txn.insert('mouvements_stock', {
        'uuid': m.uuid,
        'operation_uuid': m.operationUuid,
        'produit_id': m.productId,
        'quantite_micros': m.quantityMicros,
        'couvert_le': null,
        'cree_le': now,
      });
    }
    if (draftUuid != null) {
      await txn.insert('paniers_consommes', {'brouillon_uuid': draftUuid, 'operation_uuid': operation.uuid, 'consomme_le': now});
    }
    return operation;
  }, exclusive: true);

  @override
  Future<void> update(OfflineOperation operation) => _db.update(
    'operations',
    {..._row(operation), if (operation.status != OperationStatus.pending) 'transmise_le': DateTime.now().toUtc().toIso8601String()},
    where: 'uuid = ?',
    whereArgs: [operation.uuid],
  );

  @override
  Future<List<OfflineOperation>> operations({String? status, int? limit}) async {
    final rows = await _db.query(
      'operations',
      where: status == null ? null : 'statut = ?',
      whereArgs: status == null ? null : [status],
      orderBy: 'sequence',
      limit: limit,
    );
    return rows.map(_operation).toList();
  }

  @override
  Future<List<OfflineOperation>> awaitingArbitration({int limit = 50}) async {
    final rows = await _db.query(
      'operations',
      where: 'statut = ? AND statut_serveur = ?',
      whereArgs: [OperationStatus.sent, 'a_arbitrer'],
      orderBy: 'sequence',
      limit: limit,
    );
    return rows.map(_operation).toList();
  }

  @override
  Future<QueueCounts> counts() async {
    final rows = await _db.rawQuery(
      'SELECT '
      "SUM(CASE WHEN statut = 'en_attente' THEN 1 ELSE 0 END) AS attente, "
      "SUM(CASE WHEN statut = 'en_attente' AND type = 'vente' THEN 1 ELSE 0 END) AS ventes, "
      "SUM(CASE WHEN statut = 'refusee' THEN 1 ELSE 0 END) AS refusees, "
      "SUM(CASE WHEN statut = 'transmise' AND statut_serveur = 'a_arbitrer' THEN 1 ELSE 0 END) AS arbitrage "
      'FROM operations',
    );
    final r = rows.first;
    return QueueCounts(
      pending: r['attente'] as int? ?? 0,
      pendingSales: r['ventes'] as int? ?? 0,
      refused: r['refusees'] as int? ?? 0,
      arbitration: r['arbitrage'] as int? ?? 0,
    );
  }

  @override
  Future<Map<int, int>> uncoveredStock() async {
    final rows = await _db.rawQuery('SELECT produit_id, SUM(quantite_micros) AS q FROM mouvements_stock WHERE couvert_le IS NULL GROUP BY produit_id');
    return {for (final r in rows) r['produit_id'] as int: r['q'] as int? ?? 0};
  }

  @override
  Future<List<StockMovement>> movements(String operationUuid) async {
    final rows = await _db.query('mouvements_stock', where: 'operation_uuid = ?', whereArgs: [operationUuid], orderBy: 'uuid');
    return rows.map(_movement).toList();
  }

  @override
  Future<void> saveSnapshot({required String json, required DateTime at, required DateTime coverResolvedBefore, StockCoverage? coverage}) =>
      _db.transaction((txn) async {
        await txn.insert('kv', {'cle': StoreKeys.snapshot, 'valeur': json}, conflictAlgorithm: ConflictAlgorithm.replace);
        await txn.insert('kv', {'cle': StoreKeys.snapshotAt, 'valeur': at.toUtc().toIso8601String()}, conflictAlgorithm: ConflictAlgorithm.replace);
        final now = DateTime.now().toUtc().toIso8601String();
        if (coverage == null) {
          await txn.rawUpdate(
            'UPDATE mouvements_stock SET couvert_le = ? WHERE couvert_le IS NULL AND operation_uuid IN '
            "(SELECT uuid FROM operations WHERE statut_serveur IN ('integree', 'ecartee') AND resolue_le IS NOT NULL AND resolue_le <= ?)",
            [now, coverResolvedBefore.toUtc().toIso8601String()],
          );
          return;
        }
        // Par paquets : SQLite d'Android anciens limite une requête à 999 paramètres.
        for (final (status, uuids) in [('integree', coverage.integrated), ('ecartee', coverage.dismissed)]) {
          final list = uuids.toList();
          for (var i = 0; i < list.length; i += 500) {
            final chunk = list.sublist(i, i + 500 > list.length ? list.length : i + 500);
            final marks = List.filled(chunk.length, '?').join(', ');
            await txn.rawUpdate('UPDATE mouvements_stock SET couvert_le = ? WHERE couvert_le IS NULL AND operation_uuid IN ($marks)', [now, ...chunk]);
            await txn.rawUpdate(
              'UPDATE operations SET statut_serveur = ?, resolue_le = COALESCE(resolue_le, ?) '
              "WHERE statut = 'transmise' AND (statut_serveur IS NULL OR statut_serveur <> ?) AND uuid IN ($marks)",
              [status, now, status, ...chunk],
            );
          }
        }
      });

  @override
  Future<int?> oldestUncoveredSequence() async {
    final rows = await _db.rawQuery(
      'SELECT MIN(o.sequence) AS s FROM operations o WHERE EXISTS '
      '(SELECT 1 FROM mouvements_stock m WHERE m.operation_uuid = o.uuid AND m.couvert_le IS NULL)',
    );
    return rows.first['s'] as int?;
  }

  @override
  Future<void> purgeSent(Duration keep) => _db.transaction((txn) async {
    const purgeable =
        "statut = 'transmise' AND statut_serveur IN ('integree', 'ecartee') AND transmise_le < ? "
        'AND NOT EXISTS (SELECT 1 FROM mouvements_stock m WHERE m.operation_uuid = operations.uuid AND m.couvert_le IS NULL)';
    final cutoff = DateTime.now().toUtc().subtract(keep).toIso8601String();
    await txn.rawDelete('DELETE FROM mouvements_stock WHERE operation_uuid IN (SELECT uuid FROM operations WHERE $purgeable)', [cutoff]);
    await txn.rawDelete('DELETE FROM paniers_consommes WHERE operation_uuid IN (SELECT uuid FROM operations WHERE $purgeable)', [cutoff]);
    await txn.rawDelete('DELETE FROM operations WHERE $purgeable', [cutoff]);
  });
}

/// Mémoire volatile, pour les tests (mêmes règles que la base SQLite).
class MemoryOfflineStore implements OfflineStore {
  final Map<String, String> values = {};
  final List<OfflineOperation> items = [];
  final List<StockMovement> stock = [];
  final Map<String, String> consumedDrafts = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String? value) async => value == null ? values.remove(key) : values[key] = value;

  @override
  Future<void> append(OfflineOperation operation) async {
    if (items.any((o) => o.sequence == operation.sequence || o.uuid == operation.uuid)) throw StateError('séquence ou uuid déjà utilisé');
    items.add(operation);
    values[StoreKeys.lastSequence] = '${operation.sequence}';
  }

  @override
  Future<OfflineOperation> appendAtomic({
    required int sequenceFloor,
    required OfflineOperation Function(int sequence) build,
    List<StockMovement> Function(OfflineOperation operation)? movements,
    String? draftUuid,
  }) async {
    if (draftUuid != null && consumedDrafts.containsKey(draftUuid)) throw DraftAlreadyConsumed(consumedDrafts[draftUuid]!);
    final stored = int.tryParse(values[StoreKeys.lastSequence] ?? '') ?? 0;
    final used = items.fold<int>(0, (max, o) => o.sequence > max ? o.sequence : max);
    final operation = build([stored, used, sequenceFloor].reduce((a, b) => a > b ? a : b) + 1);
    await append(operation);
    stock.addAll(movements?.call(operation) ?? const []);
    if (draftUuid != null) consumedDrafts[draftUuid] = operation.uuid;
    return operation;
  }

  @override
  Future<void> update(OfflineOperation operation) async {}

  @override
  Future<List<OfflineOperation>> operations({String? status, int? limit}) async {
    final list = items.where((o) => status == null || o.status == status).toList()..sort((a, b) => a.sequence.compareTo(b.sequence));
    return limit == null ? list : list.take(limit).toList();
  }

  @override
  Future<List<OfflineOperation>> awaitingArbitration({int limit = 50}) async =>
      (await operations(status: OperationStatus.sent)).where((o) => o.serverStatus == 'a_arbitrer').take(limit).toList();

  @override
  Future<QueueCounts> counts() async => QueueCounts(
    pending: items.where((o) => o.status == OperationStatus.pending).length,
    pendingSales: items.where((o) => o.status == OperationStatus.pending && o.isSale).length,
    refused: items.where((o) => o.status == OperationStatus.refused).length,
    arbitration: items.where((o) => o.status == OperationStatus.sent && o.serverStatus == 'a_arbitrer').length,
  );

  @override
  Future<Map<int, int>> uncoveredStock() async {
    final out = <int, int>{};
    for (final m in stock.where((m) => m.coveredAt == null)) {
      out[m.productId] = (out[m.productId] ?? 0) + m.quantityMicros;
    }
    return out;
  }

  @override
  Future<List<StockMovement>> movements(String operationUuid) async => stock.where((m) => m.operationUuid == operationUuid).toList();

  @override
  Future<void> saveSnapshot({required String json, required DateTime at, required DateTime coverResolvedBefore, StockCoverage? coverage}) async {
    values[StoreKeys.snapshot] = json;
    values[StoreKeys.snapshotAt] = at.toUtc().toIso8601String();
    final Set<String> covered;
    if (coverage == null) {
      covered = {
        for (final o in items)
          if (OfflineOperation.isFinalServerStatus(o.serverStatus) && o.resolvedAt != null && !o.resolvedAt!.isAfter(coverResolvedBefore)) o.uuid,
      };
    } else {
      covered = {...coverage.integrated, ...coverage.dismissed};
      for (final o in items.where((o) => o.status == OperationStatus.sent)) {
        final status = coverage.integrated.contains(o.uuid) ? 'integree' : (coverage.dismissed.contains(o.uuid) ? 'ecartee' : null);
        if (status != null && o.serverStatus != status) {
          o
            ..serverStatus = status
            ..resolvedAt ??= DateTime.now();
        }
      }
    }
    for (var i = 0; i < stock.length; i++) {
      final m = stock[i];
      if (m.coveredAt == null && covered.contains(m.operationUuid)) {
        stock[i] = StockMovement(uuid: m.uuid, operationUuid: m.operationUuid, productId: m.productId, quantityMicros: m.quantityMicros, coveredAt: DateTime.now());
      }
    }
  }

  @override
  Future<int?> oldestUncoveredSequence() async {
    final open = {for (final m in stock.where((m) => m.coveredAt == null)) m.operationUuid};
    final sequences = [for (final o in items) if (open.contains(o.uuid)) o.sequence];
    return sequences.isEmpty ? null : sequences.reduce((a, b) => a < b ? a : b);
  }

  @override
  Future<void> purgeSent(Duration keep) async {}
}
