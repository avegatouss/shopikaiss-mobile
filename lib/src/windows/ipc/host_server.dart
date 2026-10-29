import 'dart:async';

import 'protocol.dart';

/// Implemented by session B's engine adapter. This boundary contains no
/// financial rules, database schema or server synchronization implementation.
abstract interface class WindowsEngineAdapter {
  Stream<Map<String, dynamic>> get committedChanges;
  Future<Map<String, dynamic>> execute(
    HostCommand command,
    Map<String, dynamic> arguments,
    String? operationId,
  );
}

/// Host-side framing usable by B's executable; mutations are serialized.
/// All long-running network work must be scheduled by the adapter, not awaited
/// inside a command. Synchronize returns a scheduled status immediately.
class WindowsHostServer {
  WindowsHostServer(this.adapter);
  final WindowsEngineAdapter adapter;

  Future<void> serve(
    Stream<List<int>> input,
    void Function(List<int>) write,
  ) async {
    final changes = adapter.committedChanges.listen((change) {
      write(
        encodeFrame({'kind': 'event', 'name': 'committed', 'data': change}),
      );
    });
    try {
      await for (final request in decodeFrames(input)) {
        final id = request['id'];
        if (request['kind'] != 'request' || id is! String || id.length > 128) {
          throw const FormatException('Invalid request');
        }
        try {
          final command = HostCommand.values
              .where((c) => c.name == request['command'])
              .firstOrNull;
          if (command == null ||
              request['arguments'] is! Map<String, dynamic>) {
            throw const HostFailure(
              'invalid_command',
              'Commande locale non reconnue.',
            );
          }
          final operation = request['operation_id'];
          if (operation != null &&
              (operation is! String || operation.length > 128)) {
            throw const HostFailure(
              'invalid_operation',
              'Identifiant invalide.',
            );
          }
          if (command == HostCommand.commitSale && operation == null) {
            throw const HostFailure(
              'operation_required',
              'Identifiant de vente requis.',
            );
          }
          final result = await adapter.execute(
            command,
            request['arguments'] as Map<String, dynamic>,
            operation as String?,
          );
          write(
            encodeFrame({
              'kind': 'response',
              'id': id,
              'ok': true,
              'result': result,
            }),
          );
        } on HostFailure catch (error) {
          write(
            encodeFrame({
              'kind': 'response',
              'id': id,
              'ok': false,
              'error': {
                'code': error.code,
                'message': error.message,
                'not_committed': !error.outcomeUnknown,
              },
            }),
          );
        } catch (_) {
          write(
            encodeFrame({
              'kind': 'response',
              'id': id,
              'ok': false,
              'error': {
                'code': 'host_error',
                'message': 'Opération à vérifier.',
                'not_committed': false,
              },
            }),
          );
        }
      }
    } finally {
      await changes.cancel();
    }
  }
}
