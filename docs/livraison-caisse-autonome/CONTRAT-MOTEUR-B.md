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
| `search` | `query` (≤ 100) | vue filtrée (60 produits au plus) ; le filtre est gardé par la vue |
| `addProduct` | `product_id`, `packaging_id?` | vue |
| `scan` | `code` | vue ; `code_inconnu` sinon |
| `changeQuantity` | `line_id`, `quantity` (chaîne, 6 décimales au plus, > 0) | vue |
| `removeLine` / `clear` | `line_id` / — | vue |
| `preparePayment` | — | `payable`, `payable_label`, `methods[]` |
| `setPayment` | `method`, `amount?` (= à payer par défaut), `received?` (espèces) | vue + `change` |
| `commitSale` | `operation_id` (UUID minuscule, choisi par l'écran AVANT) | `state: committed`, `operation_id`, `number`, `total`, `server_status` |
| `saleStatus` | `operation_id` | `committed` (mêmes champs) ou `{state: not_found, definitive: true}` |
| `history` | `limit?` (≤ 200) | `items[]` |
| `reprint` | `operation_id` | `lines[]` du duplicata (largeur `paperWidth`) |
| `synchronize` | — | `{scheduled: true}` immédiatement ; le réseau tourne à côté |

Vue schéma 1 : `schema`, `revision` (croissante dans le processus), `ready`, `block_reason`, `can_pay`, `draft_id`,
`store_name`, `sync_label`, `total_label`, `payment_label`, `payment_valid`, `query`, `products[]` (`id`, `name`,
`price_label`, `stock_label`, `packagings[]`), `lines[]` (`id`, `name`, `quantity_label`, `quantity` (canonique, 6
décimales), `unit_price_label`, `discount_label`, `total_label`, `available`), `totals` (`gross_label`, `base_ht_label`,
`vat_label`, `vat_rate`, `vat_included`, `payable_label`) ou null, `payment` (`method`, `amount_label`,
`received_label`, `change_label`, `remaining_label`) ou null.
Montants et libellés calculés par le moteur ; Windows n'en recalcule aucun.

`capabilities` (C-REQ-005 §2) : `sell`, `open_session`, `pair`, `synchronize`, chacune `{allowed, reason,
network_required}`. Indication pour l'écran seulement : le moteur refait chaque contrôle à l'exécution.

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

## Limites actuelles

- Paiement unique en espèces par vente (v2 2.0) ; multi-paiement, moyens électroniques déclarés : contrat A requis.
- Remises de ligne non exposées (le moteur les sait valider) ; clôture de session : contrat A requis (pas d'opération
  `cloture_session` en v2 2.0).
- C-REQ-005 §3–7 restants (catégories/marque/fournisseur, brouillons multiples, client, note, tarif gros, retours,
  bons) : lots suivants, certains après contrat A.
- Hôte exécutable livré (voir ci-dessous) ; l'interface Windows ne le lance pas encore (bootstrap de C).

## Hôte exécutable (livré sur le commit intégré)

`tool/windows/moteur/Build-Moteur.ps1 -FlutterRoot C:/dev/flutter` produit `build/windows-moteur/bundle/` :
`bin/shopikaiss_moteur.exe` et `lib/sqlite3.dll` (garder cette structure), plus `integration-only.json` (empreintes,
`production_ready:false`). Lancement : `shopikaiss_moteur.exe [--dossier <absolu>] [--version <app>]` ; dossier par défaut
`%LOCALAPPDATA%\ShopiKaiss\caisse`. stdout = trames IPC v1 ; stderr = messages courts sans donnée. Sortie : 0 après EOF
(commandes et synchronisation en cours terminées, base fermée, verrou libéré), 2 argument invalide, 3 base déjà possédée
par un autre hôte (verrou système sur `caisse.lock`, y compris autre session Windows), 1 démarrage impossible.
`sqflite_common_ffi` reste propre à ce paquet : l'APK Android n'embarque pas SQLite natif.
