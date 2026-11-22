import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:bcrypt/bcrypt.dart';

import '../passes/pass_rules.dart';
import '../restaurant/resto_context.dart';
import '../restaurant/resto_engine.dart';
import '../restaurant/resto_interface.dart';
import 'cash_book.dart';
import 'catalogue_edit.dart';
import 'local_sessions.dart';
import 'models.dart';
import 'pre_sale.dart';
import 'register_interface.dart';
import 'money.dart';
import 'notifier.dart';
import 'store.dart';
import 'web_rules.dart';
import 'x_z_report.dart';

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
    if (line.packaging == null && segments.any((x) => x.lot.price != line.retailPrice)) {
      throw const OfflineRefusal('Plusieurs prix de lots : choisissez un lot ou utilisez un conditionnement.');
    }
    if (line.wholesaleRefused) {
      throw const OfflineRefusal('Tarif gros refusé pour un produit vendu au prix de ses lots (règle de la boutique) : vendez-le au détail ou par un conditionnement.');
    }
    result[line] = segments;
  }
  return result;
}

class OfflineRefusal implements Exception {
  const OfflineRefusal(this.message, {this.code});

  final String message;

  /// Code d'erreur stable pour l'adaptateur (ex. `code_deja_utilise`) ; null : refus ordinaire.
  final String? code;

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

  // ------------------------------------------------------------------ Sessions locales et synchro (2.1 lot 12)

  /// Dernier essai de synchronisation (test ou envoi), pour le compte à rebours de l'indicateur.
  DateTime? lastSyncAttempt;

  /// Délai entre deux envois automatiques : `delais.changements_secondes` en v2, sinon le sondage publié (20 s).
  int get syncIntervalSeconds => snapshot?.rules.probeSeconds ?? 20;

  /// Opérations reçues par la boutique mais en attente d'une session précédente (raisons `session.*`, `journee.*`).
  int waitingCount = 0;

  /// Envoi automatique dû : aucun essai encore, ou délai écoulé depuis le dernier.
  bool get syncDue => lastSyncAttempt == null || !now.isBefore(lastSyncAttempt!.add(Duration(seconds: syncIntervalSeconds)));

  /// État de synchronisation pour la barre de la caisse.
  SyncStatus get syncStatus => SyncStatus(
    pending: pendingCount,
    arbitration: localArbitrationCount,
    waiting: waitingCount,
    refused: refusedCount,
    intervalSeconds: syncIntervalSeconds,
    reachable: reachable,
    lastContact: lastContact,
    offlineSince: offlineSince,
    lastAttempt: lastSyncAttempt,
    syncing: syncing,
  );

  /// Capacité `session.multiple` accordée : sessions locales séparées, plafond, Z de journée du terminal.
  bool get multipleSessionsSupported => false;

  /// Plafond publié `boutique.regles.sessions_locales.max` (20 par défaut).
  int get localSessionsMax => 20;

  /// Sessions de ce terminal, de la plus ancienne à la plus récente (vide sans la capacité).
  Future<List<LocalSession>> localSessions() async => const [];

  /// Pourquoi une session ne peut pas s'ouvrir maintenant (plafond, clôture à arbitrer sans la capacité), ou null.
  Future<String?> sessionOpeningBlocker() async => null;

  /// Jour d'exploitation de la prochaine session (`AAAA-MM-JJ`) : aujourd'hui, ou le lendemain du dernier Z de journée
  /// du terminal s'il a déjà clos aujourd'hui.
  Future<String> businessDay() async => PassDay.of(now, null);

  /// Jour civil de la boutique aujourd'hui (`AAAA-MM-JJ`).
  String get today => dayOf(now);

  /// Jour civil de la boutique d'un instant (`AAAA-MM-JJ`, fuseau publié quand il est connu).
  String dayOf(DateTime date) => PassDay.of(date, null);

  /// Interface de la caisse publiée pour ce terminal (2.1 lot 13, `interface_caisse`) ; défauts sans la capacité.
  RegisterInterface get publishedInterface => RegisterInterface.defaults;

  // ------------------------------------------------------------------ Prévente / réservations (2.1 lot 15)

  /// Capacité `prevente.v1` accordée et option de la boutique (`boutique.regles.prevente.actif`).
  bool get preSaleSupported => false;

  /// Pourquoi [operator] ne peut pas utiliser la prévente, ou null.
  String? preSaleBlocker(Operator? operator) => 'Prévente non disponible sur ce terminal.';

  /// Préventes connues du poste (les siennes et celles publiées par la boutique), la plus récente d'abord ; [query] :
  /// code, nom ou téléphone ; [openOnly] : ouvertes seulement.
  Future<List<PreSale>> preSales({String query = '', bool openOnly = false}) async => const [];

  /// Nouvelle prévente : client (nom obligatoire), lignes du panier, acompte facultatif sur un moyen de la boutique.
  Future<PreSale> createPreSale(
    Operator operator, {
    required String customerName,
    String? customerPhone,
    String? customerUuid,
    DateTime? pickupAt,
    required List<CartLine> lines,
    int deposit = 0,
    PaymentMethodInfo? depositMethod,
    int? received,
    String? reference,
    String? note,
    String? operationUuid,
  }) => throw const OfflineRefusal('Prévente non disponible sur ce terminal.');

  /// Désistement : motif obligatoire, remboursement facultatif de tout ou partie de l'acompte.
  Future<PreSale> cancelPreSale(Operator operator, String uuid, {required String reason, PaymentMethodInfo? refundMethod, int refund = 0, String? reference, String? operationUuid}) =>
      throw const OfflineRefusal('Prévente non disponible sur ce terminal.');

  /// Lignes de la prévente remises au panier pour son retrait (produits encore au catalogue local).
  List<CartLine> preSaleCart(PreSale preSale) => const [];

  // ------------------------------------------------------------------ Logo de la boutique (capacité boutique.logo)

  /// La boutique publie son logo (ou l'absence de logo) : la copie locale importée sur le poste n'est plus utilisée.
  bool get shopLogoPublished => false;

  /// Uuid du logo de la boutique téléchargé sur ce terminal, null sinon.
  String? get shopLogoUuid => null;

  /// Échec du dernier téléchargement du logo publié, null sinon.
  String? get shopLogoError => null;

  /// Logo à imprimer en tête des documents, à partir de la copie locale [local] (PNG normalisé).
  Uint8List? receiptLogo(Uint8List? local) => local;

  // ------------------------------------------------------------------ Remise à zéro (2.1 lot 17)

  /// Capacité `remise.zero` accordée : la boutique peut remettre ce terminal à zéro avant la production.
  bool get shopResetSupported => false;

  /// Avis de la dernière remise à zéro appliquée sur ce terminal, à montrer une fois ; null sinon.
  String? get shopResetNotice => null;

  /// L'avis de remise à zéro a été lu.
  Future<void> acknowledgeShopReset() async {}

  // ------------------------------------------------------------------ Mobile money → espèces (2.1 lot 16)

  /// Règle `boutique.regles.transfert_especes` publiée et capacité `transfert.especes` accordée.
  bool get cashTransferSupported => false;

  /// Solde de la session ouverte par moyen transférable (encaissé moins remboursé moins déjà transféré), > 0 seulement.
  Future<List<(String, int)>> cashTransferPreview() async => const [];

  /// Pourquoi [operator] ne peut pas transférer maintenant, ou null.
  Future<String?> cashTransferBlocker(Operator? operator) async => 'Transfert vers les espèces non disponible sur ce terminal.';

  /// Transfère vers les espèces tout le solde des moyens réglés (une ligne par moyen), hors connexion compris.
  Future<OfflineOperation> recordCashTransfer(Operator operator, {String? reason, String? operationUuid}) =>
      throw const OfflineRefusal('Transfert vers les espèces non disponible sur ce terminal.');

  // ------------------------------------------------------------------ Livre de caisse (2.1 lot 14)

  /// Livre en ligne proposé : capacité `livre_caisse.v1` accordée par le serveur.
  bool get onlineCashBookSupported => false;

  /// [operator] peut-il lire le livre en ligne (droit publié `livre_caisse_voir`, gérants) ?
  bool canReadOnlineCashBook(Operator operator) => onlineCashBookSupported && hasRight(operator, 'livre_caisse_voir');

  /// Livre local du poste sur `from..to` (jours de la boutique), sans réseau. Un caissier sans `livre_caisse_voir` ne
  /// voit que les sessions qu'il a ouvertes ; null : file non lisible sur ce terminal.
  Future<CashBook?> localCashBook(Operator operator, {required String from, required String to}) async {
    final facts = await closureFacts();
    final s = snapshot;
    if (facts == null || s == null) return null;
    final error = cashBookPeriodError(from, to, today);
    if (error != null) throw OfflineRefusal(error);
    return buildLocalCashBook(facts, ZContext.of(s, publishedCashCodes: await publishedCashCodes()), from: from, to: to, dayOf: dayOf,
        onlyOpener: hasRight(operator, 'livre_caisse_voir') ? null : operator.id);
  }

  /// Livre en ligne de la boutique (`GET /livre-caisse`, toutes les pages), gardé sur le poste pour une lecture hors
  /// ligne pendant 30 jours. Lève [OfflineRefusal] avec un message lisible.
  Future<CashBook> fetchCashBook(Operator operator, {required String from, required String to}) =>
      throw const OfflineRefusal('Livre de caisse en ligne non disponible sur ce terminal.');

  /// Dernière copie du livre en ligne, si elle a moins de 30 jours et que [operator] a encore le droit ; sinon null.
  Future<CashBook?> cachedCashBook(Operator operator) async => null;

  /// Pourquoi [operator] ne peut pas clôturer la journée maintenant, ou null.
  Future<String?> dayClosureBlocker(Operator? operator) async => 'Clôture de journée non disponible sur ce terminal.';

  /// Z de journée du terminal (« clôture du registre ») : réunit ses sessions clôturées depuis le dernier, émet
  /// `cloture_journee`. Idempotent par [operationUuid]. Le document s'imprime ensuite par [closureDocument]
  /// ([ZKind.terminalDay]).
  Future<OfflineOperation> closeDay(Operator operator, {String? operationUuid}) =>
      throw const OfflineRefusal('Clôture de journée non disponible sur ce terminal.');

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

  /// Avertissement non bloquant (C, `a0236dc`) : la dernière vente porte les mêmes produits, conditionnements et
  /// quantités que [lines] (ordre indifférent). Encaisser ce nouveau client reste permis ; une vente différente
  /// intercalée fait disparaître l'avertissement.
  static const sameBasketWarning = 'Le ticket précédent contient les mêmes articles et quantités. Vous pouvez encaisser ce nouveau client.';

  Future<bool> sameAsPreviousSale(List<CartLine> lines) async {
    if (lines.isEmpty) return false;
    final previous = (await history()).reversed.where((o) => o.isSale).firstOrNull;
    return previous != null && _composition(lines) == _composition(ticketParts(previous).$1);
  }

  static String _composition(List<CartLine> lines) {
    final quantities = <String, BigInt>{};
    for (final line in lines) {
      final key = '${line.product.id}:${line.packaging?.id}';
      quantities[key] = (quantities[key] ?? BigInt.zero) + line.quantity;
    }
    final keys = quantities.keys.toList()..sort();
    return keys.map((key) => '$key=${quantities[key]}').join('|');
  }

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

  /// Tarif gros de la boutique ; null s'il n'y en a pas (ou contrat antérieur à 2.1).
  WholesaleRules? get wholesaleRules => null;

  /// Prix modifiable à la vente (2.1 lot 9) : capacité `prix.modifiable` annoncée et accordée.
  bool get editablePriceSupported => false;

  /// Modifier un ticket après encaissement (2.1 lot 11) : capacité `vente.modification` accordée et option de la
  /// boutique `regles.modification_ticket.actif`.
  bool get saleEditSupported => false;

  /// Pourquoi la modification de ticket est indisponible sur ce terminal, ou null : serveur sans la capacité, ou option
  /// éteinte pour la boutique (deux textes distincts, affichés tels quels).
  String? get saleEditUnavailable => 'Le serveur de la boutique ne propose pas encore cette fonction.';

  /// Pourquoi [operator] ne peut pas modifier [sale], ou null.
  String? saleEditBlocker(Operator? operator, OfflineOperation sale) => saleEditUnavailable;

  /// Ticket de remplacement déjà enregistré pour la vente [operationUuid], ou null (reprise après coupure).
  Future<OfflineOperation?> saleReplacement(String operationUuid) async => null;

  /// [saleEditBlocker] plus les contrôles qui lisent la file : ticket déjà remplacé, retour déjà fait.
  Future<String?> saleEditCheck(Operator? operator, OfflineOperation sale) async => saleEditBlocker(operator, sale);

  /// Responsables publiés `approbateur_modification` (code de 8 chiffres).
  List<Operator> get editApprovers => const [];

  /// Responsable reconnu par son code seul : exactement un responsable doit correspondre (note A lot 11 §3). Les échecs
  /// sont comptés comme pour les autres codes (blocage progressif sur ce terminal).
  Future<Operator> identifyEditApprover(String code) async {
    const key = '${StoreKeys.approvalFailures}modification';
    final locked = await _lockedFor(key);
    if (locked != null) throw OfflineRefusal('Trop d’essais : réessayez dans ${locked.inSeconds + 1} s.');
    final matches = <Operator>[];
    if (RegExp(r'^\d{8}$').hasMatch(code)) {
      for (final approver in editApprovers) {
        final hash = approver.approvalCodeHash;
        if (hash != null && hash.isNotEmpty && await _verifyPin(code, hash)) matches.add(approver);
      }
    }
    if (matches.length > 1) {
      throw const OfflineRefusal('Ce code correspond à plusieurs responsables : il n’identifie personne. Faites redéfinir leurs codes.');
    }
    if (matches.isEmpty) {
      final failures = (int.tryParse((await store.read(key))?.split('|').first ?? '') ?? 0) + 1;
      final lockedUntil = failures >= 3 ? now.add(Duration(seconds: (30 * (1 << (failures - 3).clamp(0, 5))).clamp(30, 900))) : null;
      await store.write(key, '$failures|${lockedUntil?.toUtc().toIso8601String() ?? ''}');
      throw const OfflineRefusal('Code responsable inconnu.');
    }
    await store.write(key, null);
    return matches.single;
  }

  /// Code responsable seul (demande du responsable, 22/11) : le responsable est reconnu par son code de 8 chiffres
  /// parmi TOUS les codes publiés ; plusieurs correspondances valent un refus ; un code inconnu est compté (blocage
  /// progressif). Le responsable reconnu doit ensuite figurer dans [eligible], sinon [notAllowed] (son nom en tête).
  Future<Operator> identifyApprover(String code, {required List<Operator> eligible, required String notAllowed}) async {
    const key = '${StoreKeys.approvalFailures}code';
    final locked = await _lockedFor(key);
    if (locked != null) throw OfflineRefusal('Trop d’essais : réessayez dans ${locked.inSeconds + 1} s.');
    final holders = <int, Operator>{
      for (final o in [...?snapshot?.operators, ...editApprovers, ...eligible])
        if (o.approvalCodeHash?.isNotEmpty ?? false) o.id: o,
    };
    final matches = <Operator>[];
    if (RegExp(r'^\d{8}$').hasMatch(code)) {
      for (final o in holders.values) {
        if (await approvalCodeMatches(o, code)) matches.add(o);
      }
    }
    if (matches.length > 1) {
      throw const OfflineRefusal('Ce code correspond à plusieurs responsables : il n’identifie personne. Faites redéfinir leurs codes.');
    }
    if (matches.isEmpty) {
      final failures = (int.tryParse((await store.read(key))?.split('|').first ?? '') ?? 0) + 1;
      final lockedUntil = failures >= 3 ? now.add(Duration(seconds: (30 * (1 << (failures - 3).clamp(0, 5))).clamp(30, 900))) : null;
      await store.write(key, '$failures|${lockedUntil?.toUtc().toIso8601String() ?? ''}');
      throw const OfflineRefusal('Code responsable inconnu.');
    }
    await store.write(key, null);
    final approver = matches.single;
    if (!eligible.any((o) => o.id == approver.id)) throw OfflineRefusal('${approver.name} $notAllowed');
    return approver;
  }

  /// [code] est-il celui de [approver] (empreinte publiée) ? Sans compter d'échec : c'est [identifyApprover] qui compte.
  Future<bool> approvalCodeMatches(Operator approver, String code) async {
    final hash = approver.approvalCodeHash;
    return hash != null && hash.isNotEmpty && await _verifyPin(code, hash);
  }

  /// Remise au-delà du seuil du caissier autorisée par le seul code du responsable.
  Future<SaleApproval> authorizeDiscountByCode({
    required Operator cashier,
    required String code,
    required String reason,
    required List<CartLine> lines,
    required int globalDiscount,
  }) async {
    final motive = reason.trim();
    if (motive.isEmpty || motive.length > 500) throw const OfflineRefusal('Indiquez le motif de la remise (500 caractères au plus).');
    final approver = await identifyApprover(code, eligible: approversFor(cashier, lines, globalDiscount), notAllowed: 'ne peut pas autoriser cette remise (droit ou plafond).');
    return SaleApproval(approverId: approver.id, reason: motive, verifiedAt: now.toUtc().toIso8601String());
  }

  /// Geste du restaurant autorisé par le seul code du responsable (mêmes contrôles que [restoAuthorize]).
  Future<RestoApproval> restoAuthorizeByCode({
    required Operator cashier,
    required String code,
    required String reason,
    required int amount,
    String type = 'resto_modifier_envoye',
    int? percent,
    String? refund,
  }) async {
    final eligible = await restoApprovers(cashier, amount, type: type, percent: percent, refund: refund);
    final approver = await identifyApprover(code, eligible: eligible, notAllowed: 'ne peut pas autoriser ce geste (droit ou plafonds).');
    return restoAuthorize(cashier: cashier, approver: approver, code: code, reason: reason, amount: amount, type: type, percent: percent, refund: refund);
  }

  /// Ancien total, nouveau total, différence et moyens de règlement possibles d'une modification de [sale].
  SaleEditPreview previewSaleEdit(OfflineOperation sale, List<CartLine> lines) =>
      throw const OfflineRefusal('Modification de ticket non disponible sur ce terminal.');

  /// Enregistre le ticket de remplacement de [sale] : contenu complet [lines], différence réglée sur [method] (un moyen
  /// de la vente d'origine), autorisation de [approver] reconnu par son code. La vente d'origine n'est jamais modifiée.
  Future<OfflineOperation> recordSaleEdit(
    Operator cashier,
    OfflineOperation sale,
    List<CartLine> lines, {
    required Operator approver,
    String? method,
    String? reason,
    String? operationUuid,
  }) => throw const OfflineRefusal('Modification de ticket non disponible sur ce terminal.');

  /// Catalogue hors connexion (2.1 lot 10) : capacités `produit.creation` et `produit.modification` accordées.
  bool get productCreationSupported => false;
  bool get productEditSupported => false;

  /// Pourquoi [operator] ne peut pas créer (ou modifier) une fiche, ou null.
  String? productCreateBlocker(Operator? operator) {
    if (!productCreationSupported) return 'Création de produit non disponible sur ce terminal.';
    if (operator == null) return 'Identifiez le caissier.';
    if (!hasRight(operator, 'produits_creer')) return '${operator.name} n’a pas le droit de créer un produit.';
    return null;
  }

  String? productEditBlocker(Operator? operator) {
    if (!productEditSupported) return 'Modification de produit non disponible sur ce terminal.';
    if (operator == null) return 'Identifiez le caissier.';
    if (!hasRight(operator, 'produits_modifier')) return '${operator.name} n’a pas le droit de modifier un produit.';
    return null;
  }

  /// Catégories actives proposées dans la fiche produit (uuid, nom).
  List<({String uuid, String name})> get productCategories => const [];

  /// Champs modifiables d'une fiche du catalogue local, ou null si le produit est inconnu.
  ProductFields? productFields(int productId) => null;

  /// Crée une fiche sur ce terminal : vendable tout de suite ici, envoyée au serveur avant toute vente qui la cite.
  Future<Product> createProduct(Operator operator, NewProduct product, {String? operationUuid}) =>
      throw const OfflineRefusal('Création de produit non disponible sur ce terminal.');

  /// Modifie une fiche : [changes] porte seulement les champs changés (`nom`, `reference`, `categorie_uuid`, `prix`,
  /// `prix_gros`, `gros_quantite_min`), aux formats du contrat.
  Future<Product> updateProduct(Operator operator, int productId, Map<String, Object?> changes, {String? operationUuid, Map<String, Object?>? expected}) =>
      throw const OfflineRefusal('Modification de produit non disponible sur ce terminal.');

  /// Créations et modifications de ce terminal, les plus récentes d'abord.
  Future<List<CatalogueChange>> catalogueChanges() async => const [];

  /// Plafond d'un prix saisi, en francs (celui de la caisse web).
  static const maxEnteredPrice = 1000000000;

  /// Pourquoi [operator] ne peut pas saisir le prix de [line], ou null s'il le peut : produit coché, unité de base,
  /// droit `prix_vente_modifier`. Contrôlé de nouveau à l'encaissement ; le serveur refait le contrôle au rejeu.
  String? enteredPriceBlocker(Operator? operator, CartLine line) {
    if (!editablePriceSupported) return 'Prix modifiable non disponible sur ce terminal.';
    if (!line.product.priceEditable) return 'Le prix de « ${line.product.name} » ne se modifie pas à la vente.';
    if (line.packaging != null) return 'Le prix se saisit à l’unité de base, pas sur un conditionnement.';
    if (operator == null) return 'Identifiez le caissier.';
    if (!hasRight(operator, 'prix_vente_modifier')) return '${operator.name} n’a pas le droit de modifier le prix de vente.';
    return null;
  }

  /// Remise maximale (francs) que [operator] peut accorder sur une ligne de [base] francs : plafond du terminal
  /// (`remises.ligne_max_pourcent`) et, s'il est publié (contrat 2.1), celui de son rôle — le plus petit des deux.
  int maxLineDiscountFor(Operator operator, int base) => maxLineDiscount(base, snapshot?.rules.maxLineDiscountPercent ?? 0);

  /// Retours hors ligne ouverts à [operator] : fermés par défaut (capacité `retour.especes`, `retours.mode`, droits).
  bool returnsOpen(Operator operator) => returnBlocker(operator) == null;

  /// Pourquoi [operator] ne peut pas faire de retour hors ligne, ou null s'il le peut.
  String? returnBlocker(Operator operator) => 'Retours hors ligne non disponibles sur ce terminal.';

  /// Passes événement (capacité `passes.evenement`) : réglages du module quand il est ouvert à ce terminal, sinon null.
  PassSettings? get passSettings => null;

  /// « Scanner le pass » : module ouvert et droit `pass_encaisser` de l'opérateur.
  bool canPayByPass(Operator operator) => false;

  /// Vérifie le code d'un pass pour ce panier : en ligne d'abord (`POST /passes/verifier`), sinon par les règles locales
  /// quand l'événement l'autorise hors connexion. [already] : passes déjà retenus pour la vente. Refus : [OfflineRefusal]
  /// avec le message d'ECAS.
  Future<PassCheck> verifyPass(Operator operator, String code, List<CartLine> lines, SaleExtras extras, {List<PassCheck> already = const []}) =>
      throw const OfflineRefusal('Passes événement non disponibles sur ce terminal.');

  // ---------------------------------------------------------------- restaurant (capacité restaurant.v1)

  /// Restaurant du point de vente du terminal (profil, caisse maîtresse, salles, tables) ; null hors restaurant.
  RestoContext? get restaurant => null;

  /// Interface simplifiée de la caisse restaurant (`restaurant.interface`, lot Z local) : couverts, libellé d'envoi,
  /// navigation de la carte ; valeurs par défaut sans entité reçue.
  RestoInterface get restaurantInterface => RestoInterface.defaults;

  /// Pourquoi [operator] ne peut pas prendre de commande sur ce terminal, ou null s'il le peut (caisse maîtresse, profil
  /// Service de table, droit `caisse_table`).
  String? restaurantBlocker(Operator operator) => 'Restaurant non disponible sur ce terminal.';

  /// Commandes de la caisse maîtresse (dernière version de chacune) ; [all] : closes et annulées comprises.
  Future<List<RestoOrderView>> restaurantOrders({bool all = false}) async => const [];

  /// Ouvre une commande à [tableUuid] (version 1, vide, en attente).
  /// [customer] : client cité à l'ouverture seulement (lot R-5, porte la remise client).
  Future<RestoOrderView> restoOpen(Operator operator, String tableUuid, {int? covers, Customer? customer}) => throw const OfflineRefusal('Restaurant non disponible sur ce terminal.');

  /// Une validation de l'opérateur = une version : articles ajoutés ([added], prix du catalogue figés), quantités ou
  /// commentaires changés, articles retirés.
  Future<RestoOrderView> restoEditLines(
    Operator operator,
    String orderUuid, {
    List<(CartLine, String?)> added = const [],
    Map<String, int> quantities = const {},
    Map<String, String?> comments = const {},
    Set<String> removed = const {},
  }) => throw const OfflineRefusal('Restaurant non disponible sur ce terminal.');

  Future<RestoOrderView> restoPrebill(Operator operator, String orderUuid) => throw const OfflineRefusal('Restaurant non disponible sur ce terminal.');

  Future<RestoOrderView> restoTransfer(Operator operator, String orderUuid, String tableUuid) => throw const OfflineRefusal('Restaurant non disponible sur ce terminal.');

  Future<RestoOrderView> restoCancel(Operator operator, String orderUuid, String? reason, {RestoApproval? approval}) =>
      throw const OfflineRefusal('Restaurant non disponible sur ce terminal.');

  /// Envoi aux postes (R-3) : un bon par poste pour ce qui est en attente ; « Valider » sans bon quand l'envoi en
  /// production est éteint. Les bons partent aussitôt vers leurs cibles.
  Future<RestoOrderView> restoSend(Operator operator, String orderUuid) => throw const OfflineRefusal('Restaurant non disponible sur ce terminal.');

  /// Réduit ou annule un article déjà envoyé (motif de 3 caractères au moins ; [approval] si
  /// [restoApprovalRequired]).
  Future<RestoOrderView> restoCancelLine(Operator operator, String orderUuid, String lineUuid, int quantity, String reason, {RestoApproval? approval}) =>
      throw const OfflineRefusal('Restaurant non disponible sur ce terminal.');

  /// Annuler un article envoyé exige-t-il l'autorisation d'un responsable pour [operator] ?
  bool restoApprovalRequired(Operator operator) => true;

  /// Responsables qui peuvent autoriser l'annulation d'un envoyé de [amount] F pour [cashier] ; [type] : autre geste
  /// (`resto_offrir`, `remise`, R-4) et [percent] : remise en % arrondi au supérieur (plafond de l'assistant).
  /// [refund] : `retour` ou `annulation` pour l'autorisation `remboursement` (lot R-5).
  Future<List<Operator>> restoApprovers(Operator cashier, int amount, {String type = 'resto_modifier_envoye', int? percent, String? refund}) async => const [];

  /// Vérifie le code de 8 chiffres de [approver] et rend l'autorisation à joindre à l'annulation (ou au geste [type]).
  Future<RestoApproval> restoAuthorize({
    required Operator cashier,
    required Operator approver,
    required String code,
    required String reason,
    required int amount,
    String type = 'resto_modifier_envoye',
    int? percent,
    String? refund,
  }) => throw const OfflineRefusal('Restaurant non disponible sur ce terminal.');

  // ---------------------------------------------------------------- tarif du personnel, remboursement (R-5)

  /// Remise totale de [added] au tarif du personnel de l'employé [staffId] (montant de l'autorisation `remise`) ;
  /// [OfflineRefusal] si le tarif ne s'applique pas à un article maintenant.
  Future<int> restoStaffDiscount(String orderUuid, int staffId, List<(CartLine, String?)> added) => throw const OfflineRefusal('Restaurant non disponible sur ce terminal.');

  /// Une version `lignes` : [added] servis à l'employé [staffId] au tarif du personnel ; motif obligatoire, droit `remise`
  /// ou [approval] (`remise`) pour la remise totale.
  Future<RestoOrderView> restoStaffLines(Operator operator, String orderUuid, int staffId, List<(CartLine, String?)> added, {required String reason, RestoApproval? approval}) =>
      throw const OfflineRefusal('Restaurant non disponible sur ce terminal.');

  /// Ventes de cette caisse qui ont réglé une commande du Restaurant (la plus récente d'abord) et leurs remboursements.
  Future<List<RestoSettledSale>> restoSettledSales() async => const [];

  /// Pourquoi [operator] ne peut pas rembourser une vente restaurant, ou null.
  String? restoRefundBlocker(Operator operator) => 'Restaurant non disponible sur ce terminal.';

  /// [type] (`retour`, `annulation`) exige-t-il l'autorisation `remboursement` d'un responsable pour [operator] ?
  bool restoRefundNeedsApproval(Operator operator, String type) => true;

  /// Montant rendu : `retour` des [quantities] (ligne de vente → millionièmes de l'unité de base), ou `annulation`.
  Future<int> restoRefundAmount(String saleUuid, String type, Map<String, int> quantities) => throw const OfflineRefusal('Restaurant non disponible sur ce terminal.');

  /// Remboursement restaurant (`resto_remboursement`) : `retour` en espèces ou `annulation` sur les moyens d'origine.
  /// [operationUuid] : identifiant de l'opération de remboursement (rejeu sans double par l'adaptateur), sinon tiré.
  Future<OfflineOperation> restoRefund(Operator operator, String saleUuid, String type, Map<String, int> quantities, String reason, {RestoApproval? approval, String? operationUuid}) =>
      throw const OfflineRefusal('Restaurant non disponible sur ce terminal.');

  // ---------------------------------------------------------------- gestes sur une commande (R-4)

  /// Le geste [type] (`resto_offrir`, `remise`) exige-t-il l'autorisation d'un responsable pour [operator] ?
  bool restoNeedsApproval(Operator operator, String type) => true;

  /// Offre un article (remise = brut de la ligne, quantité inchangée), motif de 3 caractères au moins.
  Future<RestoOrderView> restoOffer(Operator operator, String orderUuid, String lineUuid, String reason, {RestoApproval? approval}) => throw const OfflineRefusal('Restaurant non disponible sur ce terminal.');

  /// Remise d'un article : [value] francs, ou [value] % du brut ([percent], arrondi vers le bas) ; motif obligatoire.
  Future<RestoOrderView> restoDiscountLine(Operator operator, String orderUuid, String lineUuid, {required bool percent, required int value, required String reason, RestoApproval? approval}) =>
      throw const OfflineRefusal('Restaurant non disponible sur ce terminal.');

  /// Remise de la commande en francs, plafonnée ([restoOrderDiscountCeiling]) ; 0 la retire (droit Remise, sans motif).
  Future<RestoOrderView> restoDiscountOrder(Operator operator, String orderUuid, int amount, {String? reason, RestoApproval? approval}) => throw const OfflineRefusal('Restaurant non disponible sur ce terminal.');

  /// Remise de commande maximale pour [order].
  int restoOrderDiscountCeiling(RestoOrder order) => 0;

  /// Déplace des articles de [orderUuid] vers la commande [targetUuid] (une opération sur la source).
  Future<RestoOrderView> restoMoveLines(Operator operator, String orderUuid, String targetUuid, Set<String> lineUuids) => throw const OfflineRefusal('Restaurant non disponible sur ce terminal.');

  /// Regroupe [orderUuid] dans [targetUuid] : articles, couverts et remises passent à la cible, la source est annulée.
  Future<RestoOrderView> restoMerge(Operator operator, String orderUuid, String targetUuid, {String? reason}) => throw const OfflineRefusal('Restaurant non disponible sur ce terminal.');

  /// Couverts et serveur de la commande.
  Future<RestoOrderView> restoCoversAndServer(Operator operator, String orderUuid, {int? covers, String? serverId}) => throw const OfflineRefusal('Restaurant non disponible sur ce terminal.');

  /// Le client a validé la préfacture (Service de table).
  Future<RestoOrderView> restoValidateCustomer(Operator operator, String orderUuid) => throw const OfflineRefusal('Restaurant non disponible sur ce terminal.');

  /// Bons de production de ce terminal (d'une commande si [orderUuid]) et état de leur livraison.
  Future<List<RestoTicketView>> restoTickets({String? orderUuid}) async => const [];

  /// Vérification sur place d'un bon livré avec une issue inconnue.
  Future<void> restoVerifyTicket(Operator operator, String ticketUuid, {required bool printed}) =>
      throw const OfflineRefusal('Restaurant non disponible sur ce terminal.');

  /// Réimpression d'un bon (DUPLICATA) avec un motif ; null : confiée à [restoDeferredPrinter], résultat à venir.
  Future<RestoOutcome?> restoDuplicateTicket(Operator operator, String ticketUuid, String reason) =>
      throw const OfflineRefusal('Restaurant non disponible sur ce terminal.');

  /// Hôte séparé de l'interface (Windows) : un bon destiné à une cible de [restoDeferredTargets] est confié à ce crochet,
  /// qui le conserve durablement et rend aussitôt (jamais d'attente de l'impression) ; le résultat revient plus tard par
  /// [restoDeferredOutcome]. Null : impression directe ([restoRegisterPrinter], [restoStationPrinter]).
  Future<void> Function(RestoDeferredPrint job)? restoDeferredPrinter;

  /// Cibles confiées à [restoDeferredPrinter] : l'imprimante de la caisse ; l'imprimante de poste si l'hôte l'ajoute.
  Set<RestoTarget> restoDeferredTargets = {RestoTarget.imprimanteCaisse};

  /// Résultat d'une impression différée, noté au journal des bons (livraison ou duplicata) ; une livraison `non_envoye`
  /// reprend la chaîne de secours du bon, sauf si une autre tentative du même bon est encore en cours ([inFlight]).
  /// Rejouer le même résultat ne note rien de plus.
  Future<void> restoDeferredOutcome(Operator operator, RestoDeferredPrint job, RestoOutcome outcome, {Set<RestoTarget> inFlight = const {}}) =>
      throw const OfflineRefusal('Restaurant non disponible sur ce terminal.');

  /// Adresses locales des imprimantes de poste (`ip` ou `ip:port`), par poste.
  Map<String, String> get restoPrinterAddresses => const {};

  Future<void> setRestoPrinterAddress(String stationUuid, String? address) => throw const OfflineRefusal('Restaurant non disponible sur ce terminal.');

  /// Imprimante de la caisse pour les bons (secours `imprimante_caisse`) ; null = aucune (échec certain).
  Future<RestoOutcome> Function(List<String> text)? restoRegisterPrinter;

  /// Imprimante de poste ; null = imprimante réseau ESC/POS à l'adresse locale du poste.
  Future<RestoOutcome> Function(String address, List<String> text)? restoStationPrinter;

  /// Afficheur de poste ; null = aucun sur ce terminal (échec certain, la chaîne de secours prend le relais).
  Future<RestoOutcome> Function(RestoTicket ticket, RestoStation station)? restoStationScreen;

  /// Largeur des bons imprimés, en caractères.
  int restoTicketColumns = 32;

  /// Panier de règlement d'une commande : une ligne par article actif, au prix figé de la commande.
  Future<List<CartLine>> restoCart(String orderUuid) => throw const OfflineRefusal('Restaurant non disponible sur ce terminal.');

  /// Encaisse toute la commande (vente v2 avec `commande` de type `full`), puis la clôt. [lines] : panier rendu par
  /// [restoCart] ou [restoCartItems], inchangé. Profil Restaurant (R-4) : une partie du reste (`items`), ou tout le reste
  /// partagé en [shares] (`shares`, chaque paiement dans une part et une seule) ; la commande se clôt une fois soldée.
  /// [operationUuid] : identifiant de la vente (encaissement idempotent, comme [recordSale]).
  Future<OfflineOperation> restoSettle(
    Operator operator,
    String orderUuid,
    List<CartLine> lines,
    List<CartPayment> payments, {
    String? draftUuid,
    List<RestoShare>? shares,
    String? operationUuid,
  }) => throw const OfflineRefusal('Restaurant non disponible sur ce terminal.');

  /// Profil Restaurant (R-4) : ouvre une commande sur le canal [channelCode] (table si le canal l'exige, référence
  /// externe si le canal l'exige).
  Future<RestoOrderView> restoOpenOnChannel(Operator operator, String channelCode, {String? tableUuid, String? reference, String? customerName, int? covers, String? customerUuid}) =>
      throw const OfflineRefusal('Restaurant non disponible sur ce terminal.');

  /// Panier d'un règlement par articles (profil Restaurant) : [quantities] par ligne de commande (millionièmes), au plus
  /// le reste à régler de chacune.
  Future<List<CartLine>> restoCartItems(String orderUuid, Map<String, int> quantities) => throw const OfflineRefusal('Restaurant non disponible sur ce terminal.');

  /// Registre (journée) de cette caisse : le dernier ouvert, clos ou non ; null si aucun.
  Future<RestoRegisterView?> restoRegister() async => null;

  /// Pourquoi [operator] ne peut pas ouvrir ou clôturer le registre (caisse maîtresse, droit `resto_registre`), ou null.
  String? restoRegisterBlocker(Operator operator) => 'Restaurant non disponible sur ce terminal.';

  Future<RestoRegisterView> restoRegisterOpen(Operator operator, {String? note}) => throw const OfflineRefusal('Restaurant non disponible sur ce terminal.');

  /// Clôture du registre et Z local (session close, commandes soldées).
  Future<RestoRegisterView> restoRegisterClose(Operator operator, {String? note}) => throw const OfflineRefusal('Restaurant non disponible sur ce terminal.');

  /// Clôt une commande déjà réglée par une vente de ce terminal (clôture interrompue).
  Future<RestoOrderView> restoClose(Operator operator, String orderUuid) => throw const OfflineRefusal('Restaurant non disponible sur ce terminal.');

  /// Contrôles de règle de la vente faits avant l'encaissement (tarif gros, cumul avec une remise) : [OfflineRefusal] sinon.
  void checkSaleRules(Operator operator, List<CartLine> lines, SaleExtras extras) {}

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

  /// Faits de clôture lus dans la file du terminal (sessions, ventes, retours, clôtures) pour imprimer pré-X, Z et pré-Z
  /// sans réseau ; null : documents locaux non disponibles sur ce terminal.
  Future<ClosureFacts?> closureFacts() async => null;

  /// Codes des moyens de paiement publiés comme espèces (booléen `especes`), locaux ou non ; vide hors contrat v2.
  Future<Set<String>> publishedCashCodes() async => const {};

  /// Document de clôture prêt à imprimer ([ZKind.preX], [ZKind.session], [ZKind.preZ]), calculé sans réseau à partir
  /// de [closureFacts] ; null : documents locaux non disponibles. Lève [ClosureUnavailable] s'il n'y a pas de session à
  /// imprimer. Commun à Android et à l'hôte Windows (qui rend `ticket`).
  Future<ClosureDocument?> closureDocument(String kind, String version, {bool duplicate = false}) async {
    final facts = await closureFacts();
    final s = snapshot;
    if (facts == null || s == null) return null;
    return buildClosureDocument(facts, ZContext.of(s, publishedCashCodes: await publishedCashCodes()), kind: kind, version: version, now: now, duplicate: duplicate);
  }

  /// Z de journée du terminal (2.1 lot 12) visé par l'uuid de sa `cloture_journee`, même après les journées suivantes.
  Future<ClosureDocument?> dayClosureDocument(String dayClosureUuid, String version, {bool duplicate = true}) async {
    final facts = await closureFacts();
    final s = snapshot;
    if (facts == null || s == null) return null;
    return buildClosureDocument(facts, ZContext.of(s, publishedCashCodes: await publishedCashCodes()),
        kind: ZKind.terminalDay, version: version, now: now, duplicate: duplicate, dayClosureUuid: dayClosureUuid);
  }

  /// Audit d'une édition provisoire imprimée (pré-X, pré-Z ; lot Z local) : une opération par impression, avec son
  /// propre UUID. Sans effet ici ; ne lève jamais (l'audit ne bloque ni l'impression ni la clôture). [operationUuid] :
  /// UUID imposé (édition confirmée par l'adaptateur), l'opération n'est alors jamais émise deux fois.
  Future<void> recordEdition(Operator operator, ClosureDocument document, {String? operationUuid}) async {}

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

  /// Garde le modèle de ticket en vigueur avec la vente [saleUuid], avant son enregistrement : une vente enregistrée a
  /// toujours son modèle (une vente refusée laisse au plus une entrée sans effet). Sa réimpression suit ce modèle.
  Future<void> rememberTicketModel(String saleUuid) async {
    final model = snapshot?.ticketModel;
    await store.write('ticket.modele.$saleUuid', model == null ? null : jsonEncode(model.raw));
  }

  /// Modèle de ticket connu à la vente, ou null (vente antérieure, disposition d'origine ou entrée illisible).
  Future<TicketModel?> ticketModelOf(OfflineOperation sale) async {
    final raw = await store.read('ticket.modele.${sale.uuid}');
    if (raw == null) return null;
    try {
      return TicketModel.tryParse(jsonDecode(raw));
    } on FormatException {
      return null;
    }
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
          s?.methods.where((x) => x.code == code).firstOrNull ??
          PaymentMethodInfo({'code': code, 'nom': code == PassRules.method ? 'Pass événement' : code, 'especes': code == 'especes'});
      final amount = (m['montant'] as num).toInt();
      final received = (m['recu'] as num?)?.toInt();
      final rounding = (m['ecart_arrondi'] as num?)?.toInt();
      final change = (m['monnaie'] as num?)?.toInt();
      final due = rounding != null ? amount + rounding : received != null && change != null ? received - change : cashDue(amount);
      payments.add(CartPayment(method: method, amount: amount, received: received, cashDue: method.isCash ? due : amount));
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
    // Règlement d'une commande restaurant : ses remises, autorisées sur la commande, sont de confiance (R-4).
    final trusted = extras.order?.trusts(lines, extras.globalDiscount) ?? false;
    for (final line in lines) {
      if (line.quantity <= BigInt.zero) throw OfflineRefusal('Quantité invalide pour « ${line.label} ».');
      if (!trusted && line.discount > maxLineDiscount(line.base, s.rules.maxLineDiscountPercent)) {
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
    final allowed = {for (final m in s.methods) m.code, if (extras.passes.isNotEmpty) PassRules.method, if (extras.preSale != null) preSaleDepositMethod};
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
