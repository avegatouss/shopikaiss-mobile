# Raccordement de l'hôte B — session C, 29 octobre 2026

Base : fusion `c318e83` de B `0c39b40` dans `feat/caisse-windows-raccordement`. Aucun push ni changement de main. Ce document complète SESSION-C et remplace son attente d'un bootstrap et d'un journal d'intention.

## Fonctionnement livré

- Build explicitement raccordé avec `Build-Integration.ps1 -FlutterRoot C:/dev/flutter -WithEngine`. Sans ce paramètre, le point d'entrée reste fermé aux ventes.
- Hôte compilé et copié sous `moteur/bin/shopikaiss_moteur.exe`, SQLite sous `moteur/lib/sqlite3.dll`. Leurs SHA-256 sont embarqués à la compilation de l'interface et vérifiés avant lancement, sans chemin fourni par le serveur. Cela ne remplace pas la signature éditeur.
- Base dans `%LOCALAPPDATA%/ShopiKaiss/caisse`, même chemin que B. Le superviseur C utilise les tubes privés et le verrou de base B. Une reconnexion attend la sortie de l'ancien processus et ne rejoue aucune commande.
- Écran de recette : appairage HTTPS, choix du caissier et PIN, retour aux paramètres de connexion depuis la caisse. PIN effacé après tentative, code effacé après réussite. L'appairage et le catalogue restent gérés par B. Aucun identifiant d'exploitation n'est embarqué.
- `pending-sale.json` dans le même dossier conserve uniquement le schéma et l'UUID. Écriture avec flush avant tout envoi de commitSale. Échec d'écriture : aucun envoi ; fichier invalide : caisse bloquée, fichier conservé pour diagnostic.
- Après redémarrage de l'interface, cet UUID est relu avant toute activation. Consultation saleStatus locale, jamais renvoi de vente. Le journal n'est retiré qu'après résultat committed du même UUID, refus certain, ou absence définitive du même UUID. Si l'effacement échoue, la vente reste à vérifier.

Un seul propriétaire UI doit accéder au journal. Le runner possède son verrou d'instance et l'hôte son verrou exclusif de base. Ne pas permettre de changer de dossier pour contourner une intention non résolue. La durabilité testée couvre fermeture/recréation de l'interface et stockage disque ; aucune qualification de coupure électrique physique n'est revendiquée.

## Vérifications

Analyse Windows : aucune anomalie. Suite complète sans intégration serveur : **190 tests réussis**, dont **37 Windows**, hôte exécutable réel inclus. Trois nouveaux tests couvrent le journal sur disque : destruction/recréation du contrôleur sans nouvel encaissement, fichier corrompu, et impossibilité d'écrire avant envoi.

Le premier passage a relevé une différence CRLF/LF dans la comparaison des schémas embarqués. Une règle `.gitattributes` limitée à `test/fixtures/contrat-v2/schemas/*.json` conserve désormais LF. Aucun schéma ni règle métier modifié. Le script Build-Moteur a aussi reçu l'échappement PowerShell de deux apostrophes ; aucune modification du moteur B.

Les tests supposent `SHOPIKAISS_DART_EXECUTABLE=C:/dev/flutter/bin/cache/dart-sdk/bin/dart.exe`, configuré par Test-Windows.ps1. NuGet doit être sur le PATH pour la compilation native (sur ce poste : `C:/dev/nuget`). Ne pas lancer la reconstruction du moteur pendant le test de son exécutable.

Build Release raccordé réussi sur le commit propre `3ce238f`. Test-Launch : création de fenêtre et fermeture normale code 0. LOCALAPPDATA remplacé pour cet essai par un dossier temporaire sous build : la base SQLite a effectivement été créée par le moteur lancé depuis l'interface. Après fermeture de l'interface, un nouvel hôte a repris cette même base puis s'est arrêté avec code 0, confirmant la libération du verrou. Les quatre tests EngineHost ont été rejoués avec le binaire final : 4/4. Aucun appairage serveur réel ni vente client lors du contrôle natif ; le lancement masqué n'est pas une recette visuelle.

## Limites de recette / coordination B

Paquet de cette recette : `dist/windows-review/shopikaiss-windows-review-f8ad9b7fa4f54bd4a511ff7daae5cb80.zip`, accompagné de son SHA-256. Les 27 fichiers ont été vérifiés avant compression et après extraction. Il contient le build propre `3ce238f`, sans signature, installateur ni mise à jour automatique.

L'hôte livré par B utilise encore le moteur v1. Le client v2 est présent et testé, mais n'est pas activé par ce raccordement. La demande TVA B-REQ-005 et l'essai serveur v2 restent à A/B.

L'ouverture de session Windows reste absente ; l'écran l'indique si aucune session n'est ouverte. Restent notamment rendu monnaie dans l'écran, remises et paiements multiples selon contrat B, périphériques réels, impression complète, verrou d'inactivité/permissions de présentation à qualifier, installateur et signature, mise à jour et recette sur poste pilote. Ces éléments interdisent de présenter le build comme une livraison production terminée.

B peut intégrer la branche complète de C après cette remise, puis revalider Android sur le commit intégré. Aucun changement de clé Android, de pubspec partagé, d'API serveur ou de base client dans ce lot.
