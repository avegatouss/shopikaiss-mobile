# Caisse hors ligne — application ShopiKaiss Mobile

Branche `hors-ligne/caisse-mobile-2026-10-18` (autonome, utilisable comme l'application existante). Décision et
arbitrages : `shopikaiss-web/docs/decisions/ADR-421-CAISSE-MOBILE-HORS-LIGNE-ET-TERMINAL-EXCLUSIF.md`. Contrat d'API :
`shopikaiss-web/docs/mobile/CAISSE-HORS-LIGNE-API.md`. La boutique doit tourner sur la branche du même nom de
shopikaiss-web (migration `2026_10_18_100000_create_offline_register_tables`).

## Ce que fait l'application

1. **En ligne** : la caisse web, comme avant (pont `ShopiKaissNative`, imprimante, afficheur). Si le terminal est
   appairé, l'application teste la boutique toutes les 20 s (réglable), envoie les ventes restées en file et
   rafraîchit son catalogue toutes les 30 min. Elle pose le cookie `sk_appareil` (clé web) pour le mode « terminal
   réservé à l'application ».
2. **Coupure** : deux tests manqués de suite → caisse hors ligne en plein écran (ou bouton « Caisse hors ligne » si la
   boutique a choisi « proposer », et toujours sur l'écran « Boutique injoignable »).
3. **Hors ligne** : choix du caissier et PIN (vérifié sur le terminal), ouverture de session si aucune n'était ouverte,
   recherche ou scan, panier, encaissement (moyens autorisés, monnaie), vente écrite en SQLite **avant** le ticket,
   ticket ESC/POS `HL-<terminal>-<séquence>`, tiroir. Bandeau : dernier contact, temps restant, ventes en attente.
4. **Retour** : envoi de la file dans l'ordre, puis retour automatique à la caisse web si tout est parti et le panier
   vide. Journal : bouton « reçu » du bandeau, ou Réglages › Caisse hors ligne › Opérations hors ligne.

Arrêt de la vente hors ligne : durée dépassée depuis le dernier contact (72 h), file pleine (500), licence expirée,
vente désactivée par la boutique, application révoquée.

## Mise en service

1. Installer l'APK, saisir l'adresse de la boutique (inchangé).
2. Dans ShopiKaiss : Paramètres › Caisse hors ligne › « Appairer » sur la ligne du terminal → code `ABCD-EFGH`.
3. Dans l'application : 5 touchers en haut à gauche › Réglages › Caisse hors ligne › saisir le code › « Appairer ».
   Le catalogue est téléchargé aussitôt (nombre d'articles affiché).
4. Facultatif : régler l'exclusivité « terminal réservé à l'application » dans ShopiKaiss.

## Architecture

```
lib/src/offline/
  money.dart                     calcul identique à SaleCalculator (fixture serveur : test/fixtures/calcul_serveur.json)
  models.dart                    référentiel, panier, opérations, payload du contrat
  store.dart                     SQLite (appairage, référentiel, file) ; mémoire pour les tests
  api.dart                       client HTTP /api/caisse/v1
  engine.dart                    règles, limites, file, synchronisation, PIN bcrypt
  ticket.dart                    ticket hors ligne ESC/POS (32/48 colonnes, sans accents)
  offline_register_page.dart     écran de caisse hors ligne
  pending_operations_page.dart   journal des opérations
  offline_settings_section.dart  section « Caisse hors ligne » des réglages
```

## Tests

```bash
export JAVA_HOME="/c/Program Files/Android/openjdk/jdk-21.0.8" PATH="/c/dev/flutter/bin:$PATH"
flutter analyze
flutter test                       # 22 tests, dont 306 paniers calculés par le serveur
flutter build apk --release
```

Régénérer la fixture de calcul après un changement de `SaleCalculator` : script
`tool/calcul_serveur.php` (à lancer depuis shopikaiss-web, voir son en-tête).

### Essai de bout en bout (fait en local le 2026-10-18)

Contre une boutique réelle (serveur local sur base SQLite, ou recette) :

```bash
# shopikaiss-web, branche hors-ligne/caisse-mobile-2026-10-18, base d'essai :
export DB_CONNECTION=sqlite DB_DATABASE=/chemin/e2e.sqlite SHOPIKAISS_DEMO_MODE=true SESSION_DRIVER=array CACHE_STORE=array
php artisan migrate:fresh --force
php ../shopikaiss-mobile/tool/essai-hors-ligne-seed.php   # boutique d’essai, deux terminaux : affiche deux codes
php artisan serve --host=127.0.0.1 --port=8765
# shopikaiss-mobile :
flutter test integration_local/serveur_local_test.dart \
  --dart-define=SK_URL=http://127.0.0.1:8765 --dart-define=SK_CODE1=XXXX-XXXX --dart-define=SK_CODE2=YYYY-YYYY
```

Résultat obtenu : appairage des deux terminaux, référentiel, PIN, deux ventes hors ligne du même article (stock 5,
4 + 3 vendus), synchronisation → `V-20261018-0001` (ticket `HL-001-000001`) et `V-20261018-0002` (`HL-002-000001`),
renvoi sans doublon, stock −2 avec anomalie ouverte, date de vente du terminal, numéro hors ligne en commentaire.

## À faire par l'exploitant (non faisable ici)

- **Recette sur terminal physique** : couper le Wi-Fi pendant la caisse web, vérifier la bascule (≈ 40 s), vendre,
  imprimer, ouvrir le tiroir, éteindre et rallumer le terminal pendant la coupure (la file doit être retrouvée),
  rétablir le Wi-Fi et vérifier l'intégration dans ShopiKaiss (Ventes, Paramètres › Caisse hors ligne).
- **Déployer la branche shopikaiss-web** (migration + `npm run build` non nécessaire : aucune ressource front ajoutée)
  avant de distribuer l'APK : sans l'API, l'application reste une caisse web ordinaire (l'appairage échoue proprement).
- **Clé de signature** : l'APK de `dist/` est signé avec `android/shopikaiss-release.jks` (non versionnée, à sauvegarder).
- Vérifier sur le terminal la durée de vérification du PIN (bcrypt, coût 12) : quelques secondes sur un terminal lent.
