import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:sqflite_common/sqlite_api.dart';

import '../offline/store.dart';
import 'v2_store.dart';

/// Ce que dit une sauvegarde d'elle-même : d'où elle vient et jusqu'où elle va (déclaration `X-Caisse-Reprise`).
class CaisseBackupInfo {
  const CaisseBackupInfo({
    required this.createdAt,
    required this.platform,
    required this.appVersion,
    required this.schemaVersion,
    this.deviceUuid,
    this.epoch,
    this.lastSequence,
    this.shopName,
    this.terminalName,
    required this.unsent,
    required this.operations,
  });

  factory CaisseBackupInfo.fromJson(Map m) => CaisseBackupInfo(
    createdAt: DateTime.parse(m['cree_le'] as String),
    platform: '${m['plateforme'] ?? ''}',
    appVersion: '${m['version_application'] ?? ''}',
    schemaVersion: m['version_base'] as int,
    deviceUuid: m['appareil_uuid'] as String?,
    epoch: m['epoque'] as int?,
    lastSequence: m['derniere_sequence'] as int?,
    shopName: m['boutique'] as String?,
    terminalName: m['terminal'] as String?,
    unsent: m['non_envoyees'] as int? ?? 0,
    operations: m['operations'] as int? ?? 0,
  );

  final DateTime createdAt;
  final String platform;
  final String appVersion;
  final int schemaVersion;
  final String? deviceUuid;
  final int? epoch;
  final int? lastSequence;
  final String? shopName;
  final String? terminalName;

  /// Opérations encore à envoyer au serveur dans la sauvegarde.
  final int unsent;
  final int operations;

  /// Déclaration de reprise (`etat.json#/$defs/reprise`), ou null si la sauvegarde ne vient pas d'un appareil appairé.
  Map<String, dynamic>? get recovery => deviceUuid == null || epoch == null || lastSequence == null
      ? null
      : {'appareil_uuid': deviceUuid, 'epoque': epoch, 'derniere_sequence': lastSequence};

  Map<String, dynamic> toJson() => {
    'cree_le': createdAt.toUtc().toIso8601String(),
    'plateforme': platform,
    'version_application': appVersion,
    'version_base': schemaVersion,
    'appareil_uuid': deviceUuid,
    'epoque': epoch,
    'derniere_sequence': lastSequence,
    'boutique': shopName,
    'terminal': terminalName,
    'non_envoyees': unsent,
    'operations': operations,
  };
}

class CaisseBackupRefusal implements Exception {
  const CaisseBackupRefusal(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Sauvegarde locale cohérente de la caisse (plan §7.6, RESTAURANT-1 §5.4, lot R-6).
///
/// Toute la base (ventes, commandes, bons et leur journal, file d'envoi et résultats, numéros, imprimantes et écrans
/// reliés) est lue dans UNE transaction : jamais une copie du fichier ouvert. Le format (JSON compressé) ne dépend ni du
/// système ni de la version de SQLite : une sauvegarde de téléphone se restaure sur un poste Windows et inversement,
/// avec la même version de base. Les jetons de l'appareil n'y sont jamais : la caisse restaurée s'appaire à nouveau
/// (nouvelle époque) et déclare la reprise au serveur à son premier `/etat` (`X-Caisse-Reprise`).
class CaisseBackup {
  CaisseBackup._();

  static const format = 'shopikaiss.sauvegarde-caisse';
  static const formatVersion = 1;

  /// Extension proposée pour le fichier.
  static const extension = 'skcaisse';

  /// Jetons et clés de l'appareil : jamais dans une sauvegarde.
  static const secretKeys = {V2Keys.token, StoreKeys.token, StoreKeys.webToken};

  /// Clés propres à l'installation qui reçoit la sauvegarde : gardées telles quelles à la restauration.
  static const localKeys = {V2Keys.installation};

  static const _ignoredTables = {'android_metadata', 'sqlite_sequence'};

  /// Crée la sauvegarde de [db] : octets à écrire tels quels dans un fichier.
  static Future<(Uint8List, CaisseBackupInfo)> create(Database db, {required String platform, required String appVersion, DateTime? now}) =>
      db.transaction((txn) async {
        final version = (await txn.rawQuery('PRAGMA user_version')).first.values.first as int;
        final tables = <String, List<Map<String, dynamic>>>{};
        for (final t in await txn.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")) {
          final name = t['name'] as String;
          if (_ignoredTables.contains(name)) continue;
          tables[name] = [
            for (final row in await txn.query(name))
              if (!(name == 'kv' && secretKeys.contains(row['cle']))) {for (final e in row.entries) e.key: _encode(e.value)},
          ];
        }
        String? kv(String key) => tables['kv']?.where((r) => r['cle'] == key).firstOrNull?['valeur'] as String?;
        final device = _decodeMap(kv(V2Keys.device));
        final next = int.tryParse(kv(V2Keys.nextSequence) ?? '');
        final operations = tables['v2_operations'] ?? const [];
        final info = CaisseBackupInfo(
          createdAt: (now ?? DateTime.now()).toUtc(),
          platform: platform,
          appVersion: appVersion,
          schemaVersion: version,
          deviceUuid: device?['uuid'] as String?,
          epoch: int.tryParse(kv(V2Keys.epoch) ?? ''),
          lastSequence: next == null ? null : next - 1,
          shopName: device?['boutique_nom'] as String?,
          terminalName: device?['terminal_nom'] as String?,
          unsent: operations.where((r) => V2OperationState.unsent.contains(r['etat'])).length,
          operations: operations.length,
        );
        // Contrôle (audit M03) : nombre de lignes de chaque table et empreinte du contenu, vérifiés avant toute
        // suppression à la restauration.
        final control = {
          'lignes': {for (final e in tables.entries) e.key: e.value.length},
          'empreinte': sha256.convert(utf8.encode(jsonEncode(tables))).toString(),
        };
        final json = jsonEncode({'format': format, 'version': formatVersion, 'sauvegarde': info.toJson(), 'controle': control, 'tables': tables});
        return (Uint8List.fromList(GZipCodec(level: 6).encode(utf8.encode(json))), info);
      });

  /// Écrit [bytes] dans [dir] (`caisse-AAAAMMJJ-HHMMSS.skcaisse`, fichier temporaire puis renommage : jamais un fichier
  /// à moitié écrit) et ne garde que les [keep] plus récentes.
  static Future<File> writeRotating(Directory dir, List<int> bytes, {required DateTime at, int keep = 5}) async {
    await dir.create(recursive: true);
    String two(int v) => v.toString().padLeft(2, '0');
    final t = at.toLocal();
    final name = 'caisse-${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}.$extension';
    final temp = File('${dir.path}${Platform.pathSeparator}$name.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    final file = await temp.rename('${dir.path}${Platform.pathSeparator}$name');
    final all = (await backups(dir)).toList();
    for (final old in all.skip(keep)) {
      try {
        await old.delete();
      } catch (_) {}
    }
    return file;
  }

  /// Sauvegardes de [dir], la plus récente d'abord.
  static Future<List<File>> backups(Directory dir) async {
    if (!await dir.exists()) return const [];
    final files = [
      await for (final f in dir.list())
        if (f is File && f.path.endsWith('.$extension')) f,
    ]..sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  /// Lit l'en-tête d'une sauvegarde sans rien écrire.
  static CaisseBackupInfo inspect(List<int> bytes) => CaisseBackupInfo.fromJson(_read(bytes)['sauvegarde'] as Map);

  /// Remplace le contenu de [db] par la sauvegarde, dans UNE transaction. Refusé si [db] a encore des opérations à
  /// envoyer (elles seraient perdues) ou si les versions de base diffèrent. La caisse restaurée n'est pas appairée :
  /// elle garde la déclaration de reprise ([V2Keys.recovery]) jusqu'à ce que le serveur l'ait reçue.
  static Future<CaisseBackupInfo> restore(Database db, List<int> bytes) async {
    final data = _read(bytes);
    final info = CaisseBackupInfo.fromJson(data['sauvegarde'] as Map);
    final tables = (data['tables'] as Map).cast<String, dynamic>();
    return db.transaction((txn) async {
      final version = (await txn.rawQuery('PRAGMA user_version')).first.values.first as int;
      if (info.schemaVersion != version) {
        throw CaisseBackupRefusal(
          'Sauvegarde en version de base ${info.schemaVersion}, cette caisse en version $version : mettez les deux appareils à la même version de l’application.',
        );
      }
      final existing = {
        for (final t in await txn.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")) t['name'] as String,
      }..removeAll(_ignoredTables);
      final unsentV2 = existing.contains('v2_operations')
          ? (await txn.rawQuery('SELECT COUNT(*) AS n FROM v2_operations WHERE etat IN (?, ?)', V2OperationState.unsent.toList())).first['n'] as int
          : 0;
      final unsentV1 = existing.contains('operations')
          ? (await txn.rawQuery("SELECT COUNT(*) AS n FROM operations WHERE statut IN ('a_envoyer', 'envoi_inconnu')")).first['n'] as int
          : 0;
      if (unsentV2 + unsentV1 > 0) {
        throw CaisseBackupRefusal('Cette caisse a ${unsentV2 + unsentV1} opération(s) non envoyée(s) : envoyez-les avant de restaurer une sauvegarde.');
      }
      for (final name in tables.keys) {
        if (!existing.contains(name)) throw CaisseBackupRefusal('Sauvegarde illisible : table « $name » inconnue.');
      }
      // Sauvegarde complète exigée (audit M03) : même version de base = mêmes tables, chacune présente.
      final missing = existing.where((t) => !tables.containsKey(t)).toList()..sort();
      if (missing.isNotEmpty) throw CaisseBackupRefusal('Sauvegarde incomplète (table « ${missing.first} » absente) : rien n’a été modifié.');
      for (final e in tables.entries) {
        if (e.value is! List || (e.value as List).any((r) => r is! Map)) throw CaisseBackupRefusal('Sauvegarde illisible : table « ${e.key} » abîmée.');
      }
      if ((tables['v2_operations'] as List?)?.length case final n? when n != info.operations) {
        throw const CaisseBackupRefusal('Sauvegarde incohérente (nombre d’opérations) : rien n’a été modifié.');
      }
      _checkControl(data['controle'], tables);
      final kept = <String, String>{};
      for (final key in localKeys) {
        final rows = await txn.query('kv', where: 'cle = ?', whereArgs: [key], limit: 1);
        if (rows.isNotEmpty && rows.first['valeur'] != null) kept[key] = rows.first['valeur'] as String;
      }
      for (final name in existing) {
        await txn.delete(name);
      }
      for (final entry in tables.entries) {
        for (final row in (entry.value as List).cast<Map>()) {
          if (entry.key == 'kv' && (secretKeys.contains(row['cle']) || localKeys.contains(row['cle']))) continue;
          await txn.insert(entry.key, {for (final e in row.entries) e.key as String: _decode(e.value)});
        }
      }
      for (final e in kept.entries) {
        await txn.insert('kv', {'cle': e.key, 'valeur': e.value}, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      final recovery = info.recovery;
      if (recovery != null) {
        await txn.insert('kv', {'cle': V2Keys.recovery, 'valeur': jsonEncode(recovery)}, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await txn.insert('kv', {'cle': V2Keys.restoredFrom, 'valeur': jsonEncode(info.toJson())}, conflictAlgorithm: ConflictAlgorithm.replace);
      return info;
    });
  }

  /// Nombre de lignes par table et empreinte du contenu ; une sauvegarde d'avant le contrôle (sans `controle`) reste
  /// lisible, avec les seules vérifications de complétude.
  static void _checkControl(Object? control, Map<String, dynamic> tables) {
    if (control == null) return;
    if (control is! Map || control['lignes'] is! Map || control['empreinte'] is! String) {
      throw const CaisseBackupRefusal('Sauvegarde abîmée (contrôle illisible) : rien n’a été modifié.');
    }
    final counts = (control['lignes'] as Map).cast<String, dynamic>();
    if (counts.length != tables.length || tables.entries.any((e) => counts[e.key] != (e.value as List).length)) {
      throw const CaisseBackupRefusal('Sauvegarde incomplète (nombre de lignes) : rien n’a été modifié.');
    }
    if (sha256.convert(utf8.encode(jsonEncode(tables))).toString() != control['empreinte']) {
      throw const CaisseBackupRefusal('Sauvegarde abîmée (empreinte différente) : rien n’a été modifié.');
    }
  }

  static Map _read(List<int> bytes) {
    final Object? data;
    try {
      data = jsonDecode(utf8.decode(GZipCodec().decode(bytes)));
    } catch (_) {
      throw const CaisseBackupRefusal('Ce fichier n’est pas une sauvegarde de caisse ShopiKaiss.');
    }
    if (data is! Map || data['format'] != format || data['sauvegarde'] is! Map || data['tables'] is! Map) {
      throw const CaisseBackupRefusal('Ce fichier n’est pas une sauvegarde de caisse ShopiKaiss.');
    }
    if (data['version'] != formatVersion) throw const CaisseBackupRefusal('Sauvegarde d’une version plus récente : mettez l’application à jour.');
    return data;
  }

  static Map? _decodeMap(String? raw) {
    if (raw == null) return null;
    try {
      final value = jsonDecode(raw);
      return value is Map ? value : null;
    } catch (_) {
      return null;
    }
  }

  static Object? _encode(Object? value) => value is Uint8List ? {r'$octets': base64.encode(value)} : value;

  static Object? _decode(Object? value) => value is Map && value[r'$octets'] is String ? base64.decode(value[r'$octets'] as String) : value;
}
