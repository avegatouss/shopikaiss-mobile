import 'dart:convert';

/// Script injecté au démarrage de chaque page de la caisse (cadre principal).
///
/// Il recrée `window.ShopiKaissNative`, le contrat n°4 de l'application Android « ShopiKaiss Bridge »
/// (`android/shopikaiss-bridge/.../web/NativeBridge.kt` dans shopikaiss-web), au-dessus du canal
/// asynchrone de flutter_inappwebview :
///
/// - `printEscPos`, `openDrawer`, `getPrinterStatus`, `beep` renvoient une **Promise**. La page
///   (`ticket-printer.js`, `callNative`) passe la valeur de retour à `resolve()` : une Promise est
///   adoptée, et un `{ok:false}` natif devient un rejet portant `code` et `permanent` comme le pont
///   Kotlin ;
/// - `showCustomerDisplay`, `hideCustomerDisplay`, `getDeviceInfo` restent **synchrones** :
///   `caisse-afficheur-client.blade.php` fait `JSON.parse(pont.showCustomerDisplay(url))`. L'ordre
///   part en tâche de fond ; un échec tardif devient un toast `pos-toast`.
///
/// Il remplace aussi `window.print()` (fenêtre principale et cadres de même origine, y compris les
/// `iframe srcdoc` des tickets) : le document est sérialisé et confié à l'application, qui l'envoie à
/// l'imprimante intégrée (ticket `[data-paper-width]`) ou à la boîte d'impression Android (A4).
String buildBridgeScript({required Map<String, dynamic> deviceInfo, required bool hasSecondaryDisplay}) {
  final config = jsonEncode({'deviceInfo': deviceInfo, 'hasSecondaryDisplay': hasSecondaryDisplay});
  return _template.replaceFirst('__SHOPIKAISS_CONFIG__', config);
}

const String bridgeHandlerName = 'ShopiKaissNative';

const String _template = r'''
(function () {
  'use strict';
  if (window.ShopiKaissNative && window.ShopiKaissNative.__terminal) { return; }
  var cfg = __SHOPIKAISS_CONFIG__;

  var LABELS = {
    payload_not_base64: 'Ticket mal encodé pour l’imprimante (base64 attendu).',
    payload_too_large: 'Ticket trop volumineux pour l’imprimante (plus de 512 Ko).',
    usb_permission_pending: 'Autorisation USB en attente : acceptez la demande affichée par Android, puis réimprimez.',
    bluetooth_permission_pending: 'Autorisation Bluetooth en attente : acceptez la demande affichée par Android, puis réimprimez.',
    sdk_absent: 'Imprimante intégrée introuvable sur ce terminal : vérifiez le pilote dans les réglages de l’application.',
    printer_not_configured: 'Aucune imprimante configurée dans l’application ShopiKaiss (réglages : 5 touchers en haut à gauche).',
    paper_out: 'Plus de papier dans l’imprimante.',
    cover_open: 'Capot de l’imprimante ouvert.',
    no_secondary_display: 'Aucun second écran détecté : vérifiez le câble de l’afficheur client.',
    origin_not_allowed: 'Adresse de la caisse non autorisée par l’application ShopiKaiss (boutique à reconfigurer).'
  };
  var PERMANENT = ['payload_not_base64', 'payload_too_large', 'sdk_absent', 'printer_not_configured', 'no_secondary_display', 'origin_not_allowed'];

  var ready = new Promise(function (resolve) {
    if (window.flutter_inappwebview && typeof window.flutter_inappwebview.callHandler === 'function') { resolve(); return; }
    window.addEventListener('flutterInAppWebViewPlatformReady', function () { resolve(); }, { once: true });
  });

  function call(method, args) {
    return ready
      .then(function () { return window.flutter_inappwebview.callHandler('ShopiKaissNative', method, args || []); })
      .then(function (raw) {
        var parsed = typeof raw === 'string' ? JSON.parse(raw) : (raw || {});
        if (parsed && parsed.ok === false) {
          var error = new Error(LABELS[parsed.error] || parsed.error || (method + ' refusé par l’application'));
          error.code = parsed.error || null;
          error.permanent = PERMANENT.indexOf(parsed.error) >= 0;
          throw error;
        }
        return parsed;
      });
  }

  function toast(message) {
    window.dispatchEvent(new CustomEvent('pos-toast', { detail: { level: 'warning', message: message } }));
  }

  var api = {
    __terminal: true,
    printEscPos: function (base64) { return call('printEscPos', [String(base64 || '')]); },
    openDrawer: function () { return call('openDrawer'); },
    getPrinterStatus: function () { return call('getPrinterStatus'); },
    beep: function (ms) { return call('beep', [Number(ms) || 80]); },
    showCustomerDisplay: function (url) {
      if (!cfg.hasSecondaryDisplay) { return '{"ok":false,"error":"no_secondary_display"}'; }
      call('showCustomerDisplay', [String(url || '')]).catch(function (error) { toast('Afficheur client non affiché : ' + error.message); });
      return '{"ok":true}';
    },
    hideCustomerDisplay: function () { call('hideCustomerDisplay').catch(function () {}); return '{"ok":true}'; },
    getDeviceInfo: function () { return JSON.stringify(cfg.deviceInfo); }
  };
  try {
    Object.defineProperty(window, 'ShopiKaissNative', { value: Object.freeze(api), writable: false, configurable: false });
  } catch (e) { window.ShopiKaissNative = api; }

  /* ---------------------------------------------------------------- window.print() */

  function paperOf(doc) {
    var el = doc.querySelector('[data-paper-width]');
    if (el) {
      return { width: Number(el.getAttribute('data-paper-width')) || 0, margin: Number(el.getAttribute('data-paper-margin')) || 0 };
    }
    var cls = doc.querySelector('.sk-paper-58, .sk-paper-80');
    if (cls) { return { width: cls.classList.contains('sk-paper-58') ? 58 : 80, margin: 2 }; }
    return null;
  }

  function nativePrint(win) {
    var doc = win.document;
    try { win.dispatchEvent(new Event('beforeprint')); } catch (e) {}
    var paper = paperOf(doc);
    var job = {
      html: '<!doctype html>' + doc.documentElement.outerHTML,
      baseUrl: doc.baseURI && doc.baseURI.indexOf('http') === 0 ? doc.baseURI : window.location.href,
      title: doc.title || 'ShopiKaiss',
      paperWidth: paper ? paper.width : 0,
      paperMargin: paper ? paper.margin : 0
    };
    setTimeout(function () { try { win.dispatchEvent(new Event('afterprint')); } catch (e) {} }, 0);
    call('printHtml', [job]).catch(function (error) { toast('Impression impossible : ' + error.message); });
  }

  function patch(win) {
    try {
      if (!win || win.__shopikaissPrint === win.document) { return; }
      win.__shopikaissPrint = win.document;
      win.print = function () { nativePrint(win); };
    } catch (e) { /* cadre d'une autre origine : laissé tel quel */ }
  }

  patch(window);
  var descriptor = Object.getOwnPropertyDescriptor(HTMLIFrameElement.prototype, 'contentWindow');
  if (descriptor && descriptor.get) {
    Object.defineProperty(HTMLIFrameElement.prototype, 'contentWindow', {
      configurable: true,
      enumerable: descriptor.enumerable,
      get: function () { var w = descriptor.get.call(this); patch(w); return w; }
    });
  }
})();
''';
