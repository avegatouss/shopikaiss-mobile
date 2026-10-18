import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'models.dart';

/// Mémoire durable de la caisse hors ligne sur le terminal : appairage, dernier référentiel, file des opérations.
///
/// Une vente hors ligne est écrite ici, avec son numéro de ticket, AVANT l'impression : si le terminal s'éteint, elle
/// est retrouvée au redémarrage et part à la prochaine connexion.
abstract class OfflineStore {
  Future<String?> read(String key);
  Future<void> write(String key, String? value);

  /// Ajoute une opération et réserve son numéro de séquence en une seule écriture.
  Future<void> append(OfflineOperation operation);
  Future<void> update(OfflineOperation operation);
  Future<List<OfflineOperation>> operations({String? status, int? limit});

  /// Retire les opérations transmises depuis plus de [keep] (l'historique récent reste consultable).
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
}

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
);

class SqfliteOfflineStore implements OfflineStore {
  SqfliteOfflineStore._(this._db);

  final Database _db;

  static Future<SqfliteOfflineStore> open({String name = 'caisse_hors_ligne.db', DatabaseFactory? factory}) async {
    final dbFactory = factory ?? databaseFactory;
    final path = name == inMemoryDatabasePath ? name : p.join(await dbFactory.getDatabasesPath(), name);
    final db = await dbFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute('CREATE TABLE kv (cle TEXT PRIMARY KEY, valeur TEXT)');
          await db.execute(
            'CREATE TABLE operations (uuid TEXT PRIMARY KEY, sequence INTEGER NOT NULL UNIQUE, type TEXT NOT NULL, '
            'numero TEXT, date TEXT NOT NULL, caissier_id INTEGER NOT NULL, contenu TEXT NOT NULL, statut TEXT NOT NULL, '
            'statut_serveur TEXT, numero_serveur TEXT, message TEXT, transmise_le TEXT)',
          );
          await db.execute('CREATE INDEX operations_statut ON operations (statut, sequence)');
        },
      ),
    );
    return SqfliteOfflineStore._(db);
  }

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
  Future<void> purgeSent(Duration keep) => _db.delete(
    'operations',
    where: 'statut = ? AND transmise_le < ?',
    whereArgs: [OperationStatus.sent, DateTime.now().toUtc().subtract(keep).toIso8601String()],
  );
}

/// Mémoire volatile, pour les tests.
class MemoryOfflineStore implements OfflineStore {
  final Map<String, String> values = {};
  final List<OfflineOperation> items = [];

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
  Future<void> update(OfflineOperation operation) async {}

  @override
  Future<List<OfflineOperation>> operations({String? status, int? limit}) async {
    final list = items.where((o) => status == null || o.status == status).toList()..sort((a, b) => a.sequence.compareTo(b.sequence));
    return limit == null ? list : list.take(limit).toList();
  }

  @override
  Future<void> purgeSent(Duration keep) async {}
}
