import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:bcrypt/bcrypt.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'api.dart';
import 'models.dart';
import 'money.dart';
import 'store.dart';

/// Vérifie un PIN contre l'empreinte bcrypt du serveur (Laravel écrit `$2y$`, équivalent de `$2a$`).
Future<bool> verifyPinHash(String pin, String hash) => compute(_checkPin, [pin, hash]);

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
  const SyncReport({this.sent = 0, this.integrated = 0, this.pending = 0, this.refused = 0, this.reachable = true, this.message});

  final int sent;
  final int integrated;

  /// Reçues mais à arbitrer côté boutique (conservées sur le serveur).
  final int pending;
  final int refused;
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

/// Caisse hors ligne de ce terminal (ADR-421) : appairage, référentiel, règles, file d'opérations et synchronisation.
///
/// Chaque terminal est autonome : son appairage, sa session de caisse, sa série de tickets (préfixe du terminal +
/// séquence) et sa file. Plusieurs terminaux d'une même boutique peuvent donc vendre hors ligne en même temps sans se
/// coordonner : le serveur intègre chaque vente telle qu'encaissée (stock négatif = anomalie à traiter, jamais un refus).
class OfflineEngine extends ChangeNotifier {
  OfflineEngine({
    required this.store,
    required this.transport,
    DateTime Function()? clock,
    String Function()? newUuid,
    Future<bool> Function(String pin, String hash)? pinVerifier,
  }) : _clock = clock ?? DateTime.now,
       _newUuid = newUuid ?? (() => const Uuid().v4()),
       _verifyPin = pinVerifier ?? verifyPinHash;

  final OfflineStore store;
  final RegisterTransport transport;
  final DateTime Function() _clock;
  final String Function() _newUuid;
  final Future<bool> Function(String pin, String hash) _verifyPin;

  String? apiBase;
  String? _token;
  String? webToken;
  String? deviceName;
  Snapshot? snapshot;
  DateTime? snapshotAt;
  DateTime? lastContact;
  DateTime? offlineSince;
  bool localSessionOpen = false;

  /// Dernier état connu du serveur : null = pas encore testé.
  bool? reachable;

  /// Ventes en attente pour une autre boutique que celle des réglages (voir [load]).
  bool shopMismatch = false;

  /// Dernier test : boutique injoignable (réseau), et non une réponse d'erreur du serveur.
  bool lastUnreachable = false;

  /// Application révoquée côté boutique (401) : il faut l'appairer de nouveau.
  bool revoked = false;
  int pendingCount = 0;
  int refusedCount = 0;
  int arbitrationCount = 0;
  bool _syncing = false;

  bool get paired => _token != null;
  bool get syncing => _syncing;
  DateTime get now => _clock();

  /// Adresse de l'API d'une boutique : `https://boutique.exemple.ci/api/caisse/v1`.
  static String apiBaseFor(String origin) => '$origin/api/caisse/v1';

  Future<void> load(String origin) async {
    final base = apiBaseFor(origin);
    final storedBase = await store.read(StoreKeys.apiBase);
    final queued = (await store.operations(status: OperationStatus.pending)).isNotEmpty;
    // Boutique changée dans les réglages alors que des ventes attendent : elles appartiennent à l'ancienne boutique et
    // partent vers elle (même jeton) ; la nouvelle adresse ne sera appairée qu'une fois la file vide.
    shopMismatch = storedBase != null && storedBase != base && queued;
    apiBase = shopMismatch ? storedBase : base;
    if (storedBase != null && storedBase != base && !queued) {
      // Boutique changée, file vide : l'ancien appairage ne vaut plus.
      await _forget();
    } else {
      _token = await store.read(StoreKeys.token);
      webToken = await store.read(StoreKeys.webToken);
      deviceName = await store.read(StoreKeys.deviceName);
      final raw = await store.read(StoreKeys.snapshot);
      if (raw != null) {
        try {
          final decoded = raw.length > 65536 ? await Isolate.run(() => jsonDecode(raw)) : jsonDecode(raw);
          snapshot = Snapshot(Map<String, dynamic>.from(decoded as Map));
        } catch (_) {
          snapshot = null;
        }
      }
      snapshotAt = DateTime.tryParse(await store.read(StoreKeys.snapshotAt) ?? '');
      lastContact = DateTime.tryParse(await store.read(StoreKeys.lastContact) ?? '');
      offlineSince = DateTime.tryParse(await store.read(StoreKeys.offlineSince) ?? '');
      localSessionOpen = await store.read(StoreKeys.localSession) == '1';
    }
    await _count();
    notifyListeners();
  }

  /// Échange d'un code d'appairage. Renvoie le message d'erreur, ou null en cas de succès.
  Future<String?> pair(String code, {required String model, required String appVersion}) async {
    final base = apiBase;
    if (base == null) return 'Adresse de la boutique absente.';
    if (shopMismatch) {
      return 'Des ventes hors ligne attendent encore l’ancienne boutique : reconnectez-la pour les envoyer avant d’appairer celle-ci.';
    }
    final response = await transport.pair(base, code.trim(), model, appVersion);
    if (!response.ok) return response.unreachable ? 'Boutique injoignable : l’appairage exige une connexion.' : response.message;
    _token = response.body['jeton'] as String?;
    webToken = response.body['cle_web'] as String?;
    final device = Map<String, dynamic>.from(response.body['appareil'] as Map? ?? const {});
    deviceName = '${device['nom'] ?? ''} — ${device['terminal'] ?? ''}';
    revoked = false;
    await store.write(StoreKeys.apiBase, base);
    await store.write(StoreKeys.token, _token);
    await store.write(StoreKeys.webToken, webToken);
    await store.write(StoreKeys.deviceName, deviceName);
    await _contact();
    final error = await refreshSnapshot();
    notifyListeners();
    return error;
  }

  /// Oublie l'appairage (la file reste sur le terminal, envoyée après un nouvel appairage au même terminal).
  Future<void> unpair() async {
    await _forget();
    notifyListeners();
  }

  Future<void> _forget() async {
    _token = null;
    webToken = null;
    deviceName = null;
    snapshot = null;
    snapshotAt = null;
    for (final key in [StoreKeys.token, StoreKeys.webToken, StoreKeys.deviceName, StoreKeys.snapshot, StoreKeys.snapshotAt]) {
      await store.write(key, null);
    }
    await store.write(StoreKeys.apiBase, apiBase);
  }

  /// Test de la boutique (`/etat`) : met à jour [reachable] et le dernier contact.
  Future<bool> probe() async {
    final base = apiBase;
    final token = _token;
    if (base == null || token == null) return false;
    final response = await transport.status(base, token);
    _handleAuth(response);
    final ok = response.ok;
    lastUnreachable = response.unreachable;
    if (ok) {
      await _contact();
      arbitrationCount = (response.body['operations_a_arbitrer'] as num?)?.toInt() ?? arbitrationCount;
    } else if (response.unreachable && offlineSince == null) {
      offlineSince = now;
      await store.write(StoreKeys.offlineSince, offlineSince!.toUtc().toIso8601String());
    }
    if (reachable != ok) {
      reachable = ok;
      notifyListeners();
    }
    return ok;
  }

  /// Télécharge le référentiel. Renvoie le message d'erreur, ou null.
  Future<String?> refreshSnapshot() async {
    final base = apiBase;
    final token = _token;
    if (base == null || token == null) return 'Application non appairée.';
    final response = await transport.snapshot(base, token);
    _handleAuth(response);
    if (!response.ok) return response.message;
    snapshot = Snapshot(response.body);
    snapshotAt = now;
    // Le serveur dit si une session est ouverte : une ouverture hors ligne déjà intégrée y figure.
    if (snapshot!.sessionOpen || pendingCount == 0) {
      localSessionOpen = false;
      await store.write(StoreKeys.localSession, null);
    }
    final body = response.body;
    await store.write(StoreKeys.snapshot, body.length > 200 ? await Isolate.run(() => jsonEncode(body)) : jsonEncode(body));
    await store.write(StoreKeys.snapshotAt, snapshotAt!.toUtc().toIso8601String());
    await _contact();
    notifyListeners();
    return null;
  }

  /// Le référentiel a-t-il dépassé l'intervalle de mise à jour réglé par la boutique ?
  bool get snapshotStale {
    final at = snapshotAt;
    final s = snapshot;
    if (at == null || s == null) return true;
    return now.difference(at) > Duration(minutes: s.rules.refreshMinutes);
  }

  /// Envoie la file (dans l'ordre de la séquence, par lots de 50).
  Future<SyncReport> sync() async {
    final base = apiBase;
    final token = _token;
    if (base == null || token == null || _syncing) return const SyncReport(reachable: false);
    _syncing = true;
    notifyListeners();
    var sent = 0, integrated = 0, pending = 0, refused = 0;
    try {
      while (true) {
        final batch = await store.operations(status: OperationStatus.pending, limit: 50);
        if (batch.isEmpty) break;
        final response = await transport.synchronize(base, token, [for (final o in batch) o.toPayload()]);
        _handleAuth(response);
        if (!response.ok) {
          return SyncReport(
            sent: sent,
            integrated: integrated,
            pending: pending,
            refused: refused,
            reachable: !response.unreachable,
            message: response.message,
          );
        }
        await _contact();
        final results = {for (final r in (response.body['resultats'] as List? ?? const [])) (r as Map)['uuid']: Map<String, dynamic>.from(r)};
        var progressed = false;
        for (final operation in batch) {
          final result = results[operation.uuid];
          if (result == null) continue;
          progressed = true;
          sent++;
          final status = result['statut'] as String?;
          operation
            ..serverStatus = status
            ..serverNumber = result['numero'] as String?
            ..message = result['message'] as String?
            ..status = status == 'refusee' ? OperationStatus.refused : OperationStatus.sent;
          if (status == 'integree') integrated++;
          if (status == 'a_arbitrer') pending++;
          if (status == 'refusee') refused++;
          await store.update(operation);
        }
        if (!progressed) break;
      }
      await store.purgeSent(const Duration(days: 30));
      return SyncReport(sent: sent, integrated: integrated, pending: pending, refused: refused);
    } finally {
      _syncing = false;
      await _count();
      if (pendingCount == 0) {
        offlineSince = null;
        await store.write(StoreKeys.offlineSince, null);
      }
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------- Règles de la vente hors ligne

  /// Session de caisse utilisable hors ligne : ouverte au dernier contact, ou ouverte sur ce terminal hors ligne.
  bool get sessionOpen => (snapshot?.sessionOpen ?? false) || localSessionOpen;

  /// Raison qui empêche de vendre hors ligne, ou null si la vente est possible.
  String? get blockReason {
    final s = snapshot;
    if (!paired) {
      return revoked
          ? 'Application révoquée par la boutique : appairez-la de nouveau (Réglages).'
          : 'Application non appairée à un terminal (Réglages › Caisse hors ligne).';
    }
    if (shopMismatch) return 'Ventes en attente pour l’ancienne boutique ($apiBase) : elles doivent être envoyées avant de vendre ici.';
    if (s == null) return 'Aucun catalogue reçu : connectez le terminal une première fois.';
    if (!s.available) {
      return s.reason == 'autorite_centrale'
          ? 'Boutique sous autorité centrale : la vente hors ligne n’y est pas disponible.'
          : 'La vente hors ligne est désactivée par la boutique.';
    }
    if (s.methods.isEmpty) return 'Aucun moyen de paiement autorisé hors ligne.';
    final contact = lastContact ?? snapshotAt;
    if (contact != null && now.difference(contact) > Duration(hours: s.rules.maxHours)) {
      return 'Durée hors ligne dépassée (${s.rules.maxHours} h depuis le dernier contact) : reconnectez le terminal.';
    }
    final licence = s.licenceExpiresAt;
    if (licence != null && now.isAfter(licence)) return 'Licence du terminal expirée.';
    if (pendingSales >= s.rules.maxSales) return 'Nombre maximal de ventes hors ligne atteint (${s.rules.maxSales}) : reconnectez le terminal.';
    return null;
  }

  int pendingSales = 0;

  /// Heures restantes avant l'arrêt de la vente hors ligne.
  Duration? get remaining {
    final s = snapshot;
    final contact = lastContact ?? snapshotAt;
    if (s == null || contact == null) return null;
    final left = Duration(hours: s.rules.maxHours) - now.difference(contact);
    return left.isNegative ? Duration.zero : left;
  }

  Future<bool> checkPin(Operator operator, String pin) async {
    final hash = operator.pinHash;
    if (hash == null || hash.isEmpty || !RegExp(r'^\d{4,6}$').hasMatch(pin)) return false;
    return _verifyPin(pin, hash);
  }

  /// Ouverture de session hors ligne (fond compté sur le terminal), rejouée par le serveur.
  Future<OfflineOperation> openSession(int float, Operator operator) async {
    final s = _requireSelling(allowWithoutSession: true);
    if (!s.rules.sessionOpening) throw const OfflineRefusal('L’ouverture de session hors ligne n’est pas autorisée : ouvrez-la en ligne.');
    if (sessionOpen) throw const OfflineRefusal('Une session est déjà ouverte sur ce terminal.');
    if (float < 0) throw const OfflineRefusal('Fond de caisse invalide.');
    final operation = await _append('ouverture_session', null, operator.id, {'fond': float});
    localSessionOpen = true;
    await store.write(StoreKeys.localSession, '1');
    notifyListeners();
    return operation;
  }

  /// Enregistre une vente hors ligne (avant l'impression du ticket). Lève [OfflineRefusal] si une règle s'y oppose.
  Future<OfflineOperation> recordSale(List<CartLine> lines, List<CartPayment> payments, Operator operator) async {
    final s = _requireSelling();
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
    final sequence = await _nextSequence();
    final number = '${s.terminal.ticketPrefix}-${sequence.toString().padLeft(6, '0')}';
    return _append('vente', number, operator.id, {
      'lignes': [for (final l in lines) l.toPayload()],
      'paiements': [for (final p in payments) p.toPayload()],
      'total': totals.payable,
    }, sequence: sequence);
  }

  /// Quantité vendue hors ligne d'un produit depuis le référentiel (pour un stock indicatif à jour).
  Future<Map<int, BigInt>> soldSinceSnapshot() async {
    final sold = <int, BigInt>{};
    final s = snapshot;
    if (s == null) return sold;
    for (final operation in await store.operations(status: OperationStatus.pending)) {
      if (!operation.isSale) continue;
      for (final line in (operation.content['lignes'] as List)) {
        final m = line as Map;
        final product = s.products.where((p) => p.id == m['produit_id']).firstOrNull;
        final coefficient = parseMicros(product?.packaging((m['conditionnement_id'] as num?)?.toInt())?.coefficient ?? '1') ?? BigInt.from(1000000);
        final quantity = parseMicros(m['quantite'] as String) ?? BigInt.zero;
        final id = (m['produit_id'] as num).toInt();
        sold[id] = (sold[id] ?? BigInt.zero) + quantity * coefficient ~/ BigInt.from(1000000);
      }
    }
    return sold;
  }

  Future<List<OfflineOperation>> history() => store.operations();

  Snapshot _requireSelling({bool allowWithoutSession = false}) {
    final reason = blockReason;
    if (reason != null) throw OfflineRefusal(reason);
    if (!allowWithoutSession && !sessionOpen) throw const OfflineRefusal('Aucune session de caisse ouverte sur ce terminal : ouvrez-la d’abord.');
    return snapshot!;
  }

  Future<int> _nextSequence() async {
    final stored = int.tryParse(await store.read(StoreKeys.lastSequence) ?? '') ?? 0;
    final fromServer = snapshot?.lastSequence ?? 0;
    return (stored > fromServer ? stored : fromServer) + 1;
  }

  Future<OfflineOperation> _append(String type, String? number, int operatorId, Map<String, dynamic> content, {int? sequence}) async {
    final operation = OfflineOperation(
      uuid: _newUuid(),
      sequence: sequence ?? await _nextSequence(),
      type: type,
      number: number,
      date: now,
      operatorId: operatorId,
      content: content,
    );
    await store.append(operation);
    if (offlineSince == null) {
      offlineSince = now;
      await store.write(StoreKeys.offlineSince, offlineSince!.toUtc().toIso8601String());
    }
    await _count();
    notifyListeners();
    return operation;
  }

  Future<void> _count() async {
    final pending = await store.operations(status: OperationStatus.pending);
    pendingCount = pending.length;
    pendingSales = pending.where((o) => o.isSale).length;
    refusedCount = (await store.operations(status: OperationStatus.refused)).length;
  }

  Future<void> _contact() async {
    lastContact = now;
    await store.write(StoreKeys.lastContact, lastContact!.toUtc().toIso8601String());
  }

  void _handleAuth(ApiResponse response) {
    if (response.unauthorized) {
      revoked = true;
      _token = null;
      store.write(StoreKeys.token, null);
    }
  }
}
