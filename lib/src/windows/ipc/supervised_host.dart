import 'dart:async';

import 'protocol.dart';

/// Explicit reconnection only: never replays a scan, payment or sale.
/// The factory must verify the packaged executable before launching it.
/// close() on the underlying host must prove process exit, not just pipe EOF.
class SupervisedWindowsHost implements WindowsHost {
  SupervisedWindowsHost(this._factory);

  final Future<WindowsHost> Function() _factory;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  WindowsHost? _host;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  Future<void>? _connecting;
  Future<void>? _closeAttempt;
  bool _ready = false;
  bool _closing = false;
  bool _closed = false;

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  Future<void> connect() {
    if (_closing) return Future.error(_unavailable());
    if (_ready) return Future.value();
    return _connecting ??= _connect().whenComplete(() => _connecting = null);
  }

  Future<void> _connect() async {
    try {
      final previous = _host;
      if (previous != null) {
        // Timeout leaves the previous host retained and blocks a second writer.
        await previous.close();
        await _subscription?.cancel();
        _subscription = null;
        _host = null;
      }
      if (_closing) return;
      final next = await _factory();
      _host = next;
      if (_closing) {
        await next.close();
        _host = null;
        return;
      }
      _subscription = next.events.listen(
        (event) {
          if (event['name'] == 'disconnected') _ready = false;
          if (!_events.isClosed) _events.add(event);
        },
        onError: (Object _) => _lost(),
        onDone: _lost,
      );
      _ready = true;
      _events.add({
        'version': windowsIpcVersion,
        'kind': 'event',
        'name': 'connected',
      });
    } catch (_) {
      _lost();
      throw const HostFailure(
        'host_reconnect',
        'Le moteur précédent doit être arrêté avant toute reconnexion.',
      );
    }
  }

  void _lost() {
    _ready = false;
    if (!_events.isClosed) {
      _events.add({
        'version': windowsIpcVersion,
        'kind': 'event',
        'name': 'disconnected',
      });
    }
  }

  HostFailure _unavailable([HostCommand? command]) => HostFailure(
    'host_unavailable',
    'Moteur local indisponible. Vérifiez la connexion et les ventes en attente.',
    outcomeUnknown: command == HostCommand.commitSale,
  );

  @override
  Future<Map<String, dynamic>> call(
    HostCommand command, {
    Map<String, dynamic> arguments = const {},
    String? operationId,
  }) async {
    final current = _host;
    if (!_ready || _closing || current == null) throw _unavailable(command);
    // Propagate once, never retry (even when another host reconnects meanwhile).
    try {
      return await current.call(
        command,
        arguments: arguments,
        operationId: operationId,
      );
    } on HostFailure catch (error) {
      if (identical(current, _host) && error.code == 'host_unavailable') {
        _lost();
      }
      rethrow;
    }
  }

  @override
  Future<void> close() {
    _closing = true;
    _ready = false;
    if (_closed) return Future.value();
    return _closeAttempt ??= _close().whenComplete(() => _closeAttempt = null);
  }

  Future<void> _close() async {
    try {
      await _connecting;
    } catch (_) {
      // A failed connect may still own a child awaiting shutdown.
    }
    await _host?.close();
    await _subscription?.cancel();
    _host = null;
    _subscription = null;
    await _events.close();
    _closed = true;
  }
}
