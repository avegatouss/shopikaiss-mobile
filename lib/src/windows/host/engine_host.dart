import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqlite_api.dart';

import '../../offline/api.dart';
import '../../offline/engine.dart';
import '../../offline/store.dart';
import '../../register/register_adapter.dart';
import '../ipc/b_engine_adapter.dart';
import '../ipc/host_server.dart';

/// La base est déjà possédée par un autre hôte (autre fenêtre, autre session Windows) : ce processus n'y touche pas.
class EngineHostBusy implements Exception {
  const EngineHostBusy(this.path);

  final String path;

  @override
  String toString() => 'Moteur de caisse déjà démarré sur cette base ($path).';
}

/// Hôte du moteur de caisse Windows (C-REQ-002/003) : SEUL propriétaire de la base SQLite, il démarre le moteur
/// partagé, restaure le panier conservé et sert le protocole privé de C (`WindowsHostServer`, stdin/stdout).
///
/// - Verrou exclusif du système sur `caisse.lock` à côté de la base, tenu toute la vie du processus : un second hôte,
///   même dans une autre session Windows, s'arrête sans ouvrir la base.
/// - [factory] : `databaseFactoryFfi` (sqflite_common_ffi), injectée par l'exécutable : l'application Android n'embarque
///   pas la bibliothèque SQLite native de l'hôte.
/// - Aucun chemin ni exécutable venant du serveur ; le dossier est choisi par l'hôte (LocalAppData) ou ses arguments.
/// - Synchronisation planifiée périodiquement, jamais attendue par une commande ; la fermeture attend la
///   synchronisation et les commandes en cours, puis ferme la base et libère le verrou.
class EngineHost {
  EngineHost._(this.directory, this._lock, this.store, this.engine, this.adapter);

  final String directory;
  final RandomAccessFile _lock;
  final SqfliteOfflineStore store;
  final OfflineEngine engine;
  final LocalRegisterAdapter adapter;
  Timer? _timer;
  bool _closed = false;

  static const databaseName = 'caisse.db';
  static const lockName = 'caisse.lock';

  /// Dossier par défaut : `%LOCALAPPDATA%\ShopiKaiss\caisse`.
  static String defaultDirectory() {
    final local = Platform.environment['LOCALAPPDATA'];
    if (local == null || local.isEmpty) throw StateError('LOCALAPPDATA introuvable : dossier de la caisse à préciser (--dossier).');
    return p.join(local, 'ShopiKaiss', 'caisse');
  }

  static Future<EngineHost> open({
    required String directory,
    required String appVersion,
    required DatabaseFactory factory,
    RegisterTransport? transport,
    int paperWidth = 80,
    Duration? syncEvery = const Duration(minutes: 1),
  }) async {
    if (!p.isAbsolute(directory)) throw ArgumentError('Dossier de la caisse non absolu : $directory');
    await Directory(directory).create(recursive: true);
    final lock = await File(p.join(directory, lockName)).open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.exclusive);
    } on FileSystemException {
      await lock.close();
      throw EngineHostBusy(directory);
    }
    try {
      final store = await SqfliteOfflineStore.open(name: p.join(directory, databaseName), factory: factory);
      final engine = OfflineEngine(store: store, transport: transport ?? HttpRegisterTransport(appVersion: appVersion));
      final storedBase = await store.read(StoreKeys.apiBase);
      if (storedBase != null) {
        final suffix = OfflineEngine.apiBaseFor('');
        await engine.load(storedBase.endsWith(suffix) ? storedBase.substring(0, storedBase.length - suffix.length) : storedBase);
      }
      final adapter = LocalRegisterAdapter(engine, paperWidth: paperWidth);
      await adapter.start();
      final host = EngineHost._(directory, lock, store, engine, adapter);
      if (syncEvery != null) {
        host._timer = Timer.periodic(syncEvery, (_) {
          if (engine.paired) adapter.scheduleSynchronization();
        });
        if (engine.paired) adapter.scheduleSynchronization();
      }
      return host;
    } catch (_) {
      await lock.unlock();
      await lock.close();
      rethrow;
    }
  }

  /// Sert les commandes jusqu'à la fin de [input] (EOF : l'interface a fermé le canal), puis ferme proprement.
  Future<void> serve(Stream<List<int>> input, void Function(List<int>) write) async {
    try {
      await WindowsHostServer(BEngineAdapter(adapter)).serve(input, write);
    } finally {
      await close();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    await adapter.close();
    await store.close();
    await _lock.unlock();
    await _lock.close();
  }
}
