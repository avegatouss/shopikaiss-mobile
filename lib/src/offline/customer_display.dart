import 'dart:async';
import 'dart:convert';

import 'models.dart';
import 'money.dart';
import 'web_rules.dart';

/// Envoi d'un état à l'afficheur client (second écran) ; levée ou `ok:false` sans conséquence pour la vente.
typedef CustomerDisplayPush = Future<void> Function(Map<String, dynamic> state);

/// Nombre de lignes envoyées à l'écran (les dernières ajoutées), comme `CustomerDisplayFeed::MAX_LINES` du web.
const customerDisplayMaxLines = 60;

/// Quantité lisible comme sur l'afficheur web (« 2 », « 1,5 »).
String _quantity(BigInt micros) => formatMicros(micros).replaceAll('.', ',');

/// État de l'afficheur au format exact que la page de l'afficheur web reçoit de `/etat` (`CustomerDisplayFeed::state()`,
/// ADR-401) et qu'elle accepte par `window.ShopiKaissDisplay.push(state)`. `idle` est laissé à la page (message d'accueil,
/// promotion et images de la boutique déjà reçus) : le script d'envoi le reprend de l'état affiché.
///
/// [phase] : `idle`, `cart`, `payment` ou `completed`.
Map<String, dynamic> customerDisplayState({
  required String phase,
  List<CartLine> lines = const [],
  WebTotals? totals,
  Map<String, dynamic>? payment,
  int? total,
  String? saleNumber,
}) {
  final shown = lines.length > customerDisplayMaxLines ? lines.sublist(lines.length - customerDisplayMaxLines) : lines;
  final payable = total ?? totals?.payable ?? 0;
  return {
    'phase': phase,
    'event': switch (phase) {
      'idle' => 'display.idle',
      'payment' => 'payment.started',
      'completed' => 'payment.completed',
      _ => 'cart.updated',
    },
    'lines': [
      for (final line in shown)
        {
          'name': line.label.length > 120 ? line.label.substring(0, 120) : line.label,
          'quantity': _quantity(line.quantity),
          'unit': null,
          'unit_price': line.unitPrice,
          'discount': line.discount > 0 ? line.discount : 0,
          'total': line.total,
          'free': false,
          'promotion': null,
        },
    ],
    'line_count': lines.length,
    'total': payable,
    'discount': totals?.discounts ?? 0,
    'delivery': totals?.delivery ?? 0,
    'paid': (payment?['paid'] as int?) ?? 0,
    'remaining': (payment?['remaining'] as int?) ?? (phase == 'completed' ? 0 : payable),
    'order_number': null,
    'sale_number': saleNumber,
    'customer': null,
    'payment': payment,
    'message': null,
  };
}

/// Script exécuté dans la page du second écran : l'état est remis à `ShopiKaissDisplay.push` de la page de l'afficheur
/// (web chargée avant la coupure, ou page locale). Répond `"absent"` si la page affichée n'est pas un afficheur.
String customerDisplayScript(Map<String, dynamic> state) {
  final json = jsonEncode(state).replaceAll(' ', r' ').replaceAll(' ', r' ');
  return '(function(s){var d=window.ShopiKaissDisplay;if(!d||!d.push)return "absent";'
      'var c=d.state?d.state():null;s.idle=s.idle||(c&&c.idle)||{};d.push(s);return "ok";})($json)';
}

String _html(String text) => text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

/// Page locale de l'afficheur, ouverte sur le second écran quand aucune page d'afficheur web n'est chargée (démarrage
/// sans réseau). Même interface `window.ShopiKaissDisplay` et mêmes vues que la page web : accueil, panier, merci.
String customerDisplayPage(String storeName) => '''<!DOCTYPE html>
<html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root{--fond:#0b1f17;--carte:#12302a;--ligne:#1f4a3f;--texte:#f5f3ee;--doux:#b9c4bf;--or:#c9a961;--vert:#34d399;--orange:#fbbf24;--pad:clamp(12px,2.2vw,32px);--fs:clamp(16px,2.1vh + .4vw,26px)}
*{box-sizing:border-box;margin:0;padding:0}
html,body{height:100%;overflow:hidden;background:var(--fond);color:var(--texte);font-family:system-ui,Roboto,sans-serif;cursor:none}
body{display:grid;grid-template-rows:auto 1fr;height:100vh;font-size:var(--fs)}
.num{font-variant-numeric:tabular-nums;white-space:nowrap}
header{padding:calc(var(--pad)*.6) var(--pad);border-bottom:1px solid var(--ligne);font-weight:700;font-size:1.15em}
main{position:relative;min-height:0}.vue{position:absolute;inset:0;display:none}.vue.active{display:grid}[hidden]{display:none!important}
#vue-panier{grid-template-columns:minmax(0,1.55fr) minmax(0,1fr);gap:var(--pad);padding:var(--pad)}
ol{list-style:none;overflow:hidden}li{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:4px 16px;padding:.5em 0;border-bottom:1px solid var(--ligne)}
.nom{font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.detail{color:var(--doux);font-size:.8em}.tl{font-weight:700;text-align:right;grid-row:span 2;align-self:center}.remise{color:var(--orange);font-size:.8em}
.montants{background:var(--carte);border-radius:18px;padding:var(--pad);display:flex;flex-direction:column;justify-content:flex-end;gap:.5em}
.rang{display:flex;justify-content:space-between;gap:12px}.doux{color:var(--doux)}.lib{color:var(--doux);text-transform:uppercase;letter-spacing:.08em}
.total{font-size:clamp(40px,11vh,104px);font-weight:800;line-height:1;color:var(--or);text-align:right}.rendu{font-size:1.6em;font-weight:800;color:var(--vert)}
#vue-merci,#vue-attente{place-items:center;text-align:center;padding:var(--pad)}h1{font-size:clamp(40px,10vh,96px);color:var(--or)}#vue-merci p{margin-top:.4em;color:var(--doux)}#vue-merci .rendu{font-size:clamp(32px,8vh,72px)}
@media (max-width:720px){#vue-panier{grid-template-columns:1fr;grid-template-rows:minmax(0,1fr) auto}}
</style></head><body>
<header>${_html(storeName)}</header>
<main>
<section class="vue" id="vue-panier"><ol id="lignes"></ol><div class="montants">
<div class="rang doux" id="rang-remise" hidden><span>Remises</span><span class="num" id="remise"></span></div>
<div class="rang doux" id="rang-livraison" hidden><span>Livraison</span><span class="num" id="livraison"></span></div>
<span class="lib">Total à payer</span><span class="total num" id="total"></span>
<div id="paiement" hidden><div class="rang"><span>Reçu</span><span class="num" id="recu"></span></div>
<div class="rang" id="rang-reste" hidden><span>Reste à payer</span><span class="num" id="reste"></span></div>
<div class="rang rendu" id="rang-rendu" hidden><span>Rendu</span><span class="num" id="rendu"></span></div></div>
</div></section>
<section class="vue" id="vue-merci"><div><h1>Merci&nbsp;!</h1><p id="merci-total" class="num"></p><p class="rendu num" id="merci-rendu" hidden></p><p id="merci-vente"></p></div></section>
<section class="vue" id="vue-attente"><div><h1 id="accueil">Bienvenue</h1><p id="promo" hidden></p></div></section>
</main>
<script>
(function(){
var cur=null,L={};
function \$(i){return document.getElementById(i)}
function money(v){return Number(v||0).toLocaleString('fr-FR')+' F'}
function show(i){document.querySelectorAll('.vue').forEach(function(v){v.classList.toggle('active',v.id===i)})}
function text(i,v){\$(i).textContent=v}
function toggle(i,v){\$(i).hidden=!v}
function render(s){
cur=s;
if(s.phase==='completed'){text('merci-total','Total réglé : '+money(s.total));var c=s.payment?s.payment.change:0;toggle('merci-rendu',c>0);text('merci-rendu','Rendu : '+money(c));text('merci-vente',s.sale_number?'Vente '+s.sale_number:'');show('vue-merci');}
else if(s.phase==='idle'||!s.lines||s.lines.length===0){var w=(s.idle&&s.idle.welcome!=null)?s.idle.welcome:'Bienvenue';text('accueil',w);toggle('accueil',w!=='');toggle('promo',!!(s.idle&&s.idle.promo));text('promo',(s.idle&&s.idle.promo)||'');show('vue-attente');}
else{var ol=\$('lignes');ol.replaceChildren.apply(ol,s.lines.slice(-12).map(function(l){var li=document.createElement('li');
var n=document.createElement('span');n.className='nom';n.textContent=l.name;var t=document.createElement('span');t.className='tl num';t.textContent=l.free?'Offert':money(l.total);
var d=document.createElement('span');d.className='detail num';d.textContent=l.quantity+(l.unit?' '+l.unit:'')+' × '+money(l.unit_price);li.append(n,t,d);
if(l.discount>0){var r=document.createElement('span');r.className='remise num';r.textContent=(l.promotion||'Remise')+' −'+money(l.discount);li.append(r);}return li;}));
toggle('rang-remise',s.discount>0);text('remise','−'+money(s.discount));toggle('rang-livraison',s.delivery>0);text('livraison',money(s.delivery));text('total',money(s.total));
var p=s.phase==='payment'?s.payment:null;toggle('paiement',!!p);if(p){text('recu',money(p.received));toggle('rang-reste',p.remaining>0);text('reste',money(p.remaining));toggle('rang-rendu',p.change>0);text('rendu',money(p.change));}
show('vue-panier');}
(L[s.event]||[]).concat(L['*']||[]).forEach(function(f){try{f(s)}catch(e){}});
}
window.ShopiKaissDisplay={push:render,on:function(e,f){(L[e]=L[e]||[]).push(f)},state:function(){return cur}};
render({phase:'idle',event:'display.idle',lines:[],idle:{}});
})();
</script></body></html>''';

/// Afficheur client de la caisse hors ligne : chaque état différent du précédent est poussé une fois, sans réseau.
/// Sans afficheur (aucun second écran), [push] est null et rien n'est envoyé.
class OfflineCustomerDisplay {
  OfflineCustomerDisplay(this.push);

  final CustomerDisplayPush? Function() push;
  String? _last;

  /// Au moins un état a été envoyé : au retour en ligne, l'afficheur doit reprendre la page de la boutique.
  bool used = false;

  void publish(Map<String, dynamic> state) {
    final send = push();
    if (send == null) return;
    final encoded = jsonEncode(state);
    if (encoded == _last) return;
    _last = encoded;
    used = true;
    unawaited(
      Future.sync(() => send(state)).then<void>(
        (_) {},
        onError: (Object _) {
          // Afficheur débranché ou refus du natif : le prochain état sera renvoyé.
          if (_last == encoded) _last = null;
        },
      ),
    );
  }
}
