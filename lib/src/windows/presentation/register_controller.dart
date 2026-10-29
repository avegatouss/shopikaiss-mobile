import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../ipc/protocol.dart';

/// Presentation only. The engine owns totals, permissions and durable drafts.
class WindowsRegisterController extends ChangeNotifier {
  WindowsRegisterController(this.host) {
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
  late final StreamSubscription<Map<String, dynamic>> _subscription;
  Map<String, dynamic> view = const {};
  bool ready = false;
  bool busy = false;
  bool _disposed = false;
  bool _transportAvailable = true;
  int _refreshGeneration = 0;
  String? message;
  String? uncertainOperation;
  String? receipt;
  String? _checkoutId;
  List<Map<String, dynamic>> paymentMethods = const [];

  List<Map<String, dynamic>> get products => _rows('products');
  List<Map<String, dynamic>> get lines => _rows('lines');
  List<Map<String, dynamic>> _rows(String key) =>
      (view[key] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
  bool get canPay =>
      !_disposed &&
      _transportAvailable &&
      ready &&
      !busy &&
      uncertainOperation == null &&
      lines.isNotEmpty &&
      view['can_pay'] == true;

  Future<void> refresh() async {
    if (_disposed || !_transportAvailable) return;
    final generation = ++_refreshGeneration;
    try {
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

  Future<void> command(
    HostCommand command,
    Map<String, dynamic> arguments,
  ) async {
    if (!ready || busy || uncertainOperation != null) return;
    busy = true;
    message = null;
    if (command == HostCommand.preparePayment) paymentMethods = const [];
    notifyListeners();
    try {
      final result = await host.call(command, arguments: arguments);
      if (command == HostCommand.preparePayment) {
        paymentMethods = (result['methods'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .where((m) => m['code'] is String && m['name'] is String)
            .toList();
      }
      _checkoutId = null;
      await refresh();
    } on HostFailure catch (error) {
      message = error.message;
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
  }

  Future<void> commitSale() async {
    if (!canPay) return;
    final operation = _checkoutId ??= const Uuid().v4();
    busy = true;
    message = null;
    receipt = null;
    notifyListeners();
    try {
      final result = await host.call(
        HostCommand.commitSale,
        arguments: {'draft_id': view['draft_id'], 'revision': view['revision']},
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
      receipt = result['number'] as String?;
      _checkoutId = null;
      await refresh();
    } on HostFailure catch (error) {
      message = error.message;
      if (error.outcomeUnknown) uncertainOperation = operation;
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
        receipt = result['number'] as String?;
        uncertainOperation = null;
        _checkoutId = null;
        message = null;
        await refresh();
      } else if (result['state'] == 'not_found' &&
          result['definitive'] == true &&
          result['operation_id'] == operation) {
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
