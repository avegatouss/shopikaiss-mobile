import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../ipc/protocol.dart';
import '../platform/sale_intent.dart';

/// Presentation only. The engine owns totals, permissions and durable drafts.
class WindowsRegisterController extends ChangeNotifier {
  WindowsRegisterController(this.host, {this.journal}) {
    _subscription = host.events.listen(
      (event) {
        if (_disposed) return;
        if (event['name'] == 'disconnected') {
          _markDisconnected();
        } else if (event['name'] == 'connected') {
          _transportAvailable = true;
          ready = false;
          // B's revision is process-local. The supervisor proves old host exit.
          view = const {};
          paymentMethods = const [];
          if (uncertainOperation == null) message = null;
          unawaited(refresh());
        } else if (event['name'] == 'committed') {
          unawaited(refresh());
        }
      },
      onError: (Object _) => _markDisconnected(),
      onDone: _markDisconnected,
    );
  }
  final WindowsHost host;
  final SaleIntentJournal? journal;
  Future<void>? _recovery;
  bool _journalBlocked = false;

  Future<void> recoverIntent() => _recovery ??= _recoverIntent();
  Future<void> _recoverIntent() async {
    try {
      uncertainOperation = await journal?.read();
      if (uncertainOperation != null) {
        message = 'Encaissement précédent à vérifier avant de continuer.';
      }
    } catch (_) {
      _journalBlocked = true;
      message = 'Journal de caisse illisible. Contactez le support ; ne le supprimez pas.';
    }
  }

  Future<void> _resolveIntent(String operation) async {
    if (journal != null) await journal!.resolve(operation);
  }

  late final StreamSubscription<Map<String, dynamic>> _subscription;
  Map<String, dynamic> view = const {};
  Map<String, dynamic> capabilities = const {};
  bool ready = false;
  bool? sessionOpen;
  String? webOrigin;
  bool busy = false;
  bool _disposed = false;
  bool _transportAvailable = true;
  int _refreshGeneration = 0;
  String? message;
  String? uncertainOperation;
  String? receipt;
  String? _checkoutId;
  List<Map<String, dynamic>> paymentMethods = const [];
  int? paymentChange;

  List<Map<String, dynamic>> get products => _rows('products');
  List<Map<String, dynamic>> get lines => _rows('lines');
  List<Map<String, dynamic>> _rows(String key) =>
      (view[key] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
  bool get canPay =>
      !_journalBlocked &&
      !_disposed &&
      _transportAvailable &&
      ready &&
      !busy &&
      uncertainOperation == null &&
      lines.isNotEmpty &&
      view['can_pay'] == true;

  Future<void> refresh() async {
    await recoverIntent();
    if (_disposed || !_transportAvailable || _journalBlocked) return;
    final generation = ++_refreshGeneration;
    try {
      final status = await host.call(HostCommand.status);
      final next = await host.call(HostCommand.view);
      if (_disposed || generation != _refreshGeneration) return;
      if (next['schema'] != 1 || next['revision'] is! int) {
        throw const HostFailure(
          'view_schema',
          'Version du moteur incompatible.',
        );
      }
      if ((next['revision'] as int) < (view['revision'] as int? ?? -1)) return;
      view = next;
      webOrigin = status['web_origin'] as String?;
      sessionOpen = status['session_open'] is bool
          ? status['session_open'] as bool
          : null;
      capabilities = status['capabilities'] is Map<String, dynamic>
          ? status['capabilities'] as Map<String, dynamic>
          : const {};
      ready = next['ready'] == true;
    } on HostFailure catch (error) {
      if (_disposed || generation != _refreshGeneration) return;
      ready = false;
      message = error.message;
    } catch (_) {
      if (_disposed || generation != _refreshGeneration) return;
      ready = false;
      message = 'Le moteur local doit être vérifié.';
    }
    if (!_disposed) notifyListeners();
  }

  void _markDisconnected() {
    if (_disposed) return;
    _transportAvailable = false;
    ++_refreshGeneration;
    ready = false;
    message = 'Le moteur local est arrêté. Les ventes restent à vérifier.';
    notifyListeners();
  }

  Future<Map<String, dynamic>?> command(
    HostCommand command,
    Map<String, dynamic> arguments, {
    String? operationId,
  }) async {
    if (_journalBlocked || !ready || busy || uncertainOperation != null) {
      return null;
    }
    busy = true;
    message = null;
    if (command == HostCommand.preparePayment) {
      paymentMethods = const [];
      paymentChange = null;
    }
    notifyListeners();
    try {
      final result = await host.call(
        command,
        arguments: arguments,
        operationId: operationId,
      );
      if (command == HostCommand.setPayment) {
        paymentChange = result['change'] is int
            ? result['change'] as int
            : null;
      }
      if (command == HostCommand.preparePayment) {
        paymentMethods = (result['methods'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .where((m) => m['code'] is String && m['name'] is String)
            .toList();
      }
      _checkoutId = null;
      await refresh();
      return result;
    } on HostFailure catch (error) {
      message = error.message;
      if (command == HostCommand.setPayments ||
          command == HostCommand.setPayment) {
        paymentChange = null;
        await refresh();
      }
      // A timed-out basket command might have committed. Disable editing until
      // the authoritative draft is reloaded; never replay a scan blindly.
      if (error.code == 'host_unavailable') ready = false;
    } catch (_) {
      ready = false;
      message = 'Opération à vérifier auprès du moteur local.';
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
    return null;
  }

  Future<void> commitSale({Map<String, dynamic>? approval}) async {
    if (!canPay) return;
    final operation = _checkoutId ??= const Uuid().v4();
    busy = true;
    message = null;
    receipt = null;
    notifyListeners();
    try {
      await journal?.begin(operation);
    } catch (_) {
      _journalBlocked = true;
      busy = false;
      message = 'Impossible de conserver la vente avant envoi. Aucun encaissement envoyé.';
      if (!_disposed) notifyListeners();
      return;
    }
    try {
      final result = await host.call(
        HostCommand.commitSale,
        arguments: {
          'draft_id': view['draft_id'],
          'revision': view['revision'],
          'approval': ?approval,
        },
        operationId: operation,
      );
      if (result['state'] != 'committed' ||
          result['operation_id'] != operation) {
        throw const HostFailure(
          'unknown',
          'Résultat à vérifier.',
          outcomeUnknown: true,
        );
      }
      await _resolveIntent(operation);
      receipt = result['number'] as String?;
      _checkoutId = null;
      await refresh();
    } on HostFailure catch (error) {
      message = error.message;
      if (error.outcomeUnknown) {
        uncertainOperation = operation;
      } else {
        try {
          await _resolveIntent(operation);
          _checkoutId = null;
        } catch (_) {
          uncertainOperation = operation;
          message = 'Journal à vérifier avant de continuer.';
        }
      }
    } catch (_) {
      uncertainOperation = operation;
      message =
          'Résultat de la vente à vérifier. Ne réencaissez pas ce panier.';
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> reconcile() async {
    final operation = uncertainOperation;
    if (operation == null || busy) return;
    busy = true;
    notifyListeners();
    try {
      final result = await host.call(
        HostCommand.saleStatus,
        arguments: {'operation_id': operation},
      );
      if (result['state'] == 'committed' &&
          result['operation_id'] == operation) {
        await _resolveIntent(operation);
        receipt = result['number'] as String?;
        uncertainOperation = null;
        _checkoutId = null;
        message = null;
        await refresh();
      } else if (result['state'] == 'not_found' &&
          result['definitive'] == true &&
          result['operation_id'] == operation) {
        await _resolveIntent(operation);
        uncertainOperation = null;
        _checkoutId = null;
        message = 'Vente non enregistrée. Le panier peut être repris.';
        await refresh();
      } else {
        // A simple "not found" is not proof that another process won't commit.
        message = 'Vérification en cours. Ne réencaissez pas ce panier.';
      }
    } catch (_) {
      message = 'Vérification indisponible. La vente reste à contrôler.';
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
