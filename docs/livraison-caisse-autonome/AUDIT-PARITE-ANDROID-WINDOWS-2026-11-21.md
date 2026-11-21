# Écarts Android / Windows — revue du 21 novembre 2026

## Mise à jour C — chantier restaurant intégré

Les sections suivantes conservent l'inventaire initial comme référence ; leurs mentions « à faire » décrivent l'état avant ce chantier. Le présent état les remplace pour C01 à C18.

- Moteur B intégré : `1bd1cd1`, puis `722813a` (documents de clôture durables et repli du démarrage web), et `e672360` (interface Android : paiement, afficheur, raccourcis).
- C01–C17 : parcours raccordés dans Windows. Activation annoncée par le terminal de recette, sous contrôle de l'activation serveur. Les 34 commandes restaurant du protocole ont un appelant ; ce comptage ne remplace pas une recette métier.
- C18 : cache d'édition remplacé par les commandes durables `closureDocument` et `recordEdition` de B. Journal Windows par profil avant impression ; confirmation rejouée avec le même identifiant après perte de réponse. Une impression interrompue demande une vérification humaine et n'est jamais relancée automatiquement.
- Les 18 observations de B sont traitées dans le code : résultats incertains et reprise durable, règlement des tables, annulations/offerts/remises, bons à vérifier et duplicatas, Z original, brouillon groupé, lignes envoyées protégées, commentaires/conditionnements, imprimantes, transferts/fusions/déplacements, couverts/serveur/client, largeur 58/80 mm, résumé serveur, taille de réponse et rafraîchissement.
- Les résultats d'impression cuisine/bar sont conservés avant acquittement. Leur reprise confirme le résultat connu sans renvoyer le bon.
- Paiements mixtes sur lignes compactes, montants rapides espèces, catalogue restaurant paginé sans modifier les filtres de la vente classique. Les calculs et autorisations restent dans le moteur de B.

Validation du premier lot : 549 tests locaux réussis, 3 tests natifs réussis, analyse sans anomalie. Après le complément durable de B : 567 tests réussis, analyse propre. Le lot Android ultérieur est vérifié par sa suite ciblée ; résultat et référence installée consignés dans le journal commun de livraison. Aucun essai de service de table contre un serveur réel, ni essai physique POS-80, ne sont revendiqués.

Éléments encore nécessaires hors C : terminal de démonstration réservé pour la recette restaurant ; imprimante POS-80 connectée et retour papier ; matériel d'affichage pour la recette physique ; contrats A/B pour le prix manuel et l'autorisation de survente. Les écarts côté Android et les autres contrats serveur de l'inventaire initial restent à leurs responsables. Aucune activation restaurant de TBC n'a été modifiée.

## Inventaire initial conservé

## Périmètre et preuve

Comparaison du code local de B (`shopikaiss-mobile`, `5a02990`) avec C (`_wt/windows-engine-integration`, `1c65ce9`), des écrans natifs, commandes du moteur, intégrations matérielles et journal commun. Windows installé : `1c65ce9503ab`, confirmé par le raccourci du bureau. APK disponible : `essai-telephone/shopikaiss-5a02990.apk` ; installation sur les téléphones non vérifiée.

Il s'agit d'une revue statique des différences et des parcours, pas d'une certification exhaustive sans défaut ni d'une recette sur appareil. « Présent » signifie code raccordé, pas essai réel réussi. Aucune vente ni modification de configuration métier pendant cet audit. Le contenu web distant affiché dans Android n'est pas assimilé aux fonctions natives hors ligne.

Le diff de tous les fichiers `lib` et `android` entre les deux références ne contient, hors Windows, que trois fichiers métier modifiés par `5a02990` : `offline/caisse_engine.dart`, `offline/x_z_report.dart`, `sync_v2/v2_engine.dart`. Le reste du moteur et du code Android est identique entre ces références. Cela ne signifie pas que Windows affiche tous les écrans Android : les points d'entrée sont distincts. B possède une modification non commitée dans `analysis_options.yaml`, sans modification métier constatée ; elle n'a pas été reprise.

## Conclusion

Les versions ne sont pas identiques fonctionnellement. Le moteur B est intégré jusqu'à `aad6efd`, avec un correctif ultérieur à reprendre. L'écart principal est le raccordement de l'interface restaurant Windows : B a déjà livré les commandes nécessaires. L'activation restaurant Windows reste désactivée par défaut ; la présence des nouveaux écrans dans le code ne les rend donc pas disponibles sur un terminal standard.

## 1. Travaux restant chez C

| ID | Sujet | Android B | Windows C / travail restant | Priorité |
| --- | --- | --- | --- | --- |
| C01 | Dernier moteur | `5a02990` | Intégrer ce commit : identification des espèces par le booléen publié, y compris moyens non locaux ; pied des documents « Ventes de ce terminal seulement… ». Recompiler et remplacer l'installation ensuite. | Haute |
| C02 | Activation restaurant | `terminal_session.dart:58` annonce la capacité | `engine_host.dart` ne passe pas `announceRestaurant:true`. Activer seulement après raccordement des parcours nécessaires et recette. | Bloquante |
| C03 | Entrée après PIN | Android choisit Salle/Commandes selon profil | Windows ne possède pas le même aiguillage restaurant complet après connexion. | Haute |
| C04 | Encaissement restaurant | Total, articles, parts ; paiement mixte ; vente entièrement offerte | Pas d'appel UI à `restoPrepareSettlement`, `restoSettle`, `restoClose`. Ajouter écran, intention durable, traitement des réponses perdues, impression et reprise. Le paiement de la caisse classique ne remplace pas ce parcours. | Bloquante |
| C05 | Profil restaurant / canaux | Écran de commandes, ouverture sur canal, client | Windows ouvre une table uniquement ; pas de `restoOpenOnChannel`. | Haute |
| C06 | Transfert / partage de commande | Transférer table, déplacer lignes, fusionner | Commandes livrées mais aucun appel UI C à `restoTransfer`, `restoMoveLines`, `restoMerge`. | Haute |
| C07 | Annulations et responsable | Annuler ligne envoyée ou commande avec motif et autorisation | Pas d'écran relié à `restoApprovalInfo`, `restoCancelLine`, `restoCancel`. | Haute |
| C08 | Offerts / remises restaurant | Offert, remise ligne/commande avec plafonds | Pas de `restoOffer`, `restoDiscountLine`, `restoDiscountOrder` dans les écrans C. | Haute |
| C09 | Personnel / remise client | Tarif personnel et validation remise client | Pas de `restoStaffLines`, `restoValidateCustomer`. Promotions automatiques présentes dans le moteur, mais cela ne couvre pas ces commandes manuelles. | Haute |
| C10 | Couverts / serveur / client | Sélection client, modification couverts et serveur | C demande les couverts à l'ouverture ; pas de modification après ouverture (`restoCoversAndServer`) ni sélection de client dans ce parcours. | Moyenne |
| C11 | Saisie restaurant | Conditionnements, commentaires de ligne, édition de brouillon | C ajoute le produit et modifie la quantité ; reprendre conditionnements, commentaires et suppression explicite des lignes non envoyées. | Haute |
| C12 | Navigation carte | Puces ou dossiers selon `restaurant.interface` | C lit couverts/libellé d'envoi mais pas la navigation carte. Ajouter catégories/dossiers ; familles restent une limite serveur. | Moyenne |
| C13 | Registre restaurant | Consultation, ouverture/clôture de journée | Pas d'appels UI `restoRegister`, `restoRegisterOpen/Close`. À distinguer de la session de caisse classique déjà disponible. | Haute |
| C14 | Remboursement restaurant | Liste ventes réglées, aperçu, remboursement / annulation | Pas de `restoSettledSales`, `restoRefundPreview`, `restoRefund` dans les écrans C. Les retours de vente classique ne suffisent pas. | Haute |
| C15 | Bons incertains et duplicata | Liste, vérification manuelle, duplicata motivé | Le consommateur d'impression C existe mais pas les écrans `restoTickets`, `restoVerifyTicket`, `restoDuplicateTicket`. | Bloquante pour exploitation production |
| C16 | Imprimantes de production | Écran de configuration des adresses de postes | Pas d'appel UI `restoSetPrinterAddress`. L'imprimante générale du poste Windows reste configurable. | Haute |
| C17 | Erreurs file d'impression | Liste de bons sur Android | `ProductionQueue.error` contient un message renvoyant à une liste de bons, mais cette liste manque et cette erreur n'est pas affichée par le bootstrap. Afficher l'alerte et un accès opérateur. | Haute |
| C18 | Audit éditions Z | Appel direct `recordEdition` sur Android | C conserve les jetons d'édition en mémoire entre rendu et acquittement : un redémarrage peut perdre cet audit. Prévoir persistance et statut d'impression explicite. | Moyenne |

Preuves principales C (chemins relatifs à ce dépôt) : `lib/src/windows/host/engine_host.dart`, `ipc/protocol.dart`, `ipc/b_engine_adapter.dart`, `presentation/restaurant_dialog.dart`, `presentation/restaurant_order.dart`, `presentation/restaurant_workspace.dart`, `platform/production_queue.dart`, `presentation/bootstrap.dart`, `presentation/cash_documents.dart`.

Preuves B (dans `C:/laragon/www/shopikaiss-mobile/lib/src`) : `offline/restaurant_screen.dart` (transfert 1042, envoi 1061, annulation 1093, remises 1120–1244, déplacement/fusion 1268–1334, paiement 1439, carte 1743), `offline/restaurant_production_screen.dart` (client 268, registre 410, remboursements 635), `register/register_adapter_resto.dart`, `terminal/terminal_session.dart`.

### Mesure du raccordement restaurant C

34 noms `resto*` sont déclarés dans `HostCommand`. La recherche de leurs appels dans l'ensemble de `presentation` et `platform` trouve 8 noms : `restoOrder`, `restoOpen`, `restoEditLines`, `restoSend`, `restoPrebill`, `restoPrintJobs`, `restoPrintStart`, `restoPrintResult`. **26 commandes n'ont pas d'appel à ces endroits**. Ce nombre mesure des points de raccordement, pas 26 fonctionnalités indépendantes. Le relais moteur est déjà présent.

Noms non appelés : `restoTickets`, `restoRegister`, `restoSettledSales`, `restoApprovalInfo`, `restoRefundPreview`, `restoPrepareSettlement`, `restoOpenOnChannel`, `restoStaffLines`, `restoTransfer`, `restoMoveLines`, `restoMerge`, `restoCoversAndServer`, `restoValidateCustomer`, `restoCancelLine`, `restoCancel`, `restoOffer`, `restoDiscountLine`, `restoDiscountOrder`, `restoSettle`, `restoClose`, `restoRegisterOpen`, `restoRegisterClose`, `restoRefund`, `restoVerifyTicket`, `restoDuplicateTicket`, `restoSetPrinterAddress`.

## 2. Écarts côté B ou entre les deux interfaces

| ID | Sujet | Constat vérifié | Responsable / action |
| --- | --- | --- | --- |
| B01 | Paiement compact | Windows dispose de lignes moyen/montant/référence et de répartition sur deux moyens ; Android `_PaymentDialog` saisit un paiement à la fois dans un formulaire vertical puis l'ajoute à une liste. Le restant est bien prérempli sur Android (`_reset`). | B : aligner l'ergonomie sur tablette/terminal ; conserver une variante téléphone. |
| B02 | Adresse de démarrage | C utilise `/caisse/demarrer`. `app_settings.dart:180` de B normalise encore une origine sans chemin vers `/caisse`. Une URL complète configurée peut toutefois déjà utiliser la nouvelle route. | B : aligner défaut et migration prudente des anciennes URL. |
| B03 | Afficheur hors ligne | C pousse le panier local vers `CustomerDisplayService`. Android a un contrôleur de second écran web, branché depuis `web/caisse_page.dart`. Aucun raccord à ce contrôleur trouvé dans `offline_register_page.dart`. | B : vérifier puis raccorder l'affichage natif hors ligne. Ne pas annoncer « aucun afficheur Android » : l'afficheur web existe. |
| B04 | Raccourcis clavier | C déclare F1/F2/F4/F8/F11 et Ctrl+F via `CallbackShortcuts`. Pas de mécanisme équivalent trouvé dans la caisse native Android ; clavier/douchette restent pris en charge. | B si parité sur terminaux Android avec clavier physique souhaitée. |
| B05 | Présentation initiale | Même palette et taille 175. C : image à gauche, image entière (`contain`), partage catalogue en %. B : image au-dessus, recadrée (`cover`), largeur panier 380. | C/B : choisir des défauts communs ; adaptation téléphone volontaire possible. |
| B06 | Copie du code Windows chez B | B n'a pas les derniers fichiers C : file de production, écrans restaurant C, raccord Z, route de démarrage et ajustements paiement. Android n'en utilise pas automatiquement tous les fichiers. | Intégration commune : fusionner les branches, sans écraser la branche C par la copie Windows plus ancienne de B. |
| B07 | Matériel | Android possède Sunmi, USB, Bluetooth, série ; Windows spooler RAW/PDF, réseau et afficheur Windows/série. | Différence de plateforme attendue, pas obligation de copier chaque pilote. Tester les mêmes résultats métier : ticket, coupe, tiroir, affichage. |
| B08 | Navigation web | Android utilise une WebView interne ; C ouvre les destinations web du poste. | Différence de parcours à garder explicite ; les opérations web ne prouvent pas la parité native hors ligne. |

## 3. Limites communes et dépendances A

| ID | Sujet | État et action |
| --- | --- | --- |
| A01 | Code responsable pour stock insuffisant | Non finalisé dans les ventes natives classiques des deux côtés : `SaleApproval.toJson()` publie uniquement `type: remise` (`offline/models.dart`), et l'écran demande `authorizeDiscount`. L'alerte stock dit pourtant qu'une autorisation est possible (`offline/web_rules.dart:239`). Ne pas confondre les autorisations restaurant avec la survente classique. A/B doivent confirmer le contrat et fournir le parcours ; C doit ensuite le raccorder. Aucun contournement du refus strict. |
| A02 | Prix manuel autorisé | Aucun parcours d'autorisation dédié constaté dans les écrans natifs classiques examinés. À cadrer avec A/B avant promesse de parité avec le web. |
| A03 | Rapport complet de boutique | Le moteur local ne connaît pas toutes les ventes web d'une même session ni les anciennes ventes perdues lors d'une réinstallation. A accepte la limite : Z serveur fait foi. C doit prendre le pied explicatif de `5a02990`. |
| A04 | Familles | Familles de rapports non publiées aux terminaux. Android remplace navigation familles par dossiers de catégories ; C doit au moins gérer cette navigation. Z familles complet dépend de A. |
| A05 | Plafonds restaurant | Plafonds spécifiques de remise et plafond remboursement assistant non publiés ; contrôle serveur peut produire un arbitrage. A accepte les défauts actuels pour TBC, pas une identité universelle de réglages. |
| A06 | Égalité promotions | Pas d'ancienneté web publiée : départage local peut diverger à égalité de priorité/remise. A annonce une publication future ; pas de cas égal chez TBC selon son message, non revérifié en base. |
| A07 | Droit annulation | Non publié : responsable systématiquement demandé, accepté par A. |
| A08 | Annuler après remboursement partiel | Refus hors ligne accepté par A ; traitement en ligne. |
| A09 | Remboursement et stock restaurant | Ne réajuste pas le stock, confirmé voulu par A ; ce n'est pas un défaut d'intégration C/B. |
| A10 | Écran de production | Le contrat moteur prévoit `restoStationScreen`. Aucun raccord matériel de poste de production confirmé dans les points d'entrée inspectés. À distinguer de l'afficheur client. Recette dédiée nécessaire avant utilisation. |

Source des décisions A : `C:/laragon/www/_coordination/caisse-autonome/JOURNAL.md`, réponses 6–19 du 19 novembre. Ces indications ne remplacent pas une vérification du déploiement actuel du serveur.

## 4. Fonctions classiques présentes des deux côtés

Les fonctions suivantes ont des parcours dans `offline/offline_register_page.dart` chez B et dans `windows/presentation` chez C. Elles ne sont donc plus à déclarer « en attente de B » :

- catalogue, recherche, catégories, marque/fournisseur avec recherche, chargement supplémentaire ;
- panier, quantités, suppression, lots et conditionnements, tarif gros ;
- création et recherche client, client de passage ;
- remises ligne et globale, frais de livraison, note ;
- code responsable pour **remise** et plafonds ;
- paiements déclaratifs hors ligne, plusieurs moyens, référence, arrondi espèces et monnaie ;
- pass, paniers suspendus et paniers partagés ;
- historique, retours classiques, reçu et réimpression ;
- ouverture/clôture de session classique, documents pré-X/pré-Z/Z (avec le correctif manquant C01) ;
- alertes stock indicatives, images locales et plage horaire de téléchargement ;
- palette, disposition/taille des produits et calculatrice (Android importe même `DeskCalculator` de Windows) ;
- synchronisation, file persistante et arbitrages via le moteur commun.

« Présent des deux côtés » ne veut pas dire interfaces identiques, droits identiques dans chaque boutique, ni recette matérielle effectuée. Les différences de paiement, afficheur, restaurant et code stock restent celles listées plus haut.

## 5. Validation et ordre de travail

Dernière installation C : 537 tests locaux, 3 tests natifs, analyse propre et démarrage masqué réussis le 19/11. Ces résultats sont historiques, pas une nouvelle exécution complète le 21/11. Les 524 tests B sont un résultat annoncé par B au journal, non une suite complète relancée lors de cette revue. Ce 21/11, `flutter test --no-pub test/z_local_test.dart` dans le dépôt B : **17 tests réussis**, journal `C:/laragon/www/shopikaiss-mobile/z-audit-20261121.log`.

Recettes manquantes : serveur de démo bout en bout, paiement restaurant et reprise après coupure, caisse maîtresse, papier/coupe/tiroir POS-80, second écran et afficheur série, vrai téléphone, pertes de connexion et doublons de bons. Aucune preuve nouvelle d'installation APK sur appareil ou de recette papier n'a été trouvée dans les derniers messages lus.

Ordre proposé : (1) C01 correctif moteur et tests Z ; (2) C04 encaissement restaurant durable ; (3) C15–C17 supervision impression et configuration ; (4) C05–C14 autres parcours restaurant ; (5) C02/C03 activation et démarrage après recette ; (6) alignements B01–B05 et décision A/B sur A01/A02. Une compilation seule ne clôture aucun de ces parcours.

Cet audit n'a ni fusionné `5a02990`, ni modifié l'installation, ni activé le restaurant. Il fournit les écarts avant travaux.
