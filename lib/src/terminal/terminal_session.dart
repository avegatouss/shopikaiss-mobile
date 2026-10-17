import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app_settings.dart';
import 'terminal_channel.dart';

/// État partagé de l'application : réglages, terminal détecté, pilote d'imprimante actif.
class TerminalSession extends ChangeNotifier {
  TerminalSession._(this.settings, this.info, this.appVersion);

  final AppSettings settings;
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
    final session = TerminalSession._(settings, TerminalInfo.unsupported, package.version);
    await session.refresh();
    return session;
  }

  bool get hasPrinter => activeDriver != 'none';

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
