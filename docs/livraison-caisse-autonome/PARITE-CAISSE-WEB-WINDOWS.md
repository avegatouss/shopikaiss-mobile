# Parité de la caisse Windows avec la caisse web

## Actualisation du 31 octobre 2026

Le tableau historique ci-dessous décrit le premier lot, pas l'installation actuelle. Filtres, pagination, quantité +/−, clients, remises/livraison/note, paiement multiple déclaré, code responsable, calculatrice, liens web et impression sont raccordés.

Dernier lot C : paniers locaux ET partagés, clôture à l'aveugle, retours espèces avec prévisualisation moteur, journal durable des demandes de clôture/retour et reprise avec le même UUID, badges produits. Recette réelle de ces nouveaux parcours encore ouverte.

À fournir par B : projection du stock après panier et programmation/pause des téléchargements images. À fournir par A/B : tarif gros, autres frais hors livraison, lots/variantes/coffrets et création produit complète, bons/cartes/points/crédit en ligne, journal de caisse/X/historique serveur, paniers de rayon, règles avancées de session/horaires/inactivité. Raccordement C ensuite. Le bouton Reçus actuel n'est pas la file des paniers de rayon.

À qualifier par C avec matériel/serveur de recette : impression papier et tiroir, afficheur selon modèle, latences réelles, reprise après coupure/redémarrage, comparaison native au web. Installation de recette non signée ; aucune validation production ni fusion main.

## Objectif demandé

Même disposition, mêmes parcours, mêmes options et mêmes droits que la caisse web. Seuls le stockage local et la synchronisation changent. Une fonction absente du moteur n'est ni supprimée du périmètre ni remplacée par un bouton factice. La caisse Windows n'est pas prête pour la production tant que cette parité et la recette v2 ne sont pas démontrées.

Référence lue : web-autonome, commit 217ad22b, `resources/views/livewire/pos/register.blade.php`, partials caisse-barre-actions, caisse-outils, caisse-panier, caisse-totaux, paiement-fenetre, et `resources/css/app.css` (grille 58/42, commandes 40 px, densité tactile). Moteur B disponible : cb10844. Les modifications non commitées de B ne sont pas intégrées.

## État par parcours

| Parcours web | Windows après ce lot | Dépendance restante |
|---|---|---|
| Catalogue à gauche, panier à droite | Grille 58/42, catalogue densifié | Vérification visuelle native côte à côte, couleurs/thème boutique |
| Visuelle / Compacte | Deux présentations utilisables | Persistance de préférence et images produit |
| Scan F2 / Ajouter et recherche séparée | Raccordés ; Entrée dans recherche ne scanne plus | Scan caméra, index cartes/bons |
| Catégories, marque, fournisseur | Non exposés | Champs de catalogue et filtres B/A, catalogue au-delà des 60 résultats |
| Produit et conditionnements | Choix unité/conditionnement raccordé | Variantes, lots, coffrets, favoris |
| Panier, quantité, suppression | Raccordés | Boutons +/- via quantité canonique, prix unitaire, alertes stock et autorisation de survente |
| Client de passage / client nommé / création | Non exposés | Commandes clients, soldes, crédit et permissions |
| En attente / Suspendus / Note / Tarif gros | Non exposés | Brouillons multiples durables, réservation, note et tarification B |
| Paiement espèces et moyen unique | Raccordés | Référence des moyens électroniques déclarés |
| Espèces reçues et monnaie | Saisie raccordée, calcul moteur | Réaffichage durable du montant reçu et de la monnaie dans la vue B |
| Paiements multiples, remises et frais | Non exposés | Calculateur partagé, validations de droits, contrat v2 étendu si nécessaire |
| Bons, carte cadeau, points et crédit | Non exposés | Soldes et règles explicites hors connexion, arbitrage serveur |
| Détail HT/TVA et quatre montants paiement | Non exposés dans la vue | Libellés calculés par B, aucun calcul financier dans Flutter |
| Ventes récentes et duplicata | Consultation locale raccordée | Historique serveur, impression et action fin de vente |
| Retours / avoirs | Non exposés | Contrat, autorisations, stock et comptabilité côté A/B |
| Ouverture/clôture, verrou, changement caissier | PIN et connexion présents | Session locale v2, clôture, droits et verrou d'inactivité à qualifier |
| Calculatrice / clavier / plein écran | F2/F4 présents | Outils et autres raccourcis à reprendre après définition des commandes |
| Impression, tiroir, afficheur | Transport impression testé séparément | Configuration et qualification matérielle réelle |

## Demande C → B : C-REQ-005, parité fonctionnelle et v2

Priorité de remise : moteur v2 et vue enrichie, puis panier/session/paiement, puis autres parcours. Conserver le protocole IPC privé, ou versionner explicitement ses ruptures. Ne pas confondre sa version avec celle du réseau.

1. Livrer un SHA intégrable avec l'hôte réellement relié à v2 : appairage, autorisation locale, instantané, journal, couverture des stocks, dépôt/lecture du sort, reprise après interruption. La décision A du 29/10 cible les clients v2 uniquement ; ne pas développer de nouvelle synchronisation v1. Les travaux UI de C réutilisent les commandes privées existantes et ne changent aucun transport réseau.
2. Fournir une vue de capacités par opérateur/boutique : autorisé, motif de refus, besoin réseau et fraîcheur requise. Les contrôles sont répétés au moment de l'exécution, pas seulement dans l'écran. Thème, session et caissier viennent du référentiel réel.
3. Enrichir la vue : catégories/marque/fournisseur, images/variantes/conditionnements/lots ; quantité canonique et prix unitaire ; détails HT/TVA/remises/frais ; paiement affecté/restant/monnaie ; montant reçu et moyen sélectionné. Les montants sont calculés par le moteur et rendus sous forme de libellés. Ne pas laisser Flutter reconstruire les taxes ou soldes.
4. Exposer les commandes de brouillon : client, note, tarif gros, remise de ligne/globale selon droits, frais, suspension/reprise/liste. Définir les identifiants durables et la consommation atomique d'un panier repris. Reprise après crash obligatoire, aucun double encaissement.
5. Exposer préparation/édition de plusieurs paiements avec montant, espèces reçues, référence, crédit autorisé et règles d'arrondi. Édition invalide = validation désactivée, sans réutiliser silencieusement un ancien paiement valide. L'intention reste journalisée avant encaissement ; une issue inconnue reste à vérifier avec le même UUID.
6. Exposer ouverture/clôture de session v2, verrouillage/déverrouillage et changement de caissier ; définir l'effet sur le panier et sur un encaissement incertain. Une session d'un autre terminal n'est jamais prise comme session locale.
7. Pour retours, cartes/bons/points, création client/produit, coffrets et survente : fournir contrats et politiques avec A avant implémentation. Distinguer disponibilité hors connexion et impossibilité de garantir un solde partagé ; ne pas inventer d'autorisation. Chaque opération nécessite idempotence, piste d'audit et arbitrage approprié.

C possède uniquement l'interface Windows, l'adaptation IPC, le journal d'intention et l'installation. B garde le stockage, les règles de vente et le moteur partagé ; A garde les règles serveur et les contrats réseau. Ce document est une remise à transmettre aux sessions ; aucun message externe n'a été envoyé automatiquement.

## Recette de parité exigée

Comparer sur la même boutique, les mêmes droits et les mêmes produits : 1366×768 et 1280×800, zoom/accessibilité, vue visuelle/compacte, panier long et paiement avec erreurs. Tester chaque ligne du tableau en ligne, hors connexion, après redémarrage et après resynchronisation lorsque le parcours l'autorise. Refus explicite lorsque le réseau est indispensable, panier conservé. Vérifier les droits retirés, la politique expirée, les prix modifiés, le stock couvrant la vente, la TVA, les doubles tentatives et l'impression perdue. Pas de validation globale sur la seule base d'une vente espèces réussie.

## Lot C du 29/10 — validation

45/45 tests Windows passent ; analyse Dart sans anomalie. Deux nouveaux tests vérifient la séparation recherche/scan et le choix de conditionnement dans la vue compacte, puis la désactivation de la confirmation après édition des espèces reçues jusqu'à validation moteur. Les calculs financiers restent dans B. Aucun fichier moteur B, serveur A, dépendance Android ou clé de signature modifié. La comparaison native visuelle et la parité complète restent à faire ; ces tests ne les remplacent pas.
