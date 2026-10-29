import 'dart:async';
import 'dart:io';

import 'protocol.dart';

/// Inherited stdin/stdout pipes: no TCP port or remotely reachable listener.
/// No command is replayed after a timeout, including after a process restart.
class ProcessWindowsHost implements WindowsHost {
  ProcessWindowsHost._(this._process, this.timeout) {
    _output = decodeFrames(_process.stdout).listen(
      (frame) {
        try {
          _receive(frame);
        } catch (_) {
          _disconnect();
        }
      },
      onError: (Object error) => _disconnect(),
      onDone: _disconnect,
    );
    // Drain diagnostic output without copying potentially sensitive content.
    _errors = _process.stderr.listen((_) {});
    unawaited(_process.exitCode.then((_) => _disconnect()));
  }

  static Future<ProcessWindowsHost> start(
    String executable, {
    List<String> arguments = const [],
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (!File(executable).isAbsolute || !await File(executable).exists()) {
      throw const HostFailure(
        'host_missing',
        'Le moteur local n’est pas installé.',
      );
    }
    try {
      final process = await Process.start(
        executable,
        arguments,
        runInShell: false,
      );
      return ProcessWindowsHost._(process, timeout);
    } on ProcessException {
      throw const HostFailure(
        'host_start',
        'Impossible de démarrer le moteur local.',
      );
    }
  }

  final Process _process;
  final Duration timeout;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  final _commands = <String, HostCommand>{};
  late final StreamSubscription<Map<String, dynamic>> _output;
  late final StreamSubscription<List<int>> _errors;
  int _sequence = 0;
  bool _disconnected = false;
  Future<void>? _shutdown;
  Future<void> _writes = Future.value();

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Future<Map<String, dynamic>> call(
    HostCommand command, {
    Map<String, dynamic> arguments = const {},
    String? operationId,
  }) async {
    if (_disconnected) throw _failure(command);
    if (command == HostCommand.commitSale && operationId == null) {
      throw const HostFailure(
        'operation_required',
        'Identifiant de vente requis.',
      );
    }
    if (_pending.length >= 32) {
      throw const HostFailure(
        'busy',
        'Le moteur traite les opérations précédentes.',
      );
    }
    final id = '${++_sequence}';
    final frame = encodeFrame({
      'kind': 'request',
      'id': id,
      'command': command.name,
      'arguments': arguments,
      'operation_id': ?operationId,
    });
    final result = Completer<Map<String, dynamic>>();
    _pending[id] = result;
    _commands[id] = command;
    final timer = Timer(timeout, () {
      _pending.remove(id)?.completeError(_failure(command));
      _commands.remove(id);
    });
    try {
      // IOSink rejects add() while a previous flush() is bound. Serialize
      // transport writes, not response waits, so status/view may run together.
      _writes = _writes
          .then((_) async {
            if (_disconnected || !_pending.containsKey(id)) return;
            _process.stdin.add(frame);
            await _process.stdin.flush();
          })
          .catchError((Object error) => _disconnect());
      return await result.future;
    } finally {
      timer.cancel();
      _pending.remove(id);
      _commands.remove(id);
    }
  }

  void _receive(Map<String, dynamic> frame) {
    if (frame['kind'] == 'event') {
      _events.add(frame);
      return;
    }
    final id = frame['id'];
    if (frame['kind'] != 'response' || id is! String) {
      _disconnect();
      return;
    }
    final completer = _pending.remove(id);
    final command = _commands.remove(id);
    if (completer == null) {
      return; // Late result never mutates the current view.
    }
    if (frame['ok'] == true && frame['result'] is Map<String, dynamic>) {
      completer.complete(frame['result'] as Map<String, dynamic>);
    } else if (frame['ok'] == false && frame['error'] is Map) {
      final error = frame['error'] as Map;
      // Validate before casting: this completer is no longer in _pending.
      // Throwing here would orphan it, so neither disconnect nor timeout could
      // settle the call. A malformed failure never proves absence of a sale.
      if ((error['code'] != null && error['code'] is! String) ||
          (error['message'] != null && error['message'] is! String) ||
          (error['not_committed'] != null && error['not_committed'] is! bool)) {
        completer.completeError(_failure(command));
        _disconnect();
        return;
      }
      completer.completeError(
        HostFailure(
          error['code'] as String? ?? 'host_error',
          error['message'] as String? ?? 'Opération locale non terminée.',
          // Only the engine can prove that a failed commit did not take place.
          outcomeUnknown:
              command == HostCommand.commitSale &&
              error['not_committed'] != true,
        ),
      );
    } else {
      completer.completeError(_failure(command));
      _disconnect();
    }
  }

  HostFailure _failure(HostCommand? command) => HostFailure(
    'host_unavailable',
    command == HostCommand.commitSale
        ? 'Résultat de la vente à vérifier. Ne réencaissez pas ce panier.'
        : 'Le moteur local ne répond pas. Votre opération doit être vérifiée.',
    outcomeUnknown: command == HostCommand.commitSale,
  );

  void _disconnect() {
    if (_disconnected) return;
    _disconnected = true;
    for (final item in _pending.entries) {
      item.value.completeError(_failure(_commands[item.key]));
    }
    _pending.clear();
    _commands.clear();
    if (!_events.isClosed) {
      _events.add({
        'version': windowsIpcVersion,
        'kind': 'event',
        'name': 'disconnected',
      });
    }
  }

  @override
  Future<void> close() async {
    _disconnect();
    // Keep the shutdown future after a timeout. A supervisor must never treat
    // a second close as proof of exit while the old writer is still running.
    _shutdown ??= _finishShutdown();
    await _shutdown!.timeout(timeout);
  }

  Future<void> _finishShutdown() async {
    // EOF asks the host to finish accepted local commands, then shut down.
    // Do not kill it halfway through a durable write.
    // Drain output until exit: cancelling a process pipe before sending EOF can
    // deadlock on Windows while the child is waiting for more input.
    try {
      await _writes;
      await _process.stdin.close();
    } catch (_) {
      // Broken stdin is not proof of process exit; still wait for the owner.
    }
    await _process.exitCode;
    await _output.cancel();
    await _errors.cancel();
    await _events.close();
  }
}
