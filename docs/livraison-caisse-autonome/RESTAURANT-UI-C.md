# Préparation Windows — Restaurant et service de table

## Mise à jour du 18 novembre 2026

Les commits B `7a7e7d1` et `e0dee59` sont intégrés. Les contrats R-1/R-2 sont validés par A ; R-3 est également livré côté serveur, mais pas encore repris dans le moteur B intégré ici.

La commande IPC `restaurantView` consulte le contexte et les commandes du moteur partagé après identification de l'opérateur. Elle ne crée aucune opération. Le bouton « Salle et tables » ouvre la présentation Windows, avec actualisation explicite, motif de non-désignation maîtresse, numéros des commandes et attente de synchronisation. Plusieurs commandes sur la même table restent des entrées distinctes ; leurs totaux ne sont pas additionnés par l'écran.

La capacité restaurant n'est pas encore annoncée par l'hôte Windows : l'écran affiche son indisponibilité tant que le moteur ne fournit pas de contexte. Les actions de salle restent désactivées. Ne pas considérer cette livraison comme une caisse restaurant opérationnelle.

Demande à B consignée dans JOURNAL : commandes de l'adaptateur partagé pour ouverture, lignes, préfacture, transfert, annulation, règlement complet et clôture, avec sérialisation et reprise des identifiants après réponse perdue. C ne prend pas l'opérateur privé de B pour appeler directement les mutations métier. L'annonce Windows attend ces commandes et les schémas critiques R-3. Les imprimantes, afficheurs et leur recette restent à raccorder ensuite.

17 novembre 2026. Travail indépendant demandé par le responsable, en attendant les livraisons A/B.

## Livré côté présentation

- `RestaurantWorkspace` : recherche de table/salle, filtres de salle, cartes libre/en service/à encaisser, sélection et détail de commande, notes de préparation, état de chaque ligne et montants déjà calculés. Disposition en deux panneaux sur grand écran et verticale sur fenêtre étroite. Présentation des destinations et états cuisine/bar fournis par l'appelant.
- `RestaurantStationEditor` : formulaire de brouillon (nom, IP littérale, port 1–65535). Retourne un `RestaurantStationDraft` au demandeur. Ne persiste rien, ne contacte aucun équipement et n'ouvre aucun service réseau.
- Aucun exemple de test ni donnée fictive ajouté au catalogue ou à la base de caisse.

## Limite explicite

Ces composants ne sont pas encore reliés au menu de la caisse installée. Les actions de commande/envoi/encaissement sont désactivées. Aucun écran ne confirme une opération non exécutée. L'appelant doit fournir un message de disponibilité explicite ; le prototype ne déduit pas l'autorisation d'être maître depuis une simple connexion réseau.

## Raccordement attendu de B et A

1. Vue moteur : profil et désignation de maître validés, salles/tables avec identifiants durables, états et commandes, montants et libellés calculés par B, droits effectifs, disponibilité des opérations.
2. Commandes sérialisées : ouvrir/modifier/transférer une commande, envoyer la différence en cuisine, encaisser via le chemin de vente v2, sans calcul financier dans les widgets.
3. File durable de bons et tentatives : cible, identité/empreinte immuable, résultat certain ou inconnu, accusés et duplicata explicite. Aucun secours automatique après résultat inconnu.
4. Contrat réseau des afficheurs : appairage et révocation, limites d'accès, accusés durables, procédures de reprise. Ne pas démarrer de serveur LAN depuis ce seul écran.
5. Persistance et diagnostic des destinations locales avant de raccorder le formulaire. « Valider le brouillon » n'est pas une preuve de connexion ou d'impression.

La définition A `restaurant.v1` reste une proposition ; aucun nom de commande IPC ni type serveur n'est ajouté par cette livraison de présentation.
