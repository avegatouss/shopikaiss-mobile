import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import 'shop_browser_policy.dart';

/// Web account navigation only. No cashier JavaScript bridge or native sale API.
class ShopBrowserPage extends StatefulWidget {
  const ShopBrowserPage({
    super.key,
    required this.policy,
    this.admin = true,
    this.deviceCookie,
  });
  final ShopBrowserPolicy policy;
  final bool admin;
  final String? deviceCookie;
  @override
  State<ShopBrowserPage> createState() => _ShopBrowserPageState();
}

class _ShopBrowserPageState extends State<ShopBrowserPage> {
  InAppWebViewController? controller;
  Timer? deadline;
  double progress = 0;
  bool canBack = false, canForward = false;
  String? error;
  Uri get initial => widget.admin ? widget.policy.admin : widget.policy.site;
  @override
  void dispose() {
    deadline?.cancel();
    super.dispose();
  }

  void started() {
    if (!mounted) return;
    setState(() {
      error = null;
      progress = 0;
    });
    deadline?.cancel();
    deadline = Timer(const Duration(seconds: 30), () {
      if (mounted) {
        setState(
          () => error = 'Le site ne répond pas. Vérifiez le résultat de votre dernière action avant de recharger.',
        );
      }
    });
  }

  Future<void> navigationState() async {
    final back = await controller?.canGoBack() ?? false;
    final forward = await controller?.canGoForward() ?? false;
    if (mounted) {
      setState(() {
        canBack = back;
        canForward = forward;
      });
    }
  }

  Future<void> navigate(Uri uri) async {
    switch (widget.policy.navigation(uri)) {
      case ShopNavigation.internal:
        await controller?.loadUrl(urlRequest: URLRequest(url: WebUri.uri(uri)));
      case ShopNavigation.external:
        try {
          if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
              mounted) {
            setState(
              () => error = 'Aucune application ne peut ouvrir ce lien.',
            );
          }
        } catch (_) {
          if (mounted) setState(() => error = 'Impossible d’ouvrir ce lien.');
        }
      case ShopNavigation.blocked:
        if (mounted) {
          setState(() => error = 'Ce type de lien ne peut pas être ouvert.');
        }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !canBack,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) controller?.goBack();
    },
    child: Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: IconButton(
          tooltip: 'Revenir à la caisse',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(widget.admin ? 'Back-office' : 'Site de la boutique'),
        actions: [
          IconButton(
            tooltip: 'Site de la boutique',
            icon: const Icon(Icons.public),
            onPressed: () => navigate(widget.policy.site),
          ),
          IconButton(
            tooltip: 'Accueil du back-office',
            icon: const Icon(Icons.dashboard_outlined),
            onPressed: () => navigate(widget.policy.admin),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              '${widget.policy.origin.host} · Connexion Internet requise',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (progress < 1) LinearProgressIndicator(value: progress),
          Expanded(
            child: Stack(
              children: [
                InAppWebView(
                  initialSettings: InAppWebViewSettings(
                    javaScriptEnabled: true,
                    domStorageEnabled: true,
                    useShouldOverrideUrlLoading: true,
                    useOnDownloadStart: true,
                    supportMultipleWindows: true,
                    javaScriptCanOpenWindowsAutomatically: false,
                    thirdPartyCookiesEnabled: false,
                  ),
                  onWebViewCreated: (c) async {
                    controller = c;
                    try {
                      final cookies = CookieManager.instance();
                      if (widget.deviceCookie != null) {
                        await cookies.setCookie(
                          url: WebUri.uri(widget.policy.origin),
                          name: 'sk_appareil',
                          value: widget.deviceCookie!,
                          path: '/',
                          isSecure: true,
                          isHttpOnly: true,
                        );
                      } else {
                        await cookies.deleteCookie(
                          url: WebUri.uri(widget.policy.origin),
                          name: 'sk_appareil',
                        );
                      }
                      if (mounted) await navigate(initial);
                    } catch (_) {
                      if (mounted) {
                        setState(
                          () => error = 'Impossible de préparer la navigation. Revenez à la caisse puis réessayez.',
                        );
                      }
                    }
                  },
                  shouldOverrideUrlLoading: (c, action) async {
                    final uri = action.request.url;
                    if (uri == null) return NavigationActionPolicy.CANCEL;
                    if (widget.policy.navigation(uri) ==
                        ShopNavigation.internal) {
                      return NavigationActionPolicy.ALLOW;
                    }
                    if (action.isForMainFrame) await navigate(uri);
                    return NavigationActionPolicy.CANCEL;
                  },
                  onCreateWindow: (c, action) async {
                    final uri = action.request.url;
                    if (uri != null) await navigate(uri);
                    return false;
                  },
                  onPermissionRequest: (c, request) async => PermissionResponse(
                    resources: request.resources,
                    action: PermissionResponseAction.DENY,
                  ),
                  onDownloadStartRequest: (c, request) async {
                    // Keep authenticated downloads explicit; never inject session cookies into another client.
                    if (mounted) {
                      setState(
                        () => error = 'Pour télécharger ce document, utilisez le navigateur système et connectez-vous au site.',
                      );
                    }
                  },
                  onLoadStart: (c, url) => started(),
                  onProgressChanged: (c, value) {
                    if (mounted) setState(() => progress = value / 100);
                  },
                  onLoadStop: (c, url) async {
                    deadline?.cancel();
                    if (mounted) setState(() => progress = 1);
                    await navigationState();
                  },
                  onUpdateVisitedHistory: (c, url, reload) => navigationState(),
                  onReceivedError: (c, request, failure) {
                    if ((request.isForMainFrame ?? false) && mounted) {
                      deadline?.cancel();
                      setState(
                        () => error = 'Site inaccessible. La caisse locale reste disponible.',
                      );
                    }
                  },
                  onReceivedHttpError: (c, request, response) {
                    if ((request.isForMainFrame ?? false) &&
                        (response.statusCode ?? 0) >= 500 &&
                        mounted) {
                      setState(
                        () => error = 'Le serveur rencontre une erreur. La caisse locale reste disponible.',
                      );
                    }
                  },
                ),
                if (error != null)
                  Positioned.fill(
                    child: ColoredBox(
                      color: Theme.of(context).colorScheme.surface,
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.cloud_off, size: 40),
                              const SizedBox(height: 16),
                              Text(error!, textAlign: TextAlign.center),
                              const SizedBox(height: 16),
                              FilledButton(
                                onPressed: () => controller?.reload(),
                                child: const Text('Recharger'),
                              ),
                              TextButton(
                                onPressed: () async {
                                  try {
                                    await launchUrl(
                                      initial,
                                      mode: LaunchMode.externalApplication,
                                    );
                                  } catch (_) {
                                    if (mounted) {
                                      setState(
                                        () => error = 'Impossible d’ouvrir le navigateur système.',
                                      );
                                    }
                                  }
                                },
                                child: const Text(
                                  'Ouvrir le site dans le navigateur système',
                                ),
                              ),
                              TextButton(
                                onPressed: () => Navigator.of(context).pop(),
                                child: const Text('Revenir à la caisse'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  tooltip: 'Page précédente',
                  onPressed: canBack ? () => controller?.goBack() : null,
                  icon: const Icon(Icons.arrow_back),
                ),
                IconButton(
                  tooltip: 'Page suivante',
                  onPressed: canForward ? () => controller?.goForward() : null,
                  icon: const Icon(Icons.arrow_forward),
                ),
                IconButton(
                  tooltip: 'Recharger',
                  onPressed: () => controller?.reload(),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
