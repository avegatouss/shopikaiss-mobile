# ShopiKaiss Terminal (Flutter)

Application mobile qui ouvre la caisse **ShopiKaiss** d'une boutique et la relie au matériel du terminal :
imprimante thermique intégrée, tiroir-caisse, bip et afficheur client (second écran).

Elle remplace, en multi-terminal, l'application Kotlin `android/shopikaiss-bridge` de shopikaiss-web. Elle
expose **le même contrat** `window.ShopiKaissNative`, donc **aucune modification du site n'est nécessaire**.

## Mise en service sur un terminal

1. Installer `ShopiKaiss-terminal.apk`.
2. Au premier lancement, saisir l'adresse de la boutique (par exemple `boutique.exemple.ci`). Sans chemin,
   l'application ouvre `/caisse`.
3. Vérifier le **terminal détecté** et l'**imprimante détectée**, puis imprimer le **ticket de test**.
4. Dans ShopiKaiss, aller dans *Réglages › Terminaux* et choisir l'imprimante « Imprimante intégrée par
   l'application ShopiKaiss Bridge » (mode `native-bridge`), avec la largeur 58 ou 80 mm. Les tickets partent
   alors directement sur l'imprimante, sans boîte de dialogue.
5. Pour revenir aux réglages depuis la caisse : **5 touchers en 3 s dans le coin haut gauche**. Un code
   d'accès peut être demandé (facultatif).

## Caisse hors ligne (branche `hors-ligne/caisse-mobile-2026-10-18`)

Appairée à son terminal (code généré dans ShopiKaiss, Paramètres › Caisse hors ligne), l'application continue de vendre
quand la boutique ne répond plus : dernier catalogue reçu, PIN du caissier, ticket `HL-<terminal>-<séquence>`, ventes
gardées en SQLite et envoyées au retour de la connexion, où chacune devient une vente ordinaire. Plusieurs terminaux d'une
même boutique vendent hors ligne indépendamment. Détails, tests et recette : [docs/CAISSE-HORS-LIGNE.md](docs/CAISSE-HORS-LIGNE.md).

## Adaptation au terminal

| Terminal | Pilote choisi en « Automatique » |
|---|---|
| SUNMI (V2, V2s, P2, T2, D2, K2…) | service `woyou.aidlservice.jiuiv5` via `com.sunmi:printerlibrary` |
| Imprimante interne USB (iMin, Rockchip…) | USB classe 7, endpoint bulk (permission Android au premier envoi) |
| Imprimante virtuelle Bluetooth « InnerPrinter » | Bluetooth SPP |
| Port série `/dev/ttyS*` (ST-T40, Telpo…) | réglage **manuel** uniquement (chemin et débit) |
| Téléphone ou tablette sans imprimante | « Aucune » : les documents passent par l'impression Android |

La largeur du rouleau est lue sur l'imprimante quand le pilote le permet (SUNMI). Sinon, elle se règle à la
main (58 ou 80 mm).

## Ce qui est imprimé, et par où

| Origine dans la caisse | Traitement |
|---|---|
| `ShopiKaissPrinter` (ticket ESC/POS de `escpos-ticket.js`, mode `native-bridge`) | octets envoyés tels quels à l'imprimante intégrée |
| `window.print()` d'un ticket HTML (`[data-paper-width]` : fin de vente, page ticket, ticket test…) | rendu PDF, rastérisation à la largeur du rouleau, puis ESC/POS `GS v 0` vers l'imprimante intégrée |
| `window.print()` d'un document A4 (facture, devis, rapports, étiquettes…) | boîte d'impression Android (imprimante réseau, « Enregistrer en PDF ») |
| Tiroir, état, bip | `openDrawer`, `getPrinterStatus`, `beep` du contrat |
| Afficheur client (`native-presentation`) | `Presentation` Android sur le second écran |

### Tickets HTML (X, Z…) : mémoire bornée

Les documents imprimés par `window.print()` au format ticket (X et Z de la caisse) sont rendus en image puis envoyés en
ESC/POS. Jusqu'à la 1.1.2, la page faisait toujours 1,20 m de haut à deux fois la résolution de la tête : environ 80 Mo
d'image, et Android fermait l'application faute de mémoire. Depuis la 1.1.3, la page prend la hauteur réelle mesurée par
la caisse et chaque page rastérisée reste sous 6 millions de pixels (`ticketRasterPlan`) ; la conversion noir et blanc
se fait hors du fil de l'écran. Les documents A4 demandés par la page elle-même (Z journalier, rapports) passent par le
service d'impression natif d'Android sur la vue affichée. Réglages › Diagnostic montre la dernière panne native et les
erreurs récentes (à copier pour l'assistance).

### Version 1.1.4 : rapidité, impression directe, afficheur

- **Rendu rapide** (Réglages › Affichage, actif par défaut) : la vue web est composée par texture au lieu de la
  composition hybride d'Android, qui faisait passer chaque image de la page par le fil principal (2 à 5 s par toucher dans
  la fenêtre de paiement). La vue web n'est plus reconstruite par l'écran Flutter ; le catalogue hors ligne est décodé hors
  du fil de l'écran.
- **Imprimante de l'application prioritaire** (Réglages › Imprimante, actif par défaut) : si le profil du terminal
  (ShopiKaiss › Terminaux) indique l'impression du navigateur ou un transport web, l'application le ramène à
  `native-bridge` : les tickets partent en ESC/POS sur l'imprimante intégrée, plus en image HTML. Le réseau (9100) est
  respecté.
- **X et Z en miniature** (1.1.3) : la règle `@page` du ticket (297 mm) dépassait la page de rendu et le moteur réduisait
  tout le ticket. La taille de page du rendu est désormais imposée au document (`withPageSize`).
- **Afficheur client** : le lien envoyé par la caisse (jeton frais) prime sur le lien imposé dans les réglages, dont le
  jeton expire (12 h par défaut) — d'où les 404 du lendemain ; une erreur de la page de l'afficheur est détectée et le lien
  frais rouvert ; bouton « Afficheur » en bas à gauche de la caisse pour le rafraîchir.

## Architecture

```
lib/
  main.dart                       premier lancement → réglages, sinon caisse
  src/web/bridge_script.dart      JS injecté : window.ShopiKaissNative + interception de window.print()
  src/web/caisse_page.dart        WebView (flutter_inappwebview), confinée à l'origine de la boutique
  src/printer/html_printer.dart   ticket HTML → raster ESC/POS ; A4 → impression système
  src/printer/escpos.dart         ticket de test, bitmap 1 bit, GS v 0
  src/terminal/                   canal natif, session (réglages + pilote actif)
  src/settings/settings_page.dart configuration et tests matériel
android/app/src/main/kotlin/ci/khoga/shopikaiss/terminal/
  TerminalPlugin.kt               canal ci.khoga.shopikaiss/terminal
  printer/                        pilotes SUNMI, USB, Bluetooth, série (USB et série repris du Bridge)
  display/                        afficheur client (Presentation)
```

Le pont Flutter est asynchrone. `callNative()` (`ticket-printer.js`) adopte la Promise renvoyée, et chaque
`{ok:false}` devient un rejet qui porte `code` et `permanent`, comme avec le pont Kotlin.
`showCustomerDisplay` reste synchrone, car `caisse-afficheur-client.blade.php` en lit le retour avec
`JSON.parse`.

Le pont ne répond qu'aux pages de l'origine configurée (`origin_not_allowed` sinon). Les liens vers une autre
origine s'ouvrent dans le navigateur du système.

## Compiler

Prérequis sur ce poste : Flutter (`C:\dev\flutter`), SDK Android (`C:\dev\android-sdk`), JDK 21
(`C:\Program Files\Android\openjdk\jdk-21.0.8`).

```bash
export JAVA_HOME="/c/Program Files/Android/openjdk/jdk-21.0.8" PATH="/c/dev/flutter/bin:$PATH"
flutter test
flutter build apk --release
```

L'APK est produit dans `build/app/outputs/flutter-apk/app-release.apk`.

Signature : `android/key.properties` et `android/shopikaiss-release.jks` ne sont pas versionnés. **Il faut
les sauvegarder**, car sans cette clé on ne peut plus publier de mise à jour installable par-dessus les APK
déjà déployés. En leur absence, le build utilise la clé de debug.

## iOS (plus tard)

La partie Dart (caisse, pont, tickets HTML) est commune. Pour iOS, il restera à écrire :

- l'implémentation native du canal `ci.khoga.shopikaiss/terminal`, aujourd'hui Android seulement. Sans
  elle, les impressions passent par AirPrint ;
- un pilote Bluetooth LE ou réseau pour les imprimantes ESC/POS. iOS n'a ni SPP ni USB hôte ;
- la compilation sur un Mac avec Xcode et un compte Apple Developer.
