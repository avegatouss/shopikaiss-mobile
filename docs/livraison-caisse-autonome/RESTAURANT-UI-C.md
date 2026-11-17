# Préparation Windows — Restaurant et service de table

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
