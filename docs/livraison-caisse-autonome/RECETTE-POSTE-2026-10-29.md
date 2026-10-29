# Installation et début de recette sur le poste Windows

Demande utilisateur : installer Windows sur ce poste et tester avec demo.khoga.ci.

## Version installée

Code `9f079ed`, branche `feat/caisse-windows-raccordement`. Build Release raccordé, non signé, conservé sous `%LOCALAPPDATA%/Programs/Shopikaiss-Recette/9f079ede937d`. Raccourcis « Shopikaiss Windows - Recette » sur le Bureau et dans le menu Démarrer. Installation par utilisateur avec `tool/windows/Install-Review.ps1 -DesktopShortcut`, contrôle des empreintes après copie. Pas d'Inno Setup, de service ni d'entrée de désinstallation automatique dans ce lot. Les anciens dossiers de programme sont conservés ; les raccourcis pointent vers le dernier build installé.

Base locale séparée : `%LOCALAPPDATA%/ShopiKaiss/caisse`. La mise à jour n'efface ni cette base ni le journal d'encaissement. Aucune modification de main ni push.

## Contrôles et correction

- Le site HTTPS répond HTTP 200 sur sa page `/connexion` depuis le poste. Cela ne constitue pas une preuve de fonctionnement des API authentifiées ni de version serveur.
- L'application installée lance le moteur depuis son propre dossier, qui ouvre la base locale.
- Le contrôle de l'écran par son arbre d'accessibilité a relevé « Le moteur local doit être vérifié » au premier démarrage. Reproduction automatisée sur le vrai exécutable : `StreamSink is bound to a stream` lorsque status et view écrivaient simultanément pendant un flush.
- Correction : file d'écriture IPC sérialisée, sans sérialiser l'attente des réponses. Les requêtes expirées encore en file ne sont pas envoyées. La fermeture attend les écritures engagées avant EOF. Aucun rejeu de commande ajouté.
- Analyse Windows sans anomalie, **40 tests Windows réussis**, dont démarrage natif non appairé et 20 requêtes concurrentes. Fermeture normale de l'ancien écran et disparition des deux processus constatées. Reconstruction depuis commit propre et installation de la version corrigée.
- Après relance, l'arbre d'accessibilité montre l'écran d'appairage sans l'erreur technique. L'application est laissée ouverte pour la suite.
- Les captures graphiques ont échoué deux fois (`FrameArrived timed out`, `window capture timed out`). La vérification des contrôles est faite via l'accessibilité ; aucune validation visuelle complète n'est revendiquée.

## Avancement B et suite

B est au commit local `f5247a4` lors de la vérification. Son client v2 et son essai serveur sont livrés ; le raccordement v2 de l'hôte n'est pas encore commité. Des changements locaux B existent et n'ont pas été copiés ni modifiés. L'hôte installé utilise donc encore v1.

Attente des informations de test demandées à l'utilisateur : boutique/caisse de démonstration, code d'appairage récent, caissier de test. Aucune vente distante effectuée. Les contrôles suivants restent à exécuter après appairage : téléchargement du catalogue, PIN et session, scan/recherche, quantités, paiement, reprise de panier après fermeture, vente avec perte de réponse, synchronisation après coupure, stock sans double déduction, impression réelle. L'ouverture de session Windows et les capacités de paiement encore absentes ne doivent pas être présentées comme terminées.

B doit reprendre au minimum le correctif transport `9f079ed` avant sa prochaine validation de l'hôte v2 (les fichiers sont exclusivement Windows).

## Suite : appairage Cocody et panier durable

Avec le nouveau code fourni par l'utilisateur, appairage réussi via le véritable hôte installé, dans le dossier de données de l'application. Boutique renvoyée : Cocody ; état prêt, aucune raison de blocage, session ouverte, sept produits téléchargés. Aucun code, PIN ni jeton n'est enregistré dans ce compte rendu.

Sur un panier initialement vide : ajout d'un produit puis quantité passée à deux, total calculé par le moteur 2 360 F. Arrêt propre de l'hôte et relance : même UUID de brouillon, même ligne et quantité deux. Panier de test vidé ensuite ; aucune vente et aucun paiement enregistrés. L'application installée a été relancée et son arbre d'accessibilité montre désormais le choix du caissier et le PIN, sans erreur de démarrage.

Deux opérateurs sont proposés, Administrateur et Gérante Démo. La correspondance du PIN fourni a été demandée à l'utilisateur avant toute tentative, sans essai successif sur plusieurs comptes. La suite d'encaissement reste en attente de cette précision. Ces contrôles utilisent toujours l'hôte v1 ; l'activation v2 serveur ne change pas le protocole du binaire installé.

## Diagnostic du refus de PIN Cocody

L'utilisateur confirme un PIN commun à tous les profils. Une tentative Gérante Démo avait été refusée avant toute modification de panier ou vente. Analyse suivante : les deux caissiers de Cocody ont une empreinte PIN absente dans le référentiel local. Lecture authentifiée, sans mutation, du référentiel actuel de demo.khoga.ci : même résultat pour Administrateur (1) et Gérante Démo (2), avec `mode_caissier=pin`. Le problème n'est donc pas un code saisi comparé à une empreinte valide ; le vérificateur est absent des données reçues. Aucun secret ni empreinte n'a été imprimé ou sauvegardé dans le compte rendu.

Demande à A : contrôler les données de démonstration et la projection OfflineSnapshot. Le code serveur consulté projette users.pin_hash lorsque le mode PIN est actif. Vérifier où disparaît cette valeur et assurer la cohérence entre le PIN commun annoncé et les caissiers des deux boutiques. Ne pas désactiver le contrôle PIN pour contourner le défaut. Après correction, recharger le référentiel et poursuivre l'essai d'encaissement autorisé par l'utilisateur.

Correctif C : BEngineAdapter refuse explicitement `pin_unconfigured` si le référentiel exige un PIN sans fournir d'empreinte pour l'utilisateur sélectionné. Aucune tentative n'est consommée dans ce cas, aucune connexion n'est autorisée. Test ajouté sur vraie base SQLite avec un référentiel sans PIN : compteur inchangé, refus explicite ; quatre tests d'adaptateur réussis. Ce correctif source n'est pas encore recompilé dans l'installation locale. Aucune vente créée.
