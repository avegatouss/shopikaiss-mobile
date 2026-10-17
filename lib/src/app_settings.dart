import 'package:shared_preferences/shared_preferences.dart';

import 'terminal/terminal_channel.dart';

/// Réglages de l'application, conservés sur le terminal.
class AppSettings {
  AppSettings({
    required this.shopUrl,
    required this.driver,
    required this.paperWidth,
    required this.serialPath,
    required this.serialBaud,
    required this.bluetoothAddress,
    required this.usbDevice,
    required this.adminCode,
    this.hideSoftKeyboard = true,
    this.customerDisplayUrl = '',
  });

  /// Adresse de la caisse, ex. `https://boutique.exemple.ci/caisse`. Vide = pas encore configurée.
  String shopUrl;

  /// `auto`, `sunmi`, `usb`, `bluetooth`, `serial`, `none`.
  String driver;

  /// Largeur du rouleau pour les tickets HTML rastérisés : 58, 80, ou 0 = selon le ticket / le terminal.
  int paperWidth;

  String serialPath;
  int serialBaud;
  String bluetoothAddress;

  /// Imprimante USB choisie, `vendorId:productId` en décimal ; vide = première interface de classe imprimante.
  String usbDevice;

  /// Code protégeant l'accès aux réglages depuis la caisse (vide = pas de code).
  String adminCode;

  /// Clavier de l'écran masqué sur les champs de la caisse (clavier externe ou douchette) : saisie physique intacte.
  /// Masqué par défaut ; le bouton ⌨ de la caisse l'autorise. Préférence `softKeyboardAllowed` (l'ancienne clé
  /// `hideSoftKeyboard`, enregistrée à false par défaut, n'est plus lue).
  bool hideSoftKeyboard;

  /// Lien imposé à l'afficheur client (second écran), même origine que la boutique ; vide = lien envoyé par la caisse.
  /// Typiquement le lien « page web » copié depuis Réglages › Afficheur client, pour vérifier l'affichage.
  String customerDisplayUrl;

  bool get configured => shopUrl.isNotEmpty;

  /// Origine autorisée (`https://hôte[:port]`) : seule origine qui reçoit le pont natif.
  String get origin => originOf(shopUrl) ?? '';

  PrinterConfig get printerConfig => PrinterConfig(
        driver: driver,
        serialPath: serialPath,
        serialBaud: serialBaud,
        bluetoothAddress: bluetoothAddress,
        usbVendorId: int.tryParse(usbDevice.split(':').first) ?? 0,
        usbProductId: usbDevice.contains(':') ? int.tryParse(usbDevice.split(':').last) ?? 0 : 0,
      );

  static Future<AppSettings> load() async {
    final p = await SharedPreferences.getInstance();
    return AppSettings(
      shopUrl: p.getString('shopUrl') ?? '',
      driver: p.getString('driver') ?? 'auto',
      paperWidth: p.getInt('paperWidth') ?? 0,
      serialPath: p.getString('serialPath') ?? '/dev/ttyS1',
      serialBaud: p.getInt('serialBaud') ?? 115200,
      bluetoothAddress: p.getString('bluetoothAddress') ?? '',
      usbDevice: p.getString('usbDevice') ?? '',
      adminCode: p.getString('adminCode') ?? '',
      hideSoftKeyboard: !(p.getBool('softKeyboardAllowed') ?? false),
      customerDisplayUrl: p.getString('customerDisplayUrl') ?? '',
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('shopUrl', shopUrl);
    await p.setString('driver', driver);
    await p.setInt('paperWidth', paperWidth);
    await p.setString('serialPath', serialPath);
    await p.setInt('serialBaud', serialBaud);
    await p.setString('bluetoothAddress', bluetoothAddress);
    await p.setString('usbDevice', usbDevice);
    await p.setString('adminCode', adminCode);
    await p.setBool('softKeyboardAllowed', !hideSoftKeyboard);
    await p.setString('customerDisplayUrl', customerDisplayUrl);
  }
}

/// `scheme://hôte[:port]` en minuscules, ou null si l'adresse n'est pas http(s).
String? originOf(String? url) {
  if (url == null || url.isEmpty) return null;
  final uri = Uri.tryParse(url);
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https') || uri.host.isEmpty) return null;
  final defaultPort = uri.scheme == 'https' ? 443 : 80;
  final port = uri.hasPort && uri.port != defaultPort ? ':${uri.port}' : '';
  return '${uri.scheme}://${uri.host.toLowerCase()}$port';
}

/// Normalise l'adresse saisie : `https://` par défaut, `/caisse` si aucun chemin n'est donné
/// (même point d'entrée que l'application ShopiKaiss Bridge). Renvoie null si elle est invalide.
String? normalizeShopUrl(String input) {
  var text = input.trim();
  if (text.isEmpty) return null;
  if (!text.contains('://')) text = 'https://$text';
  final uri = Uri.tryParse(text);
  if (uri == null || originOf(text) == null) return null;
  final path = (uri.path.isEmpty || uri.path == '/') ? '/caisse' : uri.path;
  return uri.replace(path: path).toString();
}
