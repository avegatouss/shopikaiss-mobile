Écrit pour : session C (Windows)

# Adaptateur — commandes restaurant (version 2)

Livré par B le 19/11/2026 sur `feat/mobile-adapter-resto`. `LocalRegisterAdapter.execute(command, arguments, operationId)` porte maintenant les commandes de la salle, du règlement, du registre, des remboursements et des bons, avec la même sérialisation que les commandes de vente. `status.version` vaut **2**.

L'adaptateur ne contient aucune règle métier : chaque commande appelle la même méthode du moteur (`engine.resto*`) que l'écran Android, avec les mêmes contrôles de saisie que ses dialogues (motif, plafonds, montant de l'autorisation, responsable). Le moteur refait tous ses contrôles.

À faire côté C : ajouter ces noms à `HostCommand` et les relayer dans `BEngineAdapter` comme les autres commandes (les erreurs `AdapterFailure` y deviennent déjà des `HostFailure`). La commande `restaurantView` de C peut rester ou passer à celle-ci : la forme de C est conservée (voir plus bas).

## Règles communes

| | Lectures | Écritures | Pont d'impression |
|---|---|---|---|
| Caissier identifié (`login`) | oui (`caissier_requis`) | oui (`caissier_requis`) | non (l'écran peut être verrouillé) |
| `operationId` (UUID v4 en minuscules) | non | **obligatoire** (`identifiant_requis`) | non, idempotent par `job_id` |

**Rejeu d'une écriture.** Le résultat est conservé par identifiant (`resto_operation.<operationId>` dans la base du moteur) :

- même identifiant, même commande, déjà faite : la réponse d'origine, plus `replayed: true` ; rien n'est refait (pas de seconde version, pas de seconde vente) ;
- même identifiant pour une autre commande : `identifiant_reutilise` ;
- refus du moteur (`restaurant_refuse`, message du moteur) ou contrôle de saisie : rien n'est enregistré (`not_committed: true`), l'identifiant est libéré ;
- hôte arrêté pendant l'écriture : au rejeu, `resultat_incertain` avec `not_committed: false`. Relire la commande (`restoOrder`) avant de recommencer avec un **nouvel** identifiant. Exception : `restoSettle` et `restoRefund` portent l'identifiant comme uuid de la vente ou du remboursement ; leur rejeu retrouve l'opération dans la file et rend le même résultat, ou l'exécute si elle n'existe pas.

Chaque écriture réussie émet `committedChanges` `{reason: 'restaurant'}`. Chaque bon confié à l'interface émet `{reason: 'resto_impression'}`.

Une réponse d'écriture contient `operation_id` et, si des bons ont été confiés à l'interface pendant la commande, `print_jobs: [job_id…]`.

Quantités : chaînes décimales en unité de base (`"1"`, `"0,5"`, `"1.5"`, six décimales au plus). Montants : francs entiers.

## Vues

`order` (rendu par toutes les commandes sur une commande) : `order_uuid`, `local_number`, `server_number`, `business_day`, `profile` (`TABLE_SERVICE`/`PRODUCTION`), `channel`, `channel_name`, `table_uuid`, `table_name`, `covers`, `server_id`, `customer_uuid`, `customer_name`, `external_reference`, `comment`, `status` (`open`/`settled`/`cancelled`), `stage`, `version`, `prebills`, `gross`, `discounts`, `global_discount(_label)`, `global_discount_source`, `discount_frozen`, `discount_base`, `discount_ceiling`, `payable(_label)`, `paid` (réglée, à clôturer), `announced` (des articles sont partis aux postes), `pending_versions`, `server_message`, `waiting`, `sync_message`, `tickets_to_check`, `lines[]` (`line_uuid`, `label`, `quantity(_label)`, `unit_price(_label)`, `gross`, `discount`, `total(_label)`, `comment`, `status` `pending`/`sent`/`cancelled`, `state_label`, `active`, `free`, `sent`, `to_send`, `settled`, `rest`, `station_uuid`, `promotion_uuid`, `promotion_name`, `tariff`, `staff_id`), `tickets[]` (bons créés par ce fait : `ticket_uuid`, `station_uuid`, `number`, `day_number`, `type`, `title`, `lines[]`).

Tous les montants viennent du moteur ; l'écran n'en calcule aucun.

## Lectures

| Commande | Arguments | Réponse |
|---|---|---|
| `restaurantView` | — | Forme de la `restaurantView` de C (`available`, `message`, `profile`, `master`, `tables[]` avec `id`, `name`, `room`, `state` `free`/`occupied`/`payment`, `order_label`, `total_label`, `guests_label`, `sync_message`, `lines[]` `name`/`quantity_label`/`total_label`/`state_label`/`note`), plus `table_uuid`, `room_uuid`, `capacity`, `order_uuid` par entrée, `blocker`, `production`, `table_service`, `send_label` (libellé du bouton d'envoi selon `restaurant.interface.libelle_envoi`), `interface{demander_couverts, libelle_envoi, navigation_carte}` (défauts vrai/`send`/`chips`), `session_open`, `staff_pricing`, `settings{}`, `rights{}` (besoins d'autorisation de l'opérateur, `register_blocker`, `refund_blocker`), `rooms[]`, `channels[]`, `stations[]` (avec `printer_address`), `staff[]`, `customer_discounts`, `orders[]` (vues `order` ouvertes), `register`, `tickets_to_check`, `print_jobs_pending`. Sans restaurant : `{available: false, message, tables: []}`. |
| `restoOrder` | `order_uuid` | `{order}` (closes et annulées comprises) |
| `restoTickets` | `order_uuid` facultatif | `{tickets[]}` : bon + `station_name`, `order_number`, `table`, `state` (`livre`, `a_verifier`, `echec`, `en_attente`, `en_impression` = confié à l'interface sans résultat), `check_attempt`, `checked`, `print_jobs[]` en cours |
| `restoApprovalInfo` | `gesture` ∈ `cancel_line`, `cancel_order`, `offer`, `discount_line`, `discount_order`, `staff`, `refund`, avec les arguments de la commande correspondante | `{required, type, amount(_label), percent, approvers[{id, name}]}` : ce que montre le dialogue Android avant le code du responsable |
| `restoRegister` | — | `{register, blocker}` |
| `restoSettledSales` | — | `{blocker, sales[]}` ventes de la caisse qui ont réglé une commande du Restaurant (lignes restantes, remboursements) |
| `restoRefundPreview` | `sale_uuid`, `type` (`retour`/`annulation`), `lines` `{ligne_vente_uuid: "1"}` | comme `restoApprovalInfo` + `blocker` |
| `restoPrepareSettlement` | `order_uuid`, `mode` `full` (défaut) / `items` (`items: {line_uuid: "1"}`) / `shares` (`shares: n`) | `{payable(_label), rest_payable, shares[{index, label, amount}], lines[], methods[]}`. Garde en mémoire le panier rendu par le moteur pour `restoSettle`. Le Service de table règle tout (`reglement_refuse` sinon) ; session de caisse ouverte exigée (`session_requise`). |

## Écritures (operationId obligatoire)

| Commande | Arguments | Réponse |
|---|---|---|
| `restoOpen` | `table_uuid`, `covers` (0/absent = non renseigné), `customer` `{uuid, name}` facultatif | `{order}` |
| `restoOpenOnChannel` | `channel`, `table_uuid`, `reference`, `customer_name`, `customer_uuid`, `covers` (profil Restaurant) | `{order}` |
| `restoEditLines` | `order_uuid`, `added[{product_id, packaging_id?, quantity? ("1" par défaut), comment?}]`, `quantities{line_uuid: "2"}`, `comments{line_uuid: texte\|null}`, `removed[line_uuid]` — une validation = une version | `{order}` |
| `restoStaffLines` | `order_uuid`, `staff_id`, `added[]`, `reason`, `approval?` | `{order}` |
| `restoSend` | `order_uuid` (« Valider » quand l'envoi en production est éteint) | `{order}` ; `order.tickets` et `print_jobs` |
| `restoPrebill` | `order_uuid` | `{order, prebill_lines[]}` (texte de la préfacture Android, 48 ou 32 colonnes selon `paperWidth`) |
| `restoTransfer` | `order_uuid`, `table_uuid` | `{order}` |
| `restoMoveLines` | `order_uuid`, `target_uuid`, `line_uuids[]` | `{order}` (source) |
| `restoMerge` | `order_uuid`, `target_uuid`, `reason?` | `{order}` (source) |
| `restoCoversAndServer` | `order_uuid`, `covers`, `server_id` | `{order}` |
| `restoValidateCustomer` | `order_uuid` | `{order}` |
| `restoCancelLine` | `order_uuid`, `line_uuid`, `quantity`, `reason` (3 à 500), `approval?` | `{order}` |
| `restoCancel` | `order_uuid`, `reason`, `approval?` — motif et responsable si des articles sont annoncés | `{order}` |
| `restoOffer` | `order_uuid`, `line_uuid`, `reason`, `approval?` | `{order}` |
| `restoDiscountLine` | `order_uuid`, `line_uuid`, `percent` (bool), `value`, `reason`, `approval?` | `{order}` |
| `restoDiscountOrder` | `order_uuid`, `value` (0 = retirer, sans motif), `reason`, `approval?` | `{order}` |
| `restoSettle` | `order_uuid`, `payments[{method, amount, received?, reference?, share?}]` (`share` = index de la part en mode `shares`) | `{state: 'committed', sale_id (= operationId), number, total, server_status, change(_label), order, closed}` ; la commande soldée est clôturée par le moteur. Le ticket de vente s'imprime par `printTicket` avec le même identifiant. |
| `restoClose` | `order_uuid` (commande réglée dont la clôture a été interrompue) | `{order}` |
| `restoRegisterOpen` / `restoRegisterClose` | `note?` | `{register}` |
| `restoRefund` | `sale_uuid`, `type`, `lines`, `reason`, `approval?` | `{refund_id (= operationId), amount(_label), server_status}` |
| `restoVerifyTicket` | `ticket_uuid`, `printed` (bool) | `{ticket_uuid, printed}` |
| `restoDuplicateTicket` | `ticket_uuid`, `reason` | `{ticket_uuid, result}` : `transmis`, `non_envoye`, `a_verifier`, ou `delegue` (+ `print_jobs`) |
| `restoSetPrinterAddress` | `station_uuid`, `address` (`ip` ou `ip:port`, absent = retirer) | `{station_uuid, address}` |

**Autorisation d'un responsable** (`approval: {approver_id, code}`) : exigée quand `restoApprovalInfo.required` est vrai pour les mêmes arguments. Absente : `autorisation_requise` ; responsable non autorisé, code faux, plafonds : `autorisation_refusee`. Le code n'est jamais conservé (ni dans la file, ni dans le résultat rejouable). Le motif de l'autorisation est celui de la commande.

**Erreurs de saisie** (toutes `not_committed: true`) : `argument_invalide`, `quantite_invalide`, `motif_requis`, `remise_invalide`, `commande_inconnue`, `ligne_inconnue`, `produit_inconnu`, `conditionnement_inconnu`, `paiement_invalide`, `reglement_a_preparer`, `reglement_refuse`, `session_requise`, `restaurant_indisponible`.

## Pont d'impression des bons (hôte → interface Windows)

L'hôte ne voit pas l'imprimante de la caisse. Au démarrage, si le moteur n'a pas d'imprimante de caisse (`restoRegisterPrinter`), l'adaptateur branche `engine.restoDeferredPrinter` : un bon destiné à l'**imprimante de la caisse** (cible directe ou secours) devient un **travail** conservé dans la base (`resto_impression.travaux`) **avant** que le moteur continue ; aucune commande n'attend l'impression (le protocole IPC est séquentiel). Les imprimantes de poste réseau (ESC/POS 9100) restent imprimées par l'hôte ; l'hôte peut aussi les confier à l'interface en ajoutant `RestoTarget.imprimantePoste` à `engine.restoDeferredTargets`.

Protocole côté interface (sans caissier, sans operationId) :

1. Sur l'événement `resto_impression`, et au démarrage de l'interface : `restoPrintJobs` → `{jobs[{job_id, kind (livraison/duplicata), ticket_uuid, order_uuid, station_uuid, station_name, target, address, fallback, lines[], state (en_attente/en_cours), created_at}]}`, du plus ancien au plus récent.
2. Avant d'envoyer des octets : `restoPrintStart {job_id}` → `print: true` une seule fois. `print: false` : ne **jamais** imprimer (déjà commencé ou terminé).
3. Après : `restoPrintResult {job_id, result}` avec `transmis` (spouleur accepté), `non_envoye` (certain que rien n'est parti), `a_verifier` (issue inconnue). Acquittement durable, rejouable : même résultat → même réponse (`replayed: true`) ; autre résultat → `resultat_deja_enregistre`. Réponse : `journalized` (passé au journal des bons du moteur) et `print_jobs` si le moteur a repris la chaîne de secours.
4. Un travail trouvé `en_cours` après un redémarrage de l'interface se déclare `a_verifier`.

Effets : le résultat est noté au journal des bons du moteur avec la tentative = `job_id` (remonté au serveur par `resto_bons_etats`). `a_verifier` n'est jamais relancé : le bon passe « à vérifier », la vérification humaine se fait par `restoVerifyTicket`, la réimpression par `restoDuplicateTicket` (DUPLICATA, autre identifiant). `non_envoye` reprend la chaîne de secours du moteur (aucune cible après l'imprimante de la caisse : le bon passe en `echec`). Si l'hôte s'arrête entre l'acquittement et le journal, l'acquittement repasse au journal au démarrage suivant, une seule fois.

Le texte `lines` est celui de `RestoTicket.printLines` (largeur `engine.restoTicketColumns`) : l'interface ne recompose ni numéros ni quantités ; `ProductionPrinting.send` de C convient tel quel.

## Points connus

- Le règlement préparé est en mémoire : après un redémarrage de l'hôte, refaire `restoPrepareSettlement` (le rejeu de `restoSettle` avec le même identifiant reste sûr).
- Le moteur refuse deux lignes d'espèces dans une même vente, parts comprises (règle existante) : en mode `shares`, une seule part en espèces.
- `tickets_to_check` du moteur compte aussi les bons en échec, y compris pendant une impression confiée à l'interface ; `restoTickets` donne l'état exact (`en_impression`).
- Un travail jamais repris par l'interface reste `en_attente` : l'interface doit lire la file à son démarrage.
