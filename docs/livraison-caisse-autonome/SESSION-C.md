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
2. Supervision/reconnexion du processus, vie en arrière-plan et intégration de l’activation v2 ; aucune de ces capacités n’est simulée dans le point d’entrée actuel.
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
