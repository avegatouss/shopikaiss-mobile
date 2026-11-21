# Paniers successifs, logo et connexion — 21 novembre 2026

- V2Engine filtrait mal les brouillons : les marqueurs v2 de consommation n'étaient pas consultés par openDrafts/saveDraft hérités. Un panier encaissé pouvait être restauré au redémarrage, puis refusé. Les deux méthodes consultent désormais les marqueurs v2 sous la file sérialisée. Les anciennes données restent conservées ; aucune vente n'est effacée. Les UUID historiques convertis en v5 sont aussi reconnus.
- Une réconciliation confirmée retire de l'écran le panier consommé, sans toucher à un nouveau panier sauvegardé. Rejouer la même opération demeure idempotent ; encaisser deux nouveaux paniers identiques reste permis.
- preparePayment rend un avertissement non bloquant si la dernière vente contient les mêmes produits, conditionnements et quantités (ordre des lignes indifférent). Il disparaît si une autre composition a été vendue entre les deux. Les prix et droits restent contrôlés par le moteur.
- Le choix Espèces dans le paiement simple préremplit cash_due calculé par le moteur. La saisie reste modifiable et effaçable pour indiquer l'argent reçu.
- La connexion affiche SHOPIKAISS_BUILD_VERSION, identique au repère de compilation des réglages.
- Le logo réel stocké était un PNG grayscale uint1 : alpha 1 divisé par 255 produisait zéro point noir. Conversion RGBA uint8 avant raster et à l'import ; les logos déjà stockés fonctionnent sans réimport. Contrôle du fichier local TBC : 12 928 points noirs après correction contre zéro avant. Aucun chemin ni logo TBC ajouté par défaut au logiciel.

Tests ajoutés : paniers identiques successifs et intercalés, reprise après redémarrage, refus de réécriture d'un panier consommé, réconciliation conservant un nouveau panier, logo 1 bit avec fond blanc, préremplissage espèces. Aucun essai serveur réel ni impression papier dans ce lot.
