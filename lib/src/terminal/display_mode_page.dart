import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../settings/settings_page.dart';
import '../web/caisse_page.dart';
import 'terminal_session.dart';

/// Mode « afficheur » d'une tablette Android (lot R-6) : la page servie par la caisse maîtresse du lieu, en plein
/// écran. L'appareil n'est jamais appairé à la boutique et ne navigue nulle part ailleurs que chez la caisse. Retour
/// (ou appui long en haut à droite) : sortie, avec le code administrateur s'il est défini.
class DisplayModePage extends StatefulWidget {
  const DisplayModePage({super.key, required this.session});

  final TerminalSession session;

  @override
  State<DisplayModePage> createState() => _DisplayModePageState();
}

class _DisplayModePageState extends State<DisplayModePage> {
  InAppWebViewController? _web;
  String? _error;
  Timer? _retry;

  String get _url => widget.session.settings.displayModeUrl;
  String get _origin => Uri.parse(_url).origin;

  @override
  void initState() {
    super.initState();
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
  }

  @override
  void dispose() {
    _retry?.cancel();
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  void _failed(String message) {
    if (!mounted) return;
    setState(() => _error = message);
    _retry?.cancel();
    // La caisse redémarre ou le Wi-Fi revient : nouvel essai sans intervention.
    _retry = Timer(const Duration(seconds: 10), _reload);
  }

  void _reload() {
    if (!mounted) return;
    setState(() => _error = null);
    unawaited(_web?.loadUrl(urlRequest: URLRequest(url: WebUri(_url))));
  }

  Future<void> _leave() async {
    final code = widget.session.settings.adminCode;
    if (code.isNotEmpty) {
      final input = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Quitter le mode afficheur'),
          content: TextField(controller: input, autofocus: true, obscureText: true, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Code administrateur')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Quitter')),
          ],
        ),
      );
      final right = ok == true && input.text == code;
      input.dispose();
      if (!right) return;
    } else {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Quitter le mode afficheur ?'),
          content: const Text('Cet appareil reviendra aux réglages de l’application.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Rester')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Quitter')),
          ],
        ),
      );
      if (ok != true) return;
    }
    widget.session.settings.displayModeUrl = '';
    await widget.session.settings.save();
    if (!mounted) return;
    final navigator = Navigator.of(context);
    final session = widget.session;
    Route<void> register() => MaterialPageRoute<void>(builder: (_) => CaissePage(session: session));
    await navigator.pushAndRemoveUntil(
      session.settings.configured
          ? register()
          : MaterialPageRoute<void>(builder: (_) => SettingsPage(session: session, firstRun: true, onDone: () => navigator.pushReplacement(register()))),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_leave());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(_url)),
              initialSettings: InAppWebViewSettings(
                isInspectable: !kReleaseMode,
                javaScriptEnabled: true,
                domStorageEnabled: true,
                mediaPlaybackRequiresUserGesture: false,
                useShouldOverrideUrlLoading: true,
                supportZoom: false,
                builtInZoomControls: false,
                displayZoomControls: false,
                cacheMode: CacheMode.LOAD_NO_CACHE,
                applicationNameForUserAgent: 'ShopiKaissAfficheur/${widget.session.appVersion}',
              ),
              onWebViewCreated: (controller) => _web = controller,
              // Seule la caisse du lieu : aucun lien vers ailleurs.
              shouldOverrideUrlLoading: (controller, action) async {
                final url = action.request.url;
                if (url == null || url.origin == _origin || url.scheme == 'about') return NavigationActionPolicy.ALLOW;
                return NavigationActionPolicy.CANCEL;
              },
              onLoadStop: (controller, url) {
                if (_error != null && mounted) setState(() => _error = null);
              },
              onReceivedError: (controller, request, error) {
                if (request.isForMainFrame ?? true) _failed('Caisse maîtresse injoignable ($_url) : vérifiez le Wi-Fi et que la caisse sert la page d’afficheur.');
              },
              onReceivedHttpError: (controller, request, response) {
                if (request.isForMainFrame ?? true) _failed('La caisse a répondu ${response.statusCode} : vérifiez l’adresse.');
              },
            ),
            if (_error case final error?)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black87,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.wifi_off, color: Colors.white, size: 56),
                          const SizedBox(height: 16),
                          Text(error, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 20)),
                          const SizedBox(height: 8),
                          const Text('Nouvel essai automatique toutes les 10 secondes.', style: TextStyle(color: Colors.white70)),
                          const SizedBox(height: 16),
                          FilledButton(onPressed: _reload, child: const Text('Réessayer maintenant')),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            // Sortie discrète : appui long en haut à droite.
            Positioned(top: 0, right: 0, width: 56, height: 56, child: GestureDetector(behavior: HitTestBehavior.translucent, onLongPress: _leave)),
          ],
        ),
      ),
    );
  }
}
