## Suite sur B f5247a4 : actions panier

Base commune avancée sans conflit vers B `f5247a4` (contrat 2.0.1). Son essai v2 réel est décrit dans SESSION-B ; C ne l'a pas rejoué. B conserve le raccordement v2 de l'hôte, sans changement prévu du protocole local. La synchronisation v1 reste celle de l'application de recette actuelle.

C ajoute uniquement l'interface panier : clic sur une ligne pour saisir sa quantité, transmise telle quelle à changeQuantity pour validation/calcul par le moteur ; vider le panier avec confirmation explicite via clear. Aucun calcul financier côté Windows. Annuler le dialogue n'écrit rien ; une vente incertaine interdit ces actions, y compris si son état change pendant le dialogue grâce au contrôle du contrôleur.

Analyse Windows sans anomalie et 39 tests Windows réussis, dont deux nouveaux tests d'interface sur quantité, confirmation et blocage pendant un encaissement incertain. Aucun fichier moteur/API/Android modifié. Pas de nouveau ZIP dans ce lot : le paquet précédent demeure au code 3ce238f. Main et production inchangées. Le correctif MySQL signalé par B reste à coordonner avec A séparément de la caisse autonome.

## Remise précédente : bootstrap et journal durable

Voir [RACCORDEMENT-HOTE-C.md](RACCORDEMENT-HOTE-C.md) pour la suite sur B `0c39b40` : lancement de l'hôte, appairage/PIN, journal d'intention et 190 tests réussis. Les états ci-dessous sont historiques.

## État actuel — raccordement B du 29 octobre 2026

Cette section remplace les états d'attente historiques ci-dessous.

Branche de remise : `feat/caisse-windows-raccordement`, worktree `C:/laragon/www/_wt/windows-engine-integration`. Fusion `276c76e` de C `2204e54` et B `1a178ef`, sans conflit. Aucun push, modification de main, serveur ou base de production.

- `BEngineAdapter` raccorde le vrai `LocalRegisterAdapter` au protocole C. Ajout des commandes pair, login, addProduct et clear. Les identifiants de consultation/réimpression sont transmis au troisième paramètre attendu par B ; deux identifiants contradictoires sont refusés. Une erreur B certaine conserve sa preuve ; les autres restent de résultat inconnu.
- Le catalogue utilise addProduct. Le dialogue de paiement propose les moyens fournis par le moteur et demande setPayment avant validation. Aucun calcul de total Windows ; paiement exact et unique à ce stade.
- Une reconnexion accepte la révision du nouveau processus, qui repart de zéro. Le panier reste bloqué si une vente est incertaine. Seul not_found définitif pour le même UUID autorise sa reprise, après lecture locale sérialisée par B.
- Trois tests passent par les trames IPC, le vrai adaptateur B et une vraie base SQLite : panier et paiement restaurés ; réponse d'encaissement perdue puis base rouverte, vente retrouvée et rejeu sans doublon ; refus certain et consultation locale sans appel réseau. Le transport HTTP est simulé et ce raccordement utilise un hôte en mémoire, pas encore l'exécutable moteur.
- Vérifications : analyse Windows sans anomalie, 30/30 tests Windows ; suite fusionnée `flutter test --no-pub --exclude-tags integration` : 167 tests réussis. Les tests contre le serveur réel sont exclus volontairement. Aucun changement de pubspec/lock ni de code métier B.

### Remise à B

Intégrer la branche complète `feat/caisse-windows-raccordement` dans la branche B (elle contient les précédents commits Windows et a déjà B 1a178ef dans ses ancêtres). Ne pas reprendre uniquement le dernier commit si les fichiers Windows antérieurs sont absents. B assemble ensuite l'hôte exécutable avec BEngineAdapter, initialise SQLite FFI dans LocalAppData, appelle start() avant d'accepter les commandes et ferme proprement adaptateur/base à la sortie. Un seul hôte doit posséder la base, y compris entre sessions Windows. Conserver RegisterCashierPlugins ; ne pas réintroduire l'enregistrement WebView non qualifié.

### Portes encore ouvertes

Le point d'entrée distribué reste fermé aux ventes : pas de nouvel exécutable raccordé produit ici. Restent l'assemblage et le bootstrap réel, écrans appairage/PIN, persistance de l'UUID incertain avant envoi et récupération après redémarrage complet de l'interface, validation Android et Windows sur le commit intégré, recette serveur isolé et matériel. Le test de reprise livré conserve le contrôleur UI pendant la réouverture de la base : il ne prouve pas encore la reprise après arrêt complet de l'interface. Ne pas confondre panier durable B et journal durable de l'intention Windows.

Restent aussi les fonctions non exposées (rendu monnaie, remises, paiements multiples, ouverture hors ligne Windows selon capacités B), impression/spouleur et distribution signée. Le ZIP de revue antérieur reste sans moteur raccordé ; aucun pilote production autorisé par ces tests. Les résultats et demandes d'accord de A sont hors de cette livraison C.

---
# Session C — Windows

Base : `c5f9483`. Branche : `feat/caisse-autonome-windows`.
Worktree : `C:/laragon/www/shopikaiss-windows` ; checkout mobile laissé intact.
Spécification : commit serveur `2221327e`, confirmé dans le worktree de la session A.

## Demandes à B (intégration en attente)

- C-REQ-001 : fournir interface/version du moteur partagé et adaptateur des commandes de caisse vers `WindowsEngineAdapter`. Le transport privé proposé est dans `lib/src/windows/ipc/`. Ne pas confondre sa version 1 avec le protocole réseau v2. Proposition à valider avec B, pas contrat métier imposé.
- C-REQ-002 : fournir un hôte exécutable qui possède le stockage et utilise `WindowsHostServer` sur stdin/stdout privés ; logs sur stderr expurgé. Aucun faux moteur en release. Une commande réseau est planifiée, jamais attendue dans la file des mutations locales. Le processus termine les commandes acceptées avant fermeture sur EOF.
- C-REQ-003 : intégrer l’entrypoint Windows dédié ou le routage commun et les dépendances Windows requises après audit des plugins. C ne modifie pas pubspec ni Android. Stockage/migrations/gestion durable UUID et brouillons restent à B.
- C-REQ-004 : définir et tester la vue d’écran (catalogue/panier/paiement/statut) et le rapprochement `saleStatus` après résultat inconnu. Le moteur doit interdire le réencaissement d’un brouillon consommé même après redémarrage UI.

## Environnement

Flutter 3.47.7 / Dart 3.13.5. Visual Studio 2026 et les composants requis sont maintenant installés (voir ci-dessous). Les premiers essais avaient identifié CMake, SDK Windows et autorisation des symlinks manquants. Aucun changement de signature Android effectué.

### Mise à jour après autorisation d’installation

Le 29 octobre 2026, installation autorisée et validation UAC effectuée : composants C++ Desktop, MSVC, CMake et SDK 10.0.26100 installés via Visual Studio Installer (code final 0). Mode développeur activé pour les symlinks. Flutter ajouté au PATH utilisateur. `flutter doctor -v` ne signale plus aucun problème.

NuGet CLI 7.9.0.83 ajouté dans `C:/dev/nuget` et au PATH utilisateur, téléchargé depuis dist.nuget.org avec signature Authenticode valide. Les versions pubspec/lock restent inchangées. `flutter pub get` réussit et génère les fichiers de plugins Windows. Redémarrer les terminaux ouverts pour récupérer le nouveau PATH.

La compilation de contrôle a été relancée après installation de NuGet. Ces installations lèvent les prérequis machine ; elles ne lèvent pas les limites fonctionnelles et portes de production ci-dessous. Aucun redémarrage automatique ni changement de clé Android effectué.

## Premier lot remis

- Cible Flutter Windows isolée, entrypoint `lib/src/windows/main_windows.dart`, sans modification Android/pubspec/moteur.
- Transport privé stdin/stdout, limites de taille/version, délais bornés, sérialisation hôte et résultat inconnu après rupture. Pas de replay automatique d’encaissement. Tests avec vrai sous-processus local.
- Interface catalogue/panier et dialogue de paiement sur une projection du moteur ; aucun calcul fiscal dupliqué. Révisions anciennes ignorées et blocage du réencaissement après résultat inconnu.
- Adaptateur d’impression TCP sur réseau local, sans nouvelle vente ni impulsion ajoutée ; testé contre serveur TCP local, pas imprimante physique.
- Code natif chemin LocalAppData, protection DPAPI utilisateur et mono-instance UI ; protection et verrou vérifiés par CTest, recette du canal dans l'application installée restante.
- Scripts de test et de build de revue. Le bootstrap par défaut affiche la configuration manquante et n’autorise aucun encaissement. Aucun faux moteur en release.

Proposition de raccordement détaillée : [CONTRAT-ADAPTATEUR-WINDOWS.md](CONTRAT-ADAPTATEUR-WINDOWS.md). Les quatre demandes à B restent ouvertes. Les modifications en cours de B ont été vues dans son checkout ; elles n’ont été ni copiées ni modifiées.

## Vérifications exécutées

- `dart analyze lib/src/windows test/windows` : aucune anomalie.
- `flutter test --no-pub test/windows` : **13 tests réussis**, dont transport sous-processus, réponse perdue, timeout, encaissement incertain, état ancien et dispositions 1280×800 / 800×600.
- Un blocage de fermeture des pipes Windows a été découvert puis corrigé : EOF est envoyé avant d’attendre l’arrêt, les sorties continuent d’être drainées. Suite repassée après correction.
- Aucun diff sur `lib/src/offline`, Android, pubspec/lock et options d’analyse dans le worktree Windows. Aucune opération serveur/production exécutée.
- Première tentative de build release dédié (avant installation) : échec sur les symlinks et prérequis CMake/SDK. Ces prérequis sont maintenant résolus. Ne pas interpréter les tests Flutter comme une compilation complète de l'application réussie.

Le script de test a été exécuté via `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tool/windows/Test-Windows.ps1 -FlutterRoot C:/dev/flutter` : exception limitée au processus, sans modification de la politique globale de la machine.

## Reste à livrer avant toute production

1. Contrat B accepté et adaptateur/hôte réel, bootstrap, persistance des brouillons/résultats incertains et preuve d’idempotence après redémarrage.
2. Raccordement du superviseur de transport testé (voir lot ci-dessous), vie en arrière-plan et intégration de l’activation ; aucune de ces capacités n’est simulée dans le point d’entrée actuel.
3. Édition complète quantité/remises/moyens de paiement, PIN/appairage et historique selon le modèle de B. L’écran initial n’est pas une caisse complète.
4. Finaliser la compilation Flutter/C++ et la recette de l'application installée. Outillage installé ; tests natifs DPAPI/mono-instance réussis le 29 octobre (voir mise à jour ci-dessous).
5. Spouleur/USB, périphériques clients, gestion des jobs, installateur signé et mises à jour. Aucun installateur prêt à distribuer à ce stade.
6. Validation du commit intégré par B sur Android et Windows, scénario serveur réel isolé et portes P0–P8 applicables.

P0 : périmètre isolé vérifié ; P3 : preuves partielles transport/UI seulement ; P5/P6/P8 : non satisfaites. **Livraison production bloquée**. Aucun push main, déploiement, changement de signature, migration ou base client touchés.

## Point de coordination et vérification native — 29 octobre 2026

Lecture directe des worktrees, sans modification des périmètres A/B :

- A : `feat/caisse-autonome-serveur` à `bc30a87e`. Réponse tardive >15 s désormais testée en navigateur (WEB-03). Protection étendue au paiement restaurant, délai limité aux composants caisse/restaurant. Profil paiement : 140–230 ms localement et environ 120 Ko par frappe ; optimisation encore ouverte. L1 et ses fixtures non livrés.
- B : HEAD `c5f9483`, incrément de stockage schéma 2 encore non commité. Son suivi annonce 47 tests réussis (non réexécutés par C). Renvoi automatique des ventes à arbitrer retiré après le test A : il peut relancer leur intégration. B-REQ-004 demande une consultation sans effet de bord. Brouillon durable et extraction du moteur partagé encore dans les prochaines étapes.
- Les sept améliorations transmises précédemment restent des propositions. Aucun basculement du plan vers un pilote v1 permanent décidé ici.

Travail C effectué :

- Extraction de la protection DPAPI dans un composant C++ utilisé par le canal Flutter et par les tests natifs. Correction de la limite : un secret de 64 Kio produit une enveloppe supérieure à 64 Kio, qui doit pouvoir être déchiffrée. Limites distinctes, rejet des enveloppes altérées, effacement du tampon de sortie précédent.
- Verrou mono-instance non copiable ; acquisitions répétées refusées sans fuite de handle ; un échec sur une instance existante ferme son handle immédiatement.
- `tool/windows/Test-Native.ps1` compile le vrai code C++ avec MSVC et exécute CTest : aller-retour DPAPI binaire et 64 Kio, rejet altération/vide/dépassement, deuxième processus refusé, acquisition possible après fermeture du propriétaire. **1/1 scénario natif réussi**, assertions actives en Release. Aucun secret réel utilisé. Ne prouve ni le fonctionnement entre comptes Windows ni la protection d'une sauvegarde portable.
- Analyse Dart sans anomalie et **13/13 tests Windows réussis à nouveau**.
- La compilation Flutter a révélé STL1011 dans les plugins WebView et permissions épinglés, qui utilisent les coroutines expérimentales. Option de compatibilité MSVC explicitement limitée à ces deux plugins dans `windows/CMakeLists.txt`, sans changement pubspec/lock ni modification de source tierce. Remplacement à prévoir lors de leur mise à niveau par B.

Le contrat d'adaptateur précise désormais que `saleStatus` ne doit jamais soumettre à nouveau une vente réseau pour en connaître l'état. Les quatre demandes C à B restent ouvertes ; ne pas fabriquer de moteur release en attendant.

### Compilation Release et démarrage : réussis

`Build-Integration.ps1` termine avec code 0 et produit `build/windows/x64/runner/Release/shopikaiss_terminal.exe`, accompagné de ses bibliothèques et données. Le dossier contient `integration-only.json` avec `production_ready:false`, SHA-256 et état Git au build. Il faut conserver le dossier complet ; ce n'est pas un installateur signé et le moteur de vente n'est toujours pas raccordé.

Le premier contrôle de fermeture a découvert un plantage réel `0xc0000602` dans `coremessaging.dll`. Le plugin WebView épinglé crée une DispatcherQueue à son enregistrement, même sans aucune WebView. Le runner de la caisse native utilise maintenant `RegisterCashierPlugins` : permissions, impression et liens externes seulement. Après retrait de l'enregistrement WebView, recompilation réussie et fermeture normale code 0. Le fichier généré et les dépendances partagées sont conservés, sans modification Android. Une future utilisation de WebView sur Windows devra faire l'objet d'une qualification de son cycle de vie ; ne pas lancer l'ancien point d'entrée WebView avec ce runner.

`tool/windows/Test-Launch.ps1` : **PASS**, fenêtre native du processus créée, processus stable pendant l'essai, fermeture par WM_CLOSE et code de sortie 0. Essai masqué, ne prétend pas valider le rendu visuel, les imprimantes ou les ventes. Le contrôle utilise EnumWindows : `MainWindowHandle` ignore les fenêtres masquées et n'était pas une preuve suffisante. Les essais n'ont utilisé ni identifiants ni données client.

État final de ce lot : 13 tests Flutter Windows réussis, analyse Dart propre, scénario CTest natif réussi, compilation Release et contrôle de démarrage/fermeture réussis. Restent le raccordement au moteur B, les fonctionnalités métier, la supervision, les périphériques et la distribution signée. Aucune recette de vente de bout en bout et aucune livraison production.

## Reprise après remise du contrat A — 29 octobre 2026

Vérification des worktrees : A est à `67defc62` ; contrat L1 remis dans `71953e43`, B-REQ-002 et B-REQ-004 implémentés pour le palier v1, environnement d'intégration isolé documenté sur 127.0.0.1:8130. Les routes v2 (L2) ne sont pas encore implémentées. L'attente du contrat A est levée ; le palier v1 est désormais retenu côté coordination.

B reste au HEAD `c5f9483`, avec ses incréments v1 et les primitives v2 non commités. Son suivi annonce 128 tests réussis (non réexécutés par C). La livraison du moteur partagé et les brouillons durables restent dans ses prochaines étapes. C n'a ni copié ni modifié ces fichiers ; la canonicalisation et le validateur ne sont pas réimplémentés côté Windows. Prochaine remise attendue : SHA intégrables du moteur/adaptateur et réponse C-REQ-001 à 004, puis recette commune.

Travail indépendant effectué côté C : correction d'un blocage IPC réel. Une réponse d'erreur dont `code` ou `message` avait un type invalide provoquait une exception après retrait de la promesse de la liste des appels en attente ; ni la déconnexion ni le délai maximal ne pouvaient ensuite terminer cet appel. Les champs d'erreur sont maintenant validés avant conversion ; une réponse invalide termine l'appel, déconnecte le transport et conserve un résultat d'encaissement inconnu, même si elle prétend `not_committed:true`.

Trois tests avec véritable sous-processus couvrent code invalide, message invalide et preuve `not_committed` invalide. Ils vérifient la fin bornée de l'appel, le résultat inconnu et le refus de nouveaux appels sur le transport déconnecté. **16 tests Windows réussis**, analyse Dart sans anomalie. Aucun code moteur mobile, dépendance partagée, API serveur ou fichier Android modifié. Le build Release de revue précédemment produit n'a pas été renouvelé pour ce lot de transport ; il reste sans moteur de vente raccordé.

## Lots indépendants : supervision et paquet de revue — 29 octobre 2026

À la nouvelle vérification, B reste au HEAD `c5f9483`, moteur partagé non livré. Travail effectué uniquement dans le périmètre Windows :

- `SupervisedWindowsHost` : connexion/reconnexion explicite, un seul lancement pour les demandes concurrentes, attente de la sortie de l'ancien moteur avant remplacement, aucune commande rejouée. Une fermeture concurrente à un démarrage récupère puis ferme le processus créé. Le superviseur est prêt au raccordement, pas activé avec un faux moteur dans l'application. La vue et la reprise durable restent à B ; pas de heartbeat, service ou zone de notification livrés.
- Correction de `ProcessWindowsHost.close()` : après un timeout, la vraie promesse d'arrêt est conservée. Une seconde fermeture ne peut plus annoncer un succès alors que le processus reste vivant. Aucun arrêt forcé pendant une éventuelle écriture métier.
- Tests : quatre scénarios de superviseur (connexions concurrentes, arrêt bloqué, vente incertaine sans rejeu, nouvelle tentative de fermeture) et un vrai sous-processus dont l'arrêt attend sept secondes. **21 tests Windows réussis**, analyse Dart sans anomalie.
- `Package-Review.ps1`, `Verify-Package.ps1`, `Test-Package.ps1` : ZIP du dossier Release complet, manifeste des empreintes, contrôle après réextraction. Les tests vérifient paquet valide et refus de fichier altéré, fichier ajouté et chemin sortant. L'empreinte n'est pas une signature d'éditeur. Aucun installateur ni mécanisme de mise à jour automatique livré.
- Compilation Release renouvelée : réussie. `Test-Launch.ps1` : fenêtre native créée, stabilité durant l'essai masqué, fermeture normale code 0.

Artefact produit : `dist/windows-review/shopikaiss-windows-review-9b50bf75bff84223bcf4e2dec34c35f7.zip` et fichier `.sha256`. **24 fichiers contrôlés** avant compression et après réextraction. Le manifeste garde le commit et l'état modifié réels au moment du build ; ne pas le présenter comme un build de production signé ou comme une caisse raccordée. Les ventes restent désactivées. Aucune modification des projets A/B, d'Android ou des dépendances communes, aucun push main ni déploiement.

## Retour C à B : compatibilité de `f61da3e`

À la demande de B, essai isolé de `79bce79` (C) + `f61da3e` (B) dans le worktree détaché `C:/laragon/www/_wt/windows-b-compat-f61da3e`. Fusion sans conflit, avec `--no-commit --no-ff` ; aucun commit de fusion, aucun cherry-pick dans la branche C. Les commits `a4cce08` et `51e106f` ne font pas partie de cet essai.

`flutter pub get --enforce-lockfile` réussit sans changement de version ; les fichiers de plugins Windows restent inchangés. Flutter a ajouté une exclusion à `analysis_options.yaml` dans ce worktree ; cette seule modification automatique a été retirée après l'essai.

`Test-Windows.ps1 -FlutterRoot C:/dev/flutter` sur la combinaison : **analyse sans anomalie, 21/21 tests Windows réussis**, incluant les 16 tests annoncés auparavant et les cinq tests de supervision/arrêt supplémentaires. Le chemin de chargement des tests est bien celui du worktree isolé. Ces tests valident la compatibilité de la suite C, pas un encaissement raccordé au moteur B ni une compilation native de la combinaison.

Réponse à B : compatibilité confirmée sur ce périmètre. L'intégration réelle reste suspendue à ton prochain commit C-REQ-001 à 004 (adaptateur, vue schéma 1, operation_id durable/idempotent, lecture locale sérialisée de saleStatus, panier durable). Aucun contournement ou duplication de ton moteur. Le worktree de recette reste disponible pour inspection ; la branche Windows conserve ses seuls commits C.

## Liaison écran / superviseur — 29 octobre 2026

B est encore à `51e106f` avec moteur/modèles/stockage en modification non commitée pour sa prochaine remise. Son suivi indique la recette serveur v1 réussie ; l'adaptateur C n'est pas livré. Ces modifications n'ont pas été intégrées.

Travail indépendant C : le contrôleur d'écran traite désormais `connected` en rechargeant sa vue, et invalide toute lecture en vol lors de `disconnected`, d'une erreur ou de la fermeture du flux d'événements. Une réponse de vue reçue après la déconnexion ne peut plus rétablir `ready` et autoriser le paiement. Le résultat incertain et son UUID sont conservés lors d'une reconnexion ; celle-ci n'appelle jamais `commitSale`. L'indicateur d'état n'affiche plus l'ancien libellé de synchronisation quand le moteur est indisponible.

Trois tests ajoutés : réponse de vue tardive après coupure, reconnexion avec vente incertaine et fermeture du flux. **24/24 tests Windows réussis**, analyse sans anomalie ; tests d'écran également revérifiés après ajustement du libellé. Ce lot ne remplace pas le journal durable de B et ne valide pas la reprise après redémarrage complet de l'application. Pas de nouveau paquet Release pour ce lot, aucun push ni déploiement ; le ZIP précédemment remis reste un artefact de revue antérieur.

## Parité demandée avec la caisse web — 29/10

Le périmètre cible est maintenant la caisse web complète, avec les mêmes parcours et droits. Référence de travail, écarts et demande C-REQ-005 à B : [PARITE-CAISSE-WEB-WINDOWS.md](PARITE-CAISSE-WEB-WINDOWS.md). Les fonctions absentes restent des travaux requis, pas des exclusions acceptées.

Lot 718ec0e : grille 58/42, présentations visuelle/compacte, scan F2 séparé de la recherche, choix du conditionnement, saisie espèces reçues et monnaie calculée par le moteur. Analyse propre, 45/45 tests Windows réussis. Release compilée et installée dans `%LOCALAPPDATA%/Programs/Shopikaiss-Recette/718ec0eb905c`, raccourci mis à jour ; données intactes, pas de fermeture imposée à la fenêtre actuelle. Comparaison visuelle native non effectuée, parité complète non acquise. B reste à cb10844 ; hôte v2 et commandes métier enrichies attendus. Aucun push, aucune modification main, aucune vente démo supplémentaire.

## Identité visuelle et pied de panier — 29/10

Six PNG fournis par le responsable conservés sans modification sous assets/branding/shopikaiss (empreintes comparées aux originaux). Logo horizontal or/noir sur fond clair et or sur noir en thème sombre, utilisé à la connexion, dans l'en-tête et sur l'écran non configuré. Icône Windows ICO dérivée du fichier 04, six tailles 16 à 256 px ; aucun changement du dessin original. pubspec.yaml ne change que l'enregistrement des ressources, aucune dépendance/version modifiée ; ces ressources seront également embarquées si B reprend ce manifeste pour Android.

Pied du panier rapproché du web : libellé À payer et actions Vider le panier / Payer (F4) côte à côte. 45/45 tests Windows réussis, analyse sans anomalie. Rendu natif côte à côte non validé ; la parité complète reste ouverte.

## Raccordement v2 — 29/10

B 9b0a5dd et 83fd64e intégrés par fusion c36df32, sans conflit. Hôte reconstruit sur V2Engine (contrat 2.0.2) ; interface privée inchangée sauf ajout des commandes openSession/logout déjà fournies par B. Bootstrap : connexion puis ouverture locale selon capacités serveur, fond de caisse validé par le moteur ; sortie vers la connexion déconnecte réellement le caissier. Totaux HT/TVA affichés depuis les libellés moteur.

Validation : analyse Windows sans anomalie, 45 tests Windows et 24 tests client/moteur v2 passent. Test de trames enrichi : logout interdit le paiement et conserve le même panier, repris après redémarrage. Exécutable moteur v2 reconstruit avant la suite, aucun test de cette passe sur l'ancien binaire v1.

Protection complémentaire : présence du journal v1 pending-sale.json bloque le démarrage v2 sans le modifier ; utiliser l'ancienne version pour résoudre cet encaissement. Le journal v2 est pending-sale-v2.json, dans le même dossier de données. Analyse ciblée finale propre. La base existante est conservée, aucune suppression ni réappairage automatique. Un nouvel appairage v2 et la recette réelle sur Tablette Pâtisserie restent nécessaires ; le succès sur Caisse 2 de B n'est pas une preuve de cette interface installée.

## Fenêtre réellement affichée — 29/10

L'utilisateur signalait une interface inchangée : processus encore ouvert depuis ddf3a746fcff, malgré les raccourcis mis à jour. Contrôle accessibilité : panier vide, état À jour, ancien libellé Encaisser · F4. Fermeture normale puis lancement effectif de bf4f3f91007c : logo présent, écran appairage v2. Capture native toujours indisponible (timeout) ; aucune validation visuelle de parité annoncée. Sauvegarde à froid après arrêt du nouveau moteur dans LocalAppData/ShopiKaiss/sauvegarde-bascule-v2-20261029-215201, puis réouverture de la version v2. Demande à A déposée dans la présentation partagée pour l'appairage Tablette Pâtisserie.

## Boîte à lettres et lot 2 B — 29/10

INBOX-C.md et PROTOCOLE.md lus. e075296 fusionné (12f68dc) après sauvegarde du lot de densité visuelle cf0baed. Résolution du doublon de clé assets introduit par la fusion automatique du manifeste ; les deux jeux de ressources sont conservés, aucune version de dépendance changée. Icône Windows régénérée en six tailles depuis marque/hd/embleme-1050-transparent.png, source HD copiée dans les ressources.

Commandes IPC ajoutées : setLineDiscount, suspendDraft, drafts, resumeDraft, deleteDraft, setPayments ; logout/openSession déjà raccordées. search.category reste un argument de search, pas une commande distincte. Interface : catégories sous le scan/recherche, remise par ligne selon capacités, mise en attente F8 et liste/reprise des paniers locaux. Prix et totaux restent calculés par B. Après refus d'un paiement, relecture de la vue autoritaire et remise à zéro du rendu de monnaie. Les paiements multiples ne sont pas proposés dans l'interface tant que la politique/contrat ne les ouvre pas. Suppression de panier disponible dans le protocole, pas de bouton de suppression ajouté dans ce lot.

46 tests Windows réussis ; analyse finale sans anomalie. Aperçu généré par Flutter à 1366×768 avec données fictives, inspecté : catalogue à gauche, panier à droite, lignes et outils compacts, actions de fin de vente fixées en bas. Ce rendu de test ne remplace pas la recette native sur le poste.

Appairage réel v2 effectué avec l'hôte installé bf4f3f9, Tablette Pâtisserie / Plateau : prêt, session déjà ouverte reprise de l'instantané, Caissier Démo identifié, panier vide, fermeture code 0. Aucune nouvelle session ni vente créée pendant ce contrôle ; aucune donnée secrète consignée. Résultat transmis dans JOURNAL.md.

## Réglages écran et validation automatique du paiement

Panneau local : catalogue liste/grille, largeur des fiches, proportion catalogue/panier. Préférences dans LocalAppData/ShopiKaiss/screen-settings.json ; une erreur de préférences ne bloque pas la caisse. Le changement ne touche ni prix, ni droits, ni taxes.

Montant reçu : validation moteur automatique après 250 ms de pause, collage compris ; Entrée force la validation. Toute modification invalide immédiatement la confirmation. Une réponse antérieure à la dernière saisie ne la réactive pas. Aucun calcul monétaire ajouté dans Windows, aucun encaissement automatique.

47 tests Windows passent et analyse sans remarque, dont le cas réponse montant tardive suivi d’une nouvelle saisie. Images : cadrage et demande A/B dans IMAGES-PRODUITS.md ; service non raccordé tant que manifeste/cache ne sont pas fournis.

## Couleurs, disposition des photos et options de vente préparées

Quatre palettes locales : vert, bleu, prune, terracotta. Emplacements images à gauche, au-dessus ou masqués, avec préférence entière/recadrée mémorisée pour les futures photos locales. Le cache image reste à raccorder ; pictogrammes seulement actuellement.

Aperçu séparé client/remise globale/frais/note : champs inactifs, aucune mutation de panier simulée. Besoins moteur dans CLIENT-REMISES-FRAIS.md, envoyés à A/B au journal partagé. Les remises de ligne existantes restent raccordées.

Validation : 47 tests Windows passent, analyse sans remarque, rendu Flutter fictif inspecté. Dernier ajustement purement visuel : palette propagée à la fenêtre de paiement.

## Raccordement du lot moteur 2.1 (018f678)

Moteur B fusionné sans conflit. Commandes Windows setGlobalDiscount, setDelivery, setNote ajoutées. Panneau client/remise/livraison désormais réel pour les trois fonctions moteur, avec contrôles capabilities et motifs de refus. Sélection/création client encore indisponible. Remise de ligne : montant ou pourcentage, valeur initiale issue de discount_entry. Totaux moteur affichés pour remise globale/livraison et arrondi espèces, sans recalcul UI.

L’activation contract21 reste inchangée : aucune activation forcée ni vente démo effectuée. Les moyens déclaratifs de B sont inclus dans le moteur, mais l’éditeur multi-paiements et référence reste à terminer côté Windows. Le téléchargement d’images reste en attente.

## Quantités, poste et impression

Boutons −/+ dans le panier, pas de retrait implicite à zéro, pas de flottants ; contrôle métier moteur conservé. Menu poste : plein écran natif/F11, back-office HTTPS configurable, aide raccourcis/F1, Ctrl+F recherche. Choix imprimante parmi pilotes Windows enregistré pour la caisse ; impression du duplicata moteur depuis historique, sans renvoi automatique ni nouvelle vente. Format PDF 80 mm ; validation papier et multi-écrans encore nécessaire. Pas de ticket original inventé (commande moteur demandée).

Les demandes catalogue complet (aujourd’hui 60 résultats), filtres marque/fournisseur, clients, clôture, promotions et afficheur sont suivies dans PERIPHERIQUES-ET-PARITE.md et le journal partagé. Aucun de ces points n’est déclaré terminé tant que son raccordement et sa recette ne sont pas faits.

## Taille, catégories et accès session

Taille des produits 150–330 px avec boutons −/+ dans les réglages. Flèches gauche/droite autour de la liste de catégories. Accès session dans menu du poste : relecture état/capacités, conservation de la session existante, saisie fond de caisse et seconde vérification avant commande openSession. Aucun ajout de clôture fictive. Analyse sans remarque ; 49 tests Windows passent en série.

## Paiements multiples et entretien des paniers

Raccordement setPayments : jusqu'a 10 lignes, reference par paiement, validation automatique apres 250 ms et totaux exclusivement fournis par le moteur. Toute edition invalide immediatement la confirmation, avec controle supplementaire au clic. Les moyens proposes restent ceux autorises par le serveur ; aucune activation 2.1 forcee. Suppression d'un panier en attente avec confirmation explicite.

Moteur B 2180f4c integre (plafond global distinct). Validation : 50 tests Windows reussis, analyse sans remarque ; 19 tests moteur v2/regles web reussis. Test de reponse IPC malformee stabilise par une requete de demarrage avant injection : le demarrage JIT n'est plus confondu avec la panne testee. Recette des nouveaux paiements sur la demo et impression physique restent a effectuer.

## Catalogue complet : fournisseur, marque et pages

Integration B c783089 sans conflit. HostCommand.moreProducts raccorde ; listes Fournisseur et Marque sous les categories. Les recherches transmettent ensemble texte, categorie, marque et fournisseur, y compris valeurs vides pour enlever un filtre. Compteur produits affiches/total et bouton Afficher plus tant que has_more ; pages de 60 gerees par le moteur sur le catalogue complet, aucun filtrage limite aux seuls produits visibles.

Contrat 2.1 active par B dans l'hote, selon les capacites serveur ; pas de modification des serveurs depuis C. Validation : analyse sans remarque, 61 tests Windows + adaptateur reussis ; rendu Flutter inspecte (donnees fictives), absence de debordement testee a 1280x800 et 800x600. Pas de nouvelle vente sur la demo dans cette livraison.

## Compatibilite prioritaire catalogue 2.1 (1b38dea)

Moteur et schemas B integres pour accepter favoris, promotions, nouveautes, stock faible et metadonnees image du serveur 198a26d7. Aucun changement de prix ni telechargement image automatique. Le raccordement visuel des nouveaux badges et le cache image restent distincts de cette mise a jour de compatibilite.

Validation : 64 tests Windows + moteur v2 reussis, analyse Windows sans remarque. La fixture FakeV2Server avait une autorisation fixe expirant le 30 octobre a 08:00 UTC ; sa valeur par defaut est maintenant relative a la date du test, les scenarios explicites d'expiration restent inchanges. Aucun controle metier affaibli. Installation a relancer avant deploiement du nouveau catalogue : un processus deja ouvert reste sur son ancien moteur.

## Acces caisse et listes recherchables

Fournisseur/Marque : selection avec recherche integree locale, effacement du filtre, resultat vide explicite. Aucun plugin web Select2 ni dependance ajoutee dans Flutter. Barre horizontale defilante : Recu, Note, Session, Calculatrice, Aide et ventes recentes ; menu Verrouiller/Se deconnecter via logout existant, PIN et selection operateur effaces, panier conserve. Client de passage affiche par defaut (aucun client nominatif encore pris en charge).

B 9f87858 integre : printTicket raccorde via identifiant d'operation ; bouton imprimante dans la liste des ventes. Verification imprimante disponible avant demande original. Le moteur marque le ticket emis avant retour IPC : une panne papier peut donc conduire a une reimpression, sans jamais recreer la vente. Affichage des fichiers images locaux uniquement, avec remplacement visuel si fichier indisponible. Cache B par lots de 30 apres synchro panier vide ; politique nocturne et interruption quand un panier commence demandees a B, non declarees realisees.

Restent explicitement absents : tarif gros, ventes du jour/X consolidees, livre de caisse, historique des modifications du panier, cloture complete et selection/creation de client. Ouverture de session actuelle = fond simple et conservation session existante ; comptage par coupure/report et horaires restent absents du contrat. Demandes inscrites au journal A/B.
Validation : 53 tests Windows (dont rendu fictif), analyse sans remarque ; 62 tests Windows/adaptateur au passage precedent. Rendu inspecte. Impression papier et essai des images sur demo non effectues.

## Autorisation responsable (lot 1c) et monnaie du ticket

205313a fusionne (inclut bcc6ee9 : monnaie du ticket calculee sur montant especes arrondi). Fenetre responsable/code masque de 8 chiffres/motif avant commitSale dans les paiements simples et multiples, seulement si discount_approval.required. Responsables proposes exclusivement par le moteur. Annuler ne soumet rien ; refus certain conserve le panier ; toute issue incertaine passe par la reconciliation existante du meme identifiant.

Le code est transitoire a la tentative, jamais ajoute au journal durable, puis les champs de preuve sont effaces ; nouvelle saisie a chaque tentative. Panier/revision controles apres fermeture de la demande : changement impose une nouvelle verification. Le moteur reste autorite sur code, plafonds, verrouillage apres echecs et droits. Le lot ne couvre pas survente/prix manuel. Pas d'essai avec code reel sur la demo par C.
Validation : 67 tests Windows/moteur v2 reussis, analyse sans remarque. Test specifique annulation/refus/code masque/effacement/nouvelle saisie ; erreur de cycle de vie du dialogue corrigee avant passe finale.

## Reference moteur 0816fbf et compatibilite des lots 2.1

Fusion de 0816fbf (pas bac42bc seul) : schemas retour_residuel a3d86150 et lots clients, cloture, paniers partages, retours. Enumeration IPC completee : searchCustomers/createCustomer/setCustomer, closeSession, resumeShared/deleteShared, returnableSale/previewReturn/commitReturn. Cela rend les commandes transportables mais ne constitue pas une recette des nouveaux ecrans : selection/creation clients, cloture aveugle, paniers partages et retours Windows restent a raccorder.

Suite automatique complete lancee sans variables de recette serveur. Le scenario reel essai_21_test exigeait SK_BASE pendant son chargement ; il est maintenant marque ignore explicitement si aucune base de recette n'est fournie, comme les autres scenarios reels. Aucun contact demo ni vente reelle dans cette passe. Analyse globale du depot : aucune remarque. Feu vert a borner a la compatibilite moteur et a l'executable effectivement lance, sans validation production ni recette physique.

## Calculatrice tactile et destinations web

Remplacement des deux champs par une calculatrice avec pavé tactile 48 px, operations en chaine, priorites, parentheses, pourcentage relatif (200 + 10 % = 220), changement de signe, effacement/correction, memoire MC/MR/M+/M-, historique de 20 calculs reutilisables et copie. Saisie clavier/Entree possible. Calcul fractionnaire exact, arrondi d'affichage a 12 decimales, aucune modification de vente. Petit ecran : contenu defilant teste sans debordement.

Retour au back-office : adresse personnalisee si renseignee, sinon origine appairee + /accueil (route web verifiee). Bouton distinct Ouvrir la caisse web : origine appairee + /caisse. L'origine publique est fournie par status de l'adaptateur Windows ; aucun jeton transmis au navigateur. Les boutons sont accessibles sans configuration manuelle supplementaire. Session du navigateur distincte, authentification web normale.
Bilan final avant compilation : suite complete 243 tests reussis, 6 scenarios reels ignores faute de configuration, 0 echec ; analyse globale avant ajustements et analyse Windows finale sans remarque. Journal build/full-final-0816fbf.log.

## Selection et creation de clients Windows, boutons arrondis

Le libelle Client de passage au-dessus du panier ouvre maintenant le repertoire local : recherche par nom/telephone avec temporisation de 250 ms, selection d'un client, retour au client de passage. Le panneau Client, remise et livraison ouvre le meme selecteur. Le nom affiche vient du panier moteur, y compris apres restauration.

Nouveau client : nom requis, telephone facultatif, commande createCustomer avec identifiant UUID, puis setCustomer ; le client en attente de synchronisation est signale. Une reponse perdue ne provoque pas une seconde creation automatique : retour a la recherche avec explication. Les capacites customer/customer_create et les verrous de caisse sont respectes. Trois tests de parcours couvrent selection, creation, retour au client de passage et reponse perdue. Pas encore de recette de ces ecrans contre la demo.

Boutons pleins, contours, textes, eleves et icones : arrondi commun de 16 px dans le theme de caisse. Pagination catalogue existante : Afficher plus ajoute 60 produits, filtres conserves ; pas de pages numerotees.
Validation de ce lot : 59 tests Windows reussis (dont executable moteur reel), analyse Windows sans remarque. Aucun essai client sur la demo pendant cette passe.

## Paiement : messages, solde propose et appels locaux

Les messages moteur sont presentes dans un bandeau colore du titre des fenetres paiement simple et multiple. Multipaiement : premier montant propose depuis preparePayment.payable, puis chaque nouvelle ligne reprend le solde non affecte ; affichage du reste a repartir, ajout desactive quand il est nul. Ce calcul est une proposition de saisie seulement : le moteur reste autorite pour les montants, l'arrondi, la monnaie et l'encaissement.

preparePayment ne declenche plus une relecture status/view inutile. setPayment/setPayments reutilisent la vue moteur retournee si schema/revision valides, au lieu de deux appels IPC supplementaires et d'un second calcul de catalogue. Erreur ou reponse sans vue : chemin de rafraichissement conserve. Temporisation de saisie 250 ms conservee, validation explicite de l'encaissement. Synchronisation du moteur deja executee en dehors de la file des commandes locales ; aucune promesse de temps maximal sans mesure sur poste reel.

## Paniers partages, cloture, retours et badges

Liste items + shared, reprise/suppression par shared_id, taken_elsewhere non actionnable et besoin reseau indique. Priorite A du 31 octobre traitee.
Menu du poste : cloture a l'aveugle (comptage especes/autres moyens, justifications), retour especes (vente connue, quantites en unites de base, previsualisation moteur et motif obligatoire). Confirmation avant ecriture. Z attendu du serveur. Aucun remboursement physique automatise.
Requete et UUID conserves avant envoi dans pending-close-v2.json ou pending-return-v2.json, a cote de la base. Reponse inconnue : requete immuable reprise avec le meme UUID, y compris apres redemarrage. Fichier illisible bloque cette operation sans ecrasement ; reponse incoherente ne vaut pas succes.
Badges stock faible/promotion/nouveau/favori depuis la vue moteur, sans recalcul. Stock projete apres panier encore attendu de B. Texte obsolete des reglages images corrige.
Validation finale : 64 tests Windows PASS en serie, analyse sans remarque. Premiere passe parallele : timeout demarrage JIT du test de fermeture et test disque execute dans zone de temps simulee ; test disque corrige via runAsync, aucun controle metier retire. Pas de recette demo supplementaire.

## Afficheur client : deux modes demandes le 31 octobre

Le responsable ne dispose pas encore d'afficheur et demande les deux familles. A implementer et qualifier, pas presente comme support livre :
- Second ecran Windows : fenetre de presentation separee, choix du moniteur, lignes/prix/totaux venant de la vue moteur, accueil apres fin de vente, aucune saisie caissier ni code/raison d'autorisation affiche. Perte du moniteur sans blocage de la caisse.
- Afficheur USB/serie : adaptateur de protocole materiel, port COM, debit et encodage configurables. USB peut etre un port serie virtuel ou un peripherique proprietaire : aucune compatibilite universelle presumee. File de sortie bornee, dernier etat prioritaire, erreurs/debranchement sans attente de la caisse. Commandes exactes a valider selon modele.
Les deux sorties utilisent les montants calcules par B, sans recalcul et sans requete reseau. Un simulateur ne remplacera pas la recette du materiel. Aucun pilote ni nouvelle dependance ajoute dans ce lot.

POS-80 (redirection de 2) choisie explicitement par le responsable : configuration applicative sauvegardee et remplacee, aucune modification du defaut Windows. Ticket TEST SANS VENTE transmis au pilote Windows ; sortie papier a confirmer. Ce test de pilote ne constitue pas une recette du ticket PDF Flutter.
Disposition demandee : selecteur Client de passage et Remise et livraison sur une ligne ; selection client retiree du panneau remise. Reprise inconnue : un refus lors d'une tentative ulterieure ne supprime plus l'intention precedente.
Ajustements finaux : 31 tests parcours caisse/operations PASS, dont refus pendant reprise inconnue et dispositions 800x600/1280x800 ; analyse propre.
Pied de panier compacte : remise globale/livraison puis base HT/TVA sur deux lignes et deux colonnes ; En attente/Suspendus sur une ligne. Total a payer et bouton paiement gardent leur prominence. 26 tests caisse PASS avec montants affiches, dont 800x600 et 1280x800, analyse propre.

## 31 octobre — stock, images et afficheurs

Moteur B 4a61829 fusionne. Alertes indicatives et stock apres panier affiches ; horaires images persistants dans le moteur, pause pendant vente. Compteur suspendus local/partage dedoublonne. Afficheur client configurable : second ecran etendu distinct de la caisse ; profil ESC/POS 20x2 via port COM (USB serie), 8N1, vitesse configurable, traitement des ecritures hors fil UI. Aucun nom de client transmis ; test sans vente. Aucun peripherique connecte : validation materielle non faite, USB HID/proprietaire hors profil disponible.

Validation : 94 tests Windows/moteur puis 69 tests Windows avec afficheurs, tous PASS ; analyse Windows sans remarque. Compilation native et installation a confirmer dans JOURNAL. Aucun main/push, aucune nouvelle vente demo ; gate A/B encore attendue. Mesure Release sur catalogue realiste et recette papier restent ouvertes.


### Mesure Release et verification native
Moteur AOT reel, IPC stdin/stdout, SQLite synthetique dediee de 5000 produits, aucun reseau ni donnees boutique : mediane de 20 appels view 74,72 ms, search 48,47 ms, scan 55,38 ms ; maxima 130,51 / 107,99 / 115,23 ms. Demarrage + premiere vue 1020,95 ms. Script reproductible tool/windows/benchmark_release.py ; ce n'est pas une mesure de rendu visuel ni de synchronisation reelle. Compilation initiale native reussie.
Test natif afficheur (echec de peripherique absent + arret du worker) PASS. Test natif securite non validable avec caisse ouverte : assertion first instance refusee normalement ; ne pas fermer la caisse de l'utilisateur pour ce test. Dernier correctif : reglages corrompus rejetes sans contaminer les menus ; 3 tests afficheur Dart PASS.


## 31 octobre — corrections paniers et arret du moteur
Moteur B a6e3dce integre (7c5af2c inclus) : panier partage conserve avant retour du journal, suppression visible immediatement pour eviter une seconde suppression.
EngineHost ferme maintenant son propre client HTTP apres drainage des commandes/synchronisation, puis SQLite et le verrou. Les transports injectes restent possedes par leur appelant. Tous les appels close attendent la meme Future. Nettoyage aussi en echec de demarrage.
86 tests Windows + moteur v2 PASS ; analyse ciblee sans remarque. Test avec vraie connexion TCP keep-alive : fermeture et reouverture de la base PASS. Script tool/windows/check_host_shutdown.py : ancien exe ne quitte pas apres EOF sous 5s (reproduit sur base synthetique seulement). Revalidation du nouvel exe apres compilation, resultat dans JOURNAL. Aucun processus utilisateur termine, aucune modification de donnees demo.

