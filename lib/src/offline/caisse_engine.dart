import 'dart:async';
import 'dart:isolate';

import 'package:bcrypt/bcrypt.dart';

import 'models.dart';
import 'money.dart';
import 'notifier.dart';
import 'store.dart';
import 'web_rules.dart';

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
/// Part d'une ligne servie par un lot, en unité de base.
class LotSegment {
  const LotSegment(this.lot, this.base);

  final ProductLot lot;
  final BigInt base;
}

/// Répartit les lignes de produits à lots sur les lots du catalogue courant [s], avec les refus de la caisse web
/// (`LotAllocationService::plan`, `LotSaleSplitter::unitPrice`) ; les lignes du panier se réservent les unes les autres.
Map<CartLine, List<LotSegment>> allocateLots(Snapshot s, List<CartLine> lines) {
  final taken = <String, BigInt>{};
  final result = <CartLine, List<LotSegment>>{};
  for (final line in lines) {
    final product = s.byId(line.product.id) ?? line.product;
    if (!product.managedByLots) continue;
    BigInt left(ProductLot lot) => lot.remaining - (taken[lot.uuid] ?? BigInt.zero);
    var available = product.lots.where((l) => left(l) > BigInt.zero).toList();
    final chosen = line.lot;
    if (chosen != null) {
      available = available.where((l) => l.uuid == chosen.uuid).toList();
      if (available.isEmpty) throw const OfflineRefusal('Le lot choisi est indisponible dans cette boutique.');
    } else if (line.packaging == null && product.lotMode == 'manuel' && available.map((l) => l.price).toSet().length > 1) {
      throw const OfflineRefusal('Choisissez le lot à vendre : plusieurs prix de vente sont disponibles.');
    }
    var rest = baseQuantity(line.quantity, line.packaging?.coefficient);
    final segments = <LotSegment>[];
    for (final lot in available) {
      if (rest <= BigInt.zero) break;
      final part = rest < left(lot) ? rest : left(lot);
      segments.add(LotSegment(lot, part));
      taken[lot.uuid] = (taken[lot.uuid] ?? BigInt.zero) + part;
      rest -= part;
    }
    if (rest > BigInt.zero) throw const OfflineRefusal('Quantité insuffisante dans les lots vendables ; aucune vente sans lot d’origine.');
    if (line.packaging == null && segments.any((x) => x.lot.price != line.unitPrice)) {
      throw const OfflineRefusal('Plusieurs prix de lots : choisissez un lot ou utilisez un conditionnement.');
    }
    result[line] = segments;
  }
  return result;
}

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
  ///
  /// [extras] : remise globale, livraison et note (contrat 2.1) ; refusés si [saleExtrasSupported] est faux.
  Future<OfflineOperation> recordSale(
    List<CartLine> lines,
    List<CartPayment> payments,
    Operator operator, {
    String? draftUuid,
    String? operationUuid,
    SaleExtras extras = const SaleExtras(),
  });

  /// Remise globale, livraison et note utilisables (vente 2.1 acceptée par le serveur).
  bool get saleExtrasSupported => false;

  /// Arrondi des remises en pourcentage (`down` ou `nearest`, règle de la boutique).
  String get percentRounding => 'down';

  /// Arrondi de caisse des espèces (pas et mode), ou null.
  ({int step, String mode})? get cashRounding => null;

  /// Droit exigé pour une livraison (null : aucun droit particulier).
  String? get deliveryRight => null;

  /// Montant dû au tiroir pour une ligne d'espèces de [amount] (arrondi de caisse).
  int cashDue(int amount) {
    final rounding = cashRounding;
    return rounding == null ? amount : cashRound(amount, step: rounding.step, mode: rounding.mode);
  }

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

  /// Retours hors ligne ouverts à [operator] : fermés par défaut (capacité `retour.especes`, `retours.mode`, droits).
  bool returnsOpen(Operator operator) => false;

  /// Lignes encore retournables d'une vente émise par ce terminal ; refus si le terminal ne peut pas chiffrer son retour.
  Future<List<ReturnableLine>> returnableLines(String saleUuid) => throw const OfflineRefusal('Retours non disponibles sur ce terminal.');

  /// Montant à rendre pour ces quantités ([quantities] : `ligne_uuid` → millionièmes de l'unité de base).
  Future<int> returnAmount(String saleUuid, Map<String, int> quantities) => throw const OfflineRefusal('Retours non disponibles sur ce terminal.');

  /// Enregistre le retour en espèces. Tout écart avec le serveur part en arbitrage, sans remboursement écrit.
  Future<OfflineOperation> recordReturn(Operator operator, String saleUuid, Map<String, int> quantities, String reason, {String? operationUuid}) =>
      throw const OfflineRefusal('Retours non disponibles sur ce terminal.');

  /// Paniers partagés avec le web et les autres terminaux (contrat 2.1, capacité `panier.partage`).
  bool get sharedCartsSupported => false;

  /// Paniers publiés visibles depuis ce terminal, le plus récent d'abord.
  Future<List<SharedCart>> sharedCarts() async => const [];

  /// Publie le panier : toujours un nouvel uuid, un panier publié est immuable. Rend sa référence.
  Future<SharedCartRef> suspendShared(Operator operator, List<CartLine> lines, SaleExtras extras, {SharedCartRef? previous, String? label}) =>
      throw const OfflineRefusal('Paniers partagés non disponibles sur ce terminal.');

  /// Reprise exclusive, réseau requis ; renouvelée à chaque synchronisation tant que le panier est tenu.
  Future<TakenCart> takeSharedCart(Operator operator, String uuid) => throw const OfflineRefusal('Paniers partagés non disponibles sur ce terminal.');

  /// Rend le panier repris aux autres caisses ; sans réseau, la reprise expire d'elle-même.
  Future<void> releaseSharedCart(Operator operator, String uuid) async {}

  /// Retire le panier pour tous.
  Future<void> deleteSharedCart(Operator operator, String uuid, {String reason = 'Supprimé sur le terminal'}) async {}

  /// `publie`, `local` (pas encore publié, reprenable hors ligne) ou `disparu` (vendu ou supprimé ailleurs).
  Future<String> sharedCartState(String uuid) async => 'local';

  /// [operator] peut-il clôturer la session ouverte (capacité `session.cloture`, droit `caisse_cloturer`) ?
  bool canCloseSession(Operator operator) => false;

  /// Écarts au regard de ce que le terminal sait de la session ; aucun si l'attendu est inconnu (session ouverte en ligne).
  Future<ClosingGaps> closingGaps(int cash, List<SessionCount> others) async => const ClosingGaps();

  /// Clôture la session, comptée à l'aveugle : le théorique et l'écart reviennent du serveur dans le Z.
  Future<OfflineOperation> closeSession(Operator operator, {required int cash, String? comment, List<SessionCount> others = const [], String? operationUuid}) =>
      throw const OfflineRefusal('Clôture non disponible sur ce terminal.');

  /// Dernière clôture émise par ce terminal, ou null ; son contenu porte `z` une fois intégrée.
  Future<OfflineOperation?> lastClosure() async => null;

  /// Clients de la boutique sur ce terminal (contrat 2.1, capacité `client.lecture`).
  bool get customersSupported => false;

  /// [operator] peut-il créer un client (capacité `client.creation`, droit `clients_creer`) ?
  bool canCreateCustomer(Operator operator) => false;

  /// Clients dont le nom ou le téléphone contient [query], par ordre alphabétique.
  Future<List<Customer>> searchCustomers(String query, {int limit = 30}) async => const [];

  /// Crée un client sur le terminal, ou rend celui qui a déjà ce téléphone.
  Future<Customer> createCustomer(Operator operator, {required String name, String? phone, String? operationUuid}) =>
      throw const OfflineRefusal('Création de client non disponible sur ce terminal.');

  /// Plafonds de saisie : ceux du rôle ; s'il existe un responsable pour autoriser, seul celui de la boutique reste
  /// (le code ne lève que le seuil du rôle). L'autorisation est demandée à l'encaissement, panier définitif.
  int enterableLineDiscount(Operator operator, int base) =>
      approvalAvailable(operator) ? maxLineDiscount(base, snapshot?.rules.maxLineDiscountPercent ?? 0) : maxLineDiscountFor(operator, base);

  int enterableGlobalDiscount(Operator operator, int subtotal) =>
      approvalAvailable(operator) ? maxLineDiscount(subtotal, snapshot?.rules.maxGlobalDiscountPercent ?? 0) : maxGlobalDiscountFor(operator, subtotal);

  int? enterableSaleDiscount(Operator operator) => approvalAvailable(operator) ? null : maxSaleDiscountFor(operator);

  /// Les remises de la vente sont-elles dans les seuils de [operator] ? Chaque remise, puis leur total.
  bool withinDiscountLimits(Operator operator, List<CartLine> lines, int globalDiscount) {
    var total = globalDiscount;
    var subtotal = 0;
    for (final l in lines) {
      if (l.discount > maxLineDiscountFor(operator, l.base)) return false;
      total += l.discount;
      subtotal += l.base - l.discount;
    }
    if (globalDiscount > maxGlobalDiscountFor(operator, subtotal)) return false;
    final cap = maxSaleDiscountFor(operator);
    return cap == null || total <= cap;
  }

  bool _canApprove(Operator approver, Operator cashier) =>
      saleExtrasSupported && approver.id != cashier.id && approver.approver && (approver.approvalCodeHash?.isNotEmpty ?? false) && hasRight(approver, 'remise');

  /// Un responsable du terminal peut-il autoriser pour [cashier] ?
  bool approvalAvailable(Operator cashier) => snapshot?.operators.any((o) => _canApprove(o, cashier)) ?? false;

  /// Responsables dont le seuil couvre les remises de la vente.
  List<Operator> approversFor(Operator cashier, List<CartLine> lines, int globalDiscount) => [
    for (final o in snapshot?.operators ?? const <Operator>[])
      if (_canApprove(o, cashier) && withinDiscountLimits(o, lines, globalDiscount)) o,
  ];

  /// Vérifie le code de [approver] pour la vente de [cashier] et rend l'autorisation à joindre à [SaleExtras].
  Future<SaleApproval> authorizeDiscount({
    required Operator cashier,
    required Operator approver,
    required String code,
    required String reason,
    required List<CartLine> lines,
    required int globalDiscount,
  }) async {
    if (!approversFor(cashier, lines, globalDiscount).any((o) => o.id == approver.id)) {
      throw OfflineRefusal('${approver.name} ne peut pas autoriser cette remise.');
    }
    final motive = reason.trim();
    if (motive.isEmpty || motive.length > 500) throw const OfflineRefusal('Indiquez le motif de la remise (500 caractères au plus).');
    final wait = await approvalLockedFor(approver);
    if (wait != null) throw OfflineRefusal('Trop d’essais : réessayez dans ${wait.inSeconds + 1} s.');
    if (!await checkApprovalCode(approver, code)) throw const OfflineRefusal('Code d’autorisation incorrect.');
    return SaleApproval(approverId: approver.id, reason: motive, verifiedAt: now.toUtc().toIso8601String());
  }

  /// Fichier local de [image] s'il est déjà téléchargé, sinon null (contrat 2.1).
  String? imagePath(ProductImage image) => null;

  /// Télécharge les images manquantes, hors vente ; rend le nombre de fichiers ajoutés. [interrupted] est relu avant chaque
  /// image : une vente qui commence arrête le lot.
  Future<int> downloadImages({bool Function()? interrupted}) async => 0;

  /// Cache d'images disponible sur ce terminal.
  bool get imagesSupported => false;

  /// Plage horaire locale du téléchargement (`HH:MM`, peut passer minuit), null = à toute heure.
  ({String start, String end})? get imageWindow => null;

  Future<void> setImageWindow(({String start, String end})? window) async {}

  /// Images du catalogue déjà en cache et au total.
  ({int cached, int total}) imageCounts() => (cached: 0, total: 0);

  /// Politique de survente de la boutique (`refuser`, `autoriser_avec_droit`), null si elle n'est pas publiée.
  String? get oversellPolicy => null;

  /// Badge « Nouveau » : nombre de jours depuis la création, null = désactivé (contrat 2.1).
  int? get newBadgeDays => null;

  /// Remise globale maximale (francs) de [operator] sur un sous-total de [subtotal] : politique
  /// `remises.globale_max_pourcent` et, s'il est publié, plafond du rôle — le plus petit des deux.
  int maxGlobalDiscountFor(Operator operator, int subtotal) => maxLineDiscount(subtotal, snapshot?.rules.maxGlobalDiscountPercent ?? 0);

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
    return _checkSecret('${StoreKeys.pinFailures}${operator.id}', RegExp(r'^\d{4,6}$').hasMatch(pin), pin, operator.pinHash!);
  }

  /// Vérifie le code de 8 chiffres d'un responsable, jamais son PIN ; échecs comptés comme ceux du PIN, par responsable.
  Future<bool> checkApprovalCode(Operator approver, String code) async {
    final hash = approver.approvalCodeHash;
    if (hash == null || hash.isEmpty || await approvalLockedFor(approver) != null) return false;
    return _checkSecret('${StoreKeys.approvalFailures}${approver.id}', RegExp(r'^\d{8}$').hasMatch(code), code, hash);
  }

  Future<bool> _checkSecret(String key, bool wellFormed, String secret, String hash) async {
    if (wellFormed && await _verifyPin(secret, hash)) {
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
  Future<Duration?> pinLockedFor(Operator operator) => _lockedFor('${StoreKeys.pinFailures}${operator.id}');

  /// Attente restante avant un nouvel essai de code pour ce responsable, ou null.
  Future<Duration?> approvalLockedFor(Operator approver) => _lockedFor('${StoreKeys.approvalFailures}${approver.id}');

  Future<Duration?> _lockedFor(String key) async {
    final raw = await store.read(key);
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
      final amount = (m['montant'] as num).toInt();
      payments.add(CartPayment(method: method, amount: amount, received: (m['recu'] as num?)?.toInt(), cashDue: method.isCash ? cashDue(amount) : amount));
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
  int checkSale(Snapshot s, List<CartLine> lines, List<CartPayment> payments, [SaleExtras extras = const SaleExtras()]) {
    if (lines.isEmpty) throw const OfflineRefusal('Le panier est vide.');
    if (lines.length > 100) throw const OfflineRefusal('Au plus 100 lignes par vente.');
    for (final line in lines) {
      if (line.quantity <= BigInt.zero) throw OfflineRefusal('Quantité invalide pour « ${line.label} ».');
      if (line.discount > maxLineDiscount(line.base, s.rules.maxLineDiscountPercent)) {
        throw OfflineRefusal('Remise sur « ${line.label} » au-delà du maximum hors ligne (${s.rules.maxLineDiscountPercent} %).');
      }
    }
    allocateLots(s, lines);
    if ((extras.note?.length ?? 0) > 2000) throw const OfflineRefusal('Note trop longue (2 000 caractères au plus).');
    final WebTotals totals;
    try {
      totals = webTotals(
        lineBases: [for (final l in lines) l.base],
        lineDiscounts: [for (final l in lines) l.discount],
        globalDiscount: extras.globalDiscount,
        vatRate: s.store.vatRate,
        vatIncluded: s.store.vatIncluded,
        delivery: extras.delivery,
      );
    } on WebRuleRefusal catch (e) {
      throw OfflineRefusal(e.message);
    }
    if (s.rules.maxSaleAmount != null && totals.payable > s.rules.maxSaleAmount!) {
      throw OfflineRefusal('Vente au-dessus du montant maximal hors ligne (${formatFcfa(s.rules.maxSaleAmount!)}).');
    }
    final allowed = {for (final m in s.methods) m.code};
    var paid = 0;
    for (final payment in payments) {
      if (!allowed.contains(payment.method.code)) throw OfflineRefusal('« ${payment.method.name} » n’est pas autorisé hors ligne.');
      if (payment.amount <= 0) throw const OfflineRefusal('Chaque paiement doit être positif.');
      if (payment.method.isCash && (payment.received ?? cashDue(payment.amount)) < cashDue(payment.amount)) {
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
