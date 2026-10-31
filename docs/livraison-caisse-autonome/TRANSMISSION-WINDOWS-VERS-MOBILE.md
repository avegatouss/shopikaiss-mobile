# Parité Windows et mobile — transmission de C à B

État au 31 octobre 2026. Destinataire : session B. Branche C : `feat/caisse-windows-raccordement`, worktree `C:/laragon/www/_wt/windows-engine-integration`. Le moteur B `39ec7f1` est intégré par `cf6b5f3`. La dernière installation Windows annoncée est `6157069` ; les modifications suivantes ne sont pas automatiquement installées sur les terminaux.

## Règle commune

Les deux applications doivent proposer les mêmes opérations et messages, avec une disposition adaptée au téléphone ou à la tablette. Réutiliser le moteur commun : aucun calcul fiscal, droit, plafond, arrondi ou contrôle de stock ne doit être réécrit dans l'écran. Une capacité absente doit être expliquée ; un bouton ne prouve pas une fonctionnalité livrée.

Le référentiel complet reste `PARITE-CAISSE-WEB.md` de A. Ce dossier décrit les intégrations de C et les points à reprendre sur mobile ; il ne certifie pas une parité complète avec les 65 fonctions web.

## Catalogue et disposition

| Intégration Windows | Comportement attendu sur mobile |
|---|---|
| Catalogue et panier côte à côte, ratio réglable 45–65 % | Deux colonnes sur tablette ; catalogue/panier accessibles sur téléphone sans réduire les touches |
| Présentation visuelle ou compacte ; taille des produits 150–330 | Réglage persistant adapté à la largeur disponible |
| Couleurs vert, bleu, prune, terre cuite ; boutons arrondis | Reprendre les choix et les logos officiels ; préserver le contraste |
| Images en haut, à gauche ou masquées ; cadrage contain/cover | Même réglage, image issue du cache local uniquement |
| Catégories avec défilement et flèches | Catégorie active visible ; accès aux catégories hors écran |
| Filtres fournisseur et marque avec recherche intégrée | Choix recherchable, filtres cumulables sur tout le catalogue |
| Recherche texte distincte du scan | Entrée dans la recherche ne doit pas devenir un scan accidentel |
| « Afficher plus », pages de 60 produits | Conserver filtres et panier lors du chargement suivant |
| Favori, promotion, nouveauté, stock faible, unités/conditionnements | Afficher les données du moteur sans inventer de prix promotionnel |

Références : `lib/src/windows/presentation/register_app.dart`, `searchable_choice.dart`, `screen_settings.dart`, `product_badges.dart`, `image_schedule.dart`.

Images : `imageSettings` / `setImageSettings` exposent la plage horaire. Le moteur interrompt les téléchargements quand le panier reprend ; la grille ne lance pas de requête réseau à chaque affichage. Montrer un substitut si l'image manque. L'utilisateur peut programmer une plage nocturne ; ce n'est pas une garantie de téléchargement si l'appareil est éteint.

## Panier, clients et remises

| Intégration | Points à préserver |
|---|---|
| Quantité +/−, saisie directe, suppression | Préserver la précision des quantités fractionnaires ; calcul par le moteur |
| Client de passage par défaut | Le bouton ouvre recherche, sélection et création ; remise à zéro vers client de passage |
| Recherche client nom/téléphone | Temporisation 250 ms, ignorer une réponse ancienne ; création avec UUID d'opération |
| Client nouvellement créé | Reste sélectionnable avant son retour dans le journal serveur (`f000212`) |
| Remise de ligne montant ou pourcentage | Le moteur recalcule le pourcentage après changement de quantité |
| Remise globale, livraison, note du ticket | Plafonds et droits du moteur ; livraison hors TVA |
| Client et « Remise et livraison » sur une ligne | Ne pas dupliquer la sélection client dans le panneau des remises |
| Résumé compact | Remise/livraison puis base HT/TVA en deux colonnes, total à payer visible |
| Stock après vente et alerte faible/insuffisant | Lire `stock_after_label` et `stock_alert` ; une alerte informative n'autorise pas la survente |

Références : `customer_picker.dart`, `sale_options_preview.dart`, `quantity_step.dart`, `register_controller.dart`. Commandes : `searchCustomers`, `createCustomer`, `setCustomer` et commandes de remise décrites dans `CONTRAT-MOTEUR-B.md`.

## Paiement et reprise après incident

- Saisie du montant : validation automatique après 250 ms et par Entrée. Les erreurs sont **dans la fenêtre de paiement**, lisibles sans fermer celle-ci.
- Paiements multiples : jusqu'à dix, une seule ligne d'espèces. À l'ajout d'un moyen, proposer le reste à payer ; le moteur valide toujours les montants définitifs.
- Les moyens déclaratifs proposés par `preparePayment` fonctionnent selon la politique reçue, sans exiger une confirmation électronique inexistante. Respecter la référence demandée par le moteur.
- Espèces : afficher montant arrondi et monnaie calculés par le moteur ; conserver le montant exact de la vente.
- Si `discount_approval.required`, demander responsable, code masqué de huit chiffres et motif. Ne jamais journaliser ou conserver ce code. Les plafonds boutique, l'interdiction de s'auto-autoriser et le ralentissement après échecs restent appliqués par le moteur.
- Écrire durablement l'intention et son UUID avant l'encaissement. Une réponse perdue entraîne « résultat inconnu », pas une seconde vente. Consulter localement `saleStatus` et rejouer uniquement le même identifiant.
- Une consultation `not_found` ne libère le panier que conformément au contrat sérialisé derrière les encaissements. Ne pas confondre délai réseau et refus certain.
- Éviter une lecture IPC supplémentaire quand la commande fournit déjà une vue autoritative valide.

Références : `multiple_payments.dart`, `payment_message.dart`, `discount_approval.dart`, `register_controller.dart` et tests `payment_feedback_test.dart`.

## Paniers, sessions, retours et tickets

| Parcours | Implémentation à reproduire |
|---|---|
| Panier courant | Durable après chaque modification ; retiré atomiquement lors de la vente |
| En attente / Suspendus | Boutons sur une ligne ; liste locale **et** partagée, compteur sans doublon |
| Partagés | `resumeShared`, `deleteShared`, confirmation de suppression ; signaler `taken_elsewhere` et besoin de réseau |
| Ouverture | Fond de caisse ; reprendre la session du terminal, pas celle d'un autre terminal de la boutique |
| Session nouvellement ouverte | Ne pas la perdre en attendant le journal (`a846ebd`) |
| Clôture | Panier vide, comptage à l'aveugle espèces/autres moyens, zéros explicites, commentaires/justifications ; aucun attendu révélé |
| Retour | Vente connue du terminal, espèces et quantités résiduelles selon contrat ; aperçu moteur et motif obligatoire |
| Incertitude clôture/retour | Intention durable, UUID et arguments immuables ; reprise avec le même UUID, sans effacer une intention incertaine sur un simple refus |
| Historique / Reçu | Historique local et ticket original par `printTicket`, puis mention REIMPRESSION ; « Reçu » n'est pas la file des paniers de rayon |

Références : `suspended_drafts.dart`, `cash_operations.dart`, `sales_history.dart`. Les correctifs B `7c5af2c`, `a6e3dce`, `f000212`, `a846ebd`, `39ec7f1` sont inclus côté C. Le dernier conserve les capacités 2.1 après redémarrage sans réseau.

## Utilitaires et matériel

- Calculatrice tactile complète : opérations enchaînées, priorités, parenthèses, décimales, pourcentage relatif, signe, correction, mémoire, historique et copie. Elle ne modifie pas le panier. Références : `calculator.dart`, `calculator_engine.dart` ; reprendre le calcul pur plutôt que deux champs de montants.
- Windows : F1 aide, F2 scan, Ctrl+F recherche, F4 paiement, F8 attente, F11 plein écran. Garder des boutons tactiles équivalents sur mobile et les raccourcis si clavier externe.
- Verrouillage, déconnexion et identification PIN restent distincts de la fermeture d'une session de caisse.
- Imprimante Windows par défaut : POS-80. Ticket original et réimpression préparés. **La sortie papier n'est pas validée : imprimante débranchée.** Sur Android, réutiliser les pilotes existants et conserver la signature de l'APK.
- Afficheur Windows : second écran étendu ou USB/série ESC/POS 20×2, désactivé par défaut. Ne pas envoyer de données personnelles du client. Aucun afficheur physique n'a été testé ; les modèles propriétaires/HID restent à qualifier. Sur Android, conserver l'intégration matérielle Android, pas le code Win32.

## Navigateur interne mobile livré avec cette transmission

Nouveaux fichiers : `lib/src/web/shop_browser_page.dart`, `shop_browser_policy.dart`, `test/shop_browser_policy_test.dart`. Entrées ajoutées à `offline_register_page.dart`, dans les menus téléphone et tablette : « Site de la boutique » et « Back-office ».

Le navigateur ouvre `/` ou `/accueil` sur l'origine HTTPS configurée. Il propose retour, suivant, rechargement et retour à la caisse. Le panier local reste dans le moteur. Pendant son ouverture, le retour automatique à la caisse web est suspendu ; la synchronisation n'est pas désactivée.

Cette vue est séparée de `CaissePage` : aucun pont JavaScript d'encaissement, impression ou scan n'est injecté. L'identification web et les droits serveur restent requis. Le cookie d'appareil suit le mécanisme existant, sans être placé dans l'URL. Les liens externes autorisés ouvrent leur application ; les schémas dangereux sont refusés. Un site inaccessible laisse revenir à la caisse. Après une erreur, aucun formulaire n'est automatiquement rejoué.

Le back-office demande Internet. Les téléchargements de documents passent pour l'instant par le navigateur système avec sa propre connexion au site. Les autorisations caméra/micro sont refusées dans cette vue générique. Ce navigateur ne constitue pas une caisse autonome supplémentaire et ne rend pas les opérations administratives disponibles hors ligne.

**À valider sur téléphone** : connexion web, droits caissier/gérant, retour Android et fermeture explicite, panier conservé, clavier des formulaires, navigation lente/interrompue, liens externes et document téléchargeable. Aucune nouvelle dépendance : `flutter_inappwebview` et `url_launcher` existaient déjà.

## Reprise par B et preuves à produire

1. Lire le diff de C dans un worktree isolé puis fusionner sa branche. Préserver les changements non commités de B. La modification volontaire de `offline_register_page.dart` doit conserver les travaux d'écran de B.
2. Reprendre aussi le correctif hôte `f2b8525` : fermeture du client HTTP possédé par l'hôte et fermeture unique attendue. Le code Windows `7b65cbf` contient notamment la déduplication du compteur de paniers.
3. Exécuter la suite mobile, les tests navigateur et Windows sur le commit commun. Le script Windows fournit `SHOPIKAISS_DART_EXECUTABLE`.
4. Construire l'APK avec **la clé existante chez B**. Le worktree C n'a pas `android/key.properties` : sa configuration de secours debug ne doit jamais servir à annoncer une release signée correctement.
5. Recette téléphone/tablette : ouverture, ajout/recherche rapide, création/sélection client, remises, paiement multiple avec erreur visible, coupure après enregistrement, redémarrage hors connexion, paniers partagés, clôture, retour, ticket et navigateur avec panier conservé.
6. Consigner SHA, certificat, scénarios et limites dans `SESSION-B.md` et le journal partagé. Pas de push/main ni de publication implicite.

Les mesures Windows précédentes sur 5 000 produits synthétiques, sans HTTP, donnaient en Release des médianes de 74,72 ms pour la vue, 48,47 ms pour la recherche et 55,38 ms pour le scan. Ce sont des mesures moteur/IPC, pas une preuve de fluidité graphique sur téléphone. Mesurer aussi le premier affichage et les interactions pendant une synchronisation réelle.

## Parité encore incomplète

À fournir ou compléter par A puis B avant raccordement d'écran : tarif de gros, frais autres que livraison, lots/variantes/compositions et création produit complète, bons/cartes cadeaux/points/crédit/acomptes en ligne, livre de caisse et X/historique serveur complet, paniers reçus de rayon, règles avancées de service/inactivité/comptage, autorisations de survente et de prix manuel.

À terminer en recette : impression POS-80 connectée, afficheur physique, téléphone réel, navigateur interne et installation du build commun. L'accès web permet les opérations administratives disponibles sur le serveur ; il ne remplace pas ces contrats pour les ventes locales.

## Validation de cette transmission

74 tests Windows/navigation passent. Les 27 tests moteur v2/adaptateur passent. Le menu a été corrigé après détection d'un débordement sur téléphone 6,5 pouces : la reprise des tests disposition/navigation passe, 18 tests dont les 3 de navigation déjà comptés. Analyse ciblée sans remarque. La navigation native et l'authentification web restent à tester sur téléphone ; aucun APK de production n'est livré par C.
