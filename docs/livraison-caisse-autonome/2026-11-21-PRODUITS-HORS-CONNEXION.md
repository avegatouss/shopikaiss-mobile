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

## Suite de préparation

Le lot B `ab2faff` est fusionné sans conflit (`cecac88`). Le panneau
`CatalogueChangesPanel` affiche les états et motifs et propose l'ouverture de
l'arbitrage web si l'appelant fournit cette action. Il ne réémet aucune mutation.
Deux tests supplémentaires couvrent l'état vide et le conflit sur écran étroit.
Les deux composants restent non raccordés au catalogue : champs complémentaires,
droits, stockage et réconciliation restent dépendants du contrat A et du moteur B.

Veille locale : `tool/windows/Watch-CatalogueCoordination.ps1`, toutes les cinq
minutes pendant cinq heures par défaut. Un mutex empêche deux instances.
`VEILLE-C-CATALOGUE.json` indique le processus et le dernier contrôle ;
`VEILLE-C-CATALOGUE-EVENEMENTS.jsonl` enregistre les changements détectés.
Créer `VEILLE-C-CATALOGUE.stop` dans le dossier de coordination arrête la veille.
Elle lit uniquement les notes de coordination, ne fusionne rien et ne réveille
pas une session Codex : une nouvelle publication demande une relecture par C.

## Contrat A détecté pendant la préparation

Le commit A `c87b57c1` publie maintenant le lot 10. Le constat d'absence de contrat
ci-dessus décrit le contrôle initial et est remplacé par cette publication.
Le formulaire est adapté : nom 160 caractères, référence 80, cinq codes ASCII
sans espace au maximum, catégorie, prix d'achat facultatif, prix de gros et seuil
à six décimales (normalisé sans calcul flottant), stock illimité ou suivi à zéro.
En édition, codes-barres, coût d'achat et mode de stock restent inchangés : ils ne
font pas partie de `modification_produit`. Aucune quantité de stock n'est saisie.

Le moteur de B reste à livrer : pas de commande de sauvegarde raccordée, pas de
mise en vente de ces fiches, pas d'arbitrage local. Le suivi visuel et le formulaire
sont prêts à recevoir ces commandes ; leur activation n'est pas annoncée.
