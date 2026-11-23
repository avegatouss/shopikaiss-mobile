# Contrat du moteur local — version 1 (session B → C)

Réponse aux demandes C-REQ-001 à 004 (`SESSION-C.md`). Propriétaire : B. Toute rupture incrémente
`registerAdapterVersion` et passe par une demande dans les fichiers de suivi.

## Ce que B fournit

| Élément | Où | Sans Flutter |
|---|---|---|
| Moteur (`OfflineEngine`) : règles, file, synchronisation v1, PIN | `lib/src/offline/engine.dart` | oui (`EngineNotifier`, `Isolate.run`) |
| Stockage SQLite schéma 3 | `lib/src/offline/store.dart`, `SqfliteOfflineStore.open(name:, factory:)` | oui (`sqflite_common`) |
| Interface de commandes (`LocalRegisterAdapter`) | `lib/src/register/register_adapter.dart` | oui |
| Contrat réseau v2 (canonicalisation, schémas) | `lib/src/sync_v2/` | oui |

## Démarrage dans l'hôte Windows (C-REQ-002/003)

```dart
sqfliteFfiInit();                                   // sqflite_common_ffi (B la passe en dépendance normale au raccordement)
final store = await SqfliteOfflineStore.open(name: '<LocalAppData>/ShopiKaiss/caisse.db', factory: databaseFactoryFfi);
final engine = OfflineEngine(store: store, transport: HttpRegisterTransport(appVersion: '<version>'));
final origin = <adresse de la boutique enregistrée par l'hôte, ou null avant appairage>;
if (origin != null) await engine.load(origin);
final adapter = LocalRegisterAdapter(engine, paperWidth: 80);
await adapter.start();                              // restaure le panier conservé
```

Un seul hôte par base (le verrou mono-instance de C est requis : deux processus sur la même base ne sont pas couverts).
Le chemin absolu de la base est choisi par l'hôte ; aucun chemin venant du serveur.

## Raccordement à `WindowsEngineAdapter` (C)

```dart
class BEngineAdapter implements WindowsEngineAdapter {
  BEngineAdapter(this.inner);
  final LocalRegisterAdapter inner;
  @override
  Stream<Map<String, dynamic>> get committedChanges => inner.committedChanges;
  @override
  Future<Map<String, dynamic>> execute(HostCommand command, Map<String, dynamic> arguments, String? operationId) async {
    try {
      return await inner.execute(command.name, arguments, operationId);
    } on AdapterFailure catch (e) {
      throw HostFailure(e.code, e.message, outcomeUnknown: !e.notCommitted);
    }
    // Toute autre exception remonte : WindowsHostServer la rend « host_error / not_committed:false » (résultat inconnu).
  }
}
```

`HostCommand` doit gagner `pair`, `login`, `addProduct` et `clear` (fichiers de C). Noms identiques côté B.

## Commandes

| Commande | Arguments | Résultat |
|---|---|---|
| `status` | — | `version`, `ready`, `block_reason`, `paired`, `operator`, `operators[]`, `pin_required`, `session_open`, `pending`, `arbitration`, `permanent_local`, `reachable`, `session` (`id`, `local`) ou null, `capabilities` (ci-dessous) |
| `pair` | `origin`, `code`, `model`, `app_version` | `status` ; exige le réseau |
| `login` | `operator_id`, `pin` | `status` ; PIN bloqué durablement après 3 échecs (progression serveur) ; `pin_non_defini` (aucun échec compté) si le caissier n'a pas de PIN |
| `logout` | — | `status` ; verrouillage ou changement de caissier : le panier reste, `saleStatus` reste possible |
| `openSession` | `float` (fond, entier en francs) | `status` ; caissier identifié requis ; refus `session_refusee` (session déjà ouverte, politique, droit) |
| `view` | — | vue schéma 1 (ci-dessous) |
| `search` | `query` (≤ 100), `category?` (≤ 120 ; absente ou vide = toutes) | vue filtrée (60 produits au plus) ; filtres gardés par la vue |
| `addProduct` | `product_id`, `packaging_id?` | vue |
| `scan` | `code` | vue ; `code_inconnu` sinon |
| `changeQuantity` | `line_id`, `quantity` (chaîne, 6 décimales au plus, > 0) | vue |
| `removeLine` / `clear` | `line_id` / — | vue |
| `setLineDiscount` | `line_id`, `amount` (francs, 0 = retirer) **ou** `percent` (« 12,5 », 2 décimales, ≤ 100) | vue ; `remise_refusee` (sans droit `remise`, au-delà du plafond du rôle ou du terminal, au-delà de la base), `remise_invalide` ; un pourcentage est recalculé à chaque changement du panier |
| `setLinePrice` | `line_id`, `amount` (entier en francs, 0 à 1 000 000 000) **ou** `null` (retour au prix habituel) | vue ; `prix_refuse` (fonction absente, produit non coché, conditionnement, caissier sans `prix_vente_modifier`), `prix_invalide` (hors bornes), `argument_invalide` (pas un entier) ; 2.1 lot 9, voir « Prix modifiable » |
| `localPriceSettings` | — | `{enabled, prices}` : mémoire des prix saisis de ce terminal (identifiant produit → francs) ; voir « Prix mémorisés » |
| `setLocalPriceSettings` | `enabled` (booléen) | même retour ; `prix_refuse` (fonction absente ou caissier sans `prix_vente_modifier`), `argument_invalide` ; désactiver efface la mémoire ; événement `prix_locaux` |
| `setGlobalDiscount` | `amount` **ou** `percent` (0 = retirer) | vue ; sur le sous-total (après remises de ligne) ; droit `remise`, plafond = min(`remises.globale_max_pourcent`, rôle) — politique à 0 : « Remise globale non autorisée hors ligne dans cette boutique. » ; `fonction_indisponible` avant la 2.1 |
| `setDelivery` | `amount` (francs, 0 = retirer) | vue ; hors TVA, ajoutée au montant à payer ; droit `boutique.regles.livraison_droit` s'il est défini |
| `setNote` | `text` (≤ 2 000, vide = retirer) | vue ; note du ticket |
| `suspendDraft` | — | vue (panier vide, `suspended_count`) ; `panier_vide` si rien à mettre en attente |
| `drafts` | — | `items[]` : `draft_id`, `updated_at`, `lines_count`, `summary`, `total_label` (catalogue courant), `complete` |
| `resumeDraft` | `draft_id` | vue ; le panier courant non vide part en attente à sa place ; paiements préparés effacés ; `panier_inconnu` |
| `deleteDraft` | `draft_id` (en attente ou courant) | vue ; `panier_inconnu` |
| `preparePayment` | — | `payable`, `payable_label`, `methods[]` |
| `setPayment` | `method`, `amount?` (= à payer par défaut), `received?` (espèces), `reference?` | vue + `change` (raccourci de `setPayments`) |
| `setPayments` | `payments[]` (≤ 10) : `method`, `amount`, `received?` (espèces), `reference?` (moyen déclaré, ≤ 100) | vue + `change` ; somme = à payer, une seule ligne d'espèces. **Édition invalide : paiements préparés effacés, puis refus `paiement_invalide`** |
| `commitSale` | `operation_id` (UUID minuscule, choisi par l'écran AVANT) ; `draft_id?`, `draft_revision?` (repris de la vue affichée) | `state: committed`, `operation_id`, `number`, `total`, `server_status`. Si `draft_id`/`draft_revision` sont fournis et ne sont plus ceux du panier courant : refus `panier_modifie`, rien d'écrit (recharger la vue) |
| `saleStatus` | `operation_id` | `committed` (mêmes champs) ou `{state: not_found, definitive: true}` |
| `history` | `limit?` (≤ 200) | `items[]` |
| `reprint` | `operation_id` | `lines[]` du duplicata (largeur `paperWidth`) |
| `synchronize` | — | `{scheduled: true}` immédiatement ; le réseau tourne à côté |

Vue schéma 1 : `schema`, `revision` (croissante dans le processus), `ready`, `block_reason`, `can_pay`, `pay_reason`
(motif quand `can_pay` est faux : caissier, session, panier vide, article retiré, remise devenue invalide), `draft_id`,
`suspended_count`, `store_name`, `sync_label`, `total_label`, `payment_label`, `payment_valid`, `query`, `category`,
`categories[]`, `global_discount_entry`, `delivery`, `note`, `products[]` (`id`, `name`, `category`, `price_label`, `stock_label`, `packagings[]`), `lines[]` (`id`,
`name`, `quantity_label`, `quantity` (canonique, 6 décimales), `unit_price_label`, `discount_label`, `discount` (francs,
pour l'édition), `discount_entry` (`{type, valeur}` ou null), `total_label`, `available`), `totals` (`gross_label` = sous-total
après remises de ligne, `discounts_label` (lignes), `global_discount_label`, `delivery_label`, `base_ht_label`, `vat_label`,
`vat_rate`, `vat_included`, `payable_label`) ou null, `payment` (premier paiement : `method`, `amount_label` ; ligne
d'espèces : `received_label`, `cash_due_label` (montant au tiroir, arrondi de caisse), `rounding_label` (écart, ou null),
`change_label` (sur le montant au tiroir) ; ensemble : `paid_label`, `remaining_label`) ou null, `payments[]`
(`method`, `name`, `amount_label`, `received_label`, `reference`).
Montants et libellés calculés par le moteur ; Windows n'en recalcule aucun.

`capabilities` (C-REQ-005 §2) : `sell`, `open_session`, `pair`, `synchronize`, `discount` (+ `max_percent`),
`global_discount`, `delivery`, `note`, `suspend`, chacune `{allowed, reason, network_required}`. Indication pour l'écran seulement : le moteur refait chaque contrôle à l'exécution.

## Protocole v2 (décision du 2026-10-29)

Depuis `9b0a5dd`, l'hôte et Android utilisent `V2Engine` (`lib/src/sync_v2/v2_engine.dart`) : mêmes commandes, mêmes
identifiants entiers (attribués localement, stables, rattachés aux UUID du contrat). Différences visibles :
paiement unique en espèces (capacité `vente.especes`) ; numéro local `HL2-<époque>-<séquence>` ; session = celle du
terminal publiée par le serveur, ou l'ouverture locale (`openSession`) tant que le serveur ne l'a pas intégrée ;
`history[].server_status` peut valoir `recue` ou `resolue` en plus de `integree`/`a_arbitrer` ; vente locale refusée
avec motif si l'autorisation du serveur est retirée ou expirée. Essai réel : 29/10, exécutable de l'hôte contre la démo,
Caisse 2, vente V-20261029-0016.

## Garanties (C-REQ-004)

- **Panier conservé** à chaque modification (table `paniers`, révision croissante) ; `start()` le restaure après
  redémarrage. Un panier encaissé est retiré dans la transaction de la vente et ne peut plus être réécrit.
- **`commitSale` idempotent** : le même `operation_id` rend la même vente (réponse perdue, hôte redémarré entre COMMIT
  et réponse). Vente, mouvements de stock et consommation du panier sont écrits en une transaction.
- **`saleStatus` ne touche jamais le réseau** et ne renvoie rien au serveur. Il passe dans la file d'écriture, après
  tout encaissement déjà demandé : `not_found` est **définitif** pour ce moteur, l'écran peut déverrouiller le panier.
- **`AdapterFailure.notCommitted == true`** : refus certain avant écriture (règle, paiement, caissier, panier). Toute
  autre erreur d'un `commitSale` = résultat inconnu → `saleStatus` avec le même identifiant.
- Une erreur d'un abonné d'écran n'interrompt jamais le moteur (`EngineNotifier`).

## Paniers en attente, remises, paiements (C-REQ-005 lot 2)

- **Paniers en attente** : un panier courant, les autres suspendus (`suspendu` dans la table `paniers`), conservés sur
  le terminal, jamais partagés avec la caisse web. Au redémarrage, `start()` reprend le panier courant, jamais un
  panier en attente. Encaisser consomme le panier dans la transaction de la vente : une seule vente par panier.
- **Remise de ligne** : droit `remise` publié par le serveur pour l'opérateur et plafond `remises.ligne_max_pourcent`
  (politique absente = 0 = aucune remise). Contrôlée par l'adaptateur, puis **de nouveau par le moteur à
  l'encaissement** (droit retiré, politique abaissée, quantité réduite : `can_pay` faux avec `pay_reason`).
- **Paiements multiples** : jusqu'à 10 lignes, une seule d'espèces (reçu et monnaie portent sur elle). Les moyens
  proposés sont ceux du catalogue local : espèces, et moyens **déclarés** (Wave, Orange Money…) hors connexion comme
  les espèces dès que le serveur rend `vente.paiement_declare` (feu vert A du 29/10, `f82a33c3`) et que la boutique les
  a ajoutés à `paiements.moyens_locaux`. `reference` facultative, figée dans la vente ; un moyen déclaré n'est jamais
  une confirmation de paiement. Android et l'hôte Windows annoncent la capacité.

## Contrat 2.1 (lot 1a, `d1bfc9ac` de A)

`V2Engine.contract21` annonce `contrat.2_1` ; la forme 2.1 n'est utilisée que si le serveur rend aussi la capacité.
Changement de forme : nouvel instantané complet (`reparation`), jamais de mélange. Désactivé par défaut (pas en
production avant l'accord de A). Apports visibles : catégories dans l'ordre de la boutique, `products[].brand`,
`supplier`, `unit`, recherche par marque ; plafond de remise du rôle (`remise_max_pourcent`, le plus petit avec la
politique du terminal) et `remise_max_montant` par vente, contrôlés par l'adaptateur et par le moteur ;
`preparePayment.methods[].reference` (`aucune` | `facultative` | `obligatoire`), référence obligatoire exigée.

**Lot 1b (`4bb14454` de A)** : vente 2.1 (`versions.calcul = "2"`) avec `remise_saisie` par ligne, remise globale
(`remise_globale_saisie`), livraison, note, `monnaie` et `ecart_arrondi` des espèces. Calcul de la caisse web
(`lib/src/offline/web_rules.dart`, exemples E1–E11 du référentiel de A) : remise en % arrondie selon la boutique
(`down` / `nearest`), remise globale ≤ sous-total, TVA sur le reste, livraison hors TVA ; espèces : le montant reste la
part exacte, le tiroir reçoit le montant arrondi (`arrondi_especes`), la monnaie se calcule dessus. Trop-perçu
électronique refusé hors connexion (« Trop-perçu électronique : en ligne seulement. Saisissez le montant exact. »).

## Limites actuelles

- Clôture de session, client, note, tarif gros, remise globale, frais, marque/fournisseur/images,
  retours, bons/points/crédit, survente : contrat A requis (demandes B-REQ-007 à B-REQ-015 du 29/10).
- Les commandes du lot 2 ne sont pas encore dans l'énumération IPC `HostCommand` (périmètre C) : à ajouter par C,
  comme `logout` et `openSession`.
- Hôte exécutable livré (voir ci-dessous) ; l'interface Windows ne le lance pas encore (bootstrap de C).

## Hôte exécutable (livré sur le commit intégré)

`tool/windows/moteur/Build-Moteur.ps1 -FlutterRoot C:/dev/flutter` produit `build/windows-moteur/bundle/` :
`bin/shopikaiss_moteur.exe` et `lib/sqlite3.dll` (garder cette structure), plus `integration-only.json` (empreintes,
`production_ready:false`). Lancement : `shopikaiss_moteur.exe [--dossier <absolu>] [--version <app>]` ; dossier par défaut
`%LOCALAPPDATA%\ShopiKaiss\caisse`. stdout = trames IPC v1 ; stderr = messages courts sans donnée. Sortie : 0 après EOF
(commandes et synchronisation en cours terminées, base fermée, verrou libéré), 2 argument invalide, 3 base déjà possédée
par un autre hôte (verrou système sur `caisse.lock`, y compris autre session Windows), 1 démarrage impossible.
`sqflite_common_ffi` reste propre à ce paquet : l'APK Android n'embarque pas SQLite natif.

## Catalogue complet (filtres et pages)

- `search` accepte `brand` et `supplier` en plus de `query` et `category`. Absents ou vides : aucun filtre. Les filtres portent sur tout le catalogue et restent actifs jusqu'à la prochaine recherche.
- `moreProducts` ajoute une page de 60 produits à la recherche courante ; `search` revient à la première page.
- Vue : `brand`, `brands[]`, `supplier`, `suppliers[]` (listes du catalogue complet, triées), `products_total`, `has_more`.

## Activation du contrat 2.1

`contract21: true` est activé sur Android (`terminal_session.dart`) et sur l'hôte Windows (`engine_host.dart`). Le format 2.1 ne s'applique que si le serveur rend `contrat.2_1` ; sinon le terminal reste en 2.0, avec les motifs d'indisponibilité.

## Catalogue 2.1 : badges et image (lot 1b bis de A)

Par produit dans la vue : `favorite`, `promotion` (libellé ou null, présentation seule, aucun prix ne change), `is_new`, `low_stock`, `image` ({uuid, hash, width, height} ou null). La date du jour vient de l'horloge du terminal, pas du fuseau de la boutique.

## Ticket original et images

- `printTicket` (identifiant d'opération) : première impression sans mention, puis « REIMPRESSION » ; rend `duplicate`. `reprint` force toujours la réimpression. Aucune des deux ne crée de vente.
- Confirmation d'impression (23/11, recommandée) : `printTicket {deferred_confirmation: true}` ne retient pas l'original ; l'hôte appelle `confirmTicketPrinted` (identifiant d'opération) une fois le ticket réellement sorti → `{operation_id, printed: true}` (`vente_inconnue` sinon). Une imprimante en échec laisse donc l'original pour l'essai suivant. Sans le drapeau, comportement d'origine (original retenu dès la demande).
- `image.path` (vue produit) : fichier JPEG local, ou null tant qu'il n'est pas téléchargé. Le téléchargement se fait après une synchronisation, panier vide, 30 images par passage, et respecte `Retry-After`.

## Remise autorisée par un responsable (2.1, lot 1c)

Au-delà du seuil du rôle du caissier, la saisie reste possible jusqu'au plafond de la boutique s'il existe un responsable publié (`approbateur_remise`, `code_autorisation_empreinte`, autre que le caissier). Le plafond de la boutique n'est jamais levé.

- Vue de l'adaptateur : `discount_approval` `{required, approvers: [{id, name}]}`. Sans responsable dont le seuil couvre la vente, `can_pay` est faux avec le motif.
- `commitSale` reçoit alors `approval` `{approver_id, code, reason}` ; erreurs `autorisation_requise`, `autorisation_refusee`. Le code n'est jamais conservé : le redemander à chaque essai.
- Échecs comptés par responsable, gardés sur le terminal : 3 essais, puis 30 s doublées à chaque échec, 15 min au plus.
- La vente porte `autorisations[]` (`type: remise`, `approbateur_id`, `motif`, `preuve: code_local|<horodatage>`) seulement si le seuil du caissier est dépassé.
- Ne couvre pas `survente` ni `prix_manuel`.

## Clients (2.1, lot 2)

Capacités `client.lecture` et `client.creation` annoncées avec `contrat.2_1`. La première obtention de `client.lecture` déclenche un seul instantané (`reparation`). Le client de passage n'est pas proposé ; aucune fonction de solde.

- Adaptateur : `searchCustomers` {query}, `createCustomer` {name, phone}, `setCustomer` {uuid, name}. Vue : `customer`. Capacités : `customer`, `customer_create`. Erreur : `client_refuse`.
- `createCustomer` rend la fiche existante si le téléphone normalisé est déjà connu, refuse un numéro illisible, exige le droit `clients_creer`.
- La création précède toujours la vente dans la file. Une fois intégrée, le client créé disparaît de la liste locale au profit de la fiche du journal ; son uuid reste accepté dans les paniers conservés. `details.client_uuid_canonique` n'est pas utilisé.

## Clôture de session (2.1, lot 3)

Capacité `session.cloture`, droit `caisse_cloturer`, comptage à l'aveugle : l'attendu n'est ni affiché ni exposé par l'adaptateur.

- Adaptateur : `closeSession` {cash, comment, counts: [{method, amount, justification}]}, panier vide. Capacité `close_session`. Erreurs `panier_en_cours`, `cloture_refusee`. `status.last_closure` est à brancher par C si l'écran en a besoin (`engine.lastClosure()`).
- Le terminal calcule un attendu si l'ouverture de la session est dans sa file (fond + encaissements, arrondi compris). Un écart exige alors un commentaire ou une justification. Session ouverte en ligne : attendu inconnu, commentaire facultatif, risque d'arbitrage côté serveur.
- La session se ferme aussitôt sur le terminal. Une ouverture est refusée tant que la clôture précédente est `a_arbitrer`. Rejet protocole : la session du serveur reprend.
- Le Z (`details.z`) est conservé et visible dans le journal des opérations. Pas d'impression du Z.

## Paniers partagés (2.1, lot 4)

Capacité `panier.partage`, instantané unique à la première obtention. Un panier mis en attente par un caissier identifié est publié (`panier_suspendre`) et reste aussi sur le terminal.

- Adaptateur : `suspendDraft` {label}, `drafts` donne `shared`, `resumeShared` {shared_id}, `deleteShared` {shared_id}. Capacité `shared_carts`. Erreur `panier_refuse`.
- Reprise d'un panier publié : réseau requis, renouvelée à chaque synchronisation, libérée si le panier est vidé. Prix figés conservés (`prix_fige`) et repris dans la vente avec `panier_uuid`.
- Suspendre de nouveau : nouvel uuid. Repris : `remplace_uuid`. Non repris : `panier_supprimer` d'abord.
- Un panier local intégré puis absent du journal (vendu ou supprimé ailleurs) quitte la liste. `remise_saisie` en % n'est pas conservée après reprise.

## Retours limités (2.1, lot 5)

Fermés par défaut : capacité `retour.especes`, `retours.mode` = `especes`, fonction `retour` absente de `fonctions_restreintes`, droits `retour_creer` et `retour_rembourser_especes`, session ouverte. Ventes de ce terminal seulement, dans `retours.delai_jours`, jusqu'à `retours.max_montant`.

- Adaptateur : `returnableSale` {sale_id}, `previewReturn` {sale_id, lines: [{line_id, quantity}]}, `commitReturn` {sale_id, lines, reason}. Capacité `returns`. Erreur `retour_refuse`. Quantités en unité de base.
- Montant selon §3.13 : part = arrondi(net × total_ligne / brut), demi vers le haut ; rendu = arrondi(part × (avant + q) / Q) − arrondi(part × avant / Q).
- Parts inexactes : règle `boutique.regles.retour_residuel` (`refuse`, `last_line`, `largest_share`, `largest_fraction`), appliquée comme `ReturnService`. Clé absente ou cas non chiffrable : le terminal refuse et renvoie en ligne. Si la règle change entre deux retours d'une vente, le serveur garde la première : `a_arbitrer`.
- Limites : un retour fait en ligne sur la même vente n'est pas vu du terminal (écart `a_arbitrer`) ; produit à lots non détecté (`a_arbitrer`) ; aucun bon de retour imprimé ; tiroir ouvert si une imprimante est branchée.

## Stock après le panier, plage d'images, performances

- Vue : `products[].stock_after_label`, `lines[].stock_after_label`, `lines[].stock_alert` {level: `low`|`short`, message}, sur la première ligne du produit. Conditionnements convertis en unité de base. Message `short` complété selon `regles.survente` (`refuser`, `autoriser_avec_droit`).
- L'alerte est indicative : elle n'empêche pas l'encaissement. L'autorisation de survente n'est pas livrée. Le seuil global de la boutique n'est pas publié : seul le seuil de la fiche compte. Produits à lots non détectés.
- Images : `imageSettings` donne {start, end, images_cached, images_total} ; `setImageSettings` {start, end} en `HH:MM` locales, plage pouvant passer minuit, sans argument = à toute heure (défaut). Erreur `reglage_refuse`. Capacité `image_schedule`. Une vente qui commence arrête le lot avant l'image suivante ; l'image en cours se termine.
- Mesure sur 5 000 produits, moteur v2, poste de dev, mode test : `view` 2 ms, `search` 15 ms, `scan` panier de 15 lignes 20 ms. Le gel d'une synchronisation passe de 1 990 ms à 52 ms (reconstruction du catalogue indexée). Non mesuré sur le poste Windows réel ni en build Release.

## Prix modifiable (2.1 lot 9, contrat `4176383b` de A)

- **Fonction** : capacité `prix.modifiable`, annoncée avec `contrat.2_1`. La première obtention fait reprendre un
  instantané (révision de projection `+prix1`) pour recevoir `produit.prix_modifiable` et le droit `prix_vente_modifier`.
- **Statut** : `capabilities.line_price` vaut `{allowed, reason}`. Il dit si la fonction existe sur le terminal et si le
  caissier connecté a le droit.
- **Vue, par ligne** :
  - `price_editable` (booléen) : afficher le champ « Prix unitaire F » seulement s'il est vrai ;
  - `price_edit_reason` : motif sinon (produit non coché, conditionnement, droit, fonction absente) ;
  - `entered_price` : entier ou `null` ;
  - `usual_price` et `usual_price_label` : prix habituel, à montrer en aide (« vide : prix habituel ») ;
  - `unit_price_label` : prix appliqué.
- **Commande** : `setLinePrice {line_id, amount}`. Avec `amount: null`, la ligne revient au prix habituel.
- **Calcul** : le prix saisi devient le `prix_unitaire` de la ligne de vente, au tarif `detail` (le gros ne s'applique
  plus à cette ligne). La remise en pourcentage se recalcule sur lui. Une remise en montant qui dépasse la nouvelle
  ligne bloque l'encaissement (`pay_reason`).
- **Conservation** : le prix saisi est gardé dans le panier courant et dans les paniers en attente (`prix_saisi`), au
  redémarrage comme à la reprise.
- **Encaissement** : le moteur refait tous les contrôles. Un prix saisi par un caissier puis encaissé par un autre sans
  le droit est refusé : `can_pay` faux, `pay_reason` « Prix saisi sur … ».
- **Refus du moteur** : prix saisi sur une commande restaurant.
- **Panier à prix saisi** :
  - il n'est pas partagé avec les autres caisses (le contrat `panier_suspendre` ne porte pas de prix) ;
  - `suspendDraft` le garde sur ce terminal seulement ;
  - un panier repris puis modifié avec un prix saisi est refusé au partage (`panier_refuse`).
- **Ticket et Z** : rien à changer, la ligne porte son prix réel.
- **Windows** : C n'annonce rien de plus, la capacité est annoncée par le moteur. Il affiche le champ dans le détail de
  ligne selon `price_editable` et appelle `setLinePrice`.

### Prix mémorisés (demande utilisateur du 21/11, C `e8354be`, repris par B)

- **Principe** : option locale du terminal, désactivée par défaut. Activée, chaque `setLinePrice` mémorise le prix du
  produit (`null` l'oublie) ; le prochain `addProduct` ou `scan` du produit reprend ce prix comme prix saisi.
- **Contrôles** : la reprise n'a lieu que si le moteur accepterait un prix saisi sur la ligne (fonction présente,
  produit coché, unité de base, caissier avec `prix_vente_modifier`). Sinon la ligne part au prix habituel. Le moteur
  refait tous les contrôles à l'encaissement, comme pour un prix tapé.
- **Catalogue** : `products[].price_label` montre le prix mémorisé au caissier autorisé.
- **Stockage** : clé `local-prices-v1:<uuid boutique>` dans la base du moteur, partagée par Windows (adaptateur) et
  Android (`LocalPrices`, `lib/src/offline/local_prices.dart`). Rien n'est envoyé au serveur ni ne modifie le
  catalogue : au rejeu, chaque vente est une vente à prix saisi (journal `prix_vente_modifie`).
- **Android** : menu de la caisse locale, « Mémoriser les prix saisis » (case à cocher), visible pour un caissier avec
  le droit ; la désactivation demande confirmation si des prix sont mémorisés.
