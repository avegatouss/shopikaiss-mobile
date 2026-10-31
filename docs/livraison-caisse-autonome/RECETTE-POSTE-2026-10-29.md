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

## Clarification A et vente réelle de démonstration sur Plateau

A confirme que les comptes Administrateur et Gérante Démo n'ont pas de PIN défini : le référentiel est fidèle à la base, aucun défaut serveur n'est établi. Le PIN annoncé sur la page de démonstration concerne Caissier Démo (3), présent à Plateau. Le diagnostic précédent doit donc être lu comme une configuration absente, non comme une perte de synchronisation. Le contrat précise ce cas.

Le code v1 Windows destiné à Tablette Pâtisserie a été consommé sur le moteur installé `9f079ed`. Base initialement distincte `%LOCALAPPDATA%/ShopiKaiss/recette-tablette-patisserie`, sans remplacer Cocody et sans utiliser le code de B ou son terminal Caisse 2. Appairage Plateau réussi, session déjà ouverte et authentification Caissier Démo réussie. Vente locale permanente autorisée par les données reçues ; C n'a publié aucune politique.

Essai via les tubes privés du véritable exécutable installé, pas via les clics de l'interface :

- Produit 42, Tasse en céramique ; stock initial 22. Quantité changée à deux puis ramenée à une par commandes du moteur.
- Paiement espèces 1 500 F, sans recalcul côté pilote. UUID durable écrit avant envoi : `c95c4cd9-aba0-4d5b-a07f-a05dfd381f10`.
- Vente locale `HL-005-000003`, acceptée par le serveur sous **V-20261029-0015**, état intégrée. Une occurrence dans l'historique local.
- Renvoi local de commitSale avec le même UUID : même vente, sans nouvel encaissement. Consultation saleStatus confirme committed ; intention retirée après confirmation.
- Synchronisation : stock affiché 21, panier vide, état À jour. Arrêt et relance de l'hôte : même vente intégrée, stock toujours 21 et deuxième rejeu idempotent. Ticket récupéré (22 lignes), sans impression matérielle.

Le contrôle de l'historique web par navigateur, la coupure réelle du réseau et l'imprimante ne sont pas encore faits. Aucune preuve de déploiement de e9a45bfa n'a été recueillie par C ; le test porte sur l'hôte v1 et ne valide pas le champ v2 versions.politiques.

La fenêtre utilisateur reste pour l'instant sur Cocody. Sa fermeture automatisée a été refusée par Computer Use car des saisies utilisateur étaient en cours ; fermeture demandée à l'utilisateur avant changement de base. Cocody ne contient aucune opération ; la base Tablette contient une seule opération transmise/intégrée et aucun journal d'intention en attente. Les sessions serveur restent ouvertes pour la suite des essais et devront être clôturées en coordination avec A/B, sans fermer Caisse 2 à leur place.

Suite après confirmation utilisateur « fenêtre fermée » : absence des processus vérifiée, dossiers absolus contrôlés sous LocalAppData/ShopiKaiss, absence d'intention en attente vérifiée. Base Cocody déplacée sans suppression vers `caisse-cocody-conservee-20261029` ; base Tablette déplacée vers `caisse` pour devenir la base active du bootstrap. Relecture en mode lecture seule : Plateau avec une vente, Cocody avec zéro opération. Aucun compteur PIN ni donnée métier modifié par ce changement de dossiers.

Build Release propre `ddf3a74` compilé et installé par utilisateur sous `Programs/Shopikaiss-Recette/ddf3a746fcff`, raccourcis mis à jour. Il comprend le correctif PIN non défini. Application relancée sur la base active Plateau/Tablette Pâtisserie ; connexion caissier à effectuer dans l'interface. La vente et les tests ci-dessus restent ceux du moteur réel installé, sans prétendre à une recette complète de l'interface, de l'imprimante ou à un mode v2 déjà raccordé.

## Historique accessible dans la caisse Windows

Ajout du bouton « Ventes de ce poste » : consultation des 200 ventes locales les plus récentes, état serveur et affichage du duplicata calculé par le moteur. Aucun paiement renvoyé, aucun calcul financier côté écran, aucune impression physique déclenchée. En cas d'erreur, la consultation peut être fermée ou rechargée sans toucher au panier.

Validation : 43/43 tests Windows réussis, dont deux nouveaux scénarios d'interface (historique/duplicata sans mutation et reprise après erreur). Les deux remarques de style de l'analyse initiale ont été corrigées ; analyse ciblée finale sans anomalie. B reste au commit cb10844 ; le raccordement v2 de l'hôte n'est pas livré. Pas de nouveau test réseau réel ni de vente démo dans ce lot.

Compilation Release raccordée réussie depuis le commit propre a2ac2b4. Installation côte à côte dans `%LOCALAPPDATA%/Programs/Shopikaiss-Recette/a2ac2b4d3e93`, raccourci « Shopikaiss Windows - Recette » mis à jour. Données conservées ; fenêtre actuelle non fermée et nouveau binaire non lancé sur la base occupée. L'historique sera disponible au prochain lancement par le raccourci. Contrôle visuel natif et impression physique non effectués pour ce lot.
