# Proposition de raccordement Windows à B

Ce contrat local de présentation/transport est proposé par C. Il ne remplace pas les contrats métier de B ou l’API serveur de A. À valider puis adapter par B avant intégration. Version IPC : 1.

## Transport réel

Processus enfant dédié avec stdin/stdout hérités privés, sans port réseau. Messages JSON UTF-8 terminés par LF, borne 1 Mio avant décodage. `version`, `kind`, `id` de requête, `command`, `arguments`, `operation_id` pour encaissement. Réponse `ok/result` ou `ok=false/error`. Notifications après COMMIT : `kind=event,name=committed` ; la vue autoritaire est ensuite relue.

`ProcessWindowsHost` démarre uniquement un exécutable de chemin absolu, pas une commande shell. Le bootstrap définit un chemin de distribution fiable et doit vérifier l’identité/signature de l’hôte avant démarrage. Aucun chemin provenant du serveur n’est exécutable. Le contrôle de signature/distribution reste à intégrer avec l’installateur final.

L’hôte doit héberger le moteur commun réel, son verrou d’écriture et son stockage. `WindowsHostServer` encadre et sérialise les commandes locales ; aucun appel réseau long ne doit être attendu dans `execute`. `synchronize` planifie une tâche indépendante. EOF laisse terminer les commandes reçues puis fermer proprement. La survie en zone de notification après fermeture UI et la relance supervisée sont des travaux restants, pas des propriétés déjà livrées.

## Vue consommée par l’interface (schéma proposé 1)

`schema:1`, `revision` entière monotone de la vue, `ready`, `can_pay`, `draft_id`, `store_name`, `sync_label`, `total_label`, `payment_label`, `payment_valid`.

`products`: liste bornée/paginée d’objets avec `id`, `name`, `price_label`, `stock_label`.
`lines`: `id`, `name`, `quantity_label`, `total_label`.

Les libellés et montants proviennent du moteur ; aucun total fiscal n’est recalculé par Windows. La recherche doit retourner une vue complète mise à jour ou faire publier `committed` afin que la vue reflète ses résultats. Les grands catalogues ne doivent jamais dépasser la borne IPC : pagination/index moteur requis. Une modification catalogue ne doit pas supprimer le filtre courant.

Commandes proposées : `status`, `view`, `search`, `scan`, `changeQuantity`, `removeLine`, `preparePayment`, `setPayment`, `commitSale`, `saleStatus`, `history`, `reprint`, `synchronize`. Certaines ne sont pas encore exposées par l’écran initial (édition paiement/quantité, historique complet) ; leur UI attend le modèle métier de B.

## Encaissement et reprise

Point de coordination vérifié le 29 octobre 2026 : en réseau v1, renvoyer une vente `a_arbitrer` peut relancer son intégration (test A `RenvoiIdentiqueV1Test`, commit `bc30a87e`). L'adaptateur ne doit donc jamais implémenter `saleStatus` par une nouvelle soumission réseau. Lire le journal local ; pour le sort serveur des arbitrages, attendre une lecture sans effet de bord (demande B-REQ-004 / contrat v2). Une demande de vérification de l'utilisateur ne constitue pas une autorisation de rejouer un arbitrage.

`commitSale` reçoit UUID stable, identifiant et révision du brouillon. B doit lier durablement le brouillon consommé à l’opération dans sa transaction de vente. Résultat : `state=committed`, `operation_id`, `number` après COMMIT uniquement.

Une erreur prouvant absence de COMMIT peut déclarer `not_committed:true`. Toute erreur inattendue, timeout ou rupture est un résultat inconnu. La présentation bloque un nouvel encaissement et interroge `saleStatus` avec le même UUID. `not_found` seul ne déverrouille pas une vente : une commande peut encore être en train de terminer. Le moteur doit fournir une résolution définitive si un rejet est certain ; le déverrouillage de ce cas est à convenir avec B.

Après redémarrage UI, B doit restaurer le brouillon et la vente potentiellement engagée depuis son journal ; l’UUID uniquement en mémoire de l’interface n’est pas une garantie de reprise. Le bootstrap n’activera pas de vraie vente avant ce raccordement durable. Aucune confirmation simulée dans `lib/`.

## Adaptateurs natifs et limites

Le canal `ci.khoga.shopikaiss/windows` fournit chemin LocalAppData et protection DPAPI utilisateur de blocs de secrets (pas chiffrement automatique de toute la base). Le code C++ de protection et de verrou est compilé et testé nativement le 29 octobre 2026 ; la recette du canal Flutter dans l'application installée reste à effectuer. Mono-instance UI par SID/session Windows ; le verrou SQLite/moteur reste indispensable, notamment pour plusieurs sessions Windows. DPAPI est lié au compte Windows et ne remplace pas un chiffrement de sauvegarde récupérable sur une autre machine.

L’adaptateur réseau ESC/POS transmet uniquement les octets du ticket déjà enregistré. Succès = transmis, pas preuve de papier sorti. Aucune répétition automatique ni impulsion de tiroir ajoutée par le transport. USB/spouleur Windows, matériel réel et sélection des périphériques restent à réaliser.

## Commandes de vérification

Depuis ce worktree, après résolution des dépendances existantes :

```powershell
./tool/windows/Test-Windows.ps1 -FlutterRoot C:/dev/flutter
./tool/windows/Test-Native.ps1
./tool/windows/Build-Integration.ps1 -FlutterRoot C:/dev/flutter
```

Si la politique locale interdit les scripts, une exécution explicitement limitée au processus est possible avec `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tool/windows/Test-Windows.ps1 -FlutterRoot C:/dev/flutter`, après lecture du script. Ne pas changer la politique globale pour ces tests.

La dernière commande construit uniquement une version de revue fermée aux ventes, jamais un installateur production. Ne pas substituer des tests Flutter ou CTest au contrôle de l'exécutable installé.
