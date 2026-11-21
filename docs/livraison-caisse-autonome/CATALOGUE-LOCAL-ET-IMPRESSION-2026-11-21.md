# Catalogue local et impression après encaissement — Windows

## Catalogue hors connexion (contrat 2.1 lot 10)

Le moteur B `32264d0` est fusionné. Le menu de caisse propose « Nouveau produit hors connexion » quand la capacité et le droit du caissier l'autorisent. Un appui long sur un produit ouvre sa fiche ; en présentation liste, un bouton crayon offre aussi cet accès. « Produits créés ou modifiés ici » présente l'état des demandes et ouvre l'arbitrage web si nécessaire.

Les cinq commandes `catalogueForm`, `productForEdit`, `createProduct`, `updateProduct` et `catalogueChanges` passent par le moteur. Les champs modifiables, les prix, les droits, les correspondances et la synchronisation suivent le contrat de A. Les codes-barres, le coût d'achat et le mode de stock ne sont pas modifiables sur une fiche existante. Le stock initial d'un nouveau produit suivi reste nul.

Avant envoi, Windows conserve l'identifiant et les arguments dans `pending-catalogue-v1.json`, à côté de la base du site. Après réponse perdue, il reprend exactement la même demande avec le même caissier. Un changement de site est bloqué tant que cette demande reste incertaine.

Extension compatible du moteur commun : `updateProduct(expected: ...)` et `expected_fields` facultatif dans l'adaptateur. Pour chaque champ changé, Windows envoie la valeur de la fiche ouverte. Le moteur vérifie atomiquement qu'elle est toujours courante, après vérification du rejeu idempotent. Sinon, `produit_modifie_depuis_lecture` demande de rouvrir la fiche. Aucun prix n'est recalculé par Windows.

Les nouvelles fonctions ne s'activent sur un terminal que lorsque le serveur accorde les capacités et droits correspondants. Le lot serveur de A n'est pas déployé par cette livraison Windows.

## Impression automatique

Le réglage « automatique » supprime la demande de confirmation. Le mode avec confirmation conserve le choix du caissier.

- Paiement simple : le déclenchement existant est conservé.
- Paiement par pass : ajout du déclenchement manquant après validation.
- Paiement multiple : ajout du déclenchement manquant après fermeture des deux fenêtres ; un ticket pour la vente complète, pas un ticket par moyen.
- Restaurant : le règlement respecte désormais le même réglage, alors qu'il demandait toujours une confirmation.

Le ticket en attente est consommé avant l'appel d'impression. Une panne d'imprimante ne réencaisse pas le panier et ne déclenche pas de réimpression automatique. Une vente au résultat incertain doit être vérifiée ; aucune impression n'est lancée sur la seule présomption de succès. La quantité d'exemplaires configurée dans l'impression reste inchangée.

## Vérifications et limites

Tests dédiés : reprise catalogue après réponse perdue, blocage de changement de site, rejet définitif, protection contre une modification concurrente, formulaire à 800 × 600, paiements simples/pass/multiples, un seul dispatch, échec imprimante sans nouvelle vente, fermeture des fenêtres avant confirmation d'impression. Capture du formulaire sous `build/visual-checks/catalogue-800x600.png`.

Aucun ticket physique ni opération sur serveur réel n'est réalisé par ces tests. L'essai papier POS-80 reste à faire lorsque l'imprimante sera connectée.

Le contrat A de modification de ticket après encaissement (lot 11) est reçu ; le raccordement Windows attend la livraison des commandes du moteur B. Il ne fait pas partie de ce lot.
