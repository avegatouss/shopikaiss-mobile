import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app_settings.dart';
import '../offline/caisse_engine.dart';
import '../restaurant/resto_display_server.dart';
import '../sync_v2/v2_backup.dart';
import '../sync_v2/v2_engine.dart';

/// Ce que le mode maître demande au système (Android : `TerminalPlugin.kt`).
abstract class MasterPlatform {
  Future<({int level, bool plugged})?> battery();
  Future<void> startService(String text);
  Future<void> stopService();
}

/// Téléphone en caisse maîtresse restaurant (lot R-6, RESTAURANT-1 §5.6) : tant que le serveur le désigne maître, il
/// - sert la page d'afficheur sur le Wi-Fi du lieu si le gérant l'a allumée sur ce poste ([AppSettings.displayServer]) ;
/// - tient un service de premier plan (processus, processeur et Wi-Fi actifs, écran éteint compris) ;
/// - surveille la batterie (alerte si elle baisse sans secteur) ;
/// - écrit une sauvegarde cohérente toutes les [backupEvery] quand la caisse a changé (les [keepBackups] dernières).
///
/// Désigné ou retiré par le serveur : tout suit au prochain changement du moteur, sans action sur le téléphone.
class MasterRuntime extends ChangeNotifier {
  MasterRuntime({
    required this.engine,
    required this.settings,
    required this.platform,
    required this.backupDirectory,
    this.backupEvery = const Duration(minutes: 5),
    this.batteryEvery = const Duration(minutes: 1),
    this.keepBackups = 6,
    this.lowBattery = 30,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final CaisseEngine engine;
  final AppSettings settings;
  final MasterPlatform platform;
  final Directory backupDirectory;
  final Duration backupEvery;
  final Duration batteryEvery;
  final int keepBackups;

  /// Seuil d'alerte de la batterie, en %.
  final int lowBattery;
  final DateTime Function() _clock;

  RestoDisplayServer? _display;
  bool _service = false;
  String? _serviceText;
  bool _master = false;
  bool _dirty = true;
  bool _started = false;
  Timer? _backupTimer;
  Timer? _batteryTimer;
  Future<void> _pending = Future.value();

  /// Service d'afficheur en marche (null sinon).
  RestoDisplayServer? get display => _display?.running == true ? _display : null;

  /// Erreur de démarrage du service d'afficheur (port occupé…).
  String? displayError;

  /// Adresses privées de ce téléphone sur le réseau du lieu.
  List<String> addresses = const [];

  ({int level, bool plugged})? battery;
  DateTime? lastBackupAt;
  String? lastBackupPath;
  String? backupError;

  bool get master => engine.restaurant?.master == true;
  bool get serviceRunning => _service;

  /// Liens à ouvrir sur la tablette (`http://IP:port/`).
  List<String> get displayLinks => [
    if (display case final d?) for (final a in addresses) 'http://$a:${d.port}/',
  ];

  /// Alerte à montrer à l'écran de service, ou null.
  String? get batteryWarning {
    final b = battery;
    if (!master || b == null || b.plugged || b.level < 0) return null;
    if (b.level <= lowBattery) return 'Batterie à ${b.level} % et téléphone non branché : branchez-le sur secteur pour tenir le service.';
    return null;
  }

  void start() {
    if (_started) return;
    _started = true;
    engine.addListener(_engineChanged);
    _backupTimer = Timer.periodic(backupEvery, (_) => unawaited(backupNow(onlyIfChanged: true)));
    _batteryTimer = Timer.periodic(batteryEvery, (_) => unawaited(_readBattery()));
    unawaited(apply());
  }

  void _engineChanged() {
    _dirty = true;
    if (master != _master) unawaited(apply());
  }

  /// Remet le téléphone dans l'état voulu (après un changement de réglage ou de désignation).
  Future<void> apply() => _pending = _pending.then((_) => _apply()).catchError((Object _) {});

  Future<void> _apply() async {
    final master = this.master;
    _master = master;
    final serve = master && settings.displayServer && engine is V2Engine;
    final current = _display;
    if (serve && (current == null || !current.running || current.port != settings.displayServerPort)) {
      await current?.stop();
      final v2 = (engine as V2Engine).v2;
      final display = current ?? RestoDisplayServer(engine, read: v2.read, write: (k, v) => v2.write(k, v));
      _display = display;
      try {
        await display.start(port: settings.displayServerPort);
        displayError = null;
        addresses = await RestoDisplayServer.localAddresses();
      } on SocketException catch (e) {
        displayError = 'Port ${settings.displayServerPort} indisponible sur ce téléphone (${e.osError?.message ?? e.message}) : choisissez-en un autre.';
      }
    } else if (!serve && current != null && current.running) {
      await current.stop();
      displayError = null;
    }
    final text = display == null ? 'Bons envoyés aux imprimantes du lieu.' : 'Afficheurs servis sur le Wi-Fi : ${displayLinks.join(', ')}';
    if (master != _service || (master && text != _serviceText)) {
      try {
        if (master) {
          // Relancé avec un autre texte : la notification se met à jour, le service reste le même.
          await platform.startService(text);
          _serviceText = text;
        } else {
          await platform.stopService();
          _serviceText = null;
        }
        _service = master;
      } catch (_) {
        // Sans service, la caisse fonctionne tant que l'application est au premier plan.
      }
    }
    if (master) await _readBattery(notify: false);
    notifyListeners();
  }

  Future<void> _readBattery({bool notify = true}) async {
    if (!master) return;
    try {
      final value = await platform.battery();
      final changed = value != battery;
      battery = value;
      if (changed && notify) notifyListeners();
    } catch (_) {}
  }

  /// Sauvegarde dans [backupDirectory] (maître seulement pour l'automatique ; à la demande sinon).
  Future<File?> backupNow({bool onlyIfChanged = false}) async {
    if (onlyIfChanged && (!master || !_dirty)) return null;
    _dirty = false;
    try {
      final (bytes, _) = await engine.createBackup();
      final file = await CaisseBackup.writeRotating(backupDirectory, bytes, at: _clock(), keep: keepBackups);
      lastBackupAt = _clock();
      lastBackupPath = file.path;
      backupError = null;
      notifyListeners();
      return file;
    } catch (e) {
      _dirty = true;
      backupError = 'Sauvegarde automatique impossible : $e';
      notifyListeners();
      return null;
    }
  }

  Future<void> stop() async {
    _backupTimer?.cancel();
    _batteryTimer?.cancel();
    engine.removeListener(_engineChanged);
    _started = false;
    await _display?.stop();
    if (_service) {
      try {
        await platform.stopService();
      } catch (_) {}
      _service = false;
    }
  }

  @override
  void dispose() {
    unawaited(stop());
    super.dispose();
  }
}
