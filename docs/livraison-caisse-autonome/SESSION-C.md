# Session C — Windows

Base : `c5f9483`. Branche : `feat/caisse-autonome-windows`.
Worktree : `C:/laragon/www/shopikaiss-windows` ; checkout mobile laissé intact.
Spécification : documents locaux du 29 octobre 2026 dans le dépôt serveur, encore non commités au démarrage.

## Demandes à B (intégration en attente)

- C-REQ-001 : fournir interface/version du moteur partagé et adaptateur des commandes de caisse vers `WindowsEngineAdapter`. Le transport privé proposé est dans `lib/src/windows/ipc/`. Ne pas confondre sa version 1 avec le protocole réseau v2. Proposition à valider avec B, pas contrat métier imposé.
- C-REQ-002 : fournir un hôte exécutable qui possède le stockage et utilise `WindowsHostServer` sur stdin/stdout privés ; logs sur stderr expurgé. Aucun faux moteur en release. Une commande réseau est planifiée, jamais attendue dans la file des mutations locales. Le processus termine les commandes acceptées avant fermeture sur EOF.
- C-REQ-003 : intégrer l’entrypoint Windows dédié ou le routage commun et les dépendances Windows requises après audit des plugins. C ne modifie pas pubspec ni Android. Stockage/migrations/gestion durable UUID et brouillons restent à B.
- C-REQ-004 : définir et tester la vue d’écran (catalogue/panier/paiement/statut) et le rapprochement `saleStatus` après résultat inconnu. Le moteur doit interdire le réencaissement d’un brouillon consommé même après redémarrage UI.

## Environnement

Flutter 3.47.7 / Dart 3.13.5. Visual Studio 2026 installé, mais `flutter doctor -v` signale CMake et SDK Windows manquants. Pas d’installation système ni changement de signature Android effectués.

## Premier lot remis

- Cible Flutter Windows isolée, entrypoint `lib/src/windows/main_windows.dart`, sans modification Android/pubspec/moteur.
- Transport privé stdin/stdout, limites de taille/version, délais bornés, sérialisation hôte et résultat inconnu après rupture. Pas de replay automatique d’encaissement. Tests avec vrai sous-processus local.
- Interface catalogue/panier et dialogue de paiement sur une projection du moteur ; aucun calcul fiscal dupliqué. Révisions anciennes ignorées et blocage du réencaissement après résultat inconnu.
- Adaptateur d’impression TCP sur réseau local, sans nouvelle vente ni impulsion ajoutée ; testé contre serveur TCP local, pas imprimante physique.
- Code natif chemin LocalAppData, protection DPAPI utilisateur et mono-instance UI ; compilation/exécution native encore non vérifiée.
- Scripts de test et de build de revue. Le bootstrap par défaut affiche la configuration manquante et n’autorise aucun encaissement. Aucun faux moteur en release.

Proposition de raccordement détaillée : [CONTRAT-ADAPTATEUR-WINDOWS.md](CONTRAT-ADAPTATEUR-WINDOWS.md). Les quatre demandes à B restent ouvertes. Les modifications en cours de B ont été vues dans son checkout ; elles n’ont été ni copiées ni modifiées.

## Vérifications exécutées

- `dart analyze lib/src/windows test/windows` : aucune anomalie.
- `flutter test --no-pub test/windows` : **13 tests réussis**, dont transport sous-processus, réponse perdue, timeout, encaissement incertain, état ancien et dispositions 1280×800 / 800×600.
- Un blocage de fermeture des pipes Windows a été découvert puis corrigé : EOF est envoyé avant d’attendre l’arrêt, les sorties continuent d’être drainées. Suite repassée après correction.
- Aucun diff sur `lib/src/offline`, Android, pubspec/lock et options d’analyse dans le worktree Windows. Aucune opération serveur/production exécutée.
- Tentative de build release dédié : échec explicite car les liens symboliques ne sont pas autorisés sur ce poste. `flutter doctor` signale également CMake/SDK Windows manquants. Ne pas interpréter les tests Flutter comme une compilation C++ réussie.

Le script de test a été exécuté via `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tool/windows/Test-Windows.ps1 -FlutterRoot C:/dev/flutter` : exception limitée au processus, sans modification de la politique globale de la machine.

## Reste à livrer avant toute production

1. Contrat B accepté et adaptateur/hôte réel, bootstrap, persistance des brouillons/résultats incertains et preuve d’idempotence après redémarrage.
2. Supervision/reconnexion du processus, vie en arrière-plan et intégration de l’activation v2 ; aucune de ces capacités n’est simulée dans le point d’entrée actuel.
3. Édition complète quantité/remises/moyens de paiement, PIN/appairage et historique selon le modèle de B. L’écran initial n’est pas une caisse complète.
4. Outillage Windows (symlinks, CMake, SDK), compilation C++, essais DPAPI/mono-instance et tests sur machine installée.
5. Spouleur/USB, périphériques clients, gestion des jobs, installateur signé et mises à jour. Aucun installateur prêt à distribuer à ce stade.
6. Validation du commit intégré par B sur Android et Windows, scénario serveur réel isolé et portes P0–P8 applicables.

P0 : périmètre isolé vérifié ; P3 : preuves partielles transport/UI seulement ; P5/P6/P8 : non satisfaites. **Livraison production bloquée**. Aucun push main, déploiement, changement de signature, migration ou base client touchés.
