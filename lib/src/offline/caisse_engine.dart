import 'dart:async';
import 'dart:isolate';

import 'package:bcrypt/bcrypt.dart';

import 'models.dart';
import 'money.dart';
import 'notifier.dart';
import 'store.dart';

/// Vérifie un PIN contre l'empreinte bcrypt du serveur (Laravel écrit `$2y$`, équivalent de `$2a$`).
Future<bool> verifyPinHash(String pin, String hash) => Isolate.run(() => _checkPin([pin, hash]));

bool _checkPin(List<String> args) {
  final hash = args[1].startsWith(r'$2y$') ? '\$2a\$${args[1].substring(4)}' : args[1];
  try {
    return BCrypt.checkpw(args[0], hash);
  } catch (_) {
    return false;
  }
}

/// Bilan d'un envoi de la file au serveur.
class SyncReport {
  const SyncReport({this.sent = 0, this.integrated = 0, this.pending = 0, this.refused = 0, this.deferred = 0, this.reachable = true, this.message});

  final int sent;
  final int integrated;

  /// Reçues mais à arbitrer côté boutique (conservées sur le serveur).
  final int pending;
  final int refused;

  /// Gardées sur le terminal : le serveur les a refusées pour l'instant (erreur 5xx), nouvel essai plus tard.
  final int deferred;
  final bool reachable;
  final String? message;
}

/// Refus lisible d'une vente hors ligne (règle de la boutique, saisie).
class OfflineRefusal implements Exception {
  const OfflineRefusal(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Moteur de caisse locale vu par les écrans (Android) et l'adaptateur Windows, quel que soit le protocole de
/// synchronisation : v1 ([OfflineEngine]) ou v2 (`V2Engine`). Le catalogue est toujours présenté en [Snapshot], les
/// opérations en [OfflineOperation] : les écrans et le protocole de l'hôte Windows ne dépendent pas du protocole.
///
/// Partagé ici : état de contact, PIN hors ligne (échecs gardés sur le terminal), ticket, paniers conservés, file
/// d'écriture.
abstract class CaisseEngine extends EngineNotifier {
  CaisseEngine({required this.store, DateTime Function()? clock, Future<bool> Function(String pin, String hash)? pinVerifier})
    : _clock = clock ?? DateTime.now,
      _verifyPin = pinVerifier ?? verifyPinHash;

  /// Stockage local : clés/valeurs, paniers conservés, échecs de PIN (et file v1).
  final OfflineStore store;
  final DateTime Function() _clock;
  final Future<bool> Function(String pin, String hash) _verifyPin;

  String? apiBase;
  String? webToken;
  String? deviceName;
  Snapshot? snapshot;
  DateTime? snapshotAt;
  DateTime? lastContact;
  DateTime? offlineSince;

  /// Dernier état connu du serveur : null = pas encore testé.
  bool? reachable;

  /// Ventes en attente pour une autre boutique que celle des réglages (voir [load]).
  bool shopMismatch = false;

  /// Dernier test : boutique injoignable (réseau), et non une réponse d'erreur du serveur.
  bool lastUnreachable = false;

  /// Application révoquée côté boutique (401) : il faut l'appairer de nouveau.
  bool revoked = false;
  int pendingCount = 0;
  int pendingSales = 0;
  int refusedCount = 0;

  /// Ventes reçues par le serveur mais à arbitrer, d'après le dernier état connu du terminal.
  int localArbitrationCount = 0;

  DateTime get now => _clock();

  bool get paired;

  /// Terminal pilote de la vente locale permanente : la caisse locale est la caisse principale, connectée ou non ; la
  /// caisse web reste accessible à la demande.
  bool get permanentLocal;
  bool get syncing;

  /// Session de caisse utilisable pour vendre localement.
  bool get sessionOpen;

  /// Raison qui empêche de vendre localement, ou null si la vente est possible.
  String? get blockReason;

  /// Charge l'état conservé pour la boutique [origin] (`https://boutique.exemple.ci`).
  Future<void> load(String origin);

  /// Adresse de la boutique conservée par le dernier [load] ou appairage, ou null.
  Future<String?> storedOrigin();

  /// Échange d'un code d'appairage. Renvoie le message d'erreur, ou null en cas de succès.
  Future<String?> pair(String code, {required String model, required String appVersion});

  /// Oublie l'appairage (la file reste sur le terminal).
  Future<void> unpair();

  /// Test de la boutique : met à jour [reachable] et le dernier contact.
  Future<bool> probe();

  /// Met le catalogue à jour. Renvoie le message d'erreur, ou null.
  Future<String?> refreshSnapshot();

  /// Envoie la file et lit le sort des opérations.
  Future<SyncReport> sync();

  /// Ouverture de session locale (fond compté sur le terminal), transmise au serveur.
  Future<OfflineOperation> openSession(int float, Operator operator);

  /// Enregistre une vente locale (avant l'impression du ticket). Lève [OfflineRefusal] si une règle s'y oppose.
  ///
  /// [operationUuid] : identifiant stable choisi par l'écran AVANT l'encaissement. Rejouer la même commande rend la
  /// vente déjà enregistrée, sans en créer une seconde ; un second encaissement du panier [draftUuid] est refusé.
  Future<OfflineOperation> recordSale(List<CartLine> lines, List<CartPayment> payments, Operator operator, {String? draftUuid, String? operationUuid});

  /// État local d'une vente, sans réseau ni renvoi.
  Future<OfflineOperation?> saleStatus(String operationUuid);

  /// Quantité vendue localement par produit, encore absente du stock du catalogue (pour un stock indicatif à jour).
  Future<Map<int, BigInt>> soldSinceSnapshot();

  Future<List<OfflineOperation>> history();

  /// L'opérateur a-t-il le droit métier [right] (`vente`, `ouverture_session`, `remise`) ? Contrôlé de nouveau par le
  /// moteur au moment de l'écriture ; l'écran s'en sert pour proposer ou non l'action.
  bool hasRight(Operator operator, String right);

  /// Remise maximale (francs) que [operator] peut accorder sur une ligne de [base] francs : plafond du terminal
  /// (`remises.ligne_max_pourcent`) et, s'il est publié (contrat 2.1), celui de son rôle — le plus petit des deux.
  int maxLineDiscountFor(Operator operator, int base) => maxLineDiscount(base, snapshot?.rules.maxLineDiscountPercent ?? 0);

  /// Total des remises permis à [operator] sur une vente (contrat 2.1 `remise_max_montant`), ou null sans limite.
  int? maxSaleDiscountFor(Operator operator) => null;

  /// Heures restantes avant l'arrêt de la vente locale.
  Duration? get remaining {
    final s = snapshot;
    final contact = lastContact ?? snapshotAt;
    if (s == null || contact == null) return null;
    final left = Duration(hours: s.rules.maxHours) - now.difference(contact);
    return left.isNegative ? Duration.zero : left;
  }

  /// Le catalogue a-t-il dépassé l'intervalle de mise à jour réglé par la boutique ?
  bool get snapshotStale {
    final at = snapshotAt;
    final s = snapshot;
    if (at == null || s == null) return true;
    return now.difference(at) > Duration(minutes: s.rules.refreshMinutes);
  }

  /// Vérifie un PIN hors ligne. Les échecs sont gardés sur le terminal (redémarrer l'application ne les efface pas) :
  /// même progression que le serveur (PinService) — 3 essais, puis 30 s doublées à chaque nouvel échec, 15 min au plus.
  ///
  /// Opérateur sans PIN défini (empreinte nulle) : refusé sans compter d'échec (contrat v2 2.0.2) — voir [pinDefined].
  Future<bool> checkPin(Operator operator, String pin) async {
    if (!pinDefined(operator)) return false;
    if (await pinLockedFor(operator) != null) return false;
    final hash = operator.pinHash!;
    final ok = RegExp(r'^\d{4,6}$').hasMatch(pin) && await _verifyPin(pin, hash);
    final key = '${StoreKeys.pinFailures}${operator.id}';
    if (ok) {
      await store.write(key, null);
      return true;
    }
    final failures = (int.tryParse((await store.read(key))?.split('|').first ?? '') ?? 0) + 1;
    final lockedUntil = failures >= 3 ? now.add(Duration(seconds: (30 * (1 << (failures - 3).clamp(0, 5))).clamp(30, 900))) : null;
    await store.write(key, '$failures|${lockedUntil?.toUtc().toIso8601String() ?? ''}');
    return false;
  }

  /// L'opérateur a-t-il un PIN défini côté boutique ? Sinon : motif « PIN non défini », jamais un échec compté.
  bool pinDefined(Operator operator) => operator.pinHash != null && operator.pinHash!.isNotEmpty;

  /// Attente restante avant un nouvel essai de PIN pour ce caissier, ou null.
  Future<Duration?> pinLockedFor(Operator operator) async {
    final raw = await store.read('${StoreKeys.pinFailures}${operator.id}');
    final until = DateTime.tryParse(raw?.split('|').elementAtOrNull(1) ?? '');
    if (until == null || !now.isBefore(until)) return null;
    return until.difference(now);
  }

  /// Lignes et paiements d'une vente locale enregistrée, pour réimprimer son ticket : prix et quantités tels
  /// qu'encaissés (jamais ceux du catalogue actuel), nom de l'article lu dans le catalogue du terminal.
  (List<CartLine>, List<CartPayment>) ticketParts(OfflineOperation operation) {
    final s = snapshot;
    final lines = <CartLine>[];
    for (final raw in (operation.content['lignes'] as List? ?? const [])) {
      final m = Map<String, dynamic>.from(raw as Map);
      final id = (m['produit_id'] as num).toInt();
      final product =
          s?.products.where((p) => p.id == id).firstOrNull ??
          Product({'id': id, 'nom': m['libelle'] ?? 'Article n° $id', 'prix': (m['prix_unitaire'] as num?)?.toInt() ?? 0});
      lines.add(
        CartLine(
          product: product,
          packaging: product.packaging((m['conditionnement_id'] as num?)?.toInt()),
          quantity: parseMicros('${m['quantite']}') ?? BigInt.zero,
          discount: (m['remise'] as num?)?.toInt() ?? 0,
          fixedPrice: (m['prix_unitaire'] as num?)?.toInt(),
        ),
      );
    }
    final payments = <CartPayment>[];
    for (final raw in (operation.content['paiements'] as List? ?? const [])) {
      final m = Map<String, dynamic>.from(raw as Map);
      final code = '${m['moyen']}';
      final method =
          s?.methods.where((x) => x.code == code).firstOrNull ?? PaymentMethodInfo({'code': code, 'nom': code, 'especes': code == 'especes'});
      payments.add(CartPayment(method: method, amount: (m['montant'] as num).toInt(), received: (m['recu'] as num?)?.toInt()));
    }
    return (lines, payments);
  }

  /// Conserve le panier en cours (révision croissante). Faux si une révision plus récente est conservée ou si le
  /// panier est déjà encaissé.
  Future<bool> saveDraft(String uuid, int revision, Map<String, dynamic> content) => serialized(() => store.saveDraft(uuid, revision, content));

  Future<List<StoredDraft>> openDrafts() => store.openDrafts();

  Future<void> deleteDraft(String uuid) => serialized(() => store.deleteDraft(uuid));

  /// File d'écriture locale : une commande d'encaissement à la fois (double clic, deux écrans), dans l'ordre d'arrivée.
  Future<void> _writeQueue = Future.value();

  Future<T> serialized<T>(Future<T> Function() action) {
    final result = _writeQueue.then((_) => action());
    _writeQueue = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// Contrôles de la vente communs aux deux protocoles (règles de la boutique, paiements). Rend le total à payer.
  int checkSale(Snapshot s, List<CartLine> lines, List<CartPayment> payments) {
    if (lines.isEmpty) throw const OfflineRefusal('Le panier est vide.');
    if (lines.length > 100) throw const OfflineRefusal('Au plus 100 lignes par vente.');
    for (final line in lines) {
      if (line.quantity <= BigInt.zero) throw OfflineRefusal('Quantité invalide pour « ${line.label} ».');
      if (line.discount > maxLineDiscount(line.base, s.rules.maxLineDiscountPercent)) {
        throw OfflineRefusal('Remise sur « ${line.label} » au-delà du maximum hors ligne (${s.rules.maxLineDiscountPercent} %).');
      }
    }
    final totals = saleTotals([for (final l in lines) l.total], s.store.vatRate, s.store.vatIncluded);
    if (s.rules.maxSaleAmount != null && totals.payable > s.rules.maxSaleAmount!) {
      throw OfflineRefusal('Vente au-dessus du montant maximal hors ligne (${formatFcfa(s.rules.maxSaleAmount!)}).');
    }
    final allowed = {for (final m in s.methods) m.code};
    var paid = 0;
    for (final payment in payments) {
      if (!allowed.contains(payment.method.code)) throw OfflineRefusal('« ${payment.method.name} » n’est pas autorisé hors ligne.');
      if (payment.amount <= 0) throw const OfflineRefusal('Chaque paiement doit être positif.');
      if (payment.method.isCash && (payment.received ?? payment.amount) < payment.amount) {
        throw const OfflineRefusal('Le montant reçu est inférieur au montant espèces à régler.');
      }
      paid += payment.amount;
    }
    if (paid != totals.payable) {
      throw OfflineRefusal('La somme des paiements (${formatFcfa(paid)}) ne correspond pas au montant à payer (${formatFcfa(totals.payable)}).');
    }
    return totals.payable;
  }

  /// Rejeu d'une commande d'encaissement : l'identifiant doit désigner une vente.
  OfflineOperation sameSale(OfflineOperation existing) {
    if (!existing.isSale) throw OfflineRefusal('Identifiant déjà utilisé par une autre opération (${existing.type}).');
    return existing;
  }

  static final uuidPattern = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
}
