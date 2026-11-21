import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../ipc/protocol.dart';

/// One immutable request saved before IPC. Retried with the same operation ID.
class CatalogueIntent {
  CatalogueIntent(this.host, this.file);
  final WindowsHost host;
  final File file;
  Map<String, dynamic>? pending;
  bool busy = false;

  Future<void> load() async {
    if (!await file.exists()) return;
    final data = jsonDecode(await file.readAsString());
    if (data is! Map ||
        data['schema'] != 1 ||
        !['createProduct', 'updateProduct'].contains(data['command']) ||
        data['arguments'] is! Map ||
        data['operator_id'] == null ||
        data['id'] is! String ||
        !RegExp(r'^[0-9a-f-]{36}$').hasMatch(data['id'])) {
      throw const FormatException(
        'Journal produit illisible : ne pas le supprimer.',
      );
    }
    pending = Map<String, dynamic>.from(data);
  }

  Future<void> execute(
    HostCommand command,
    Map<String, dynamic> args,
    Object operatorId,
  ) async {
    if (busy) throw StateError('Enregistrement en cours.');
    await load();
    if (pending != null) {
      throw StateError('Vérifiez la modification précédente.');
    }
    pending = {
      'schema': 1,
      'id': const Uuid().v4(),
      'command': command.name,
      'operator_id': operatorId,
      'arguments': jsonDecode(jsonEncode(args)),
    };
    await retry(operatorId);
  }

  Future<void> retry(Object operatorId) async {
    if (busy) throw StateError('Enregistrement en cours.');
    if (pending == null) throw StateError('Aucune modification à vérifier.');
    if ('${pending!['operator_id']}' != '$operatorId') {
      throw const HostFailure(
        'operator_required',
        'Reconnectez le caissier ayant saisi cette modification.',
      );
    }
    busy = true;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(pending), flush: true);
      try {
        await host.call(
          HostCommand.values.byName(pending!['command']),
          arguments: Map<String, dynamic>.from(pending!['arguments']),
          operationId: pending!['id'],
        );
      } on HostFailure catch (e) {
        if (e.outcomeUnknown ||
            [
              'caissier_requis',
              'operator_required',
              'produit_refuse',
              'host_unavailable',
              'timeout',
            ].contains(e.code)) {
          rethrow;
        }
        await file.delete();
        pending = null;
        rethrow;
      }
      await file.delete();
      pending = null;
    } finally {
      busy = false;
    }
  }
}
