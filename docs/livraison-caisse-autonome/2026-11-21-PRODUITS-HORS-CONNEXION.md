# Produits hors connexion — préparation Windows

## Réalisé

Composant `CatalogueProductEditor`, indépendant du transport, non exposé dans la
caisse tant que le contrat et le moteur ne sont pas livrés. Création ou édition
préremplie : désignation, référence, codes-barres (zéros initiaux conservés,
doublons exacts retirés), prix entier dont la borne est fournie par l'appelant.
Les erreurs retournées sont affichées dans le formulaire sans perdre les saisies.
Une sauvegarde en cours interdit une seconde soumission et le retour. Une exception
non qualifiée affiche un résultat non confirmé et interdit un nouvel envoi depuis
la même fenêtre. Seule une confirmation de sauvegarde durable ferme le formulaire.

Trois tests de widgets couvrent validation, conservation des codes, soumission
unique, édition préremplie, refus et résultat incertain. Il n'y a pas de stockage
de produit ni d'appel réseau dans ce composant.

## Raccordement attendu

- A publie les capacités/droits, champs et bornes, opérations idempotentes,
  révisions, alias, arbitrage et dépendances entre créations et ventes.
- B fournit le stockage durable par boutique, projection et commandes partagées.
  `createProduct`, `updateProduct`, `catalogueChanges` proposés conviennent.
- C raccorde le formulaire, complète les champs selon le contrat (catégorie,
  stock, gros, etc.), expose les boutons selon les droits et ajoute le suivi.
- La base d'une édition doit être celle de l'ouverture du formulaire ; aucune
  substitution silencieuse après un changement concurrent. Les champs non exposés
  ou non modifiés doivent être préservés par l'adaptateur.
- Un résultat incertain se réconcilie par son identité durable, y compris après
  fermeture ou redémarrage. L'appelant ne doit pas fabriquer une nouvelle création.
- L'arbitrage web est la proposition du premier lot, pas encore un contrat validé.

## Livraison

Préparation de code seulement : aucune activation, compilation de distribution ni
installation de cette fonctionnalité. La version installée reste `9e044dd`.
Contrôle du journal et du worktree de A répété pendant le travail : aucun contrat
catalogue publié constaté, dernier commit observé `4176383b` (prix modifiable).
Demandes et accord sur les commandes consignés dans INBOX-A et INBOX-B.
