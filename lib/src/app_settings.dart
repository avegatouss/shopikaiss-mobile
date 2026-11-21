import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'terminal/terminal_channel.dart';
import 'web/start_route.dart';

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
    this.scanAutoFocus = true,
    this.customerDisplayUrl = '',
    this.screenLayout = 'auto',
    this.appPrinterFirst = true,
    this.fastRendering = true,
    this.brandColor = defaultBrandColor,
    this.catalogList = false,
    this.tileWidth = 175,
    this.cartWidth = 380,
    this.imageMode = 'top',
    this.imageFit = 'cover',
    this.ticketMode = 'ask',
    this.startRouteMissing,
  });

  /// Préférence dédiée : `/caisse/demarrer` absente du serveur (404/405), notée par origine (voir web/start_route.dart).
  static const startRouteMissingKey = 'startRouteMissing';

  /// Route de démarrage absente de cette origine depuis moins de 24 h : la caisse ouvre `/caisse` directement. Jamais
  /// écrit par [save] ; l'adresse enregistrée n'est pas modifiée.
  StartRouteMemory? startRouteMissing;

  /// Note l'absence de la route de démarrage pour l'origine de la boutique.
  Future<void> rememberStartRouteMissing(DateTime now) async {
    startRouteMissing = StartRouteMemory(origin, now.toUtc());
    final p = await SharedPreferences.getInstance();
    await p.setString(startRouteMissingKey, jsonEncode(startRouteMissing!.toJson()));
  }

  /// Ticket après une vente : `ask` (demandé au caissier) ou `auto`.
  String ticketMode;

  /// Couleurs de la caisse Windows : vert, bleu, prune, terre cuite.
  static const defaultBrandColor = 0xFF164E42;
  static const brandColors = [defaultBrandColor, 0xFF234E86, 0xFF713C70, 0xFF91462D];

  /// Couleur principale de la caisse locale (ARGB).
  int brandColor;

  /// Articles en liste compacte plutôt qu'en tuiles.
  bool catalogList;

  /// Largeur maximale d'une tuile d'article (dp).
  int tileWidth;

  /// Largeur du panier à côté du catalogue, sur tablette et terminal (dp).
  int cartWidth;

  /// Image d'une tuile : `left` (à gauche du nom), `top` (au-dessus), `hidden`.
  String imageMode;

  /// `cover` (recadrée) ou `contain` (image entière).
  String imageFit;

  /// Adresse de la caisse, ex. `https://boutique.exemple.ci/caisse/demarrer`. Vide = pas encore configurée.
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

  /// Caisse hors ligne : le curseur revient seul dans le champ du scanner (ouverture, après un ajout ou une vente).
  /// Désactivé, il n'y va que sur demande (toucher, F2) : utile quand on saisit au doigt sans douchette (C, `cdf860a`).
  bool scanAutoFocus;

  /// Lien imposé à l'afficheur client (second écran), même origine que la boutique ; vide = lien envoyé par la caisse.
  /// Typiquement le lien « page web » copié depuis Réglages › Afficheur client, pour vérifier l'affichage.
  String customerDisplayUrl;

  /// Disposition des écrans de l'application : `auto` (compacte sur un téléphone de moins de 6 pouces), `compact`,
  /// `standard`. Les terminaux et tablettes (6 à 8 pouces, 14 pouces…) restent en `standard` en automatique.
  String screenLayout;

  /// Imprimante de l'application prioritaire : quand le terminal a une imprimante, la caisse imprime ses tickets en
  /// ESC/POS par l'application même si le profil du terminal (serveur) indique l'impression du navigateur ou un
  /// transport web (Bluetooth/USB du navigateur), qui ne fonctionnent pas dans l'application. Le réseau (port 9100) est
  /// laissé tel quel.
  bool appPrinterFirst;

  /// Rendu rapide de la caisse : vue web composée par texture (au lieu de la composition hybride d'Android, coûteuse à
  /// chaque image). À désactiver seulement si l'affichage ou la saisie posent problème sur un terminal.
  bool fastRendering;

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
      shopUrl: await _migratedShopUrl(p),
      driver: p.getString('driver') ?? 'auto',
      paperWidth: p.getInt('paperWidth') ?? 0,
      serialPath: p.getString('serialPath') ?? '/dev/ttyS1',
      serialBaud: p.getInt('serialBaud') ?? 115200,
      bluetoothAddress: p.getString('bluetoothAddress') ?? '',
      usbDevice: p.getString('usbDevice') ?? '',
      adminCode: p.getString('adminCode') ?? '',
      hideSoftKeyboard: !(p.getBool('softKeyboardAllowed') ?? false),
      scanAutoFocus: p.getBool('scanAutoFocus') ?? true,
      customerDisplayUrl: p.getString('customerDisplayUrl') ?? '',
      screenLayout: p.getString('screenLayout') ?? 'auto',
      appPrinterFirst: p.getBool('appPrinterFirst') ?? true,
      fastRendering: p.getBool('fastRendering') ?? true,
      brandColor: p.getInt('brandColor') ?? defaultBrandColor,
      catalogList: p.getBool('catalogList') ?? false,
      tileWidth: p.getInt('tileWidth') ?? 175,
      cartWidth: p.getInt('cartWidth') ?? 380,
      imageMode: p.getString('imageMode') ?? 'top',
      imageFit: p.getString('imageFit') ?? 'cover',
      ticketMode: p.getString('ticketMode') ?? 'ask',
      startRouteMissing: await _startRouteMemory(p),
    );
  }

  /// Souvenir de la route absente, oublié (et effacé) si l'origine a changé ou s'il a plus de 24 h.
  static Future<StartRouteMemory?> _startRouteMemory(SharedPreferences p) async {
    final raw = p.getString(startRouteMissingKey);
    if (raw == null) return null;
    StartRouteMemory? memory;
    try {
      memory = StartRouteMemory.fromJson(jsonDecode(raw));
    } on FormatException {
      memory = null;
    }
    if (memory != null && memory.appliesTo(p.getString('shopUrl') ?? '', DateTime.now())) return memory;
    await p.remove(startRouteMissingKey);
    return null;
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
    await p.setBool('scanAutoFocus', scanAutoFocus);
    await p.setString('customerDisplayUrl', customerDisplayUrl);
    await p.setString('screenLayout', screenLayout);
    await p.setBool('appPrinterFirst', appPrinterFirst);
    await p.setBool('fastRendering', fastRendering);
    await p.setInt('brandColor', brandColor);
    await p.setBool('catalogList', catalogList);
    await p.setInt('tileWidth', tileWidth);
    await p.setInt('cartWidth', cartWidth);
    await p.setString('imageMode', imageMode);
    await p.setString('imageFit', imageFit);
    await p.setString('ticketMode', ticketMode);
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

/// Chemin de démarrage de la caisse (2026-11-19) : `/caisse/demarrer` établit le terminal (appareil fixé, terminal attribué)
/// puis redirige vers la bonne caisse de la même origine (`/caisse`, `/restaurant/caisse`, `/restaurant/caisse-service-table`,
/// ou la page d'accueil). Même adresse que ShopiKaiss Bridge et la caisse Windows.
const shopStartPath = '/caisse/demarrer';

/// Normalise l'adresse saisie : `https://` par défaut, `/caisse/demarrer` si aucun chemin n'est donné
/// (même point d'entrée que l'application ShopiKaiss Bridge). Renvoie null si elle est invalide.
String? normalizeShopUrl(String input) {
  var text = input.trim();
  if (text.isEmpty) return null;
  if (!text.contains('://')) text = 'https://$text';
  final uri = Uri.tryParse(text);
  if (uri == null || originOf(text) == null) return null;
  final path = (uri.path.isEmpty || uri.path == '/') ? shopStartPath : uri.path;
  return uri.replace(path: path).toString();
}

/// Migration prudente d'une adresse enregistrée : l'ancien défaut exact `<origine>/caisse` (ou `/caisse/`, sans requête ni
/// ancre) devient `<origine>/caisse/demarrer`. Toute autre adresse (chemin personnalisé, sous-répertoire, paramètres) est
/// rendue telle quelle, de même qu'une adresse vide ou illisible.
String migrateShopUrl(String saved) {
  if (saved.isEmpty || originOf(saved) == null) return saved;
  final uri = Uri.tryParse(saved);
  if (uri == null || uri.hasQuery || uri.hasFragment || uri.userInfo.isNotEmpty) return saved;
  if (uri.path != '/caisse' && uri.path != '/caisse/') return saved;
  return uri.replace(path: shopStartPath).toString();
}

/// Adresse enregistrée, migrée une fois pour toutes (la nouvelle valeur est réenregistrée).
Future<String> _migratedShopUrl(SharedPreferences p) async {
  final saved = p.getString('shopUrl') ?? '';
  final migrated = migrateShopUrl(saved);
  if (migrated != saved) await p.setString('shopUrl', migrated);
  return migrated;
}
