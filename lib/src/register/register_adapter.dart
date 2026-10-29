import 'dart:async';

import 'package:uuid/uuid.dart';

import '../offline/engine.dart';
import '../offline/models.dart';
import '../offline/money.dart';
import '../offline/ticket.dart';

/// Version de l'interface de commandes du moteur (C-REQ-001). Toute rupture incrémente ce numéro.
const registerAdapterVersion = 1;

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
/// Commandes (`execute`) : status, pair, login, view, search, addProduct, scan, changeQuantity, removeLine, clear,
/// preparePayment, setPayment, commitSale, saleStatus, history, reprint, synchronize.
class LocalRegisterAdapter {
  LocalRegisterAdapter(this.engine, {this.paperWidth = 80, String Function()? newUuid}) : _newUuid = newUuid ?? (() => const Uuid().v4());

  final OfflineEngine engine;
  final int paperWidth;
  final String Function() _newUuid;
  final StreamController<Map<String, dynamic>> _changes = StreamController.broadcast();

  /// Après chaque écriture durable (panier, vente, synchronisation) : l'écran relit la vue.
  Stream<Map<String, dynamic>> get committedChanges => _changes.stream;

  Operator? _operator;
  late _Draft _draft;
  String _query = '';
  int _revision = 0;
  bool _started = false;
  bool _syncing = false;
  Future<void> _queue = Future.value();

  /// Restaure le panier conservé le plus récent (les autres restent conservés, rien n'est effacé).
  Future<void> start() async {
    if (_started) return;
    final drafts = await engine.openDrafts();
    _draft = drafts.isEmpty ? _Draft(_newUuid()) : _Draft.fromStored(drafts.first);
    engine.addListener(_engineChanged);
    _started = true;
  }

  Future<void> close() async {
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
      case 'view':
        return _view();
      case 'search':
        _query = _text(args, 'query', max: 100);
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
        return _mutate(() => _draft.lines.removeWhere((l) => l.id == id));
      case 'clear':
        await engine.deleteDraft(_draft.uuid);
        _draft = _Draft(_newUuid());
        _emit('panier');
        return _view();
      case 'preparePayment':
        return _preparePayment();
      case 'setPayment':
        return _setPayment(args);
      case 'commitSale':
        return _commit(_requireOperationId(operationId));
      case 'saleStatus':
        return _saleStatus(_requireOperationId(operationId));
      case 'history':
        return _history(args);
      case 'reprint':
        return _reprint(_requireOperationId(operationId));
      case 'synchronize':
        unawaited(_synchronize());
        return {'scheduled': true};
      default:
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
  };

  Future<Map<String, dynamic>> _view() async {
    final snapshot = engine.snapshot;
    final reason = engine.blockReason;
    final sold = snapshot == null ? const <int, BigInt>{} : await engine.soldSinceSnapshot();
    final resolved = snapshot == null ? const <(_DraftLine, CartLine?)>[] : [for (final l in _draft.lines) (l, l.materialize(snapshot))];
    final available = [for (final r in resolved) if (r.$2 != null) r.$2!];
    final totals = snapshot == null ? null : saleTotals([for (final l in available) l.total], snapshot.store.vatRate, snapshot.store.vatIncluded);
    final currency = snapshot?.store.currency == 'FCFA' || snapshot == null ? 'F' : snapshot.store.currency;
    final payment = _draft.payment;
    final paymentValid = totals != null && payment != null && _paymentError(payment, totals.payable) == null;
    final ready = snapshot != null && reason == null;
    return {
      'schema': 1,
      'revision': _revision,
      'ready': ready,
      'block_reason': reason,
      'can_pay': ready && _operator != null && engine.sessionOpen && available.isNotEmpty && available.length == resolved.length,
      'draft_id': _draft.uuid,
      'store_name': snapshot?.store.name ?? '',
      'sync_label': _syncLabel(),
      'total_label': totals == null ? '' : formatFcfa(totals.payable, currency),
      'payment_label': payment == null ? '' : '${payment.methodCode} ${formatFcfa(payment.amount, currency)}',
      'payment_valid': paymentValid,
      'query': _query,
      'products': [
        if (snapshot != null)
          for (final p in snapshot.search(_query, limit: 60))
            {
              'id': p.id,
              'name': p.name,
              'price_label': formatFcfa(p.price, currency),
              'stock_label': p.unlimitedStock ? '' : _stockLabel(p, sold[p.id] ?? BigInt.zero),
              'packagings': [for (final k in p.packagings) {'id': k.id, 'name': k.name, 'price_label': formatFcfa(k.price, currency)}],
            },
      ],
      'lines': [
        for (final (line, cart) in resolved)
          {
            'id': line.id,
            'name': cart?.label ?? 'Article n° ${line.productId} (retiré du catalogue)',
            'quantity_label': formatMicros(line.quantity),
            'total_label': cart == null ? '' : formatFcfa(cart.total, currency),
            'available': cart != null,
          },
      ],
    };
  }

  String _stockLabel(Product p, BigInt sold) {
    final central = p.negativeStock ? -p.stockMicros : p.stockMicros;
    final estimated = central - sold;
    return estimated.isNegative ? '-${formatMicros(-estimated)}' : formatMicros(estimated);
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
      final locked = await engine.pinLockedFor(operator);
      if (locked != null) throw AdapterFailure('pin_bloque', 'PIN bloqué : réessayez dans ${locked.inSeconds} s.');
      if (!await engine.checkPin(operator, _text(args, 'pin', max: 6))) throw const AdapterFailure('pin_refuse', 'PIN incorrect.');
    }
    _operator = operator;
    _emit('caissier');
    return _status();
  }

  // ------------------------------------------------------------------ Panier (conservé à chaque modification)

  Future<Map<String, dynamic>> _add(int productId, int? packagingId) async {
    final product = _snapshot().products.where((p) => p.id == productId).firstOrNull;
    if (product == null) throw const AdapterFailure('produit_inconnu', 'Produit absent du catalogue du terminal.');
    if (packagingId != null && product.packaging(packagingId) == null) {
      throw const AdapterFailure('conditionnement_inconnu', 'Conditionnement inconnu pour ce produit.');
    }
    return _mutate(() {
      final existing = _draft.lines.where((l) => l.productId == productId && l.packagingId == packagingId).firstOrNull;
      if (existing != null) {
        existing.quantity += BigInt.from(1000000);
      } else {
        _draft.lines.add(_DraftLine(id: _newUuid(), productId: productId, packagingId: packagingId, quantity: BigInt.from(1000000)));
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

  Future<Map<String, dynamic>> _mutate(void Function() change) async {
    final before = _draft.copy();
    change();
    _draft.payment = null; // tout changement du panier invalide le paiement préparé
    _draft.revision++;
    if (!await engine.saveDraft(_draft.uuid, _draft.revision, _draft.toJson())) {
      _draft = before;
      throw const AdapterFailure('panier_perime', 'Ce panier a changé ou a déjà été encaissé : vue rechargée.');
    }
    _emit('panier');
    return _view();
  }

  // ------------------------------------------------------------------ Paiement et encaissement

  Future<Map<String, dynamic>> _preparePayment() async {
    final snapshot = _snapshot();
    final payable = _payable(snapshot);
    return {
      'payable': payable,
      'payable_label': formatFcfa(payable),
      'methods': [for (final m in snapshot.methods) {'code': m.code, 'name': m.name, 'cash': m.isCash}],
    };
  }

  Future<Map<String, dynamic>> _setPayment(Map<String, dynamic> args) async {
    final snapshot = _snapshot();
    final method = snapshot.methods.where((m) => m.code == args['method']).firstOrNull;
    if (method == null) throw const AdapterFailure('moyen_refuse', 'Moyen de paiement non autorisé sur ce terminal.');
    final payable = _payable(snapshot);
    final payment = _DraftPayment(
      methodCode: method.code,
      amount: args['amount'] is int ? args['amount'] as int : payable,
      received: method.isCash && args['received'] is int ? args['received'] as int : null,
    );
    final error = _paymentError(payment, payable);
    if (error != null) throw AdapterFailure('paiement_invalide', error);
    _draft
      ..payment = payment
      ..revision += 1;
    await engine.saveDraft(_draft.uuid, _draft.revision, _draft.toJson());
    _emit('paiement');
    return {...await _view(), 'change': payment.received == null ? 0 : payment.received! - payment.amount};
  }

  String? _paymentError(_DraftPayment payment, int payable) {
    if (payment.amount != payable) return 'Le paiement doit égaler le montant à payer (${formatFcfa(payable)}).';
    if (payment.received != null && payment.received! < payment.amount) return 'Le montant reçu est inférieur au montant à régler.';
    return null;
  }

  /// Encaissement idempotent par [operationId] : rejoué (réponse perdue, hôte redémarré), il rend la même vente.
  Future<Map<String, dynamic>> _commit(String operationId) async {
    final already = await engine.saleStatus(operationId);
    if (already != null) return _committed(already);
    final snapshot = _snapshot();
    final operator = _operator;
    if (operator == null) throw const AdapterFailure('caissier_requis', 'Identifiez le caissier avant d’encaisser.');
    final lines = [for (final l in _draft.lines) l.materialize(snapshot)];
    if (lines.isEmpty || lines.any((l) => l == null)) {
      throw const AdapterFailure('panier_invalide', 'Panier vide ou article retiré du catalogue : corrigez le panier.');
    }
    final payment = _draft.payment;
    if (payment == null) throw const AdapterFailure('paiement_requis', 'Préparez le paiement avant d’encaisser.');
    final method = snapshot.methods.firstWhere((m) => m.code == payment.methodCode, orElse: () => throw const AdapterFailure('moyen_refuse', 'Moyen de paiement retiré.'));
    final OfflineOperation sale;
    try {
      sale = await engine.recordSale(
        lines.cast<CartLine>(),
        [CartPayment(method: method, amount: payment.amount, received: payment.received)],
        operator,
        draftUuid: _draft.uuid,
        operationUuid: operationId,
      );
    } on OfflineRefusal catch (e) {
      // Refus d'une règle, levé avant toute écriture : la vente n'existe pas, le panier reste.
      throw AdapterFailure('vente_refusee', e.message);
    }
    _draft = _Draft(_newUuid());
    _emit('vente');
    return _committed(sale);
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
          },
      ],
    };
  }

  Future<Map<String, dynamic>> _reprint(String operationId) async {
    final sale = await engine.saleStatus(operationId);
    if (sale == null || !sale.isSale) throw const AdapterFailure('vente_inconnue', 'Vente introuvable sur ce terminal.');
    final snapshot = _snapshot();
    final (lines, payments) = engine.ticketParts(sale);
    final operatorName = snapshot.operatorById(sale.operatorId)?.name ?? 'Caissier ${sale.operatorId}';
    return {
      'operation_id': sale.uuid,
      'lines': offlineTicketLines(
        snapshot: snapshot,
        operation: sale,
        lines: lines,
        payments: payments,
        operatorName: operatorName,
        paperWidth: paperWidth,
        duplicate: true,
      ),
    };
  }

  /// Planifiée, jamais attendue par la commande : le réseau ne bloque pas la file des commandes locales.
  Future<void> _synchronize() async {
    if (_syncing) return;
    _syncing = true;
    try {
      if (await engine.probe()) {
        await engine.sync();
        if (engine.snapshotStale) await engine.refreshSnapshot();
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
    final lines = [for (final l in _draft.lines) l.materialize(snapshot)].whereType<CartLine>().toList();
    return saleTotals([for (final l in lines) l.total], snapshot.store.vatRate, snapshot.store.vatIncluded).payable;
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
          quantity: parseMicros('${m['quantite']}') ?? BigInt.zero,
        ),
      );
    }
    final p = stored.content['paiement'];
    if (p is Map) payment = _DraftPayment(methodCode: p['moyen'] as String, amount: (p['montant'] as num).toInt(), received: (p['recu'] as num?)?.toInt());
  }

  final String uuid;
  int revision = 0;
  final List<_DraftLine> lines = [];
  _DraftPayment? payment;

  _Draft copy() => _Draft(uuid)
    ..revision = revision
    ..lines.addAll([for (final l in lines) _DraftLine(id: l.id, productId: l.productId, packagingId: l.packagingId, quantity: l.quantity)])
    ..payment = payment;

  Map<String, dynamic> toJson() => {
    'lignes': [
      for (final l in lines) {'id': l.id, 'produit_id': l.productId, 'conditionnement_id': l.packagingId, 'quantite': formatMicros(l.quantity)},
    ],
    if (payment != null) 'paiement': {'moyen': payment!.methodCode, 'montant': payment!.amount, 'recu': payment!.received},
  };
}

class _DraftLine {
  _DraftLine({required this.id, required this.productId, required this.packagingId, required this.quantity});

  final String id;
  final int productId;
  final int? packagingId;
  BigInt quantity;

  /// Ligne de vente au prix du catalogue courant, ou null si le produit (ou son conditionnement) a disparu.
  CartLine? materialize(Snapshot snapshot) {
    final product = snapshot.products.where((p) => p.id == productId).firstOrNull;
    if (product == null) return null;
    final packaging = packagingId == null ? null : product.packaging(packagingId);
    if (packagingId != null && packaging == null) return null;
    return CartLine(product: product, packaging: packaging, quantity: quantity);
  }
}

class _DraftPayment {
  const _DraftPayment({required this.methodCode, required this.amount, this.received});

  final String methodCode;
  final int amount;
  final int? received;
}
