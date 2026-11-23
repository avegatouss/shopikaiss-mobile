/// Page d'afficheur servie par la caisse maîtresse (R10, lot R-6) : HTML et script sans dépendance, en JavaScript ES5
/// pour les navigateurs de télévision. Lecture seule, sauf « Prêt » et « Actualiser ».
library;

const restoDisplayHtml = r'''<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Afficheur de cuisine</title>
<style>
:root { --fond: #f3f4f6; --carte: #ffffff; --texte: #111827; --doux: #6b7280; --vert: #15803d; --rouge: #b91c1c; --bleu: #1d4ed8; --ambre: #b45309; }
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; background: var(--fond); color: var(--texte); font-family: system-ui, -apple-system, "Segoe UI", Roboto, Arial, sans-serif; }
header { position: sticky; top: 0; z-index: 2; display: flex; flex-wrap: wrap; align-items: center; gap: 8px; padding: 10px 16px; background: #111827; color: #fff; }
header h1 { margin: 0 12px 0 0; font-size: 20px; font-weight: 600; }
.postes { display: flex; flex-wrap: wrap; gap: 6px; flex: 1; }
.poste { min-height: 44px; padding: 8px 14px; border-radius: 22px; border: 2px solid #4b5563; background: transparent; color: #fff; font-size: 16px; cursor: pointer; }
.poste.actif { background: #fff; color: #111827; border-color: #fff; }
.action { min-height: 48px; padding: 10px 18px; border-radius: 10px; border: 0; background: var(--bleu); color: #fff; font-size: 17px; font-weight: 600; cursor: pointer; }
.etat { width: 100%; font-size: 13px; color: #d1d5db; }
#bandeau { display: none; padding: 12px 16px; background: var(--rouge); color: #fff; font-size: 18px; font-weight: 600; text-align: center; }
#bandeau.visible { display: block; }
main { padding: 16px; }
.grille { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 14px; }
.carte { display: flex; flex-direction: column; background: var(--carte); border-radius: 12px; border-top: 8px solid var(--vert); box-shadow: 0 1px 3px rgba(0,0,0,.15); padding: 14px; }
.carte.AJOUT { border-top-color: var(--ambre); }
.carte.ANNULATION { border-top-color: var(--rouge); }
.carte.nouveau { animation: eclat 1s ease-in-out 6; }
@keyframes eclat { 50% { box-shadow: 0 0 0 6px #facc15; } }
.carte.termine { opacity: .5; }
.tete { display: flex; justify-content: space-between; align-items: baseline; gap: 8px; }
.numero { font-size: 26px; font-weight: 700; }
.heure { font-size: 18px; color: var(--doux); }
.titre { margin-top: 4px; font-size: 18px; font-weight: 700; letter-spacing: .04em; }
.ANNULATION .titre { color: var(--rouge); }
.AJOUT .titre { color: var(--ambre); }
.lieu { margin-top: 2px; font-size: 16px; color: var(--doux); }
.marques { margin-top: 6px; }
.marque { display: inline-block; padding: 3px 8px; border-radius: 6px; background: #e5e7eb; font-size: 14px; font-weight: 600; margin-right: 6px; }
ul { list-style: none; margin: 10px 0; padding: 0; flex: 1; }
li { padding: 6px 0; border-bottom: 1px solid #e5e7eb; font-size: 22px; line-height: 1.25; }
li .qte { font-weight: 700; margin-right: 8px; }
li.annule { color: var(--rouge); text-decoration: line-through; }
li .note { display: block; font-size: 17px; font-style: italic; color: var(--ambre); text-decoration: none; }
.motif { font-size: 16px; color: var(--rouge); margin-bottom: 8px; }
.pret { width: 100%; min-height: 60px; border: 0; border-radius: 10px; background: var(--vert); color: #fff; font-size: 22px; font-weight: 700; cursor: pointer; }
.pret:disabled { background: #9ca3af; }
.vide { padding: 48px 16px; text-align: center; font-size: 22px; color: var(--doux); }
form { max-width: 420px; margin: 48px auto; padding: 24px; background: var(--carte); border-radius: 12px; box-shadow: 0 1px 3px rgba(0,0,0,.15); }
form h2 { margin-top: 0; }
label { display: block; margin: 14px 0 6px; font-size: 16px; }
input { width: 100%; min-height: 52px; padding: 10px 12px; font-size: 22px; border: 2px solid #d1d5db; border-radius: 10px; }
form .action { width: 100%; margin-top: 18px; }
.aide { font-size: 15px; color: var(--doux); }
.erreur { color: var(--rouge); font-weight: 600; min-height: 1.4em; }
</style>
</head>
<body>
<header>
  <h1>Afficheur</h1>
  <div class="postes" id="postes"></div>
  <button class="action" id="actualiser" type="button">Actualiser</button>
  <div class="etat" id="etat">Connexion à la caisse…</div>
</header>
<div id="bandeau">Caisse injoignable : les nouveaux bons n’arrivent plus. Vérifiez le Wi-Fi et la caisse.</div>
<main id="contenu"></main>
<script src="/app.js"></script>
</body>
</html>
''';

const restoDisplayScript = r'''(function () {
  'use strict';
  var CLE_JETON = 'sk_afficheur_jeton';
  var CLE_POSTES = 'sk_afficheur_postes';
  var CLE_RECUS = 'sk_afficheur_recus';
  var jeton = lire(CLE_JETON);
  var choix = lireListe(CLE_POSTES);
  var recus = lireListe(CLE_RECUS);
  var version = 0;
  var echecs = 0;
  var postes = [];
  var bons = [];
  var requete = null;
  var minuterie = null;
  var accuses = {};

  function lire(cle) { try { return window.localStorage.getItem(cle); } catch (e) { return null; } }
  function ecrire(cle, valeur) { try { if (valeur === null) { window.localStorage.removeItem(cle); } else { window.localStorage.setItem(cle, valeur); } } catch (e) {} }
  function lireListe(cle) { try { var v = JSON.parse(lire(cle) || '[]'); return v instanceof Array ? v : []; } catch (e) { return []; } }
  function el(tag, classe, texte) { var n = document.createElement(tag); if (classe) { n.className = classe; } if (texte !== undefined && texte !== null) { n.appendChild(document.createTextNode(String(texte))); } return n; }
  function $(id) { return document.getElementById(id); }
  function deux(n) { return (n < 10 ? '0' : '') + n; }

  function appel(methode, chemin, corps, fin, delai) {
    var x = new XMLHttpRequest();
    x.open(methode, chemin, true);
    x.timeout = delai || 15000;
    if (jeton) { x.setRequestHeader('Authorization', 'Bearer ' + jeton); }
    if (corps) { x.setRequestHeader('Content-Type', 'application/json'); }
    x.onload = function () { var d = null; try { d = JSON.parse(x.responseText); } catch (e) {} fin(x.status, d); };
    x.onerror = function () { fin(0, null); };
    x.ontimeout = function () { fin(0, null); };
    x.send(corps ? JSON.stringify(corps) : null);
    return x;
  }

  function formulaire(message) {
    $('postes').innerHTML = '';
    $('etat').textContent = 'Écran non relié';
    $('actualiser').style.display = 'none';
    var f = el('form');
    f.appendChild(el('h2', null, 'Relier cet écran à la caisse'));
    f.appendChild(el('p', 'aide', 'Sur la caisse maîtresse : Réglages › Afficheurs › Nouveau code. Saisissez-le ici une seule fois.'));
    var l1 = el('label', null, 'Code à 6 chiffres'); f.appendChild(l1);
    var code = el('input'); code.setAttribute('inputmode', 'numeric'); code.setAttribute('maxlength', '6'); code.setAttribute('autocomplete', 'off'); f.appendChild(code);
    var l2 = el('label', null, 'Nom de cet écran (facultatif)'); f.appendChild(l2);
    var nom = el('input'); nom.setAttribute('maxlength', '40'); nom.setAttribute('placeholder', 'Cuisine, Bar…'); f.appendChild(nom);
    var err = el('p', 'erreur', message || ''); f.appendChild(err);
    var b = el('button', 'action', 'Relier'); b.setAttribute('type', 'submit'); f.appendChild(b);
    f.onsubmit = function (ev) {
      ev.preventDefault();
      b.disabled = true; err.textContent = '';
      jeton = null;
      appel('POST', '/api/appairage', { code: code.value, nom: nom.value }, function (statut, d) {
        b.disabled = false;
        if (statut === 200 && d && d.jeton) {
          jeton = d.jeton; ecrire(CLE_JETON, jeton);
          $('actualiser').style.display = '';
          version = 0; demarrer();
        } else {
          err.textContent = (d && d.erreur) || 'Caisse injoignable : vérifiez l’adresse et le Wi-Fi.';
        }
      });
    };
    var c = $('contenu'); c.innerHTML = ''; c.appendChild(f);
    code.focus();
  }

  function demarrer() {
    if (minuterie) { clearTimeout(minuterie); minuterie = null; }
    if (requete) { requete.onload = requete.onerror = requete.ontimeout = null; try { requete.abort(); } catch (e) {} requete = null; }
    interroger();
  }

  function interroger() {
    var q = '/api/bons?postes=' + encodeURIComponent(choix.join(',')) + (version ? '&version=' + version : '');
    requete = appel('GET', q, null, function (statut, d) {
      requete = null;
      if (statut === 401) { jeton = null; ecrire(CLE_JETON, null); formulaire('Cet écran a été retiré par la caisse : reliez-le à nouveau.'); return; }
      if (statut === 200 && d) {
        echecs = 0;
        $('bandeau').className = '';
        var h = new Date();
        $('etat').textContent = (d.maitre ? 'Dernière synchronisation : ' : 'Cette caisse n’est plus la caisse maîtresse. Dernier contact : ') + deux(h.getHours()) + ':' + deux(h.getMinutes()) + ':' + deux(h.getSeconds());
        version = d.version;
        postes = d.postes || [];
        bons = d.bons || [];
        afficher();
        minuterie = setTimeout(interroger, 200);
      } else {
        echecs++;
        if (echecs >= 2) { $('bandeau').className = 'visible'; }
        version = 0;
        minuterie = setTimeout(interroger, 3000);
      }
    }, 30000);
  }

  function basculer(uuid) {
    var i = choix.indexOf(uuid);
    if (i >= 0) { choix.splice(i, 1); } else { choix.push(uuid); }
    ecrire(CLE_POSTES, JSON.stringify(choix));
    version = 0; demarrer();
  }

  function afficherPostes() {
    var p = $('postes'); p.innerHTML = '';
    for (var i = 0; i < postes.length; i++) {
      (function (s) {
        var b = el('button', 'poste' + (choix.length === 0 || choix.indexOf(s.uuid) >= 0 ? ' actif' : ''), s.nom);
        b.setAttribute('type', 'button');
        b.onclick = function () { basculer(s.uuid); };
        p.appendChild(b);
      })(postes[i]);
    }
  }

  function bip() {
    try {
      var A = window.AudioContext || window.webkitAudioContext; if (!A) { return; }
      var ctx = new A(); var o = ctx.createOscillator(); o.frequency.value = 880; o.connect(ctx.destination); o.start(); o.stop(ctx.currentTime + 0.25);
    } catch (e) {}
  }

  function afficher() {
    afficherPostes();
    var c = $('contenu'); c.innerHTML = '';
    var ordre = bons.slice().sort(function (a, b) { if (a.termine !== b.termine) { return a.termine ? 1 : -1; } return a.cree_le < b.cree_le ? -1 : (a.cree_le > b.cree_le ? 1 : 0); });
    if (ordre.length === 0) { c.appendChild(el('div', 'vide', postes.length ? 'Aucun bon en cours.' : 'Aucun poste avec écran n’est déclaré au back-office.')); }
    var grille = el('div', 'grille');
    var nouveaux = [];
    var aAccuser = [];
    for (var i = 0; i < ordre.length; i++) {
      var b = ordre[i];
      var nouveau = recus.indexOf(b.uuid) < 0;
      if (nouveau) { nouveaux.push(b.uuid); }
      if (!accuses[b.uuid]) { aAccuser.push(b.uuid); }
      grille.appendChild(carte(b, nouveau));
    }
    c.appendChild(grille);
    if (nouveaux.length) {
      recus = recus.concat(nouveaux);
      if (recus.length > 500) { recus = recus.slice(recus.length - 500); }
      ecrire(CLE_RECUS, JSON.stringify(recus));
      bip();
    }
    if (aAccuser.length) {
      appel('POST', '/api/accuse', { bons: aAccuser.slice(0, 200) }, function (statut) {
        if (statut === 200) { for (var j = 0; j < aAccuser.length; j++) { accuses[aAccuser[j]] = true; } }
      });
    }
  }

  function carte(b, nouveau) {
    var k = el('div', 'carte ' + b.titre + (b.termine ? ' termine' : '') + (nouveau ? ' nouveau' : ''));
    var t = el('div', 'tete');
    t.appendChild(el('span', 'numero', b.numero_jour));
    t.appendChild(el('span', 'heure', b.heure));
    k.appendChild(t);
    k.appendChild(el('div', 'titre', b.titre + ' · ' + b.poste));
    var lieu = [];
    if (b.table) { lieu.push('Table ' + b.table); }
    if (b.commande) { lieu.push('Commande ' + b.commande + (b.bon > 1 ? ' – bon ' + b.bon : '')); }
    if (lieu.length) { k.appendChild(el('div', 'lieu', lieu.join(' · '))); }
    var m = el('div', 'marques');
    if (b.deja_imprime) { m.appendChild(el('span', 'marque', 'Déjà imprimé')); }
    if (b.termine) { m.appendChild(el('span', 'marque', b.statut === 'served' ? 'Servi' : 'Prêt')); }
    if (m.childNodes.length) { k.appendChild(m); }
    var ul = el('ul');
    for (var i = 0; i < b.lignes.length; i++) {
      var l = b.lignes[i];
      var li = el('li', l.annule ? 'annule' : null);
      li.appendChild(el('span', 'qte', (l.annule ? '−' : '') + l.quantite + ' ×'));
      li.appendChild(document.createTextNode(l.libelle));
      if (l.commentaire) { li.appendChild(el('span', 'note', l.commentaire)); }
      ul.appendChild(li);
    }
    k.appendChild(ul);
    if (b.motif) { k.appendChild(el('div', 'motif', 'Annulé : ' + b.motif)); }
    if (!b.termine) {
      var bouton = el('button', 'pret', b.type === 'annulation' ? 'Pris en compte' : 'Prêt');
      bouton.setAttribute('type', 'button');
      bouton.onclick = function () {
        bouton.disabled = true;
        appel('POST', '/api/pret', { bon: b.uuid }, function (statut, d) {
          if (statut !== 200) { bouton.disabled = false; window.alert((d && d.erreur) || 'Caisse injoignable : réessayez.'); }
        });
      };
      k.appendChild(bouton);
    }
    return k;
  }

  $('actualiser').onclick = function () { version = 0; accuses = {}; demarrer(); };
  if (jeton) { demarrer(); } else { formulaire(); }
})();
''';
