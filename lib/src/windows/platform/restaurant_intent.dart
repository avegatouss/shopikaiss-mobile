import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../ipc/protocol.dart';

/// One unresolved restaurant action per terminal. Never persists a manager PIN.
/// A corrupt journal blocks actions instead of silently discarding an intent.
class RestaurantIntent {
  RestaurantIntent(this.host, {this.file});
  final WindowsHost host;
  final File? file;
  Map<String, dynamic>? pending;
  bool busy = false;
  bool loaded = false;

  Future<void> requireResolved() async {
    await load();
    if (busy || pending != null) {
      throw const HostFailure(
        'restaurant_pending',
        'Vérifiez l’action restaurant en attente avant le Z ou la clôture.',
      );
    }
  }

  Future<void> load() async {
    if (loaded) return;
    if (file != null && await file!.exists()) {
      final value = jsonDecode(await file!.readAsString());
      if (value is! Map ||
          value['schema'] != 1 ||
          value['id'] is! String ||
          !RegExp(r'^[0-9a-f-]{36}$').hasMatch(value['id'] as String) ||
          value['arguments'] is! Map ||
          !HostCommand.values.any((c) => c.name == value['command'])) {
        throw const FormatException(
          'Journal restaurant illisible : ne pas le supprimer.',
        );
      }
      pending = Map<String, dynamic>.from(value);
    }
    loaded = true;
  }

  Future<Map<String, dynamic>> execute(
    HostCommand command,
    Map<String, dynamic> arguments, {
    Map<String, dynamic>? preparation,
  }) async {
    await load();
    if (busy || pending != null) {
      throw StateError('Action précédente à vérifier.');
    }
    busy = true;
    final safe = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(arguments)) as Map,
    )..remove('approval');
    pending = {
      'schema': 1,
      'id': const Uuid().v4(),
      'command': command.name,
      'arguments': safe,
      'preparation': preparation,
      'needs_approval': arguments['approval'] != null,
    };
    // Flush before IPC; an interrupted file must stop the next launch.
    try {
      if (file != null) {
        await file!.parent.create(recursive: true);
        await file!.writeAsString(jsonEncode(pending), flush: true);
      }
      return await _send(arguments, initial: true);
    } finally {
      busy = false;
    }
  }

  Future<Map<String, dynamic>> retry({Map<String, dynamic>? approval}) async {
    await load();
    if (busy || pending == null) throw StateError('Aucune action à reprendre.');
    final args = Map<String, dynamic>.from(pending!['arguments'] as Map);
    if (approval != null) args['approval'] = approval;
    busy = true;
    try {
      if (file != null) {
        await file!.parent.create(recursive: true);
        await file!.writeAsString(jsonEncode(pending), flush: true);
      }
      return await _send(args, initial: false);
    } finally {
      busy = false;
    }
  }

  Future<Map<String, dynamic>> _send(
    Map<String, dynamic> args, {
    required bool initial,
  }) async {
    busy = true;
    final record = pending!;
    final command = HostCommand.values.byName(record['command'] as String);
    try {
      Map<String, dynamic> result;
      try {
        result = await host.call(
          command,
          arguments: args,
          operationId: record['id'] as String,
        );
      } on HostFailure catch (e) {
        if (command != HostCommand.restoSettle ||
            e.code != 'reglement_a_preparer' ||
            e.outcomeUnknown ||
            record['preparation'] is! Map) {
          rethrow;
        }
        await host.call(
          HostCommand.restoPrepareSettlement,
          arguments: Map<String, dynamic>.from(record['preparation'] as Map),
        );
        result = await host.call(
          command,
          arguments: args,
          operationId: record['id'] as String,
        );
      }
      await resolve();
      return result;
    } on HostFailure catch (e) {
      // B recovers financial IDs before business validation. A definitive
      // business refusal proves no sale/refund exists, except authentication
      // and approval gates that can run before recovery.
      final financial =
          command == HostCommand.restoSettle ||
          command == HostCommand.restoRefund;
      final gate = const [
        'caissier_requis',
        'operator_required',
        'autorisation_requise',
        'host_unavailable',
        'timeout',
      ].contains(e.code);
      if (!e.outcomeUnknown && (initial || (financial && !gate))) {
        await resolve();
      }
      rethrow;
    } finally {
      busy = false;
    }
  }

  /// Non-financial intents only, after an explicit human review of fresh state.
  Future<void> acknowledgeReviewed() async {
    if (['restoSettle', 'restoRefund'].contains(pending?['command'])) {
      throw StateError(
        'Un règlement ou remboursement doit être retrouvé par son identifiant.',
      );
    }
    await resolve();
  }

  Future<void> resolve() async {
    if (file != null && await file!.exists()) await file!.delete();
    pending = null;
  }
}
