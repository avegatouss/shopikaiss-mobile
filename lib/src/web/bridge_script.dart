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
///   part toujours au natif (qui mémorise l'URL et rouvre l'afficheur à son branchement, comme le pont
///   Kotlin) ; un échec tardif devient un toast `pos-toast`.
///
/// Il remplace aussi `window.print()` (fenêtre principale et cadres de même origine, y compris les
/// `iframe srcdoc` des tickets) : le document est sérialisé et confié à l'application, qui l'envoie à
/// l'imprimante intégrée (ticket `[data-paper-width]`) ou à la boîte d'impression Android (A4).
///
/// Chaque appel porte [secret], tiré au lancement de l'application et présent seulement dans ce script
/// du cadre principal : le gestionnaire Dart refuse un appel sans lui, donc une iframe d'une autre
/// origine (qui voit `flutter_inappwebview.callHandler` mais pas ce script) ne peut pas imprimer.
///
/// [hideSoftKeyboard] : `inputmode="none"` posé sur les champs (et les champs ajoutés ensuite) pour qu'Android n'ouvre
/// pas son clavier virtuel ; un clavier externe ou une douchette saisissent toujours. `window.__skClavier(bool)` bascule
/// sans recharger la page (bouton ⌨ de l'application).
String buildBridgeScript({required Map<String, dynamic> deviceInfo, required String secret, bool hideSoftKeyboard = false}) {
  final config = jsonEncode({'deviceInfo': deviceInfo, 'secret': secret, 'hideSoftKeyboard': hideSoftKeyboard});
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
    printer_error: 'Imprimante en erreur : vérifiez-la puis réimprimez.',
    printer_overheated: 'Tête d’impression trop chaude : patientez quelques secondes puis réimprimez.',
    cutter_error: 'Massicot de l’imprimante bloqué.',
    sunmi_service_timeout: 'Le service d’impression du terminal ne répond pas : réimprimez dans un instant.',
    usb_printer_not_found: 'Imprimante USB introuvable : vérifiez qu’elle est branchée et allumée.',
    usb_open_failed: 'Imprimante USB inaccessible : débranchez-la, rebranchez-la puis réimprimez.',
    usb_claim_failed: 'Imprimante USB occupée par une autre application.',
    usb_write_failed: 'Envoi à l’imprimante USB interrompu : réimprimez.',
    bluetooth_absent: 'Ce terminal n’a pas de Bluetooth : choisissez un autre pilote dans les réglages de l’application.',
    bluetooth_disabled: 'Bluetooth désactivé : activez-le sur le terminal puis réimprimez.',
    bluetooth_printer_not_found: 'Imprimante Bluetooth non appairée (InnerPrinter introuvable) : appairez-la ou changez de pilote.',
    no_secondary_display: 'Aucun second écran détecté : vérifiez le câble de l’afficheur client.',
    display_invalid: 'Second écran inutilisable : rebranchez l’afficheur client.',
    origin_not_allowed: 'Adresse de la caisse non autorisée par l’application ShopiKaiss (boutique à reconfigurer).',
    unknown_method: 'Fonction inconnue de l’application ShopiKaiss : mettez l’application à jour.',
    bridge_error: 'Erreur interne de l’application ShopiKaiss : réessayez, puis redémarrez l’application.'
  };
  /* Erreurs qu'un nouvel essai automatique ne corrigera pas (une intervention est nécessaire). */
  var PERMANENT = ['payload_not_base64', 'payload_too_large', 'sdk_absent', 'printer_not_configured', 'paper_out', 'cover_open', 'cutter_error',
    'usb_printer_not_found', 'usb_claim_failed', 'bluetooth_absent', 'bluetooth_disabled', 'bluetooth_printer_not_found',
    'no_secondary_display', 'display_invalid', 'origin_not_allowed', 'unknown_method'];

  var ready = new Promise(function (resolve) {
    if (window.flutter_inappwebview && typeof window.flutter_inappwebview.callHandler === 'function') { resolve(); return; }
    window.addEventListener('flutterInAppWebViewPlatformReady', function () { resolve(); }, { once: true });
  });

  function call(method, args) {
    return ready
      .then(function () { return window.flutter_inappwebview.callHandler('ShopiKaissNative', cfg.secret, method, args || []); })
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
      call('showCustomerDisplay', [String(url || '')]).catch(function (error) { toast('Afficheur client non affiché : ' + error.message); });
      return '{"ok":true}';
    },
    hideCustomerDisplay: function () { call('hideCustomerDisplay').catch(function () {}); return '{"ok":true}'; },
    getDeviceInfo: function () { return JSON.stringify(cfg.deviceInfo); }
  };
  try {
    Object.defineProperty(window, 'ShopiKaissNative', { value: Object.freeze(api), writable: false, configurable: false });
  } catch (e) { window.ShopiKaissNative = api; }

  /* ---------------------------------------------------------------- clavier de l'écran */

  var EDITABLE = 'input:not([type=hidden]):not([type=checkbox]):not([type=radio]):not([type=button]):not([type=submit]):not([type=file]):not([type=range]):not([type=color]), textarea, [contenteditable=""], [contenteditable=true]';
  var clavierMasque = !!cfg.hideSoftKeyboard;
  function masquer(el) {
    if (el.getAttribute('inputmode') === 'none' && el.hasAttribute('data-sk-inputmode')) { return; }
    if (!el.hasAttribute('data-sk-inputmode')) { el.setAttribute('data-sk-inputmode', el.getAttribute('inputmode') || ''); }
    el.setAttribute('inputmode', 'none');
  }
  function retablir(el) {
    if (!el.hasAttribute('data-sk-inputmode')) { return; }
    var avant = el.getAttribute('data-sk-inputmode');
    if (avant) { el.setAttribute('inputmode', avant); } else { el.removeAttribute('inputmode'); }
    el.removeAttribute('data-sk-inputmode');
  }
  function appliquerClavier(racine) {
    var liste = (racine || document).querySelectorAll ? (racine || document).querySelectorAll(EDITABLE) : [];
    for (var i = 0; i < liste.length; i++) { clavierMasque ? masquer(liste[i]) : retablir(liste[i]); }
    if (racine && racine.matches && racine.matches(EDITABLE)) { clavierMasque ? masquer(racine) : retablir(racine); }
  }
  // Livewire (morph) remet à chaque rendu les attributs du serveur : `inputmode` et le repère disparaissent des champs
  // existants (le clavier revenait après quelques produits). Les changements d'attribut sont donc surveillés aussi.
  new MutationObserver(function (mutations) {
    if (!clavierMasque) { return; }
    for (var i = 0; i < mutations.length; i++) {
      var m = mutations[i];
      if (m.type === 'attributes') {
        if (m.target.matches && m.target.matches(EDITABLE) && m.target.getAttribute('inputmode') !== 'none') { masquer(m.target); }
        continue;
      }
      for (var j = 0; j < m.addedNodes.length; j++) {
        var noeud = m.addedNodes[j];
        if (noeud.nodeType === 1) { appliquerClavier(noeud); }
      }
    }
  }).observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['inputmode', 'data-sk-inputmode', 'type', 'contenteditable'] });
  document.addEventListener('DOMContentLoaded', function () { appliquerClavier(document); });
  // Filet : un champ pris au focus sans `inputmode="none"` est masqué puis repris, avant que le clavier ne s'ouvre.
  document.addEventListener('focusin', function (e) {
    var el = e.target;
    if (!clavierMasque || !el || !el.matches || !el.matches(EDITABLE) || el.getAttribute('inputmode') === 'none') { return; }
    masquer(el);
    el.blur();
    setTimeout(function () { el.focus({ preventScroll: true }); }, 0);
  }, true);
  window.__skClavier = function (masque) {
    clavierMasque = !!masque;
    appliquerClavier(document);
    // Champ déjà actif : le quitter puis y revenir applique le nouveau mode immédiatement.
    var actif = document.activeElement;
    if (actif && actif.matches && actif.matches(EDITABLE)) { actif.blur(); setTimeout(function () { actif.focus(); }, 30); }
    return clavierMasque;
  };

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
