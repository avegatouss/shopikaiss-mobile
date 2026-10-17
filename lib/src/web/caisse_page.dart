import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint, kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_settings.dart';
import '../printer/html_printer.dart';
import '../settings/settings_page.dart';
import '../terminal/terminal_channel.dart';
import '../terminal/terminal_session.dart';
import 'bridge_script.dart';

/// La caisse ShopiKaiss en plein écran, avec le pont natif `window.ShopiKaissNative`.
class CaissePage extends StatefulWidget {
  const CaissePage({super.key, required this.session});

  final TerminalSession session;

  @override
  State<CaissePage> createState() => _CaissePageState();
}

class _CaissePageState extends State<CaissePage> {
  static const _maxPayloadBytes = 512 * 1024;

  /// Secret du pont (voir buildBridgeScript) : tiré une fois par écran, connu du seul script du cadre principal.
  final String _bridgeSecret = _randomSecret();

  InAppWebViewController? _controller;
  late final HtmlPrinter _htmlPrinter = HtmlPrinter(widget.session.channel);
  double _progress = 0;
  String? _error;
  String? _forcedDisplayShown;
  final List<DateTime> _cornerTaps = [];

  TerminalSession get _session => widget.session;
  AppSettings get _settings => _session.settings;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _applyKeyboardBlock();
  }

  @override
  void dispose() {
    _session.channel.setSoftKeyboardBlocked(false);
    super.dispose();
  }

  /// Blocage Android du clavier de l'écran, seulement pendant la caisse : les réglages et le code d'accès en ont besoin.
  Future<void> _applyKeyboardBlock() => _session.channel.setSoftKeyboardBlocked(_settings.hideSoftKeyboard);

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop && await _controller?.canGoBack() == true) await _controller?.goBack();
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Stack(
            children: [
              InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri(_settings.shopUrl)),
                initialUserScripts: UnmodifiableListView([_userScript()]),
                initialSettings: InAppWebViewSettings(
                  // Inspectable (chrome://inspect) hors release : recette sur terminal avec le banc de test du pont.
                  isInspectable: !kReleaseMode,
                  javaScriptEnabled: true,
                  domStorageEnabled: true,
                  databaseEnabled: true,
                  mediaPlaybackRequiresUserGesture: false,
                  allowsInlineMediaPlayback: true,
                  useShouldOverrideUrlLoading: true,
                  useOnDownloadStart: true,
                  supportZoom: false,
                  builtInZoomControls: false,
                  displayZoomControls: false,
                  thirdPartyCookiesEnabled: true,
                  applicationNameForUserAgent: 'ShopiKaissTerminal/${_session.appVersion}',
                ),
                onWebViewCreated: (controller) {
                  _controller = controller;
                  controller.addJavaScriptHandler(handlerName: bridgeHandlerName, callback: _onBridgeCall);
                },
                shouldOverrideUrlLoading: (controller, action) async {
                  final url = action.request.url;
                  if (url == null || originOf(url.toString()) == _settings.origin) return NavigationActionPolicy.ALLOW;
                  if (url.scheme == 'about' || url.scheme == 'data' || url.scheme == 'blob') return NavigationActionPolicy.ALLOW;
                  // Hors de la boutique (paiement en ligne, aide, WhatsApp…) : navigateur ou application du système.
                  await launchUrl(url, mode: LaunchMode.externalApplication);
                  return NavigationActionPolicy.CANCEL;
                },
                onPermissionRequest: (controller, request) async {
                  final allowed = originOf(request.origin.toString()) == _settings.origin;
                  if (allowed && request.resources.contains(PermissionResourceType.CAMERA)) {
                    await Permission.camera.request();
                  }
                  return PermissionResponse(
                    resources: request.resources,
                    action: allowed ? PermissionResponseAction.GRANT : PermissionResponseAction.DENY,
                  );
                },
                onDownloadStartRequest: (controller, request) async {
                  await launchUrl(request.url, mode: LaunchMode.externalApplication);
                },
                onProgressChanged: (controller, progress) => setState(() => _progress = progress / 100),
                onLoadStop: (controller, url) {
                  setState(() => _error = null);
                  _showForcedDisplay(url?.toString());
                },
                onReceivedError: (controller, request, error) {
                  if (request.isForMainFrame ?? true) setState(() => _error = error.description);
                },
              ),
              if (_progress < 1) LinearProgressIndicator(value: _progress, minHeight: 3),
              if (_error != null) _ErrorPanel(message: _error!, onRetry: _reload, onSettings: _openSettings),
              // Accès aux réglages : 5 touchers en 3 s dans le coin haut gauche.
              Positioned(
                left: 0,
                top: 0,
                width: 56,
                height: 56,
                child: GestureDetector(behavior: HitTestBehavior.translucent, onTap: _onCornerTap),
              ),
              // Clavier de l'écran : masqué pour un clavier externe ou une douchette, rétabli d'un toucher.
              Positioned(
                left: 8,
                bottom: 8,
                child: Opacity(
                  opacity: 0.75,
                  child: Material(
                    color: _settings.hideSoftKeyboard ? const Color(0xFF0F3E2E) : Colors.white,
                    shape: const CircleBorder(side: BorderSide(color: Color(0xFF0F3E2E))),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: _toggleSoftKeyboard,
                      child: Tooltip(
                        message: _settings.hideSoftKeyboard ? 'Afficher le clavier de l’écran' : 'Masquer le clavier de l’écran',
                        child: SizedBox.square(
                          dimension: 40,
                          child: Icon(
                            _settings.hideSoftKeyboard ? Icons.keyboard_hide : Icons.keyboard,
                            size: 22,
                            color: _settings.hideSoftKeyboard ? Colors.white : const Color(0xFF0F3E2E),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Appel de `ShopiKaissNative` : `[secret, méthode, [arguments]]` → chaîne JSON du contrat n°4.
  Future<String> _onBridgeCall(List<dynamic> data) async {
    // Sans le secret, l'appel ne vient pas du script du cadre principal (iframe, autre page).
    if (data.isEmpty || data[0] != _bridgeSecret) {
      return jsonEncode({'ok': false, 'error': 'origin_not_allowed'});
    }
    final method = data.length > 1 && data[1] is String ? data[1] as String : '';
    final args = data.length > 2 && data[2] is List ? data[2] as List : const [];
    final page = await _controller?.getUrl();
    if (originOf(page?.toString()) != _settings.origin) {
      return jsonEncode({'ok': false, 'error': 'origin_not_allowed'});
    }
    final channel = _session.channel;
    try {
      final NativeResult result;
      switch (method) {
        case 'printEscPos':
          result = await _printEscPos(args.isNotEmpty ? args[0] as String? : null);
        case 'openDrawer':
          result = await channel.openDrawer();
        case 'getPrinterStatus':
          result = await channel.status();
        case 'beep':
          result = await channel.beep(args.isNotEmpty ? (args[0] as num).toInt() : 80);
        case 'showCustomerDisplay':
          final fromPage = args.isNotEmpty ? args[0] as String : '';
          _session.lastDisplayUrl = fromPage;
          result = await channel.showCustomerDisplay(_session.displayUrlFor(fromPage), _settings.origin);
        case 'hideCustomerDisplay':
          result = await channel.hideCustomerDisplay();
        case 'printHtml':
          final job = HtmlPrintJob.fromMap(Map<String, dynamic>.from(args.isNotEmpty ? args[0] as Map : const {}));
          result = await _htmlPrinter.print(job, hasPrinter: _session.hasPrinter, rollWidth: _session.rollWidth);
        default:
          result = NativeResult.failure('unknown_method');
      }
      return jsonEncode(result.data);
    } catch (e, stack) {
      // Code stable pour la page (libellé « bridge_error ») ; le détail reste dans le journal.
      debugPrint('Pont ShopiKaiss : $method en échec : $e\n$stack');
      return jsonEncode({'ok': false, 'error': 'bridge_error'});
    }
  }

  UserScript _userScript() => UserScript(
        source: buildBridgeScript(
          deviceInfo: _session.info.toDeviceInfo(_session.appVersion),
          secret: _bridgeSecret,
          hideSoftKeyboard: _settings.hideSoftKeyboard,
        ),
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        forMainFrameOnly: true,
      );

  /// Bascule le clavier de l'écran : appliqué tout de suite à la page, mémorisé, et repris aux pages suivantes.
  /// Lien d'afficheur imposé dans les réglages : ouvert sur le second écran dès la première page de la boutique chargée,
  /// sans attendre la caisse (écran de connexion compris). Sans second écran, le natif répond `no_secondary_display` : rien.
  Future<void> _showForcedDisplay(String? page) async {
    final forced = _settings.customerDisplayUrl;
    if (forced.isEmpty || forced == _forcedDisplayShown || originOf(page) != _settings.origin || !_session.info.hasSecondaryDisplay) return;
    _forcedDisplayShown = forced;
    await _session.channel.showCustomerDisplay(forced, _settings.origin);
  }

  Future<void> _toggleSoftKeyboard() async {
    setState(() => _settings.hideSoftKeyboard = !_settings.hideSoftKeyboard);
    await _settings.save();
    await _applyKeyboardBlock();
    await _controller?.evaluateJavascript(source: 'window.__skClavier && window.__skClavier(${_settings.hideSoftKeyboard})');
    await _controller?.removeAllUserScripts();
    await _controller?.addUserScript(userScript: _userScript());
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        duration: const Duration(seconds: 2),
        content: Text(_settings.hideSoftKeyboard
            ? 'Clavier de l’écran masqué : le clavier externe et la douchette restent actifs.'
            : 'Clavier de l’écran rétabli.'),
      ));
  }

  Future<NativeResult> _printEscPos(String? base64) async {
    if (base64 == null || base64.isEmpty) return NativeResult.failure('payload_not_base64');
    final Uint8List bytes;
    try {
      bytes = base64Decode(base64.replaceAll(RegExp(r'\s'), ''));
    } on FormatException {
      return NativeResult.failure('payload_not_base64');
    }
    if (bytes.length > _maxPayloadBytes) return NativeResult.failure('payload_too_large');
    return _session.channel.printRaw(bytes);
  }

  void _reload() {
    setState(() => _error = null);
    _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(_settings.shopUrl)));
  }

  void _onCornerTap() {
    final now = DateTime.now();
    _cornerTaps
      ..add(now)
      ..removeWhere((t) => now.difference(t) > const Duration(seconds: 3));
    if (_cornerTaps.length >= 5) {
      _cornerTaps.clear();
      _openSettings();
    }
  }

  Future<void> _openSettings() async {
    final previousUrl = _settings.shopUrl;
    await _session.channel.setSoftKeyboardBlocked(false);
    try {
      if (_settings.adminCode.isNotEmpty && !await _askCode()) return;
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SettingsPage(session: _session)));
    } finally {
      await _applyKeyboardBlock();
    }
    if (!mounted) return;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // Le script injecté porte la description du terminal (getDeviceInfo) : il est remplacé, puis la page rechargée.
    await _controller?.removeAllUserScripts();
    await _controller?.addUserScript(userScript: _userScript());
    if (previousUrl != _settings.shopUrl) {
      _reload();
    } else {
      await _controller?.reload();
    }
  }

  Future<bool> _askCode() async {
    final input = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Code administrateur'),
        content: TextField(
          controller: input,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          onSubmitted: (_) => Navigator.pop(context, true),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Valider')),
        ],
      ),
    );
    return ok == true && input.text == _settings.adminCode;
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message, required this.onRetry, required this.onSettings});

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.white,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off, size: 56, color: Color(0xFF0F3E2E)),
              const SizedBox(height: 16),
              Text('Boutique injoignable', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              Wrap(
                spacing: 12,
                children: [
                  FilledButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Réessayer')),
                  OutlinedButton.icon(onPressed: onSettings, icon: const Icon(Icons.settings), label: const Text('Réglages')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _randomSecret() {
  final random = Random.secure();
  return List.generate(24, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}
