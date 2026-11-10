# Impression Windows — ESC/POS et secours PDF

Version du 10 novembre 2026. Dans Réglages de l'écran, choisir l'imprimante de caisse (POS-80 sur ce poste), puis « Mode d'impression : caisse ou A4 ».

- **Caisse : ESC/POS brut**, mode par défaut, y compris pour une ancienne configuration sans mode enregistré. Le ticket est envoyé au spouleur Windows en datatype RAW avec les commandes ESC/POS, sans mise en page PDF ni feuille de 297 mm. L'imprimante doit comprendre ESC/POS. La coupe reçoit 3 lignes d'avance (2 si le ticket moteur est compact). Aucun ordre d'ouverture du tiroir.
- **PDF rouleau par pilote**, mode de secours explicite. Largeur 80 mm et hauteur mesurée suivant le contenu. Les documents longs sont découpés en sections de 40 lignes sources, sans suppression de contenu. Régler le pilote en rouleau 80 mm et coupe en fin de document ; éviter une feuille forcée 80 x 297 mm.
- **PDF A4 par pilote**, pour une imprimante bureautique. Ce mode envoie le ticket sur du papier A4 ; il ne transforme pas le ticket en facture A4 commerciale.

Le secours PDF automatique peut être désactivé. Il n'est autorisé que si le chemin RAW confirme qu'aucune donnée du ticket n'a été envoyée (échec d'ouverture ou de démarrage du document). Après WritePrinter, une écriture partielle, une réponse perdue ou un délai dépassé, le résultat est incertain : aucun second envoi automatique. Vérifier papier et file Windows avant un duplicata. Un travail accepté par le spouleur ne prouve pas la sortie papier ; une imprimante éteinte peut conserver un travail en attente.

Les appels du spouleur s'exécutent dans un worker natif séparé de l'interface, avec résultat interrogé sans bloquer la caisse. Délai d'attente écran de 30 secondes, jusqu'à quatre travaux natifs pendants. Le travail Windows peut continuer après le délai ; il n'est pas relancé. Aucun changement de l'imprimante par défaut du système, aucun shell ni dépendance supplémentaire.

## Ticket d'essai

Dans les réglages, « Imprimer un ticket d'essai (aucune vente) » imprime SHOPIKAISS - TEST / AUCUNE VENTE, une ligne de contrôle et une dernière ligne avant la coupe. Le bouton est désactivé pendant l'envoi. Aucune session, aucun stock et aucune vente ne sont modifiés. Tester à l'installation puis après un changement de pilote ou d'imprimante.

Recette matérielle encore nécessaire lorsque POS-80 sera connectée : lisibilité, largeur, coupe après la dernière ligne, ticket long, duplicata, bon de retour et Z. Aucun ticket physique n'a été envoyé pendant le développement.

Référence technique : https://learn.microsoft.com/windows/win32/printdocs/writeprinter (API potentiellement bloquante, RAW décrit le travail dans le langage compris par l'imprimante).
