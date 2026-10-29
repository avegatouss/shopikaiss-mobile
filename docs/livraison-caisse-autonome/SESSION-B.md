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

## Prochaines étapes B

0. ~~Recette du palier contre le serveur A réel~~ (fait, PASS) ; reste : Android réel.
1. Matrice de parité des parcours mobile actuels (doc 06 § C).
2. Panier durable (brouillon persistant et reprise après redémarrage), écran « vente retrouvée » entre COMMIT et impression.
3. Extraction d’un moteur sans Flutter (interfaces stockage/horloge/transport) et faux moteur pour C — contrat moteur v0.
4. Client v2 dès réception des fixtures de A.
