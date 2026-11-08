# Impression Windows sur rouleau — 8 novembre 2026

La caisse imprime ses tickets, duplicatas, bons de retour et Z par PDF via le pilote Windows. Le format produit est large de 80 mm ; sa hauteur suit le contenu. Les documents longs sont découpés en sections de 40 lignes sources, sans suppression de contenu ; les lignes longues se replient. Les modèles personnalisables ticket.modeles ne sont pas encore livrés par le moteur.

Dans Paramètres de la caisse, choisir POS-80 comme imprimante de caisse. Ce choix ne change pas l'imprimante par défaut des autres logiciels Windows. Dans les propriétés du pilote POS-80, choisir le papier rouleau 80 mm et la coupe en fin de document, si le pilote offre ces options. Éviter de forcer une feuille 80 x 297 mm ou une mise à l'échelle A4 : certains pilotes ignorent la hauteur du PDF et ajoutent alors du blanc. Les libellés exacts dépendent du pilote installé.

Recette matérielle à faire quand POS-80 est branchée : ticket test sans vente, article avec nom long/accents, plusieurs articles, duplicata, bon de retour, Z et document long. Vérifier lisibilité, largeur, dernière ligne avant coupe et absence de long blanc. Une transmission acceptée par le pilote ne prouve pas la sortie papier. Après un doute, vérifier le papier et utiliser un duplicata, sans réencaisser.

Aucune modification automatique du pilote, aucune commande envoyée à l'imprimante pendant la compilation. Le test matériel reste à confirmer par le responsable.
