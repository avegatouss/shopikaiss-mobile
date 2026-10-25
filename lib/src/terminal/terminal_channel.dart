import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Résultat d'un ordre natif, au format du contrat n°4 : `{"ok":true}` ou `{"ok":false,"error":"…"}`.
class NativeResult {
  const NativeResult(this.data);

  final Map<String, dynamic> data;

  bool get ok => data['ok'] == true;
  String? get error => data['error'] as String?;

  static NativeResult failure(String error) => NativeResult({'ok': false, 'error': error});
}

/// Terminal détecté par le code natif (fabricant, modèle, écrans, imprimante intégrée probable).
class TerminalInfo {
  const TerminalInfo(this.raw);

  final Map<String, dynamic> raw;

  String get manufacturer => (raw['manufacturer'] ?? '') as String;
  String get model => (raw['model'] ?? '') as String;
  String get label => '$manufacturer $model'.trim();
  String get android => (raw['android'] ?? '') as String;
  bool get hasSecondaryDisplay => raw['hasSecondaryDisplay'] == true;
  List<dynamic> get displays => (raw['displays'] ?? const []) as List<dynamic>;

  /// Pilote proposé par la détection : `sunmi`, `usb`, `bluetooth`, `none`.
  String get detectedDriver => (raw['detectedDriver'] ?? 'none') as String;
  String get detectedLabel => (raw['detectedLabel'] ?? 'Aucune imprimante intégrée détectée') as String;

  /// Diagonale de l'écran principal en pouces mesurée par Android, 0 si inconnue.
  double get screenInches => (raw['screenInches'] as num?)?.toDouble() ?? 0;

  /// Largeur de papier connue du pilote (58/80), 0 si inconnue.
  int get detectedPaper => (raw['detectedPaper'] ?? 0) as int;

  /// Ce que la page reçoit par `ShopiKaissNative.getDeviceInfo()` (même forme que le pont Kotlin).
  Map<String, dynamic> toDeviceInfo(String appVersion) => {
        'bridgeVersion': 'flutter-$appVersion',
        'model': label,
        'android': android,
        'displays': displays,
        // Second écran présent : la caisse ouvre l'afficheur client d'elle-même (profil « automatique »).
        'hasSecondaryDisplay': hasSecondaryDisplay,
      };

  static const unsupported = TerminalInfo({'manufacturer': '', 'model': 'Appareil', 'detectedDriver': 'none'});
}

/// Configuration du pilote envoyée au code natif.
class PrinterConfig {
  const PrinterConfig({
    required this.driver,
    this.serialPath = '/dev/ttyS1',
    this.serialBaud = 115200,
    this.bluetoothAddress = '',
    this.usbVendorId = 0,
    this.usbProductId = 0,
  });

  /// `auto`, `sunmi`, `usb`, `bluetooth`, `serial`, `none`.
  final String driver;
  final String serialPath;
  final int serialBaud;
  final String bluetoothAddress;
  final int usbVendorId;
  final int usbProductId;

  Map<String, dynamic> toMap() => {
        'driver': driver,
        'serialPath': serialPath,
        'serialBaud': serialBaud,
        'bluetoothAddress': bluetoothAddress,
        'usbVendorId': usbVendorId,
        'usbProductId': usbProductId,
      };
}

/// Pont vers le code Android (`TerminalPlugin.kt`). Sur une plateforme sans implémentation (iOS pour
/// l'instant), chaque ordre répond `printer_not_configured` et l'impression passe par le système.
class TerminalChannel {
  TerminalChannel._();

  static final TerminalChannel instance = TerminalChannel._();

  static const _channel = MethodChannel('ci.khoga.shopikaiss/terminal');

  bool get supported => Platform.isAndroid;

  Future<TerminalInfo> info() async {
    if (!supported) return TerminalInfo.unsupported;
    final raw = await _channel.invokeMapMethod<String, dynamic>('info');
    return TerminalInfo(raw ?? const {});
  }

  /// Pilote réellement actif après application de [config] (`auto` est résolu côté natif).
  Future<String> configure(PrinterConfig config) async {
    if (!supported) return 'none';
    return await _channel.invokeMethod<String>('configure', config.toMap()) ?? 'none';
  }

  Future<NativeResult> printRaw(Uint8List bytes) => _call('printRaw', {'bytes': bytes});

  Future<NativeResult> openDrawer() => _call('openDrawer');

  Future<NativeResult> status() => _call('status');

  Future<NativeResult> beep(int ms) => _call('beep', {'ms': ms});

  Future<NativeResult> showCustomerDisplay(String url, String allowedOrigin) =>
      _call('showCustomerDisplay', {'url': url, 'allowedOrigin': allowedOrigin});

  Future<NativeResult> hideCustomerDisplay() => _call('hideCustomerDisplay');

  /// Blocage Android du clavier de l'écran : refermé dès qu'il s'ouvre (filet de `inputmode="none"`).
  Future<NativeResult> setSoftKeyboardBlocked(bool blocked) => _call('setSoftKeyboardBlocked', {'blocked': blocked});

  /// Imprimantes Bluetooth appairées : `[{name, address}]`.
  Future<List<Map<String, dynamic>>> bluetoothDevices() => _list('bluetoothDevices');

  /// Appareils USB branchés : `[{vendorId, productId, name, printer}]`.
  Future<List<Map<String, dynamic>>> usbDevices() => _list('usbDevices');

  /// Dernière panne native (texte écrit par CrashLog avant l'arrêt de l'application), ou null.
  Future<String?> lastCrash() async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<String>('lastCrash');
    } on PlatformException {
      return null;
    }
  }

  Future<void> clearCrash() => _call('clearCrash');

  /// Nœuds `/dev/tty*` candidats : `[{path, writable}]`.
  Future<List<Map<String, dynamic>>> serialPorts() => _list('serialPorts');

  Future<NativeResult> _call(String method, [Map<String, dynamic>? args]) async {
    if (!supported) return NativeResult.failure('printer_not_configured');
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(method, args);
      return NativeResult(raw ?? const {'ok': true});
    } on PlatformException catch (e) {
      return NativeResult.failure(e.message ?? e.code);
    }
  }

  Future<List<Map<String, dynamic>>> _list(String method) async {
    if (!supported) return const [];
    final raw = await _channel.invokeListMethod<dynamic>(method) ?? const [];
    return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }
}
