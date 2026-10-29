# Préparation client, remise globale et frais

Le panneau « Client, remise et frais · aperçu » prépare les zones sans modifier une vente. Les champs sont désactivés tant que le contrat moteur correspondant n’est pas livré. Les remises de ligne existantes restent opérationnelles.

## Raccordement attendu avec A/B

- Client : recherche locale par nom/téléphone dans la boutique, pagination, sélection par identifiant stable, client de passage, retrait de sélection. Création hors connexion avec identifiant provisoire stable et synchronisation idempotente. Aucun solde de crédit déduit par Windows.
- Remise globale : modes autorisés montant/pourcentage, motif si requis, plafond selon rôle, cumul avec remise de ligne et ordre de calcul identiques au web. B renvoie les montants, le refus éventuel et les totaux ; C ne calcule pas les taxes ou arrondis.
- Frais : types et libellés autorisés par boutique, montant, règles fiscales et permissions ; ajout/modification/retrait par commande moteur. Aucun frais arbitraire ajouté seulement à l’écran.
- Note : limites de longueur et destination (interne/ticket) explicites.
- Après modification : invalider tout paiement préparé, restituer les totaux moteur, conserver client/remise/frais/note dans le panier durable et les paniers suspendus, puis figer dans la vente idempotente.

## Recette de raccordement

Retrouver les données après redémarrage ; reprise de panier ; changement de client ; refus de droits retirés ; remise trop élevée ou devenue excessive après retrait de ligne ; taxes et frais selon ordre web ; réponse perdue sans double mutation ; création client hors connexion et correspondance serveur ; ticket et historique cohérents avec la vente enregistrée.

## Réglages locaux déjà préparés

Palette parmi vert/bleu/prune/terracotta ; disposition de photo gauche/haut/masquée ; image entière ou remplissage du cadre. Les préférences restent propres au poste. La disposition s’applique aux emplacements ; le choix de recadrage est mémorisé pour le futur rendu des photos locales, sans téléchargement réseau. Les couleurs d’alerte gardent leur sens.
