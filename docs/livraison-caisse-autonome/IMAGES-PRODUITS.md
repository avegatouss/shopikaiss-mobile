# Images locales sans ralentir la caisse

Demande du responsable : récupérer les images par lots, de préférence la nuit ; ne pas recharger des images inchangées en journée.

## État

Le contrat du moteur actuel ne fournit pas encore les images. Le panneau d’écran l’indique ; aucun téléchargement fictif ni appel réseau par fiche produit n’est ajouté. Ce document décrit le raccordement à livrer avec A et B.

## Contrat demandé à A et B

- A publie pour chaque image l’identifiant produit, une version ou empreinte stable, la taille, le type et une référence de téléchargement autorisée. Les suppressions d’image sont explicites. Les liens temporaires peuvent être renouvelés sans changer la version de l’image.
- B conserve ce manifeste avec le catalogue et expose à C les références locales disponibles, ainsi que le progrès et les erreurs du téléchargement. Le téléchargement ne bloque ni les commandes de vente, ni les synchronisations de stock et de ventes.
- Le cache est isolé par entreprise/boutique ; aucun secret ni URL signée ne figure dans les journaux.

## Planification proposée

- Plage locale par défaut : 01 h–05 h, configurable par poste ; le PC doit être allumé et le moteur actif. Aucun réveil du poste ni service permanent implicite.
- Lots de 20 images, un seul transfert à la fois, limite de débit et budget disque configurables. Priorité aux ventes, au stock et aux politiques ; pause en cas d’activité caisse ou à la fin de la plage.
- Si le poste est éteint la nuit : reprise à la prochaine plage, ou commande explicite « Télécharger les images maintenant » hors affluence. Aucun rattrapage massif automatique au démarrage en journée.
- Premier chargement : produits visibles sans photo immédiatement ; pictogramme en attendant le cache. Une image absente n’empêche jamais d’ajouter, payer ou imprimer une vente.
- Comparer les versions du manifeste : télécharger seulement les nouveautés et modifications. Conserver l’ancienne image jusqu’à réception complète et validation de la nouvelle.
- Fichier temporaire, contrôle taille/type/empreinte puis remplacement atomique ; délais bornés, reprise et attente croissante après erreur. Les réponses HTML/erreurs ne deviennent jamais des images.
- Le catalogue affiche les fichiers locaux uniquement. Aucune requête réseau déclenchée par le défilement, l’ajout au panier ou l’ouverture du paiement.

## Recette attendue

Vente fluide pendant un transfert ; aucune requête image en journée par défaut ; deuxième nuit sans changement = zéro image retéléchargée ; reprise après panne ; remplacement d’une seule image ; image corrompue rejetée ; suppression ; disque plein ; changement de boutique ; poste éteint toute la nuit ; pause à 05 h et reprise du lot suivant sans doublon.

Les horaires et quotas ci-dessus sont des valeurs proposées, pas des réglages déjà actifs. Le panneau d’affichage livré ne prétend pas démarrer ce service tant que le manifeste et le cache ne sont pas raccordés.
