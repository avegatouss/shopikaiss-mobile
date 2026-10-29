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
