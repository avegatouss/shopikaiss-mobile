import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' show databaseFactory, getDatabasesPath;

import '../app_settings.dart';
import '../offline/api.dart';
import '../offline/caisse_engine.dart';
import '../offline/models.dart';
import '../offline/store.dart';
import '../offline/ticket.dart';
import '../restaurant/resto_engine.dart';
import '../sync_v2/v2_engine.dart';
import '../sync_v2/v2_transport.dart';
import '../ui/screen_profile.dart';
import 'master_runtime.dart';
import 'terminal_channel.dart';

/// État partagé de l'application : réglages, terminal détecté, pilote d'imprimante actif.
class TerminalSession extends ChangeNotifier {
  TerminalSession._(this.settings, this.info, this.appVersion, this.offline, this.backupDirectory);

  /// Session sans canal natif, pour les tests d'écran.
  @visibleForTesting
  TerminalSession.forTest({required this.settings, required this.offline, this.info = TerminalInfo.unsupported, this.appVersion = 'test'})
    : backupDirectory = Directory.systemTemp;

  /// Sauvegardes automatiques de la caisse (dossier privé de l'application).
  final Directory backupDirectory;

  /// Téléphone en caisse maîtresse restaurant (lot R-6) : afficheurs, service de premier plan, batterie, sauvegardes.
  late final MasterRuntime master = MasterRuntime(
    engine: offline,
    settings: settings,
    platform: _ChannelMasterPlatform(channel),
    backupDirectory: backupDirectory,
  );

  final AppSettings settings;

  /// Caisse locale de ce terminal (protocole v2, décision du 2026-10-29) : appairage, catalogue, file des ventes.
  final CaisseEngine offline;
  TerminalInfo info;
  final String appVersion;

  /// Pilote réellement retenu par le natif (`auto` résolu) : `sunmi`, `usb`, `bluetooth`, `serial`, `none`.
  String activeDriver = 'none';

  /// Dernier lien d'afficheur client envoyé par la caisse (copiable depuis les réglages).
  String? lastDisplayUrl;

  /// Lien à ouvrir sur le second écran : celui que la caisse vient d'envoyer (jeton frais), sinon celui imposé dans les
  /// réglages. Le lien imposé porte un jeton qui expire (12 h par défaut côté boutique) : prioritaire, il affichait 404 le
  /// lendemain (DKD, 2026-10-26).
  String displayUrlFor(String fromPage) => fromPage.isNotEmpty ? fromPage : settings.customerDisplayUrl;

  final TerminalChannel channel = TerminalChannel.instance;

  static Future<TerminalSession> start() async {
    final settings = await AppSettings.load();
    final package = await PackageInfo.fromPlatform();
    final offline = V2Engine.onStore(
      await SqfliteOfflineStore.open(factory: databaseFactory),
      transport: HttpV2Transport(),
      appVersion: package.version,
      platform: 'android',
      legacyTransport: HttpRegisterTransport(appVersion: package.version),
      declaredPayments: true,
      contract21: true,
      // Écran de salle présent (Service de table) : annonce restaurant.v1, accordée par le serveur sur la démo seulement.
      announceRestaurant: true,
      imageDirectory: p.join(await getDatabasesPath(), 'images'),
    );
    if (settings.configured) await offline.load(settings.origin);
    final backups = Directory(p.join(await getDatabasesPath(), 'sauvegardes'));
    final session = TerminalSession._(settings, TerminalInfo.unsupported, package.version, offline, backups);
    await session.refresh();
    session.master.start();
    return session;
  }

  bool get hasPrinter => activeDriver != 'none';

  /// Disposition des écrans de l'application pour ce terminal (réglage, sinon taille réelle de l'écran).
  ScreenLayout layoutOf(BuildContext context) =>
      resolveScreenLayout(setting: settings.screenLayout, logicalSize: MediaQuery.sizeOf(context), nativeInches: info.screenInches);

  bool isCompact(BuildContext context) => layoutOf(context) == ScreenLayout.compact;

  /// Largeur du rouleau : réglage explicite, sinon celle que le pilote connaît (0 = inconnue).
  int get rollWidth => settings.paperWidth > 0 ? settings.paperWidth : info.detectedPaper;

  /// Applique les réglages d'imprimante et relit le terminal (écrans, détection).
  Future<void> refresh() async {
    try {
      activeDriver = await channel.configure(settings.printerConfig);
      info = await channel.info();
    } catch (e) {
      debugPrint('Terminal : $e');
    }
    // Bons de production (restaurant, R-3) : l'imprimante de la caisse sert de secours aux postes.
    offline
      ..restoRegisterPrinter = hasPrinter ? _printProductionTicket : null
      ..restoTicketColumns = rollWidth >= 80 ? 48 : 32;
    notifyListeners();
  }

  Future<RestoOutcome> _printProductionTicket(List<String> text) async {
    final result = await channel.printRaw(offlineTicketBytes([for (final line in text) stripAccents(line)]));
    if (result.ok) return RestoOutcome.transmis;
    // Refus avant tout octet (imprimante absente, en chauffe, en démarrage) : échec certain ; sinon issue inconnue.
    const beforeAnyByte = {'printer_not_configured', 'printer_overheated', 'printer_initialising'};
    return beforeAnyByte.contains(result.error) ? RestoOutcome.nonEnvoye : RestoOutcome.aVerifier;
  }

  Future<void> save() async {
    await settings.save();
    if (settings.configured) await offline.load(settings.origin);
    await refresh();
    await master.apply();
  }
}

class _ChannelMasterPlatform implements MasterPlatform {
  _ChannelMasterPlatform(this.channel);

  final TerminalChannel channel;
  bool _asked = false;

  @override
  Future<({int level, bool plugged})?> battery() => channel.battery();

  @override
  Future<void> startService(String text) async {
    if (!channel.supported) return;
    // Android 13+ : sans cet accord, la notification du service est masquée (le service tourne quand même).
    if (!_asked) {
      _asked = true;
      try {
        await Permission.notification.request();
      } catch (_) {}
    }
    final result = await channel.startMasterService(text);
    if (!result.ok) throw StateError(result.error ?? 'service');
  }

  @override
  Future<void> stopService() async {
    if (channel.supported) await channel.stopMasterService();
  }
}

/// Libellés des pilotes, pour l'écran de réglage.
const driverLabels = <String, String>{
  'auto': 'Automatique',
  'sunmi': 'SUNMI (imprimante intégrée)',
  'usb': 'USB (imprimante interne ou externe)',
  'bluetooth': 'Bluetooth (InnerPrinter / appairée)',
  'serial': 'Port série (/dev/ttyS*)',
  'none': 'Aucune imprimante',
};
