# Mission Windows et mobile : caisse autonome v2

Date : 29 octobre 2026. Statut : instructions à implémenter ; aucun binaire ni changement applicatif livré par cette documentation.

Le propriétaire demande une caisse locale permanente Windows/Android, avec service de synchronisation indépendant, actualisation du stock/règles en arrière-plan et arbitrage des conflits entre caisses. Préserver toutes les fonctionnalités existantes et la signature des APK installés.

Le dossier normatif est dans le dépôt compagnon `shopikaiss-web`, chemin `docs/architecture/caisse-autonome/`. Lorsque les dépôts sont voisins, commencer par [00 — Mission et ordre de travail](../../shopikaiss-web/docs/architecture/caisse-autonome/00-MISSION-ET-ORDRE-DE-TRAVAIL.md).

Le travail est réparti en trois sessions : A serveur, B mobile/moteur commun, C Windows. B est seul intégrateur de ce dépôt ; C utilise un worktree distinct et ne modifie pas les fichiers communs. Lire [la coordination](../../shopikaiss-web/docs/architecture/caisse-autonome/08-COORDINATION-TROIS-SESSIONS.md), puis la [consigne B mobile](../../shopikaiss-web/docs/architecture/caisse-autonome/10-SESSION-B-MOBILE.md) ou la [consigne C Windows](../../shopikaiss-web/docs/architecture/caisse-autonome/11-SESSION-C-WINDOWS.md). Les [portes de livraison directe en production](../../shopikaiss-web/docs/architecture/caisse-autonome/12-LIVRAISON-DIRECTE-PRODUCTION.md) s’appliquent avant toute publication ou activation.

Lire ensuite :

- [Architecture et invariants](../../shopikaiss-web/docs/architecture/caisse-autonome/01-ARCHITECTURE-ET-INVARIANTS.md).
- [Contrat de synchronisation v2](../../shopikaiss-web/docs/architecture/caisse-autonome/02-CONTRAT-SYNCHRONISATION-V2.md).
- [Paramètres entreprise et boutique](../../shopikaiss-web/docs/architecture/caisse-autonome/03-PARAMETRES-ENTREPRISE-BOUTIQUE.md).
- [Travail Windows](../../shopikaiss-web/docs/architecture/caisse-autonome/05-TRAVAIL-APPLICATION-WINDOWS.md).
- [Travail mobile et moteur partagé](../../shopikaiss-web/docs/architecture/caisse-autonome/06-TRAVAIL-MOBILE-ET-MOTEUR-PARTAGE.md).
- [Recette et migration](../../shopikaiss-web/docs/architecture/caisse-autonome/07-RECETTE-MIGRATION-ET-EXPLOITATION.md).

Ces liens inter-dépôts sont destinés au workspace local, pas au rendu GitHub d’un dépôt isolé. Si le dépôt compagnon n’est pas présent, récupérer ce dossier avec la révision communiquée par l’agent serveur ; ne pas réinventer un contrat mobile divergent. Consigner le commit de la spécification effectivement utilisé dans chaque livraison.

## Instructions immédiates à l’agent

1. Vérifier HEAD, modifications locales et règles applicables ; coordonner les fichiers avec l’agent actif. Base de l’audit : `c5f9483`, version 1.1.5+7 ; ne pas supposer cette base inchangée.
2. Lire [l’existant hors ligne](CAISSE-HORS-LIGNE.md). Il décrit v1, mode secours et retour au web ; le nouveau dossier décrit une cible distincte.
3. Préserver le protocole v1 pour les serveurs non migrés. Activer v2 par capacité serveur et réglage terminal après migration/bootstrap validés.
4. Extraire les responsabilités du moteur local existant sans dupliquer calculs et règles pour Windows. Respecter les UUID et payloads des opérations déjà enregistrées.
5. Inventorier toutes les fonctions et périphériques ; documenter la parité avant de remplacer le parcours principal.
6. N’introduire aucune nouvelle clé Android, aucun changement de package et aucune purge de SQLite. Vérifier le certificat d’un APK release réellement installé avant livraison.
7. Produire les tests, preuves de migration et mesures demandés ; un test en mémoire ou un build debug ne valide pas une mise à jour de production.

La spécification centralisée prime pour la cible v2 ; le contrat v1 reste applicable à ses clients existants. Toute contradiction doit être résolue dans le dossier commun avec fixtures/tests coordonnés, pas par une exception silencieuse côté plateforme.
