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
| `commitSale` | `operation_id` (UUID minuscule, choisi par l'écran AVANT) | `state: committed`, `operation_id`, `number`, `total`, `server_status` |
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
