# Suivi session B — mobile Android et moteur partagé

Propriétaire : session B. Lecture : A, C. Spécification utilisée : dossier `shopikaiss-web/docs/architecture/caisse-autonome/`, commit `2221327e` (branche `feat/caisse-autonome-serveur`, versionné par A sans modification).

## Base

| Élément | Valeur |
|---|---|
| Dépôt | `shopikaiss-mobile` |
| Base | `c5f9483` (main), version 1.1.5+7 |
| Branche de travail | `feat/caisse-autonome-mobile` (checkout principal, pas de worktree) |
| Serveur constaté | `shopikaiss-web` `4f56856b`, contrat v1 seul ; pas de `SUIVI-SESSION-A.md` |
| Contrat v2 / fixtures | **absents** : rien de v2 réseau n’est implémenté côté client |

## Incrément 1 — stockage local schéma 2 (fait, non commité)

Indépendant du contrat v2 : corrige des défauts du moteur v1 actuel, et prépare la vente locale permanente.

| Défaut constaté au HEAD `c5f9483` | Correction | Test (SQLite réel, `sqflite_common_ffi`) |
|---|---|---|
| `purgeSent` supprimait après 30 jours toute opération « transmise », y compris **à arbitrer** (invariant 9) | Purge limitée à `integree`/`ecartee` dont le stock est couvert | STK-03 |
| Stock indicatif : la vente cessait d’être déduite dès l’accusé, avant que le catalogue la reflète (stock remontait de 7 à 10) | Mouvements locaux persistés ; couverts seulement par un catalogue **demandé après** le sort définitif, dans la même transaction que son enregistrement | STK-01, catalogue antérieur |
| Conversion des conditionnements relue dans le catalogue courant | Coefficient figé dans le mouvement à l’encaissement | STK-04 |
| Séquence lue hors transaction ; aucune unicité du panier (double appui) | Séquence réservée dans la transaction exclusive ; table `paniers_consommes` ; encaissements sérialisés dans le moteur | LOC-02 |
| Comptage de la file par chargement complet à chaque vente | Agrégats SQL (`counts`) | — |
| Sort d’une vente à arbitrer inconnu du terminal | **Pas de renvoi** : en v1, renvoyer une opération à arbitrer relance son intégration (= « Rejouer », test A `RenvoiIdentiqueV1Test`). Consommation gardée jusqu’à une lecture seule de l’état (B-REQ-004) | STK-03 (aucun renvoi) |

Migration 1 → 2 additive, dans la transaction de sqflite : colonne `operations.resolue_le`, tables `mouvements_stock` et `paniers_consommes`, index. UUID, séquences, contenus (à l’octet), statuts et clés `kv` (dont PIN bloqué) inchangés ; mouvements reconstitués (en attente = non couverts ; transmises = couvertes, comme la 1.1.5 les comptait). Rétrogradation refusée sans effacement. Journal SQLite laissé en mode rollback (le WAL d’Android synchronise moins : risque sur la dernière vente en cas de coupure de courant).

Fichiers : `lib/src/offline/store.dart`, `engine.dart`, `models.dart`, `offline_register_page.dart` (identifiant de panier), `test/offline_store_v2_test.dart` (9 tests). Suite complète : **47 tests passés**, `flutter analyze` sans remarque.

Limites : la base locale n’est pas encore testée sur Android réel (seulement SQLite FFI Windows) ; pas de build release ; l’hypothèse « catalogue demandé après l’intégration = stock à jour » repose sur l’intégration synchrone v1 (voir B-REQ-002).

## Incrément 2 — palier « vente locale v1 », côté terminal (fait, non commité)

Décision du propriétaire du 29/10/2026 ; serveur A : `feat/caisse-autonome-serveur` `a6aa354b` (non poussé), contrat
`docs/mobile/CAISSE-HORS-LIGNE-API.md`.

| Élément serveur (A) | Côté terminal | Test |
|---|---|---|
| `couverture_stock` + `?depuis_sequence=N` (B-REQ-002) | Demande avec la séquence de la plus ancienne vente non couverte ; couverture exacte des `integrees` dans la transaction du référentiel, statut local aligné ; `a_arbitrer` et absentes gardées. Serveur sans ce champ : règle demande / sort définitif de l’incrément 1 | couverture exacte, horloge reculée sans effet, alignement |
| `POST /etats` (B-REQ-004) | Lecture de l’état des ventes à arbitrer (200 au plus), au plus toutes les 5 min, 5 min après leur mise à arbitrer ; `inconnue` ignorée ; 404/405 = serveur antérieur, plus de tentative ; jamais de renvoi | lecture sans renvoi, serveur antérieur |
| `reglages.vente_locale_permanente` | `OfflineEngine.permanentLocal` ; caisse locale ouverte d’emblée (`caisse_page`), synchronisation en arrière-plan, catalogue relu à l’intervalle réglé, jamais de retour automatique au web ; bouton « Caisse web » (panier vide exigé) ; bandeau : « à jour », « N à transmettre », « Connexion interrompue — vente locale disponible », « N à arbitrer », « catalogue ancien » | lecture du réglage ; écran 4 et 14 pouces |

Choix B **validé par A** (29/10) : une vente **écartée** est considérée couverte (en v1, écarter ne crée aucun mouvement
serveur ; la garder déduite compterait deux fois une correction de stock manuelle). A l’écrit dans les deux contrats.

Suite : **54 tests passés**, `flutter analyze` sans remarque. Non fait : essai contre le serveur A réel, appareil Android,
build release ; `tronque: true` non traité spécialement (seules les listes reçues sont couvertes).

## Incrément 3 — contrat v2 : canonicalisation et schémas côté terminal (fait, non commité)

Contrat A `71953e43` (révision 2.0.0-l1), copié sans modification dans `test/fixtures/contrat-v2/` (`REVISION.txt` :
commit source ; recopier à chaque révision).

- `lib/src/sync_v2/canonical_json.dart` : SK-JCS-1 en Dart pur (sans Flutter, partageable avec Windows) : refus des
  nombres à virgule et des entiers hors ±(2^53 − 1), clés en ordre UTF-16, échappements du profil, aucune normalisation ;
  demi-paire UTF-16 isolée refusée (Dart la remplacerait en silence par U+FFFD). Empreinte d’opération sans `empreinte`.
- `lib/src/sync_v2/schema_validator.dart` : SK-SCHEMA-1, mêmes mots-clés et mêmes messages que `ValidateurSchema` ; mot-clé
  inconnu = erreur de schéma.
- `test/contrat_v2_test.dart` : **les 20 vecteurs et les 49 fixtures du serveur passent** (contrôles d’empreinte
  d’opération et de page compris), 74 tests.
- Dépendance : `crypto` passé de dépendance indirecte à directe, version verrouillée inchangée (3.0.7) ; `pubspec.lock` :
  seul le statut change.

Suite complète : **128 tests passés**, `flutter analyze` sans remarque. Rien de ce lot n’appelle encore le réseau (routes v2
non implémentées, lot L2 de A).

## Essai d’intégration du palier v1 contre le serveur A — 29/10/2026 05:38 : PASS (2/2)

Serveur A `http://127.0.0.1:8130`, base d’intégration isolée (`feat/caisse-autonome-serveur` ≥ `67defc62`). Client :
vrai moteur, `HttpRegisterTransport`, SQLite réelle (FFI), poste de développement — `test/integration/serveur_a_test.dart`
(`SK_CODE=… SK_PERMANENT=0|1`). Pas encore d’appareil Android.

| Étape | Caisse 2 (id 2, pilote) | Caisse Cocody (id 3, défaut) |
|---|---|---|
| Appairage, `vente_locale_permanente` | OK, `true` | OK, `false` |
| `couverture_stock` présente | oui | oui |
| Session | ouverte hors ligne (fond 0), intégrée | déjà ouverte |
| Vente locale | `HL-002-000002`, uuid `279d03f2-5930-460c-83b5-c4aa083ea5f7`, 1 × Allumettes x10, 150 F | `HL-003-000001`, uuid `0da9d318-09a4-4013-928e-17db99fcd7f1`, 1 × Crème hydratante 200 ml, 5 310 F |
| Accusé | `integree` `V-20261029-0001` ; stock local toujours déduit | `integree` `CO-20261029-0001` ; idem |
| Référentiel suivant | vente dans `integrees` ; stock 60 → 59 ; consommation locale 0 | vente dans `integrees` ; stock 16 → 15 ; consommation locale 0 |
| Renvoi identique | même état, même numéro | même état, même numéro |
| `POST /etats` | `integree` | `integree` |
| Second encaissement du même panier | refusé localement | refusé localement |

UUID de l’ouverture de session de Caisse 2 non relevé (base temporaire supprimée) : à lire côté serveur, séquence 1 du terminal.

## Incrément 4 — moteur pour Windows (réponse à C-REQ-001 à 004)

Contrat : [CONTRAT-MOTEUR-B.md](CONTRAT-MOTEUR-B.md) (version 1). Stockage **schéma 3** (table `paniers`, migration
additive 2 → 3) ; encaissement idempotent par identifiant d'opération ; `saleStatus` local, sérialisé derrière les
encaissements, `not_found` définitif ; `LocalRegisterAdapter` (commandes de C + `pair`, `login`, `addProduct`, `clear`).
Tests : `test/register_adapter_test.dart` (9, SQLite réelle) ; suite **137 tests passés**. C (`79bce79`) a validé
`f61da3e` fusionné sans conflit (21/21 tests Windows).

## Incrément 5 — client de synchronisation v2 (commit 14a1529)

Contrat 2.0.0-l1 (A `71953e43`, schémas identiques à la branche A au 29/10 08:30). Stockage **schéma 4** (tables `v2_*`,
migration additive 3 → 4, tables v1 intactes). `lib/src/sync_v2/` : transport et client (en-têtes, erreurs typées,
réponses validées par les schémas embarqués `contract_schemas.dart`), projection (bootstrap vérifié page par page puis
projection + curseur en une transaction ; journal par groupes, type critique inconnu = arrêt sans sauter), file figée par
empreinte (renvoi identique après réponse perdue, quarantaine `rejet_protocole` jamais renvoyée), couverture mouvement par
mouvement (§6, exemple 10 → 7 → 7 → 7 vérifié), `/operations/etats` en lecture seule, accusés. Vente v2 construite par la
règle de calcul unique du moteur (`money.dart`) et recoupée comme `CoherenceVente`.
Tests : `test/sync_v2_client_test.dart` (16, faux serveur validant chaque requête par le contrat) ;
`test/integration/serveur_a_v2_test.dart` (serveur A réel ; `SK_V2_CODE`, ou reprise `SK_V2_REPRISE` + `SK_V2_VENTE`).
Pas encore branché sur l'écran ni sur l'adaptateur Windows (prochain incrément).

### Essai v2 contre le serveur A — 29/10/2026 09:40 : PASS

Serveur 8130 figé sur A `11d66be1` (contrat 2.0.0), Caisse 2 pilote, code JVME-4K5W. Appairage : époque 10, dernière
séquence 2. Instantané : 176 entités (49 produits, 42 projections de stock, 17 politiques…), curseur c-1. Vente locale
Riz parfumé 5 kg (4 500 F), séquence 3, uuid 181e0701-9771-41f8-b7cb-c67febd79b3e : **integree, V-20261029-0002** ; renvoi
identique → même état et même version, aucun doublon ; `/operations/etats` → integree / inconnue. Couverture : la
projection 55 couvrant la vente arrive par le journal, stock estimé **55** (56 − 1, sans double décompte). Premier passage
en échec côté essai seulement : 5 synchronisations en moins de 2 s, alors que le serveur ne rebalaye qu'au plus toutes les
5 s (`balayage_min_secondes`) ; l'essai sonde désormais au rythme `delais.changements_secondes` ; reprise sur la même
base appairée : PASS.

### Contrat 2.0.1 (A `12dcea4e`, B-REQ-005)

Copie du contrat 2.0.1 (50 fixtures), schémas embarqués régénérés, type critique `boutique` connu du client ;
`V2Store.shopVat()` donne la TVA figée dans la vente (sans entité : aucune TVA devinée). Le serveur d'intégration peut
passer en 2.0.1.

## Incrément 6 — intégration de C et hôte exécutable Windows

Fusion `89556c0` de `feat/caisse-windows-raccordement` (C `02843f4`), sans conflit. Hôte : `lib/src/windows/host/engine_host.dart`
(propriétaire unique de la base : verrou système exclusif `caisse.lock`, valable entre sessions Windows ; origine et panier
restaurés ; synchronisation planifiée toutes les minutes, jamais attendue ; fermeture après la synchronisation et les commandes
en cours) et exécutable `tool/windows/moteur/` (paquet Dart séparé, construit par `Build-Moteur.ps1` :
`build/windows-moteur/bundle/bin/shopikaiss_moteur.exe` + `bundle/lib/sqlite3.dll`). Codes de sortie : 0 EOF, 2 arguments,
3 base déjà possédée, 1 démarrage impossible. `sqflite_common_ffi` reste hors des dépendances de l'application : son hook
natif ajouterait SQLite à l'APK.

Validation sur le commit intégré (29/10) :
- analyse sans remarque ; suite `--exclude-tags integration` **187/187** (avec `SHOPIKAISS_DART_EXECUTABLE`) ;
  `Test-Windows.ps1` **34/34** (30 C + 4 hôte, dont l'exécutable réel piloté par `ProcessWindowsHost`) ;
- Android : `flutter build apk --release` OK, `ci.khoga.shopikaiss.terminal`, versionCode 7, certificat SHA-256
  F5:D8:84:71…C2:C5:1B:EB = clé de release existante ; aucune bibliothèque native ajoutée ;
- Windows : `Build-Integration.ps1` OK (NuGet `C:/dev/nuget` au PATH), `Test-Launch.ps1` PASS, `Test-Native.ps1` 1/1.
Non fait : recette sur téléphone réel, installateur signé.

Fusion `caa9aaa` de C `5cdfb9b` (bootstrap qui lance l'hôte, écrans appairage/PIN, journal `pending-sale.json`), sans
conflit. Revalidation : suite **191/191** ; APK release identique (versionCode 7, certificat F5:D8:84…1B:EB, 9 bibliothèques
natives, aucune SQLite ajoutée).

## Demandes à A

```text
ID : B-REQ-001
Destinataire : A
Base : shopikaiss-web 2221327e (spécification versionnée)
Besoin : commit de la spécification + contrat v2 exécutable (OpenAPI, schémas, fixtures valides/invalides, vecteurs de canonicalisation)
Bloque : tout le réseau v2 côté B ; pas le stockage local
```

```text
ID : B-REQ-002
Destinataire : A
Besoin et scénario : prouver la couverture du stock en v1 sans dépendre de l’horloge. Ajouter au référentiel v1 (champ additif,
ignoré par les clients 1.1.x) la liste bornée des UUID d’opérations hors ligne de l’appareil dont les mouvements sont reflétés
dans ce stock, ou un curseur de soumission « intégrées jusqu’à ».
Compatibilité : additive ; les clients actuels l’ignorent.
Preuve attendue : test serveur snapshot ↔ opération intégrée dans la même transaction.
Bloque : intégration seulement (le client utilise aujourd’hui l’ordre demande/sort définitif).
```

```text
ID : B-REQ-003
Destinataire : A
Besoin : confirmer par test que le renvoi identique d’une opération v1 déjà reçue rend l’état courant sans mutation
(OfflineSubmissionService, même terminal, même empreinte), y compris après « Rejouer » et « Écarter ».
Bloque : rien (comportement lu dans le code), mais à verrouiller par un test serveur.
Réponse A : fait (RenvoiIdentiqueV1Test, 5 tests). Nuance : une opération À ARBITRER renvoyée relance son intégration.
Conséquence B : renvoi automatique des ventes à arbitrer retiré du moteur.
```

```text
ID : B-REQ-004
Destinataire : A
Besoin et scénario : connaître, sans effet de bord, le sort des ventes « à arbitrer » de l’appareil (intégrée après Rejouer,
écartée), pour couvrir leur stock et permettre leur purge. Proposition additive v1 : dans `/etat` ou le référentiel, liste
bornée {uuid, statut, numero} des opérations de l’appareil résolues récemment ; en v2 : `/operations/etats`.
Compatibilité : additive, ignorée par les clients 1.1.x.
Preuve attendue : test « lecture d’état ne déclenche aucune intégration ».
Bloque : purge et stock des ventes arbitrées seulement (sans elle, leur consommation reste déduite indéfiniment).
```

```text
ID : B-REQ-005
Destinataire : A
Besoin et scénario : le journal v2 ne publie pas la TVA de la boutique (taux, incluse/ajoutée) que le référentiel v1 donne
(boutique.tva_taux / tva_incluse). Sans elle, une vente v2 d'une boutique à TVA ajoutée aurait un « a_payer » différent du
total recalculé par l'intégration v1 (vente à arbitrer). Proposition : entité « boutique » ou politiques « tva.taux » /
« tva.incluse » dans donnees.json (révision du contrat).
Bloque : vente v2 dans une boutique à TVA non nulle.
```

## Prochaines étapes B

0. ~~Recette du palier contre le serveur A réel~~ (fait, PASS) ; reste : Android réel.
1. Matrice de parité des parcours mobile actuels (doc 06 § C).
2. Panier durable (brouillon persistant et reprise après redémarrage), écran « vente retrouvée » entre COMMIT et impression.
3. Extraction d’un moteur sans Flutter (interfaces stockage/horloge/transport) et faux moteur pour C — contrat moteur v0.
4. ~~Client v2~~ (incrément 5, essai A PASS) : branchement sur l'écran Android et l'hôte Windows (vente v2 du pilote).
5. ~~Bootstrap Windows~~ (C, fusionné) : recette visuelle et matérielle sur poste pilote.
