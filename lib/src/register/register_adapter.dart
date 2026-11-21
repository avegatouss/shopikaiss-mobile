import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../offline/catalogue_edit.dart';
import '../offline/engine.dart';
import '../offline/local_prices.dart';
import '../offline/models.dart';
import '../offline/money.dart';
import '../offline/ticket.dart';
import '../offline/web_rules.dart';
import '../offline/x_z_report.dart';
import '../printer/escpos.dart';
import '../restaurant/resto_context.dart';
import '../restaurant/resto_engine.dart';
import '../sync_v2/decimal6.dart';

part 'register_adapter_closure.dart';
part 'register_adapter_resto.dart';

/// Version de l'interface de commandes du moteur (C-REQ-001). Toute rupture incrémente ce numéro.
/// 2 : commandes restaurant (`restaurantView`, `resto*`) et pont d'impression des bons (docs/livraison-caisse-autonome/
/// ADAPTATEUR-RESTAURANT-B.md).
const registerAdapterVersion = 2;

/// Refus d'une commande. [notCommitted] : il est CERTAIN que rien n'a été enregistré (règle refusée avant écriture) ;
/// toute autre exception d'une commande d'encaissement doit être traitée comme un résultat inconnu.
class AdapterFailure implements Exception {
  const AdapterFailure(this.code, this.message, {this.notCommitted = true});

  final String code;
  final String message;
  final bool notCommitted;

  @override
  String toString() => message;
}

/// Interface de commandes du moteur de caisse local, sans Flutter ni réseau dans les commandes (C-REQ-001/004).
///
/// Une instance par moteur et par processus. Les commandes sont exécutées dans l'ordre d'arrivée ; les écritures
/// passent par la file d'écriture du moteur (une vente à la fois). Le panier en cours est conservé sur le terminal à
/// chaque modification : un redémarrage de l'écran ou de l'hôte le retrouve (C-REQ-004).
///
/// Commandes (`execute`) : status, pair, login, logout, openSession, view, search, addProduct, scan, changeQuantity,
/// removeLine, setLineDiscount, setGlobalDiscount, setDelivery, setNote, clear, suspendDraft, drafts, resumeDraft,
/// deleteDraft, preparePayment, setPayment, setPayments, commitSale, saleStatus, history, printTicket, reprint, synchronize.
///
/// Retours (contrat 2.1, fermés par défaut) : returnableSale {sale_id}, previewReturn {sale_id, lines: [{line_id, quantity}]},
/// commitReturn {sale_id, lines, reason} avec un identifiant d'opération facultatif. Quantités en unité de base.
///
/// Paniers partagés (contrat 2.1) : suspendDraft {label} publie le panier si le caissier est identifié ; drafts donne aussi
/// `shared` [{shared_id, label, lines_count, taken_elsewhere}] ; resumeShared {shared_id} (réseau requis), deleteShared {shared_id}.
///
/// Clôture (contrat 2.1) : closeSession {cash, comment, counts: [{method, amount, justification}]}, panier vide, identifiant
/// d'opération facultatif. L'attendu n'est jamais exposé.
///
/// Clients (contrat 2.1) : searchCustomers {query}, createCustomer {name, phone}, setCustomer {uuid, name} ; uuid absent =
/// client de passage. La vue donne `customer`.
///
/// Remise au-delà du seuil du caissier : la vue donne `discount_approval` {required, approvers} ; `commitSale` reçoit
/// alors `approval` {approver_id, code, reason}. Le code n'est jamais conservé.
///
/// Paniers en attente : un seul panier courant ; les autres sont suspendus, conservés sur le terminal et repris par
/// leur identifiant. Un panier encaissé est consommé par la transaction de la vente (une seule vente par panier).
///
/// Restaurant (version 2, capacité `restaurant.v1`) : restaurantView, restoOrder, restoTickets, restoApprovalInfo,
/// restoRegister, restoSettledSales, restoRefundPreview, restoPrepareSettlement en lecture ; restoOpen, restoOpenOnChannel,
/// restoEditLines, restoStaffLines, restoSend, restoPrebill, restoTransfer, restoMoveLines, restoMerge, restoCoversAndServer,
/// restoValidateCustomer, restoCancelLine, restoCancel, restoOffer, restoDiscountLine, restoDiscountOrder, restoSettle,
/// restoClose, restoRegisterOpen, restoRegisterClose, restoRefund, restoVerifyTicket, restoDuplicateTicket,
/// restoSetPrinterAddress en écriture (caissier identifié, identifiant d'opération, rejeu sans double) ; restoPrintJobs,
/// restoPrintStart, restoPrintResult pour les bons imprimés par l'interface (hôte Windows).
///
/// Documents de clôture (register_adapter_closure.dart) : closureDocument {kind, version, duplicate?, columns? | paper_width?}
/// rend pré-X, pré-Z ou duplicata du Z de session et, pour une édition provisoire, un `edition_id` conservé en attente ;
/// recordEdition {edition_id} confirme l'impression (audit émis une seule fois, rejeu = même réponse).
class LocalRegisterAdapter {
  LocalRegisterAdapter(this.engine, {this.paperWidth = 80, String Function()? newUuid}) : _newUuid = newUuid ?? (() => const Uuid().v4());

  final CaisseEngine engine;
  final int paperWidth;
  final String Function() _newUuid;
  final StreamController<Map<String, dynamic>> _changes = StreamController.broadcast();

  /// Après chaque écriture durable (panier, vente, synchronisation) : l'écran relit la vue.
  Stream<Map<String, dynamic>> get committedChanges => _changes.stream;

  Operator? _operator;
  late _Draft _draft;
  String _query = '';
  String? _category;
  String? _brand;
  String? _supplier;

  /// Nombre de produits rendus par la vue : une page de plus à chaque `moreProducts`, une page après `search`.
  static const productPage = 60;
  int _productLimit = productPage;
  int _revision = 0;
  bool _started = false;
  bool _syncing = false;
  Future<void> _queue = Future.value();

  /// Règlement restaurant préparé (`restoPrepareSettlement`), en mémoire : un hôte redémarré le refait.
  _RestoSettlement? _restoSettlementPrepared;

  /// Travaux d'impression confiés à l'interface pendant la commande en cours (réponse `print_jobs`).
  final List<String> _restoNewJobs = [];

  /// Vrai si l'adaptateur a branché le pont d'impression des bons sur le moteur.
  bool _restoPrintBridge = false;

  /// Restaure le panier conservé le plus récent (les autres restent conservés, rien n'est effacé).
  Future<void> start() async {
    if (_started) return;
    final current = (await engine.openDrafts()).where((d) => d.content['suspendu'] != true).firstOrNull;
    _draft = current == null ? _Draft(_newUuid()) : _Draft.fromStored(current);
    engine.addListener(_engineChanged);
    // Hôte sans imprimante de caisse joignable (Windows : l'interface imprime) : les bons lui sont confiés par une file
    // durable ; un acquittement conservé mais pas encore journalisé repasse au moteur.
    if (engine.restoRegisterPrinter == null && engine.restoDeferredPrinter == null) {
      engine.restoDeferredPrinter = _restoEnqueue;
      _restoPrintBridge = true;
    }
    _started = true;
    await _restoJournalizePending();
  }

  /// Attend la synchronisation en cours (jamais interrompue au milieu d'une écriture), puis se détache du moteur.
  Future<void> close() async {
    await _syncTask;
    await _queue;
    if (_restoPrintBridge) engine.restoDeferredPrinter = null;
    engine.removeListener(_engineChanged);
    await _changes.close();
  }

  void _engineChanged() => _emit('moteur');

  void _emit(String reason) {
    _revision++;
    if (!_changes.isClosed) _changes.add({'reason': reason, 'revision': _revision});
  }

  /// Exécute une commande ; [operationId] est obligatoire pour commitSale et saleStatus.
  Future<Map<String, dynamic>> execute(String command, Map<String, dynamic> arguments, String? operationId) {
    final result = _queue.then((_) => _run(command, arguments, operationId));
    _queue = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<Map<String, dynamic>> _run(String command, Map<String, dynamic> args, String? operationId) async {
    if (!_started) await start();
    switch (command) {
      case 'status':
        return _status();
      case 'pair':
        return _pair(args);
      case 'login':
        return _login(args);
      case 'logout':
        // Verrouillage ou changement de caissier : le panier reste ; un encaissement incertain se vérifie toujours
        // par saleStatus avec le même identifiant.
        _operator = null;
        _emit('caissier');
        return _status();
      case 'returnableSale':
        return _returnable(_text(args, 'sale_id', max: 36));
      case 'previewReturn':
        return _previewReturn(args);
      case 'commitReturn':
        return _commitReturn(args, operationId);
      case 'closeSession':
        return _closeSession(args, operationId);
      case 'openSession':
        return _openSession(args);
      case 'view':
        return _view();
      case 'search':
        _query = _text(args, 'query', max: 100);
        // Catégorie, marque, fournisseur : absents ou vides = tous ; conservés jusqu'à la prochaine recherche.
        _category = _filter(args, 'category');
        _brand = _filter(args, 'brand');
        _supplier = _filter(args, 'supplier');
        _productLimit = productPage;
        return _view();
      case 'moreProducts':
        // Page suivante des résultats de la recherche courante, filtrés sur tout le catalogue.
        _productLimit += productPage;
        return _view();
      case 'addProduct':
        return _add(_int(args, 'product_id'), args['packaging_id'] is int ? args['packaging_id'] as int : null);
      case 'scan':
        final hit = _snapshot().byCode(_text(args, 'code', max: 64));
        if (hit == null) throw const AdapterFailure('code_inconnu', 'Code-barres inconnu du catalogue du terminal.');
        return _add(hit.$1.id, hit.$2);
      case 'changeQuantity':
        return _changeQuantity(_text(args, 'line_id', max: 64), _text(args, 'quantity', max: 32));
      case 'removeLine':
        final id = _text(args, 'line_id', max: 64);
        if (!_draft.lines.any((l) => l.id == id)) throw const AdapterFailure('ligne_inconnue', 'Ligne introuvable dans le panier.');
        final view = await _mutate(() => _draft.lines.removeWhere((l) => l.id == id));
        if (_draft.lines.isEmpty) await _releaseHeld();
        return view;
      case 'setLineDiscount':
        return _setLineDiscount(_text(args, 'line_id', max: 64), _entry(args));
      case 'setLinePrice':
        return _setLinePrice(_text(args, 'line_id', max: 64), args['amount']);
      case 'startSaleEdit':
        return _startSaleEdit(_text(args, 'sale_id', max: 36));
      case 'cancelSaleEdit':
        return _cancelSaleEdit();
      case 'prepareSaleEdit':
        return _prepareSaleEdit();
      case 'commitSaleEdit':
        return _commitSaleEdit(args);
      case 'catalogueForm':
        return _catalogueForm();
      case 'createProduct':
        return _createProduct(args);
      case 'productForEdit':
        return _productForEdit(_int(args, 'product_id'));
      case 'updateProduct':
        return _updateProduct(args);
      case 'catalogueChanges':
        return {'items': [for (final c in await engine.catalogueChanges()) c.toJson()]};
      case 'localPriceSettings':
        return _localPrices();
      case 'setLocalPriceSettings':
        if (args['enabled'] is! bool) throw const AdapterFailure('argument_invalide', 'Choix activé/désactivé requis.');
        try {
          await LocalPrices.setEnabled(engine, _operator, args['enabled'] == true);
        } on StateError {
          throw const AdapterFailure('prix_refuse', 'Le droit de modifier les prix est requis.');
        }
        _emit('prix_locaux');
        return _localPrices();
      case 'setLineLot':
        return _setLineLot(_text(args, 'line_id', max: 64), args['lot_uuid'] as String?);
      case 'setWholesale':
        return _setWholesale(args['active'] == true);
      case 'setGlobalDiscount':
        return _setGlobalDiscount(_entry(args));
      case 'setDelivery':
        return _setDelivery(_int(args, 'amount'));
      case 'setNote':
        return _setNote(args['text'] == null ? null : _text(args, 'text', max: 2000));
      case 'clear':
        await _releaseHeld();
        await engine.deleteDraft(_draft.uuid);
        _draft = _Draft(_newUuid());
        _emit('panier');
        return _view();
      case 'suspendDraft':
        if (_draft.edit != null) throw const AdapterFailure('modification_en_cours', 'Modification du ticket en cours : validez-la ou abandonnez-la.');
        return _suspend(label: args['label'] as String?);
      case 'resumeShared':
        return _resumeShared(_text(args, 'shared_id', max: 36));
      case 'deleteShared':
        return _deleteShared(_text(args, 'shared_id', max: 36));
      case 'drafts':
        return _drafts();
      case 'imageSettings':
        return _imageSettings();
      case 'setImageSettings':
        return _setImageSettings(args);
      case 'resumeDraft':
        return _resume(_text(args, 'draft_id', max: 64));
      case 'deleteDraft':
        return _deleteDraft(_text(args, 'draft_id', max: 64));
      case 'preparePayment':
        if (_draft.edit != null) throw const AdapterFailure('modification_en_cours', 'Modification du ticket en cours : validez-la ou abandonnez-la.');
        return _preparePayment();
      case 'setPayment':
        // Paiement unique (raccourci de setPayments) : montant par défaut = montant à payer.
        return _setPayments([
          {'method': args['method'], 'amount': args['amount'], 'received': args['received'], 'reference': args['reference']},
        ]);
      case 'setPayments':
        final list = args['payments'];
        if (list is! List || list.any((p) => p is! Map)) throw const AdapterFailure('argument_invalide', 'Argument « payments » invalide.');
        return _setPayments([for (final p in list) Map<String, dynamic>.from(p as Map)]);
      case 'searchCustomers':
        return {'customers': [for (final c in await engine.searchCustomers(_text(args, 'query', max: 100))) _customerJson(c)]};
      case 'createCustomer':
        return _createCustomer(args, operationId);
      case 'setCustomer':
        return _setCustomer(args);
      case 'verifyPass':
        return _verifyPass(_text(args, 'code', max: 120));
      case 'removePass':
        return _removePass(_text(args, 'pass_uuid', max: 36));
      case 'commitSale':
        return _commit(_requireOperationId(operationId), args);
      case 'saleStatus':
        return _saleStatus(_requireOperationId(operationId));
      case 'history':
        return _history(args);
      case 'printTicket':
        return _printTicket(_requireOperationId(operationId));
      case 'reprint':
        return _ticket(_requireOperationId(operationId), duplicate: true);
      case 'synchronize':
        scheduleSynchronization();
        return {'scheduled': true};
      case 'closureDocument':
        return _closureDocument(args);
      case 'recordEdition':
        return _recordEdition(args);
      default:
        final restaurant = _restoCommand(command, args, operationId);
        if (restaurant != null) return restaurant;
        throw AdapterFailure('commande_inconnue', 'Commande locale non reconnue : $command.');
    }
  }

  // ------------------------------------------------------------------ Lecture

  Map<String, dynamic> _status() => {
    'version': registerAdapterVersion,
    'ready': engine.snapshot != null && engine.blockReason == null,
    'block_reason': engine.blockReason,
    'paired': engine.paired,
    'operator': _operator == null ? null : {'id': _operator!.id, 'name': _operator!.name},
    'operators': [for (final o in engine.snapshot?.operators ?? const <Operator>[]) {'id': o.id, 'name': o.name}],
    'pin_required': engine.snapshot?.rules.pinRequired ?? true,
    'session_open': engine.sessionOpen,
    'pending': engine.pendingCount,
    'arbitration': engine.localArbitrationCount,
    'permanent_local': engine.permanentLocal,
    'reachable': engine.reachable,
    'session': _sessionView(),
    'capabilities': _capabilities(),
  };

  Map<String, dynamic>? _sessionView() {
    final session = engine.snapshot?.session;
    if (session == null) return null;
    return {'id': session['session_uuid'], 'local': session['locale'] == true};
  }

  /// Ce que l'écran peut proposer maintenant, avec le motif d'un refus. Contrôles répétés à l'exécution par le moteur.
  Map<String, dynamic> _capabilities() {
    final reason = engine.blockReason;
    final rules = engine.snapshot?.rules;
    Map<String, dynamic> cap(String? refusal, {bool network = false}) => {'allowed': refusal == null, 'reason': refusal, 'network_required': network};
    return {
      'sell': cap(reason ??
          (_operator == null ? 'Identifiez le caissier.' : (engine.sessionOpen ? null : 'Aucune session de caisse ouverte sur ce terminal.'))),
      'open_session': cap(reason ??
          (_operator == null
              ? 'Identifiez le caissier.'
              : engine.sessionOpen
              ? 'Une session est déjà ouverte sur ce terminal.'
              : (rules?.sessionOpening ?? false)
              ? null
              : 'L’ouverture de session locale n’est pas autorisée : ouvrez-la en ligne.')),
      'pair': cap(null, network: true),
      'synchronize': cap(engine.paired ? null : 'Application non appairée.', network: true),
      'close_session': cap(_operator == null ? 'Identifiez le caissier.' : (engine.canCloseSession(_operator!) ? null : 'Clôture non autorisée sur ce terminal.')),
      'returns': cap(_operator == null ? 'Identifiez le caissier pour effectuer un retour.' : engine.returnBlocker(_operator!)),
      'image_schedule': cap(engine.imagesSupported ? null : 'Images non disponibles sur ce terminal.'),
      'shared_carts': cap(engine.sharedCartsSupported ? null : 'Paniers partagés non disponibles sur ce terminal.'),
      // Prix saisi (2.1 lot 9) : fonction du terminal et droit du caissier ; le produit et l'unité se lisent par ligne.
      'line_price': cap(!engine.editablePriceSupported
          ? 'Prix modifiable non disponible sur ce terminal.'
          : _operator == null
          ? 'Identifiez le caissier.'
          : engine.hasRight(_operator!, 'prix_vente_modifier')
          ? null
          : '${_operator!.name} n’a pas le droit de modifier le prix de vente.'),
      'customer': cap(engine.customersSupported ? null : 'Clients non disponibles sur ce terminal.'),
      // Catalogue hors connexion (2.1 lot 10) : capacité accordée et droit du caissier connecté.
      'product_create': cap(engine.productCreateBlocker(_operator)),
      // Modifier un ticket (2.1 lot 11) : capacité, option de la boutique et droit de vendre ; le ticket se lit par vente.
      'sale_edit': cap(!engine.saleEditSupported
          ? 'Modification de ticket non disponible sur ce terminal.'
          : _operator == null
          ? 'Identifiez le caissier.'
          : null),
      'product_edit': cap(engine.productEditBlocker(_operator)),
      'customer_create': cap(_operator != null && engine.canCreateCustomer(_operator!) ? null : 'Création de client non autorisée sur ce terminal.'),
      'discount': {...cap(_discountRefusal()), 'max_percent': rules?.maxLineDiscountPercent ?? 0},
      'global_discount': {...cap(_extrasRefusal() ?? _globalDiscountRefusal()), 'max_percent': rules?.maxGlobalDiscountPercent ?? 0},
      'delivery': cap(_extrasRefusal() ?? _deliveryRefusal()),
      'note': cap(_extrasRefusal()),
      'wholesale': cap(_wholesaleRefusal()),
      'suspend': cap(_draft.lines.isEmpty ? 'Le panier est vide.' : null),
      'pass': {
        ...cap(_operator == null
            ? 'Identifiez le caissier.'
            : engine.passSettings == null
            ? 'Passes événement non disponibles sur ce terminal.'
            : engine.canPayByPass(_operator!)
            ? null
            : 'Permission refusée : encaisser par pass.'),
        'manual_entry': engine.passSettings?.manualEntry ?? false,
        'several_per_sale': engine.passSettings?.severalPerSale ?? false,
      },
    };
  }

  /// Motif qui empêche le caissier courant d'accorder une remise globale (droit, politique de la boutique), ou null.
  String? _globalDiscountRefusal() {
    final operator = _operator;
    if (operator == null) return 'Identifiez le caissier.';
    if (!engine.hasRight(operator, 'remise')) return '${operator.name} n’a pas le droit d’accorder une remise.';
    if ((engine.snapshot?.rules.maxGlobalDiscountPercent ?? 0) <= 0) return 'Remise globale non autorisée hors ligne dans cette boutique.';
    return null;
  }

  /// Remise globale, livraison et note exigent la vente 2.1 (serveur à jour).
  String? _extrasRefusal() => engine.saleExtrasSupported ? null : 'Disponible quand la boutique est passée au contrat 2.1.';

  String? _wholesaleRefusal() {
    if (_draft.sharedCart != null) return 'Le mode tarifaire d’un panier repris est figé.';
    final rules = engine.wholesaleRules;
    final operator = _operator;
    if (rules == null || !rules.manual) return 'La bascule « Tarif gros » du panier n’est pas activée dans cette boutique.';
    if (operator == null) return 'Identifiez le caissier.';
    return engine.hasRight(operator, rules.right) ? null : '${operator.name} n’a pas le droit d’appliquer le tarif gros.';
  }

  CartTier _tierOf(_Draft draft) => CartTier(rules: engine.wholesaleRules, cart: draft.wholesale);

  String? _deliveryRefusal() {
    final operator = _operator;
    if (operator == null) return 'Identifiez le caissier.';
    final right = engine.deliveryRight;
    if (right != null && !engine.hasRight(operator, right)) return '${operator.name} n’a pas le droit d’ajouter une livraison.';
    return null;
  }

  /// Motif qui empêche le caissier courant d'accorder une remise de ligne, ou null.
  String? _discountRefusal() {
    final operator = _operator;
    if (operator == null) return 'Identifiez le caissier.';
    if (!engine.hasRight(operator, 'remise')) return '${operator.name} n’a pas le droit d’accorder une remise.';
    if ((engine.snapshot?.rules.maxLineDiscountPercent ?? 0) <= 0) return 'Aucune remise autorisée hors ligne par la boutique.';
    return null;
  }

  Future<Map<String, dynamic>> _view() async {
    final snapshot = engine.snapshot;
    final remembered = await LocalPrices.read(engine);
    int displayedPrice(Product product) => remembered.priceFor(engine, _operator, CartLine(product: product)) ?? product.price;
    final reason = engine.blockReason;
    final sold = snapshot == null ? const <int, BigInt>{} : await engine.soldSinceSnapshot();
    final resolved = snapshot == null ? const <(_DraftLine, CartLine?)>[] : [for (final l in _draft.lines) (l, l.materialize(snapshot, _tierOf(_draft)))];
    final available = [for (final r in resolved) if (r.$2 != null) r.$2!];
    final totals = snapshot == null ? null : _totalsOf(_draft, snapshot);
    final currency = snapshot?.store.currency == 'FCFA' || snapshot == null ? 'F' : snapshot.store.currency;
    final hits = snapshot == null
        ? const <Product>[]
        : snapshot.search(_query, limit: null, category: _category, brand: _brand, supplier: _supplier);
    final now = DateTime.now();
    final today = now.toIso8601String().substring(0, 10);
    final payments = _draft.payments;
    final payment = payments.firstOrNull;
    final paymentValid = totals != null && payments.isNotEmpty && _paymentsError(snapshot!, payments, totals.payable) == null;
    final paid = payments.fold<int>(0, (sum, p) => sum + p.amount);
    final cash = payments.where((p) => p.received != null).firstOrNull;
    final ready = snapshot != null && reason == null;
    final payReason = !ready
        ? (reason ?? 'Aucun catalogue reçu : connectez le terminal une première fois.')
        : _operator == null
        ? 'Identifiez le caissier.'
        : !engine.sessionOpen
        ? 'Aucune session de caisse ouverte sur ce terminal.'
        : available.isEmpty
        ? 'Le panier est vide.'
        : available.length != resolved.length
        ? 'Un article du panier a été retiré du catalogue : retirez-le.'
        : totals == null
        ? 'La remise globale dépasse le montant du panier.'
        : _discountIssue(snapshot, resolved);
    final localSuspended = (await engine.openDrafts()).where((d) => d.content['suspendu'] == true).toList();
    final linkedShared = {for (final d in localSuspended) _Draft.fromStored(d).sharedCart?.uuid};
    final suspended = localSuspended.length + (await engine.sharedCarts()).where((c) => !linkedShared.contains(c.uuid)).length;
    final carts = resolved.map((r) => r.$2).whereType<CartLine>().toList();
    final overLimit = _operator != null && !engine.withinDiscountLimits(_operator!, carts, _draft.globalDiscount);
    final demand = _stockDemand(resolved);
    final alerted = <int>{};
    return {
      'customer': _draft.customer == null ? null : _customerJson(_draft.customer!),
      'discount_approval': {
        'required': overLimit,
        'approvers': [
          if (overLimit)
            for (final o in engine.approversFor(_operator!, carts, _draft.globalDiscount)) {'id': o.id, 'name': o.name},
        ],
      },
      'schema': 1,
      'revision': _revision,
      'ready': ready,
      'block_reason': reason,
      // Modification d'un ticket en cours (2.1 lot 11) : bandeau, encaissement ordinaire et mise en attente bloqués.
      'can_pay': payReason == null && _draft.edit == null,
      'pay_reason': _draft.edit != null ? 'Modification du ticket en cours : validez-la ou abandonnez-la.' : payReason,
      'sale_edit': _draft.edit == null
          ? null
          : {
              'sale_id': _draft.edit!['vente_id'],
              'number': _draft.edit!['numero'],
              'original_total': _draft.edit!['total_origine'],
              'original_total_label': formatFcfa(((_draft.edit!['total_origine'] as num?) ?? 0).toInt()),
            },
      'draft_id': _draft.uuid,
      'suspended_count': suspended,
      'store_name': snapshot?.store.name ?? '',
      'sync_label': _syncLabel(),
      'total_label': totals == null ? '' : formatFcfa(totals.payable, currency),
      'payment_label': payments.map((p) => '${p.methodCode} ${formatFcfa(p.amount, currency)}').join(' + '),
      'payment_valid': paymentValid,
      // Détail calculé par le moteur, rendu en libellés : l'écran ne refait aucun calcul financier.
      'totals': totals == null
          ? null
          : {
              'gross_label': formatFcfa(totals.subtotal, currency),
              'discounts_label': formatFcfa(totals.lineDiscounts, currency),
              'global_discount_label': totals.globalDiscount == 0 ? '' : formatFcfa(totals.globalDiscount, currency),
              'delivery_label': totals.delivery == 0 ? '' : formatFcfa(totals.delivery, currency),
              'base_ht_label': formatFcfa(totals.baseHt, currency),
              'vat_label': formatFcfa(totals.vat, currency),
              'vat_rate': snapshot!.store.vatRate,
              'vat_included': snapshot.store.vatIncluded,
              'payable_label': formatFcfa(totals.payable, currency),
            },
      // Premier paiement (vue d'un paiement unique) ; reçu et monnaie portent sur la ligne d'espèces.
      'payment': payment == null || totals == null
          ? null
          : {
              'method': payment.methodCode,
              'amount_label': formatFcfa(payment.amount, currency),
              'received_label': cash == null ? null : formatFcfa(cash.received!, currency),
              'change_label': cash == null ? null : formatFcfa(cash.received! - engine.cashDue(cash.amount), currency),
              // Arrondi de caisse : le tiroir reçoit le montant arrondi ; la vente garde le montant exact.
              'cash_due_label': cash == null ? null : formatFcfa(engine.cashDue(cash.amount), currency),
              'rounding_label': cash == null || engine.cashDue(cash.amount) == cash.amount
                  ? null
                  : formatFcfa(engine.cashDue(cash.amount) - cash.amount, currency),
              'paid_label': formatFcfa(paid, currency),
              'remaining_label': formatFcfa(totals.payable - paid, currency),
            },
      'payments': [
        for (final p in payments)
          {
            'method': p.methodCode,
            'name': snapshot?.methods.where((m) => m.code == p.methodCode).firstOrNull?.name ?? p.methodCode,
            'amount_label': formatFcfa(p.amount, currency),
            'received_label': p.received == null ? null : formatFcfa(p.received!, currency),
            'reference': p.reference,
          },
      ],
      'global_discount_entry': _draft.globalEntry?.toJson(),
      'delivery': _draft.delivery,
      'note': _draft.note,
      'wholesale': _draft.wholesale,
      'passes': [for (final p in _draft.passes) _passJson(p, snapshot?.store.currency ?? 'FCFA')],
      'query': _query,
      'category': _category,
      'categories': snapshot?.categories ?? const <String>[],
      'brand': _brand,
      'brands': snapshot?.brands ?? const <String>[],
      'supplier': _supplier,
      'suppliers': snapshot?.suppliers ?? const <String>[],
      'products_total': hits.length,
      'has_more': hits.length > _productLimit,
      'products': [
        for (final p in hits.take(_productLimit))
            {
              'id': p.id,
              'name': p.name,
              'category': p.category,
              'brand': p.brand,
              'supplier': p.supplier,
              'unit': p.unit,
              'favorite': p.favorite,
              'promotion': p.promotionLabel(today),
              'is_new': p.isNew(engine.newBadgeDays, now),
              'low_stock': _lowStock(p, sold[p.id] ?? BigInt.zero),
              'image': p.image == null
                  ? null
                  : {'uuid': p.image!.uuid, 'hash': p.image!.hash, 'width': p.image!.width, 'height': p.image!.height, 'path': engine.imagePath(p.image!)},
              'price_label': formatFcfa(displayedPrice(p), currency),
              'local_state': p.localState,
              'wholesale_price_label': p.wholesalePrice == null || engine.wholesaleRules == null ? null : formatFcfa(p.wholesalePrice!, currency),
              'stock_label': p.unlimitedStock ? '' : _stockLabel(p, sold[p.id] ?? BigInt.zero),
              'stock_after_label': p.unlimitedStock ? '' : _stockLabel(p, (sold[p.id] ?? BigInt.zero) + (demand[p.id] ?? BigInt.zero)),
              'packagings': [for (final k in p.packagings) {'id': k.id, 'name': k.name, 'price_label': formatFcfa(k.price, currency)}],
            },
      ],
      'lines': [
        for (final (line, cart) in resolved)
          {
            'id': line.id,
            'name': cart?.label ?? 'Article n° ${line.productId} (retiré du catalogue)',
            'quantity_label': formatMicros(line.quantity),
            'quantity': formatMicros(line.quantity),
            'unit_price_label': cart == null ? '' : formatFcfa(cart.unitPrice, currency),
            // Prix saisi (2.1 lot 9) : champ proposé seulement si `price_editable` ; sinon `price_edit_reason` dit pourquoi.
            'price_editable': cart != null && engine.enteredPriceBlocker(_operator, cart) == null,
            'price_edit_reason': cart == null ? null : engine.enteredPriceBlocker(_operator, cart),
            'entered_price': line.entered,
            'usual_price': cart?.usualPrice,
            'usual_price_label': cart == null ? '' : formatFcfa(cart.usualPrice, currency),
            'discount_label': cart == null || cart.discount == 0 ? '' : formatFcfa(cart.discount, currency),
            'discount': line.discount,
            'discount_entry': line.entry?.toJson(),
            'total_label': cart == null ? '' : formatFcfa(cart.total, currency),
            'available': cart != null,
            'lot_uuid': line.lotUuid,
            'lot_label': cart?.lot?.label,
            'lot_expires_on': cart?.lot?.expiresOn,
            'wholesale': cart?.wholesale ?? false,
            'wholesale_refused': cart?.wholesaleRefused ?? false,
            'lots': [
              for (final l in cart?.product.lots ?? const <ProductLot>[])
                if (l.remaining > BigInt.zero)
                  {'uuid': l.uuid, 'label': '${l.label} · ${formatMicros(l.remaining)} disponible(s) · ${formatFcfa(l.price, currency)}/unité', 'expires_on': l.expiresOn, 'expiry_label': l.expiryLabel},
            ],
            'stock_after_label': cart == null || cart.product.unlimitedStock
                ? ''
                : _stockLabel(cart.product, (sold[cart.product.id] ?? BigInt.zero) + demand[cart.product.id]!),
            // Alerte sur la première ligne du produit, comme la caisse web.
            'stock_alert': cart == null || cart.product.unlimitedStock || !alerted.add(cart.product.id)
                ? null
                : _stockAlert(cart.product, sold[cart.product.id] ?? BigInt.zero, demand[cart.product.id]!),
          },
      ],
    };
  }

  /// Remise de ligne que l'encaissement refuserait (droit retiré, politique abaissée, quantité réduite), ou null.
  String? _discountIssue(Snapshot snapshot, List<(_DraftLine, CartLine?)> resolved) {
    for (final (_, cart) in resolved) {
      if (cart?.enteredPrice == null) continue;
      final blocker = engine.enteredPriceBlocker(_operator, cart!);
      if (blocker != null) return 'Prix saisi sur « ${cart.label} » : $blocker Retirez-le.';
    }
    for (final (_, cart) in resolved) {
      if (cart == null || cart.discount == 0) continue;
      if (!engine.hasRight(_operator!, 'remise')) return '${_operator!.name} n’a pas le droit d’accorder une remise : retirez celle de « ${cart.label} ».';
      final max = engine.enterableLineDiscount(_operator!, cart.base);
      if (cart.discount > max) return 'Remise sur « ${cart.label} » au-delà du maximum (${formatFcfa(max)}) : corrigez-la.';
    }
    final subtotal = resolved.fold<int>(0, (sum, r) => sum + (r.$2 == null ? 0 : r.$2!.base - r.$2!.discount));
    if (_draft.globalDiscount > 0) {
      if (!engine.hasRight(_operator!, 'remise')) return '${_operator!.name} n’a pas le droit d’accorder une remise : retirez la remise globale.';
      final max = engine.enterableGlobalDiscount(_operator!, subtotal);
      if (_draft.globalDiscount > max) return 'Remise globale au-delà du maximum (${formatFcfa(max)}) : corrigez-la.';
    }
    if (_draft.delivery > 0 && _deliveryRefusal() != null) return _deliveryRefusal();
    final saleCap = engine.enterableSaleDiscount(_operator!);
    final total = resolved.fold<int>(0, (sum, r) => sum + (r.$2?.discount ?? 0)) + _draft.globalDiscount;
    if (saleCap != null && total > saleCap) return 'Remises au-delà du plafond de ${_operator!.name} par vente (${formatFcfa(saleCap)}).';
    final carts = resolved.map((r) => r.$2).whereType<CartLine>().toList();
    if (!engine.withinDiscountLimits(_operator!, carts, _draft.globalDiscount) && engine.approversFor(_operator!, carts, _draft.globalDiscount).isEmpty) {
      return 'Remises au-delà du seuil de ${_operator!.name} et de celui des responsables : corrigez-les.';
    }
    return null;
  }

  /// Totaux du panier par la règle du web, ou null si la remise globale dépasse le sous-total.
  WebTotals? _totalsOf(_Draft draft, Snapshot snapshot) {
    final carts = [for (final l in draft.lines) l.materialize(snapshot, _tierOf(draft))].whereType<CartLine>().toList();
    try {
      return webTotals(
        lineBases: [for (final c in carts) c.base],
        lineDiscounts: [for (final c in carts) c.discount],
        globalDiscount: draft.globalDiscount,
        vatRate: snapshot.store.vatRate,
        vatIncluded: snapshot.store.vatIncluded,
        delivery: draft.delivery,
      );
    } on WebRuleRefusal {
      return null;
    }
  }

  String _stockLabel(Product p, BigInt sold) {
    final central = p.negativeStock ? -p.stockMicros : p.stockMicros;
    final estimated = central - sold;
    return estimated.isNegative ? '-${formatMicros(-estimated)}' : formatMicros(estimated);
  }

  /// Quantité demandée par produit suivi, toutes lignes du panier, en unité de base (millionièmes).
  Map<int, BigInt> _stockDemand(List<(_DraftLine, CartLine?)> resolved) {
    final demand = <int, BigInt>{};
    for (final (line, cart) in resolved) {
      if (cart == null || cart.product.unlimitedStock) continue;
      demand[cart.product.id] = (demand[cart.product.id] ?? BigInt.zero) + baseQuantity(line.quantity, cart.packaging?.coefficient);
    }
    return demand;
  }

  /// `level` : `low` ou `short`.
  Map<String, dynamic>? _stockAlert(Product p, BigInt sold, BigInt demand) {
    final alert = stockAlert(p.signedStock - sold, demand, p.alertThreshold, engine.oversellPolicy);
    return alert == null ? null : {'level': alert.level, 'message': alert.message};
  }

  /// Stock estimé au seuil d'alerte du produit ou en dessous (jamais pour un stock illimité).
  bool _lowStock(Product p, BigInt sold) {
    final threshold = p.alertThreshold;
    if (p.unlimitedStock || threshold == null) return false;
    return (p.negativeStock ? -p.stockMicros : p.stockMicros) - sold <= threshold;
  }

  String _syncLabel() {
    if (engine.reachable == true) {
      return engine.pendingCount == 0 ? 'À jour' : '${engine.pendingCount} vente(s) à transmettre';
    }
    final parts = ['Connexion interrompue — vente locale disponible'];
    if (engine.pendingCount > 0) parts.add('${engine.pendingCount} à transmettre');
    if (engine.localArbitrationCount > 0) parts.add('${engine.localArbitrationCount} à arbitrer');
    return parts.join(' · ');
  }

  // ------------------------------------------------------------------ Appairage

  /// Appairage du terminal (code à usage unique, 15 min) : exige la connexion à la boutique. [origin] : adresse de la
  /// boutique (`https://boutique.exemple.ci`). La file d'une autre boutique reste protégée par le moteur.
  Future<Map<String, dynamic>> _pair(Map<String, dynamic> args) async {
    final origin = _text(args, 'origin', max: 200);
    if (!RegExp(r'^https?://[^\s/]+(:\d+)?$').hasMatch(origin)) throw const AdapterFailure('adresse_invalide', 'Adresse de boutique invalide.');
    await engine.load(origin);
    final error = await engine.pair(
      _text(args, 'code', max: 32),
      model: _text(args, 'model', max: 100),
      appVersion: _text(args, 'app_version', max: 40),
    );
    if (error != null) throw AdapterFailure('appairage_refuse', error);
    _emit('appairage');
    return _status();
  }

  // ------------------------------------------------------------------ Opérateur

  Future<Map<String, dynamic>> _login(Map<String, dynamic> args) async {
    final snapshot = _snapshot();
    final operator = snapshot.operatorById(_int(args, 'operator_id'));
    if (operator == null) throw const AdapterFailure('caissier_inconnu', 'Caissier inconnu sur ce terminal.');
    if (snapshot.rules.pinRequired) {
      if (!engine.pinDefined(operator)) throw const AdapterFailure('pin_non_defini', 'PIN non défini pour ce caissier : définissez-le dans ShopiKaiss.');
      final locked = await engine.pinLockedFor(operator);
      if (locked != null) throw AdapterFailure('pin_bloque', 'PIN bloqué : réessayez dans ${locked.inSeconds} s.');
      if (!await engine.checkPin(operator, _text(args, 'pin', max: 6))) throw const AdapterFailure('pin_refuse', 'PIN incorrect.');
    }
    _operator = operator;
    _emit('caissier');
    return _status();
  }

  Map<String, int> _returnQuantities(Map<String, dynamic> args) {
    final quantities = <String, int>{};
    for (final raw in (args['lines'] as List? ?? const []).cast<Map>()) {
      final line = raw.cast<String, dynamic>();
      final quantity = parseMicros(_text(line, 'quantity', max: 32));
      if (quantity == null) throw const AdapterFailure('retour_refuse', 'Quantité invalide.');
      quantities[_text(line, 'line_id', max: 36)] = quantity.toInt();
    }
    return quantities;
  }

  Future<Map<String, dynamic>> _returnable(String saleId) async {
    try {
      return {
        'lines': [
          for (final l in await engine.returnableLines(saleId)) {'line_id': l.lineUuid, 'label': l.label, 'remaining': formatMicros(BigInt.from(l.remaining))},
        ],
      };
    } on OfflineRefusal catch (e) {
      throw AdapterFailure('retour_refuse', e.message);
    }
  }

  Future<Map<String, dynamic>> _previewReturn(Map<String, dynamic> args) async {
    try {
      final amount = await engine.returnAmount(_text(args, 'sale_id', max: 36), _returnQuantities(args));
      return {'amount': amount, 'amount_label': formatFcfa(amount)};
    } on OfflineRefusal catch (e) {
      throw AdapterFailure('retour_refuse', e.message);
    }
  }

  Future<Map<String, dynamic>> _commitReturn(Map<String, dynamic> args, String? operationId) async {
    final operator = _operator;
    if (operator == null) throw const AdapterFailure('caissier_requis', 'Identifiez le caissier avant un retour.');
    try {
      final operation = await engine.recordReturn(operator, _text(args, 'sale_id', max: 36), _returnQuantities(args), _text(args, 'reason', max: 500), operationUuid: operationId);
      _emit('retour');
      return {'operation_id': operation.uuid, 'amount': operation.content['montant'], 'amount_label': formatFcfa(operation.content['montant'] as int)};
    } on OfflineRefusal catch (e) {
      throw AdapterFailure('retour_refuse', e.message);
    }
  }

  /// Clôture de la session par le caissier identifié, comptée à l'aveugle ; le Z arrive du serveur.
  Future<Map<String, dynamic>> _closeSession(Map<String, dynamic> args, String? operationId) async {
    final operator = _operator;
    if (operator == null) throw const AdapterFailure('caissier_requis', 'Identifiez le caissier avant de clôturer.');
    if (_draft.lines.isNotEmpty) throw const AdapterFailure('panier_en_cours', 'Terminez ou videz le panier avant de clôturer.');
    final counts = [
      for (final raw in (args['counts'] as List? ?? const []).cast<Map>())
        SessionCount(
          method: _text(raw.cast<String, dynamic>(), 'method', max: 32),
          amount: _int(raw.cast<String, dynamic>(), 'amount'),
          justification: raw['justification'] as String?,
        ),
    ];
    try {
      await engine.closeSession(operator, cash: _int(args, 'cash'), comment: args['comment'] as String?, others: counts, operationUuid: operationId);
    } on OfflineRefusal catch (e) {
      throw AdapterFailure('cloture_refusee', e.message);
    }
    _emit('session');
    return _status();
  }

  /// Ouverture de session locale par le caissier identifié ([float] : fond de caisse compté, en francs).
  Future<Map<String, dynamic>> _openSession(Map<String, dynamic> args) async {
    final operator = _operator;
    if (operator == null) throw const AdapterFailure('caissier_requis', 'Identifiez le caissier avant d’ouvrir la session.');
    try {
      await engine.openSession(_int(args, 'float'), operator);
    } on OfflineRefusal catch (e) {
      throw AdapterFailure('session_refusee', e.message);
    }
    _emit('session');
    return _status();
  }

  // ------------------------------------------------------------------ Panier (conservé à chaque modification)

  Future<Map<String, dynamic>> _add(int productId, int? packagingId) async {
    final product = _snapshot().products.where((p) => p.id == productId).firstOrNull;
    if (product == null) throw const AdapterFailure('produit_inconnu', 'Produit absent du catalogue du terminal.');
    if (packagingId != null && product.packaging(packagingId) == null) {
      throw const AdapterFailure('conditionnement_inconnu', 'Conditionnement inconnu pour ce produit.');
    }
    final remembered = await LocalPrices.read(engine);
    final candidate = _DraftLine(id: _newUuid(), productId: productId, packagingId: packagingId, quantity: BigInt.from(1000000));
    final cart = candidate.materialize(_snapshot(), _tierOf(_draft));
    if (cart != null) candidate.entered = remembered.priceFor(engine, _operator, cart);
    return _mutate(() {
      final existing = _draft.lines.where((l) => l.productId == productId && l.packagingId == packagingId).firstOrNull;
      if (existing != null) {
        existing.quantity += BigInt.from(1000000);
      } else {
        _draft.lines.add(candidate);
      }
    });
  }

  Future<Map<String, dynamic>> _changeQuantity(String lineId, String quantity) {
    final line = _draft.lines.where((l) => l.id == lineId).firstOrNull;
    if (line == null) throw const AdapterFailure('ligne_inconnue', 'Ligne introuvable dans le panier.');
    final micros = parseMicros(quantity);
    if (micros == null || micros <= BigInt.zero) throw const AdapterFailure('quantite_invalide', 'Quantité invalide (positive, six décimales au plus).');
    return _mutate(() => line.quantity = micros);
  }

  /// Panier entier au tarif gros : même droit et mêmes limites que le bouton de la caisse web.
  Future<Map<String, dynamic>> _setWholesale(bool active) async {
    if (_draft.sharedCart != null) throw const AdapterFailure('tarif_fige', 'Le mode tarifaire d’un panier repris est figé.');
    if (active) {
      final refusal = _wholesaleRefusal();
      if (refusal != null) throw AdapterFailure('tarif_refuse', refusal);
    }
    return _mutate(() => _draft.wholesale = active);
  }

  /// Prix unitaire saisi sur la ligne (2.1 lot 9) : `amount` entier en francs de 0 à 1 000 000 000, ou null pour revenir
  /// au prix habituel. Produit coché, unité de base, droit `prix_vente_modifier` ; la remise en pourcentage se recalcule
  /// sur le nouveau prix. Contrôlé de nouveau par le moteur à l'encaissement.
  Future<Map<String, dynamic>> _setLinePrice(String lineId, Object? amount) async {
    final line = _draft.lines.where((l) => l.id == lineId).firstOrNull;
    if (line == null) throw const AdapterFailure('ligne_inconnue', 'Ligne introuvable dans le panier.');
    if (amount != null && amount is! int) throw const AdapterFailure('argument_invalide', 'Argument « amount » invalide (entier en francs, ou null).');
    final price = amount as int?;
    if (price != null) {
      if (price < 0 || price > CaisseEngine.maxEnteredPrice) throw const AdapterFailure('prix_invalide', 'Prix invalide (0 à 1 000 000 000 F).');
      final cart = line.materialize(_snapshot(), _tierOf(_draft));
      if (cart == null) throw const AdapterFailure('panier_invalide', 'Article retiré du catalogue : retirez-le du panier.');
      final blocker = engine.enteredPriceBlocker(_operator, cart);
      if (blocker != null) throw AdapterFailure('prix_refuse', blocker);
    }
    final result = await _mutate(() => line.entered = price);
    if (await LocalPrices.remember(engine, line.productId, price)) {
      _emit('prix_locaux');
      return _view();
    }
    return result;
  }

  // ------------------------------------------------------------------ Modifier un ticket (2.1 lot 11)

  Future<OfflineOperation> _editedSale() async {
    final id = _draft.edit?['vente_id'] as String?;
    final sale = id == null ? null : await engine.saleStatus(id);
    if (sale == null) throw const AdapterFailure('aucune_modification', 'Aucune modification de ticket en cours.');
    return sale;
  }

  List<CartLine> _editLines() {
    final snapshot = _snapshot();
    final lines = [for (final l in _draft.lines) l.materialize(snapshot, _tierOf(_draft))];
    if (lines.any((l) => l == null)) throw const AdapterFailure('panier_invalide', 'Un article du panier n’est plus au catalogue local : retirez-le.');
    return lines.cast<CartLine>();
  }

  /// Les articles du ticket reviennent dans le panier, au prix du catalogue (prix saisi gardé pour un produit coché).
  Future<Map<String, dynamic>> _startSaleEdit(String saleId) async {
    if (_draft.edit != null) throw const AdapterFailure('modification_en_cours', 'Une modification de ticket est déjà en cours.');
    if (_draft.lines.isNotEmpty) throw const AdapterFailure('panier_non_vide', 'Videz ou mettez en attente le panier avant de modifier un ticket.');
    final sale = await engine.saleStatus(saleId);
    if (sale == null || !sale.isSale) throw const AdapterFailure('vente_inconnue', 'Vente introuvable sur ce terminal.');
    final refusal = await engine.saleEditCheck(_operator, sale);
    if (refusal != null) throw AdapterFailure('modification_refusee', refusal);
    final snapshot = _snapshot();
    return _mutate(() {
      for (final l in (sale.content['lignes'] as List).cast<Map>()) {
        final productId = l['produit_id'] as int?;
        final product = productId == null ? null : snapshot.byId(productId);
        if (product == null) continue;
        final packagingId = l['conditionnement_id'] as int?;
        final usual = packagingId == null ? product.price : (product.packaging(packagingId)?.price ?? product.price);
        final unit = (l['prix_unitaire'] as num).toInt();
        _draft.lines.add(_DraftLine(
          id: _newUuid(),
          productId: product.id,
          packagingId: packagingId,
          quantity: parseMicros('${l['quantite']}') ?? BigInt.zero,
          discount: (l['remise'] as num?)?.toInt() ?? 0,
          entered: packagingId == null && product.priceEditable && unit != usual ? unit : null,
        ));
      }
      _draft.edit = {'vente_id': sale.uuid, 'numero': sale.number, 'total_origine': sale.total};
    });
  }

  Future<Map<String, dynamic>> _cancelSaleEdit() async {
    if (_draft.edit == null) return _view();
    await engine.deleteDraft(_draft.uuid);
    _draft = _Draft(_newUuid());
    _emit('panier');
    return _view();
  }

  Future<Map<String, dynamic>> _prepareSaleEdit() async {
    final sale = await _editedSale();
    final SaleEditPreview preview;
    try {
      preview = engine.previewSaleEdit(sale, _editLines());
    } on OfflineRefusal catch (e) {
      throw AdapterFailure('modification_refusee', e.message);
    }
    final names = {for (final m in _snapshot().methods) m.code: m.name};
    return {
      'sale_id': sale.uuid,
      'number': sale.number,
      'original_total': preview.originalTotal,
      'original_total_label': formatFcfa(preview.originalTotal),
      'new_total': preview.newTotal,
      'new_total_label': formatFcfa(preview.newTotal),
      'difference': preview.difference,
      'difference_label': formatFcfa(preview.difference.abs()),
      'direction': preview.direction,
      'direction_label': switch (preview.direction) {
        'encaissement' => 'Complément à encaisser',
        'remboursement' => 'À rembourser au client',
        _ => 'Aucune différence',
      },
      'method_choice': preview.methodChoice,
      'methods': [for (final m in preview.methods) {'code': m.code, 'name': names[m.code] ?? m.code, 'amount': m.amount}],
    };
  }

  /// Valide la modification : code responsable (identifie seul le responsable), moyen de la différence, motif.
  /// Idempotent par `operation_id` : rejoué, il rend le même ticket de remplacement.
  Future<Map<String, dynamic>> _commitSaleEdit(Map<String, dynamic> args) async {
    final operationId = _text(args, 'operation_id', max: 36);
    final already = await engine.saleStatus(operationId);
    if (already != null && already.isSaleEdit) {
      if (_draft.edit != null) await _cancelSaleEdit();
      return _committed(already);
    }
    final operator = _operator;
    if (operator == null) throw const AdapterFailure('caissier_requis', 'Identifiez le caissier.');
    final sale = await _editedSale();
    final code = args['approval_code'];
    if (code is! String || code.isEmpty) throw const AdapterFailure('code_requis', 'Saisissez le code du responsable.');
    final Operator approver;
    try {
      approver = await engine.identifyEditApprover(code);
    } on OfflineRefusal catch (e) {
      throw AdapterFailure('code_refuse', e.message);
    }
    try {
      final edited = await engine.recordSaleEdit(
        operator,
        sale,
        _editLines(),
        approver: approver,
        method: args['method'] as String?,
        reason: args['reason'] as String?,
        operationUuid: operationId,
      );
      await engine.deleteDraft(_draft.uuid);
      _draft = _Draft(_newUuid());
      _emit('vente');
      return _committed(edited);
    } on OfflineRefusal catch (e) {
      throw AdapterFailure('modification_refusee', e.message);
    }
  }

  // ------------------------------------------------------------------ Catalogue hors connexion (2.1 lot 10)

  Map<String, dynamic> _catalogueForm() => {
    'create': {'allowed': engine.productCreateBlocker(_operator) == null, 'reason': engine.productCreateBlocker(_operator)},
    'edit': {'allowed': engine.productEditBlocker(_operator) == null, 'reason': engine.productEditBlocker(_operator)},
    'categories': [for (final c in engine.productCategories) {'uuid': c.uuid, 'name': c.name}],
    'limits': {
      'name': CatalogueLimits.name,
      'reference': CatalogueLimits.reference,
      'barcodes': CatalogueLimits.barcodes,
      'barcode': CatalogueLimits.barcode,
      'max_amount': CatalogueLimits.maxAmount,
    },
  };

  static String? _optionalString(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value != null && value is! String) throw AdapterFailure('argument_invalide', 'Texte attendu pour $key.');
    return value as String?;
  }

  static int? _optionalInt(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value != null && value is! int) throw AdapterFailure('argument_invalide', 'Entier attendu pour $key.');
    return value as int?;
  }

  /// Refus du moteur pour le catalogue : code propre s'il en a un, sinon champ invalide.
  static AdapterFailure _catalogueFailure(OfflineRefusal e) => AdapterFailure(e.code ?? 'champ_invalide', e.message);

  Operator _catalogueOperator(String? blocker) {
    if (blocker != null) throw AdapterFailure('produit_refuse', blocker);
    return _operator!;
  }

  Future<Map<String, dynamic>> _createProduct(Map<String, dynamic> args) async {
    final operator = _catalogueOperator(engine.productCreateBlocker(_operator));
    final barcodes = args['barcodes'] ?? const <Object?>[];
    if (barcodes is! List || barcodes.any((c) => c is! String)) throw const AdapterFailure('argument_invalide', 'Liste de codes-barres attendue.');
    if (args['price'] is! int) throw const AdapterFailure('argument_invalide', 'Prix de vente entier attendu.');
    if (args['unlimited_stock'] != null && args['unlimited_stock'] is! bool) throw const AdapterFailure('argument_invalide', 'Choix du stock illimité attendu.');
    final operationId = _optionalString(args, 'operation_id');
    try {
      final product = await engine.createProduct(
        operator,
        NewProduct(
          name: _optionalString(args, 'name') ?? '',
          reference: _optionalString(args, 'reference'),
          barcodes: barcodes.cast<String>(),
          categoryUuid: _optionalString(args, 'category_uuid'),
          price: args['price'] as int,
          purchasePrice: _optionalInt(args, 'purchase_price'),
          wholesalePrice: _optionalInt(args, 'wholesale_price'),
          wholesaleMin: _optionalString(args, 'wholesale_min'),
          unlimitedStock: args['unlimited_stock'] == true,
        ),
        operationUuid: operationId,
      );
      _emit('catalogue');
      return {'product_id': product.id, 'product_uuid': engine.productFields(product.id)?.uuid, 'local_state': 'a_synchroniser'};
    } on OfflineRefusal catch (e) {
      throw _catalogueFailure(e);
    }
  }

  Map<String, dynamic> _productForEdit(int productId) {
    final fields = engine.productFields(productId);
    if (fields == null) throw const AdapterFailure('produit_inconnu', 'Produit inconnu sur ce terminal.');
    final reason = engine.productEditBlocker(_operator);
    return {
      'product_id': fields.productId,
      'product_uuid': fields.uuid,
      'name': fields.name,
      'reference': fields.reference,
      'barcodes': fields.barcodes,
      'category_uuid': fields.categoryUuid,
      'price': fields.price,
      'wholesale_price': fields.wholesalePrice,
      'wholesale_min': fields.wholesaleMin,
      'wholesale_min_label': fields.wholesaleMin == null ? null : Decimal6.label(Decimal6.parse(fields.wholesaleMin!)),
      'unlimited_stock': fields.unlimitedStock,
      'local_state': fields.localState,
      'editable': reason == null,
      'reason': reason,
    };
  }

  static const _fieldNames = {
    'name': 'nom',
    'reference': 'reference',
    'category_uuid': 'categorie_uuid',
    'price': 'prix',
    'wholesale_price': 'prix_gros',
    'wholesale_min': 'gros_quantite_min',
  };

  Future<Map<String, dynamic>> _updateProduct(Map<String, dynamic> args) async {
    final operator = _catalogueOperator(engine.productEditBlocker(_operator));
    final productId = _int(args, 'product_id');
    final fields = args['fields'];
    if (fields is! Map || fields.isEmpty) throw const AdapterFailure('aucun_changement', 'Aucun changement à enregistrer.');
    final changes = <String, Object?>{};
    final expectedInput = args['expected_fields'];
    if (expectedInput != null && expectedInput is! Map) {
      throw const AdapterFailure('argument_invalide', 'Valeurs de lecture invalides.');
    }
    final expected = expectedInput is Map ? <String, Object?>{} : null;
    for (final e in fields.entries) {
      final name = _fieldNames[e.key];
      if (name == null) throw AdapterFailure('argument_invalide', 'Champ non modifiable : ${e.key}.');
      final value = e.value;
      final integer = name == 'prix' || name == 'prix_gros';
      if (integer ? (value != null && value is! int) : (value != null && value is! String)) {
        throw AdapterFailure('argument_invalide', 'Valeur invalide pour ${e.key}.');
      }
      changes[name] = value;
      if (expected != null) {
        if (!expectedInput.containsKey(e.key)) throw const AdapterFailure('argument_invalide', 'Valeur initiale manquante.');
        expected[name] = expectedInput[e.key];
      }
    }
    try {
      final product = await engine.updateProduct(operator, productId, changes, operationUuid: _optionalString(args, 'operation_id'), expected: expected);
      _emit('catalogue');
      return {'product_id': product.id, 'local_state': 'a_synchroniser'};
    } on OfflineRefusal catch (e) {
      throw _catalogueFailure(e);
    }
  }

  Future<Map<String, dynamic>> _localPrices() async => (await LocalPrices.read(engine)).toJson();

  /// Lot de la ligne ; null = choix automatique selon la règle de la boutique.
  Future<Map<String, dynamic>> _setLineLot(String lineId, String? lot) async {
    final line = _draft.lines.where((l) => l.id == lineId).firstOrNull;
    if (line == null) throw const AdapterFailure('ligne_inconnue', 'Ligne introuvable dans le panier.');
    final product = _snapshot().byId(line.productId);
    if (lot != null && !(product?.lots.any((l) => l.uuid == lot) ?? false)) throw const AdapterFailure('lot_inconnu', 'Le lot choisi est indisponible dans cette boutique.');
    return _mutate(() => line.lotUuid = lot);
  }

  /// Remise de ligne en francs (0 = retirer). Droit `remise` du caissier et plafond de la politique, contrôlés de
  /// nouveau par le moteur à l'encaissement.
  Future<Map<String, dynamic>> _setLineDiscount(String lineId, DiscountEntry? entry) {
    final line = _draft.lines.where((l) => l.id == lineId).firstOrNull;
    if (line == null) throw const AdapterFailure('ligne_inconnue', 'Ligne introuvable dans le panier.');
    var amount = 0;
    if (entry != null) {
      final refusal = _discountRefusal();
      if (refusal != null) throw AdapterFailure('remise_refusee', refusal);
      final snapshot = _snapshot();
      final cart = line.materialize(snapshot, _tierOf(_draft));
      if (cart == null) throw const AdapterFailure('panier_invalide', 'Article retiré du catalogue : retirez-le du panier.');
      amount = _amountOf(entry, cart.base, label: cart.label);
      final max = engine.enterableLineDiscount(_operator!, cart.base);
      if (amount > max) {
        throw AdapterFailure('remise_refusee', 'Remise au-delà du maximum autorisé (${formatFcfa(max)} sur cette ligne).');
      }
      final saleCap = engine.enterableSaleDiscount(_operator!);
      final others = _draft.lines.where((l) => l.id != lineId).fold<int>(0, (sum, l) => sum + l.discount);
      if (saleCap != null && others + amount > saleCap) {
        throw AdapterFailure('remise_refusee', 'Remises au-delà du plafond de ${_operator!.name} par vente (${formatFcfa(saleCap)}).');
      }
    }
    return _mutate(() {
      line.discount = amount;
      line.entry = entry;
    });
  }

  /// Saisie d'une remise : `amount` (francs ; 0 = retirer) ou `percent` (« 12,5 »). Null = pas de remise.
  static DiscountEntry? _entry(Map<String, dynamic> args) {
    final percent = args['percent'];
    if (percent != null) {
      if (percent is! String || percent.length > 10) throw const AdapterFailure('argument_invalide', 'Argument « percent » invalide.');
      try {
        return DiscountEntry('pourcentage', formatPercent(parsePercent(percent)));
      } on WebRuleRefusal catch (e) {
        throw AdapterFailure('remise_invalide', e.message);
      }
    }
    final amount = _int(args, 'amount');
    if (amount < 0) throw const AdapterFailure('remise_invalide', 'Remise invalide (montant positif en francs).');
    return amount == 0 ? null : DiscountEntry('montant', '$amount');
  }

  /// Montant d'une saisie de remise sur [base] (règle d'arrondi de la boutique) ; refus du web au-delà de la base.
  int _amountOf(DiscountEntry entry, int base, {String? label}) {
    try {
      return enteredDiscount(type: entry.type, value: entry.value, base: base, rounding: engine.percentRounding, label: label);
    } on WebRuleRefusal catch (e) {
      throw AdapterFailure('remise_refusee', e.message);
    }
  }

  /// Remise globale (contrat 2.1) sur le sous-total : droit `remise`, plafonds du rôle et du terminal.
  Future<Map<String, dynamic>> _setGlobalDiscount(DiscountEntry? entry) {
    final unavailable = _extrasRefusal();
    if (unavailable != null) throw AdapterFailure('fonction_indisponible', unavailable);
    var amount = 0;
    if (entry != null) {
      final refusal = _globalDiscountRefusal();
      if (refusal != null) throw AdapterFailure('remise_refusee', refusal);
      final subtotal = _subtotal(_snapshot());
      try {
        amount = enteredDiscount(type: entry.type, value: entry.value, base: subtotal, rounding: engine.percentRounding);
      } on WebRuleRefusal {
        throw const AdapterFailure('remise_refusee', 'La remise globale dépasse le montant du panier.');
      }
      final max = engine.enterableGlobalDiscount(_operator!, subtotal);
      if (amount > max) throw AdapterFailure('remise_refusee', 'Remise globale au-delà du maximum autorisé (${formatFcfa(max)}).');
      final saleCap = engine.enterableSaleDiscount(_operator!);
      final lines = _draft.lines.fold<int>(0, (sum, l) => sum + l.discount);
      if (saleCap != null && lines + amount > saleCap) {
        throw AdapterFailure('remise_refusee', 'Remises au-delà du plafond de ${_operator!.name} par vente (${formatFcfa(saleCap)}).');
      }
    }
    return _mutate(() {
      _draft
        ..globalDiscount = amount
        ..globalEntry = entry;
    });
  }

  /// Livraison (contrat 2.1), hors TVA, ajoutée au montant à payer ; droit de la boutique s'il est défini.
  Future<Map<String, dynamic>> _setDelivery(int amount) {
    final unavailable = _extrasRefusal();
    if (unavailable != null) throw AdapterFailure('fonction_indisponible', unavailable);
    if (amount < 0) throw const AdapterFailure('livraison_invalide', 'Livraison invalide (montant positif en francs).');
    if (amount > 0) {
      final refusal = _deliveryRefusal();
      if (refusal != null) throw AdapterFailure('livraison_refusee', refusal);
    }
    return _mutate(() => _draft.delivery = amount);
  }

  /// Note du ticket (contrat 2.1), 2 000 caractères au plus ; vide = retirer.
  Future<Map<String, dynamic>> _setNote(String? text) {
    final unavailable = _extrasRefusal();
    if (unavailable != null) throw AdapterFailure('fonction_indisponible', unavailable);
    final note = text?.trim();
    return _mutate(() => _draft.note = note == null || note.isEmpty ? null : note);
  }

  /// Sous-total du panier (après remises de ligne) : base de la remise globale.
  int _subtotal(Snapshot snapshot) =>
      [for (final l in _draft.lines) l.materialize(snapshot, _tierOf(_draft))].whereType<CartLine>().fold<int>(0, (sum, c) => sum + c.base - c.discount);

  /// Remises en pourcentage recalculées après un changement du panier (quantité, ligne), comme le web.
  void _recomputePercents() {
    final snapshot = engine.snapshot;
    if (snapshot == null) return;
    for (final line in _draft.lines) {
      final cart = line.materialize(snapshot, _tierOf(_draft));
      if (cart != null && line.entry != null && line.entry!.isPercent) {
        line.discount = percentDiscount(cart.base, parsePercent(line.entry!.value), rounding: engine.percentRounding);
      }
    }
    final global = _draft.globalEntry;
    if (global != null && global.isPercent) {
      _draft.globalDiscount = percentDiscount(_subtotal(snapshot), parsePercent(global.value), rounding: engine.percentRounding);
    }
  }

  Future<Map<String, dynamic>> _mutate(void Function() change) async {
    final before = _draft.copy();
    change();
    _recomputePercents();
    _draft.payments.clear(); // tout changement du panier invalide les paiements préparés
    await _save(before);
    _emit('panier');
    return _view();
  }

  /// Conserve le panier courant (révision suivante) ; en cas de refus, rétablit [before].
  Future<void> _save(_Draft before) async {
    _draft.revision++;
    if (!await engine.saveDraft(_draft.uuid, _draft.revision, _draft.toJson())) {
      _draft = before;
      throw const AdapterFailure('panier_perime', 'Ce panier a changé ou a déjà été encaissé : vue rechargée.');
    }
  }

  // ------------------------------------------------------------------ Images

  Map<String, dynamic> _imageSettings() {
    final counts = engine.imageCounts();
    return {'start': engine.imageWindow?.start, 'end': engine.imageWindow?.end, 'images_cached': counts.cached, 'images_total': counts.total};
  }

  /// Plage du téléchargement, `HH:MM` locales, qui peut passer minuit ; `start` et `end` absents : à toute heure.
  Future<Map<String, dynamic>> _setImageSettings(Map<String, dynamic> args) async {
    if (!engine.imagesSupported) throw const AdapterFailure('fonction_indisponible', 'Images non disponibles sur ce terminal.');
    final start = args['start'];
    final end = args['end'];
    if (start == null && end == null) {
      await engine.setImageWindow(null);
      return _imageSettings();
    }
    if (!validTimeWindow(start, end)) throw const AdapterFailure('reglage_refuse', 'Indiquez deux heures différentes, au format HH:MM.');
    await engine.setImageWindow((start: start as String, end: end as String));
    return _imageSettings();
  }

  // ------------------------------------------------------------------ Paniers en attente

  /// Met le panier courant en attente (conservé) et ouvre un panier vide.
  Future<Map<String, dynamic>> _suspend({String? label}) async {
    if (_draft.lines.isEmpty) throw const AdapterFailure('panier_vide', 'Le panier est vide : rien à mettre en attente.');
    final before = _draft.copy();
    final snapshot = engine.snapshot;
    final lines = snapshot == null ? const <CartLine?>[] : [for (final l in _draft.lines) l.materialize(snapshot, _tierOf(_draft))];
    // Sans caissier, avec un article disparu ou un prix saisi (que le panier partagé ne porte pas) : conservé sur ce
    // terminal seulement. Un panier repris avec un prix saisi est refusé par le moteur.
    final entered = _draft.lines.any((l) => l.entered != null);
    if (engine.sharedCartsSupported && _operator != null && lines.isNotEmpty && lines.every((l) => l != null) && (!entered || _draft.sharedCart != null)) {
      try {
        _draft.sharedCart = await engine.suspendShared(
          _operator!,
          lines.cast<CartLine>(),
          SaleExtras(wholesale: _draft.wholesale, globalDiscount: _draft.globalDiscount, delivery: _draft.delivery, note: _draft.note, customer: _draft.customer),
          previous: _draft.sharedCart,
          label: label,
        );
      } on OfflineRefusal catch (e) {
        throw AdapterFailure('panier_refuse', e.message);
      }
    }
    _draft
      ..suspended = true
      ..payments.clear();
    await _save(before);
    _draft = _Draft(_newUuid());
    _emit('panier');
    return _view();
  }

  /// Paniers en attente, le plus récent d'abord : résumé calculé par le moteur au catalogue courant.
  Future<Map<String, dynamic>> _drafts() async {
    final snapshot = engine.snapshot;
    final currency = snapshot?.store.currency == 'FCFA' || snapshot == null ? 'F' : snapshot.store.currency;
    final items = <Map<String, dynamic>>[];
    final linked = <String>{};
    for (final stored in await engine.openDrafts()) {
      if (stored.content['suspendu'] != true) continue;
      final draft = _Draft.fromStored(stored);
      if (draft.sharedCart != null) {
        if (await engine.sharedCartState(draft.sharedCart!.uuid) == 'disparu') {
          await engine.deleteDraft(draft.uuid);
          continue;
        }
        linked.add(draft.sharedCart!.uuid);
      }
      final lines = snapshot == null ? const <CartLine?>[] : [for (final l in draft.lines) l.materialize(snapshot, _tierOf(draft))];
      final valid = lines.whereType<CartLine>().toList();
      items.add({
        'draft_id': draft.uuid,
        'updated_at': stored.updatedAt.toUtc().toIso8601String(),
        'lines_count': draft.lines.length,
        'summary': [for (final l in valid.take(3)) l.label].join(', '),
        'total_label': snapshot == null ? '' : formatFcfa(_totalsOf(draft, snapshot)?.payable ?? 0, currency),
        'complete': snapshot != null && valid.length == draft.lines.length,
      });
    }
    return {
      'items': items,
      'shared': [
        for (final c in await engine.sharedCarts())
          if (!linked.contains(c.uuid)) {'shared_id': c.uuid, 'label': c.label, 'lines_count': c.linesCount, 'taken_elsewhere': c.takenElsewhere},
      ],
    };
  }

  Future<void> _releaseHeld() async {
    final held = _draft.sharedCart;
    if (held != null && held.claimed && _operator != null) await engine.releaseSharedCart(_operator!, held.uuid);
  }

  /// Reprise d'un panier publié : prix figés par le serveur, le panier courant est mis en attente à sa place.
  Future<Map<String, dynamic>> _resumeShared(String uuid) async {
    final operator = _operator;
    if (operator == null) throw const AdapterFailure('caissier_requis', 'Identifiez le caissier avant de reprendre un panier.');
    final TakenCart taken;
    try {
      taken = await engine.takeSharedCart(operator, uuid);
    } on OfflineRefusal catch (e) {
      throw AdapterFailure('panier_refuse', e.message);
    }
    if (_draft.lines.isNotEmpty) {
      await _suspend();
    } else {
      await engine.deleteDraft(_draft.uuid);
    }
    _draft = _Draft(_newUuid())
      ..sharedCart = taken.ref
      ..globalDiscount = taken.globalDiscount
      ..globalEntry = taken.globalDiscount == 0 ? null : DiscountEntry('montant', '${taken.globalDiscount}')
      ..delivery = taken.delivery
      ..note = taken.note
      ..customer = taken.customer
      ..wholesale = taken.wholesale;
    _draft.lines.addAll([
      for (final l in taken.lines)
        _DraftLine(id: _newUuid(), productId: l.product.id, packagingId: l.packaging?.id, quantity: l.quantity, discount: l.discount, price: l.fixedPrice),
    ]);
    await _save(_Draft(_newUuid()));
    _emit('panier');
    return _view();
  }

  Future<Map<String, dynamic>> _deleteShared(String uuid) async {
    final operator = _operator;
    if (operator == null) throw const AdapterFailure('caissier_requis', 'Identifiez le caissier avant de supprimer un panier.');
    if ((await engine.sharedCarts()).any((c) => c.uuid == uuid && c.takenElsewhere)) {
      throw const AdapterFailure('panier_refuse', 'Ce panier est repris sur une autre caisse.');
    }
    await engine.deleteSharedCart(operator, uuid);
    _emit('panier');
    return _view();
  }

  /// Reprend un panier en attente ; le panier courant, s'il n'est pas vide, est mis en attente à sa place. Les
  /// paiements préparés sont effacés (prix et droits peuvent avoir changé depuis).
  Future<Map<String, dynamic>> _resume(String draftId) async {
    final stored = (await engine.openDrafts()).where((d) => d.uuid == draftId && d.content['suspendu'] == true).firstOrNull;
    if (stored == null) throw const AdapterFailure('panier_inconnu', 'Panier en attente introuvable (repris, encaissé ou supprimé).');
    // Un panier déjà publié ne se reprend qu'avec l'accord du serveur ; publié ou non, il reste lié à ce panier.
    var ref = SharedCartRef.fromJson(stored.content['panier']);
    if (ref != null && await engine.sharedCartState(ref.uuid) == 'publie') {
      final operator = _operator;
      if (operator == null) throw const AdapterFailure('caissier_requis', 'Identifiez le caissier avant de reprendre un panier.');
      try {
        ref = (await engine.takeSharedCart(operator, ref.uuid)).ref;
      } on OfflineRefusal catch (e) {
        throw AdapterFailure('panier_refuse', e.message);
      }
    }
    if (_draft.lines.isNotEmpty) {
      await _suspend();
    } else {
      await engine.deleteDraft(_draft.uuid);
    }
    _draft = _Draft.fromStored(stored)
      ..suspended = false
      ..sharedCart = ref;
    _draft.payments.clear();
    await _save(_Draft(_newUuid()));
    _emit('panier');
    return _view();
  }

  Future<Map<String, dynamic>> _deleteDraft(String draftId) async {
    if (draftId != _draft.uuid && !(await engine.openDrafts()).any((d) => d.uuid == draftId && d.content['suspendu'] == true)) {
      throw const AdapterFailure('panier_inconnu', 'Panier en attente introuvable (repris, encaissé ou supprimé).');
    }
    final stored = (await engine.openDrafts()).where((d) => d.uuid == draftId).firstOrNull;
    final ref = SharedCartRef.fromJson(stored?.content['panier']);
    if (ref != null && _operator != null) await engine.deleteSharedCart(_operator!, ref.uuid);
    await engine.deleteDraft(draftId);
    if (draftId == _draft.uuid) _draft = _Draft(_newUuid());
    _emit('panier');
    return _view();
  }

  // ------------------------------------------------------------------ Paiement et encaissement

  Future<Map<String, dynamic>> _preparePayment() async {
    final snapshot = _snapshot();
    final operator = _operator;
    final lines = [for (final l in _draft.lines) l.materialize(snapshot, _tierOf(_draft))];
    if (lines.any((l) => l == null)) {
      throw const AdapterFailure('panier_invalide', 'Panier vide ou article retiré du catalogue : corrigez le panier.');
    }
    try {
      // Empty basket is also used to list payment methods for blind closure.
      if (lines.isNotEmpty) {
        if (operator == null) throw const AdapterFailure('caissier_requis', 'Identifiez le caissier avant d’encaisser.');
        engine.checkSaleRules(operator, lines.cast<CartLine>(), SaleExtras(
        wholesale: _draft.wholesale, globalDiscount: _draft.globalDiscount,
        globalEntry: _draft.globalEntry, delivery: _draft.delivery,
        note: _draft.note, customer: _draft.customer, sharedCart: _draft.sharedCart?.uuid,
      ));
      }
    } on OfflineRefusal catch (e) {
      throw AdapterFailure('vente_refusee', e.message);
    }
    final payable = _payable(snapshot);
    final same = await engine.sameAsPreviousSale(lines.cast<CartLine>());
    return {
      'cash_due': engine.cashDue(payable),
      'previous_basket_warning': same ? CaisseEngine.sameBasketWarning : null,
      'payable': payable,
      'payable_label': formatFcfa(payable),
      'methods': [for (final m in snapshot.methods) {'code': m.code, 'name': m.name, 'cash': m.isCash, 'reference': m.referenceMode}],
    };
  }

  /// Remplace les paiements préparés ([entries] : method, amount, received pour les espèces, reference pour un moyen
  /// déclaré). Une édition invalide EFFACE les paiements préparés (jamais de retour silencieux à un ancien paiement
  /// valide) puis est refusée : la validation reste impossible jusqu'à une saisie correcte.
  Future<Map<String, dynamic>> _setPayments(List<Map<String, dynamic>> entries) async {
    final snapshot = _snapshot();
    final payable = _payable(snapshot);
    final payments = <_DraftPayment>[];
    String? error;
    for (final e in entries) {
      final method = snapshot.methods.where((m) => m.code == e['method']).firstOrNull;
      final amount = e['amount'] ?? (entries.length == 1 ? payable : null);
      final received = e['received'];
      final reference = e['reference'];
      if (method == null) {
        error = 'Moyen de paiement non autorisé sur ce terminal.';
        break;
      }
      if (amount is! int || (received != null && received is! int) || (reference != null && reference is! String)) {
        error = 'Paiement mal formé (montant et reçu en francs entiers).';
        break;
      }
      final text = (reference as String?)?.trim() ?? '';
      payments.add(
        _DraftPayment(
          methodCode: method.code,
          amount: amount,
          received: method.isCash ? (received as int? ?? engine.cashDue(amount)) : null,
          reference: method.isCash || method.referenceMode == 'aucune' || text.isEmpty ? null : text,
        ),
      );
    }
    error ??= _paymentsError(snapshot, payments, payable);
    final before = _draft.copy();
    _draft.passes.clear();
    _draft.payments
      ..clear()
      ..addAll(error == null ? payments : const []);
    await _save(before);
    _emit('paiement');
    if (error != null) throw AdapterFailure('paiement_invalide', error);
    final cash = payments.where((p) => p.received != null).firstOrNull;
    return {...await _view(), 'change': cash == null ? 0 : cash.received! - engine.cashDue(cash.amount)};
  }

  String? _paymentsError(Snapshot snapshot, List<_DraftPayment> payments, int payable) {
    if (payments.isEmpty) return 'Ajoutez au moins un paiement.';
    if (payments.length > 10) return 'Au plus 10 paiements par vente.';
    if (payments.where((p) => p.received != null).length > 1) return 'Une seule ligne d’espèces par vente.';
    var paid = 0;
    for (final p in payments) {
      if (!snapshot.methods.any((m) => m.code == p.methodCode)) return 'Moyen de paiement non autorisé sur ce terminal.';
      if (p.amount <= 0) return 'Chaque paiement doit être positif.';
      if (p.received != null && p.received! < engine.cashDue(p.amount)) return 'Le montant reçu est inférieur au montant à régler.';
      if ((p.reference?.length ?? 0) > 100) return 'Référence de paiement trop longue (100 caractères au plus).';
      final method = snapshot.methods.firstWhere((m) => m.code == p.methodCode);
      if (method.referenceMode == 'obligatoire' && p.reference == null) return 'Référence obligatoire pour « ${method.name} ».';
      paid += p.amount;
    }
    // Trop-perçu sur un moyen électronique (rendu ou avance) : en ligne seulement (décision A, 2.1).
    if (paid > payable && payments.any((p) => p.received == null)) return 'Trop-perçu électronique : en ligne seulement. Saisissez le montant exact.';
    if (paid != payable) return 'La somme des paiements (${formatFcfa(paid)}) doit égaler le montant à payer (${formatFcfa(payable)}).';
    return null;
  }

  /// Encaissement idempotent par [operationId] : rejoué (réponse perdue, hôte redémarré), il rend la même vente.
  Future<Map<String, dynamic>> _commit(String operationId, Map<String, dynamic> args) async {
    final already = await engine.saleStatus(operationId);
    if (already != null) {
      await _clearConsumedDraft();
      return _committed(already);
    }
    final snapshot = _snapshot();
    final operator = _operator;
    if (operator == null) throw const AdapterFailure('caissier_requis', 'Identifiez le caissier avant d’encaisser.');
    final lines = [for (final l in _draft.lines) l.materialize(snapshot, _tierOf(_draft))];
    if (lines.isEmpty || lines.any((l) => l == null)) {
      throw const AdapterFailure('panier_invalide', 'Panier vide ou article retiré du catalogue : corrigez le panier.');
    }
    final payments = _draft.payments;
    final byPass = _draft.passes.isNotEmpty;
    if (payments.isEmpty && !byPass) throw const AdapterFailure('paiement_requis', 'Préparez le paiement avant d’encaisser.');
    final error = byPass ? null : _paymentsError(snapshot, payments, _payable(snapshot));
    if (error != null) throw AdapterFailure('paiement_invalide', error);
    final approval = await _approval(lines.cast<CartLine>(), operator, args);
    final OfflineOperation sale;
    try {
      sale = await engine.recordSale(
        lines.cast<CartLine>(),
        [
          for (final p in byPass ? const <_DraftPayment>[] : payments)
            CartPayment(
              method: snapshot.methods.firstWhere((m) => m.code == p.methodCode),
              amount: p.amount,
              received: p.received,
              reference: p.reference,
              cashDue: p.received == null ? null : engine.cashDue(p.amount),
            ),
        ],
        operator,
        draftUuid: _draft.uuid,
        operationUuid: operationId,
        extras: _extras(approval: approval, passes: _draft.passes),
      );
    } on OfflineRefusal catch (e) {
      // Refus d'une règle, levé avant toute écriture : la vente n'existe pas, le panier reste.
      throw AdapterFailure('vente_refusee', e.message);
    }
    _draft = _Draft(_newUuid());
    _emit('vente');
    return _committed(sale);
  }

  SaleExtras _extras({SaleApproval? approval, List<PassCheck> passes = const []}) => SaleExtras(
    wholesale: _draft.wholesale,
    globalDiscount: _draft.globalDiscount,
    globalEntry: _draft.globalEntry,
    delivery: _draft.delivery,
    note: _draft.note,
    approval: approval,
    customer: _draft.customer,
    sharedCart: _draft.sharedCart?.uuid,
    passes: passes,
  );

  /// Pass scanné ou saisi : vérifié par le moteur (en ligne, sinon hors connexion si l'événement l'autorise), puis
  /// retenu pour payer la vente. Les paiements préparés sont retirés : un pass ne se combine à aucun autre moyen.
  Future<Map<String, dynamic>> _verifyPass(String code) async {
    final operator = _operator;
    if (operator == null) throw const AdapterFailure('caissier_requis', 'Identifiez le caissier.');
    final snapshot = _snapshot();
    final lines = [for (final l in _draft.lines) l.materialize(snapshot, _tierOf(_draft))];
    if (lines.any((l) => l == null)) throw const AdapterFailure('panier_invalide', 'Article retiré du catalogue : corrigez le panier.');
    final PassCheck check;
    try {
      check = await engine.verifyPass(operator, code, lines.cast<CartLine>(), _extras(), already: _draft.passes);
    } on OfflineRefusal catch (e) {
      throw AdapterFailure('pass_refuse', e.message);
    }
    final before = _draft.copy();
    _draft.payments.clear();
    _draft.passes.add(check);
    await _save(before);
    _emit('paiement');
    return {...await _view(), 'pass': _passJson(check, snapshot.store.currency)};
  }

  Future<Map<String, dynamic>> _removePass(String passUuid) async {
    _draft.passes.removeWhere((p) => p.passUuid == passUuid);
    _emit('paiement');
    return _view();
  }

  Map<String, dynamic> _passJson(PassCheck p, String currency) => {
    'pass_uuid': p.passUuid,
    'holder': p.holder,
    'left_today': p.leftToday,
    'left_total': p.leftTotal,
    'online': p.online,
    'amount_label': formatFcfa(p.amount, currency),
  };

  Map<String, dynamic> _customerJson(Customer c) => {'uuid': c.uuid, 'name': c.name, 'phone': c.phone, 'pending': c.pending};

  Future<Map<String, dynamic>> _createCustomer(Map<String, dynamic> args, String? operationId) async {
    final operator = _operator;
    if (operator == null) throw const AdapterFailure('caissier_requis', 'Identifiez le caissier.');
    try {
      final phone = args['phone'] == null ? null : _text(args, 'phone', max: 40);
      return _customerJson(await engine.createCustomer(operator, name: _text(args, 'name', max: 160), phone: phone, operationUuid: operationId));
    } on OfflineRefusal catch (e) {
      throw AdapterFailure('client_refuse', e.message);
    }
  }

  Future<Map<String, dynamic>> _setCustomer(Map<String, dynamic> args) async {
    final uuid = args['uuid'] == null ? null : _text(args, 'uuid', max: 36);
    final customer = uuid == null ? null : Customer(uuid: uuid, name: _text(args, 'name', max: 160), phone: args['phone'] as String?);
    return _mutate(() {
      _draft.customer = customer;
    });
  }

  /// Autorisation d'un responsable si les remises dépassent le seuil du caissier, sinon null.
  Future<SaleApproval?> _approval(List<CartLine> lines, Operator operator, Map<String, dynamic> args) async {
    if (engine.withinDiscountLimits(operator, lines, _draft.globalDiscount)) return null;
    final raw = args['approval'];
    if (raw is! Map) throw const AdapterFailure('autorisation_requise', 'Remise au-delà du seuil du caissier : autorisation d’un responsable requise.');
    final fields = raw.cast<String, dynamic>();
    final approver = engine.approversFor(operator, lines, _draft.globalDiscount).where((o) => '${o.id}' == '${fields['approver_id']}').firstOrNull;
    if (approver == null) throw const AdapterFailure('autorisation_refusee', 'Ce responsable ne peut pas autoriser cette remise.');
    try {
      return await engine.authorizeDiscount(
        cashier: operator,
        approver: approver,
        code: _text(fields, 'code', max: 8),
        reason: _text(fields, 'reason', max: 500),
        lines: lines,
        globalDiscount: _draft.globalDiscount,
      );
    } on OfflineRefusal catch (e) {
      throw AdapterFailure('autorisation_refusee', e.message);
    }
  }

  Future<void> _clearConsumedDraft() async {
    // Every edited basket is saved. A confirmed sale whose basket is no longer
    // open must not leave that consumed basket on screen after reconciliation.
    if (_draft.lines.isNotEmpty && !(await engine.openDrafts()).any((d) => d.uuid == _draft.uuid)) {
      _draft = _Draft(_newUuid());
      _emit('vente');
    }
  }

  Map<String, dynamic> _committed(OfflineOperation sale) => {
    'state': 'committed',
    'operation_id': sale.uuid,
    'number': sale.number,
    'total': sale.total,
    'server_status': sale.serverStatus,
  };

  /// État LOCAL d'une vente, jamais par le réseau ni par un nouvel envoi. Placé derrière tout encaissement en cours :
  /// `not_found` est donc définitif (`definitive: true`) et le panier peut être de nouveau encaissé.
  Future<Map<String, dynamic>> _saleStatus(String operationId) async {
    final sale = await engine.saleStatus(operationId);
    if (sale == null) return {'state': 'not_found', 'operation_id': operationId, 'definitive': true};
    await _clearConsumedDraft();
    return _committed(sale);
  }

  // ------------------------------------------------------------------ Historique, ticket, synchronisation

  Future<Map<String, dynamic>> _history(Map<String, dynamic> args) async {
    final limit = (args['limit'] is int ? args['limit'] as int : 50).clamp(1, 200);
    final all = await engine.history();
    final recent = all.reversed.where((o) => o.isSale).take(limit);
    return {
      'items': [
        for (final o in recent)
          {
            'operation_id': o.uuid,
            'number': o.number,
            'date': o.date.toUtc().toIso8601String(),
            'total_label': formatFcfa(o.total),
            'status': o.status,
            'server_status': o.serverStatus,
            'server_number': o.serverNumber,
            'replaces': o.content['remplace'],
            'edit_reason': await engine.saleEditCheck(_operator, o),
          },
      ],
    };
  }

  /// Première impression sans mention, « REIMPRESSION » ensuite (comme le web, §5.3) ; retenue par vente sur le terminal.
  Future<Map<String, dynamic>> _printTicket(String operationId) async {
    final key = 'ticket_imprime.$operationId';
    final ticket = await _ticket(operationId, duplicate: await engine.store.read(key) != null);
    await engine.store.write(key, '1');
    return ticket;
  }

  Future<Map<String, dynamic>> _ticket(String operationId, {required bool duplicate}) async {
    final sale = await engine.saleStatus(operationId);
    if (sale == null || !sale.isSale) throw const AdapterFailure('vente_inconnue', 'Vente introuvable sur ce terminal.');
    final snapshot = _snapshot();
    final (lines, payments) = engine.ticketParts(sale);
    final operatorName = snapshot.operatorById(sale.operatorId)?.name ?? 'Caissier ${sale.operatorId}';
    final model = await engine.ticketModelOf(sale);
    return {
      'operation_id': sale.uuid,
      'duplicate': duplicate,
      'compact': model?.compact ?? false,
      'lines': offlineTicketLines(
        snapshot: snapshot,
        operation: sale,
        lines: lines,
        payments: payments,
        operatorName: operatorName,
        paperWidth: paperWidth,
        duplicate: duplicate,
        model: model,
      ),
    };
  }

  Future<void>? _syncTask;

  /// Planifie une synchronisation (une seule à la fois) ; l'hôte l'appelle aussi périodiquement.
  void scheduleSynchronization() {
    _syncTask ??= _synchronize().whenComplete(() => _syncTask = null);
  }

  /// Planifiée, jamais attendue par la commande : le réseau ne bloque pas la file des commandes locales.
  Future<void> _synchronize() async {
    if (_syncing) return;
    _syncing = true;
    try {
      if (await engine.probe()) {
        await engine.sync();
        if (engine.snapshotStale) await engine.refreshSnapshot();
        // Images : hors vente seulement, pour ne jamais ralentir un encaissement.
        if (_draft.lines.isEmpty) await engine.downloadImages(interrupted: () => _draft.lines.isNotEmpty);
      }
    } catch (_) {
      // Panne réseau ou serveur : la file reste en place, l'état est relu par la vue.
    } finally {
      _syncing = false;
      _emit('synchronisation');
    }
  }

  // ------------------------------------------------------------------ Outils

  Snapshot _snapshot() {
    final snapshot = engine.snapshot;
    if (snapshot == null) throw const AdapterFailure('catalogue_absent', 'Aucun catalogue reçu : connectez le terminal une première fois.');
    return snapshot;
  }

  int _payable(Snapshot snapshot) {
    final totals = _totalsOf(_draft, snapshot);
    if (totals == null) throw const AdapterFailure('remise_refusee', 'La remise globale dépasse le montant du panier.');
    return totals.payable;
  }

  static String _requireOperationId(String? id) {
    if (id == null || !RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$').hasMatch(id)) {
      throw const AdapterFailure('identifiant_requis', 'Identifiant de vente (UUID en minuscules) requis.');
    }
    return id;
  }

  static String _text(Map<String, dynamic> args, String key, {required int max}) {
    final value = args[key];
    if (value is! String || value.length > max) throw AdapterFailure('argument_invalide', 'Argument « $key » invalide.');
    return value;
  }

  /// Filtre facultatif du catalogue : absent ou vide = aucun.
  static String? _filter(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value != null && (value is! String || value.length > 120)) throw AdapterFailure('argument_invalide', 'Argument « $key » invalide.');
    return value == null || (value as String).isEmpty ? null : value;
  }

  static int _int(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value is! int) throw AdapterFailure('argument_invalide', 'Argument « $key » invalide.');
    return value;
  }
}

/// Panier en cours, tel que conservé sur le terminal.
class _Draft {
  _Draft(this.uuid);

  _Draft.fromStored(StoredDraft stored) : uuid = stored.uuid, revision = stored.revision {
    for (final raw in (stored.content['lignes'] as List? ?? const [])) {
      final m = Map<String, dynamic>.from(raw as Map);
      lines.add(
        _DraftLine(
          id: m['id'] as String,
          productId: (m['produit_id'] as num).toInt(),
          packagingId: (m['conditionnement_id'] as num?)?.toInt(),
          lotUuid: m['lot_uuid'] as String?,
          quantity: parseMicros('${m['quantite']}') ?? BigInt.zero,
          discount: (m['remise'] as num?)?.toInt() ?? 0,
          entry: m['remise_saisie'] is Map ? DiscountEntry.fromJson(m['remise_saisie'] as Map) : null,
          price: (m['prix_fige'] as num?)?.toInt(),
          entered: (m['prix_saisi'] as num?)?.toInt(),
        ),
      );
    }
    globalDiscount = (stored.content['remise_globale'] as num?)?.toInt() ?? 0;
    final global = stored.content['remise_globale_saisie'];
    globalEntry = global is Map ? DiscountEntry.fromJson(global) : null;
    delivery = (stored.content['livraison'] as num?)?.toInt() ?? 0;
    note = stored.content['note'] as String?;
    wholesale = stored.content['tarif_gros'] == true;
    customer = customerFromDraft(stored.content['client']);
    sharedCart = SharedCartRef.fromJson(stored.content['panier']);
    // `paiement` : panier conservé avant les paiements multiples.
    final raw = stored.content['paiements'] ?? [if (stored.content['paiement'] != null) stored.content['paiement']];
    for (final p in (raw as List).cast<Map>()) {
      payments.add(
        _DraftPayment(
          methodCode: p['moyen'] as String,
          amount: (p['montant'] as num).toInt(),
          received: (p['recu'] as num?)?.toInt(),
          reference: p['reference'] as String?,
        ),
      );
    }
    suspended = stored.content['suspendu'] == true;
    edit = stored.content['modification'] is Map ? Map<String, dynamic>.from(stored.content['modification'] as Map) : null;
  }

  /// Modification d'un ticket en cours (2.1 lot 11) : `vente_id`, `numero`, `total_origine`.
  Map<String, dynamic>? edit;

  final String uuid;
  int revision = 0;
  final List<_DraftLine> lines = [];
  final List<_DraftPayment> payments = [];

  /// Passes vérifiés pour payer la vente (jamais conservés avec le panier : un panier repris se rescanne).
  final List<PassCheck> passes = [];

  /// Panier en attente (suspendu) : conservé, hors du panier courant.
  bool suspended = false;

  /// Contrat 2.1 : remise globale (montant et saisie), livraison, note.
  int globalDiscount = 0;
  DiscountEntry? globalEntry;
  int delivery = 0;
  String? note;
  Customer? customer;
  SharedCartRef? sharedCart;

  /// Panier entier au tarif gros.
  bool wholesale = false;

  _Draft copy() => _Draft(uuid)
    ..revision = revision
    ..lines.addAll([
      for (final l in lines)
        _DraftLine(id: l.id, productId: l.productId, packagingId: l.packagingId, lotUuid: l.lotUuid, quantity: l.quantity, discount: l.discount, entry: l.entry, price: l.price, entered: l.entered),
    ])
    ..payments.addAll(payments)
    ..passes.addAll(passes)
    ..suspended = suspended
    ..globalDiscount = globalDiscount
    ..globalEntry = globalEntry
    ..delivery = delivery
    ..note = note
    ..customer = customer
    ..sharedCart = sharedCart
    ..wholesale = wholesale
    ..edit = edit;

  Map<String, dynamic> toJson() => {
    'lignes': [
      for (final l in lines)
        {
          'id': l.id,
          'produit_id': l.productId,
          'conditionnement_id': l.packagingId,
          if (l.lotUuid != null) 'lot_uuid': l.lotUuid,
          'quantite': formatMicros(l.quantity),
          'remise': l.discount,
          if (l.entry != null) 'remise_saisie': l.entry!.toJson(),
          if (l.price != null) 'prix_fige': l.price,
          if (l.entered != null) 'prix_saisi': l.entered,
        },
    ],
    if (globalDiscount != 0) 'remise_globale': globalDiscount,
    if (globalEntry != null) 'remise_globale_saisie': globalEntry!.toJson(),
    if (delivery != 0) 'livraison': delivery,
    if (note != null) 'note': note,
    if (wholesale) 'tarif_gros': true,
    if (customer != null) 'client': {'uuid': customer!.uuid, 'nom': customer!.name},
    if (sharedCart != null) 'panier': sharedCart!.toJson(),
    'paiements': [
      for (final p in payments) {'moyen': p.methodCode, 'montant': p.amount, 'recu': p.received, 'reference': p.reference},
    ],
    if (suspended) 'suspendu': true,
    if (edit != null) 'modification': edit,
  };
}

class _DraftLine {
  _DraftLine({required this.id, required this.productId, required this.packagingId, required this.quantity, this.discount = 0, this.entry, this.price, this.lotUuid, this.entered});

  /// Prix unitaire saisi par le caissier (2.1 lot 9) ; null = prix habituel.
  int? entered;

  /// Lot choisi ; null = choix automatique selon la règle de la boutique.
  String? lotUuid;

  /// Prix figé d'un panier partagé ; null = prix du catalogue.
  final int? price;

  /// Saisie de la remise (montant ou pourcentage) ; un pourcentage est recalculé à chaque changement du panier.
  DiscountEntry? entry;

  final String id;
  final int productId;
  final int? packagingId;
  BigInt quantity;

  /// Remise de ligne en francs.
  int discount;

  /// Ligne de vente au prix du catalogue courant, ou null si le produit (ou son conditionnement) a disparu.
  CartLine? materialize(Snapshot snapshot, CartTier tier) {
    final product = snapshot.byId(productId);
    if (product == null) return null;
    final packaging = packagingId == null ? null : product.packaging(packagingId);
    if (packagingId != null && packaging == null) return null;
    final lot = product.lots.where((l) => l.uuid == lotUuid).firstOrNull;
    return CartLine(product: product, packaging: packaging, quantity: quantity, discount: discount, discountEntry: entry, fixedPrice: price, lot: lot, tier: tier, enteredPrice: entered);
  }
}

class _DraftPayment {
  const _DraftPayment({required this.methodCode, required this.amount, this.received, this.reference});

  final String methodCode;
  final int amount;

  /// Espèces seulement : somme remise par le client.
  final int? received;
  final String? reference;
}
