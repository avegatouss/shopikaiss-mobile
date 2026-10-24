import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app_settings.dart';
import '../offline/api.dart';
import '../offline/engine.dart';
import '../offline/store.dart';
import '../ui/screen_profile.dart';
import 'terminal_channel.dart';

/// État partagé de l'application : réglages, terminal détecté, pilote d'imprimante actif.
class TerminalSession extends ChangeNotifier {
  TerminalSession._(this.settings, this.info, this.appVersion, this.offline);

  /// Session sans canal natif, pour les tests d'écran.
  @visibleForTesting
  TerminalSession.forTest({required this.settings, required this.offline, this.info = TerminalInfo.unsupported, this.appVersion = 'test'});

  final AppSettings settings;

  /// Caisse hors ligne de ce terminal (ADR-421) : appairage, catalogue, file des ventes.
  final OfflineEngine offline;
  TerminalInfo info;
  final String appVersion;

  /// Pilote réellement retenu par le natif (`auto` résolu) : `sunmi`, `usb`, `bluetooth`, `serial`, `none`.
  String activeDriver = 'none';

  /// Dernier lien d'afficheur client envoyé par la caisse (copiable depuis les réglages).
  String? lastDisplayUrl;

  /// Lien à ouvrir sur le second écran : celui imposé dans les réglages, sinon celui de la caisse.
  String displayUrlFor(String fromPage) => settings.customerDisplayUrl.isNotEmpty ? settings.customerDisplayUrl : fromPage;

  final TerminalChannel channel = TerminalChannel.instance;

  static Future<TerminalSession> start() async {
    final settings = await AppSettings.load();
    final package = await PackageInfo.fromPlatform();
    final offline = OfflineEngine(
      store: await SqfliteOfflineStore.open(),
      transport: HttpRegisterTransport(appVersion: package.version),
    );
    if (settings.configured) await offline.load(settings.origin);
    final session = TerminalSession._(settings, TerminalInfo.unsupported, package.version, offline);
    await session.refresh();
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
    notifyListeners();
  }

  Future<void> save() async {
    await settings.save();
    if (settings.configured) await offline.load(settings.origin);
    await refresh();
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
