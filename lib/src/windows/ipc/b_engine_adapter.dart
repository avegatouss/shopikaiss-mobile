import '../../register/register_adapter.dart';
import 'host_server.dart';
import 'protocol.dart';

/// Transport adaptation only; business rules stay in B's shared engine.
class BEngineAdapter implements WindowsEngineAdapter {
  BEngineAdapter(this.inner);
  final LocalRegisterAdapter inner;
  @override
  Stream<Map<String, dynamic>> get committedChanges => inner.committedChanges;
  @override
  Future<Map<String, dynamic>> execute(
    HostCommand command,
    Map<String, dynamic> arguments,
    String? operationId,
  ) async {
    if (command == HostCommand.login) {
      final snapshot = inner.engine.snapshot;
      final id = arguments['operator_id'];
      final operator = id is int ? snapshot?.operatorById(id) : null;
      if (snapshot?.rules.pinRequired == true &&
          operator != null &&
          (operator.pinHash ?? '').isEmpty) {
        // Missing server configuration is not a wrong PIN. Do not consume
        // attempts or bypass authentication when no verifier was supplied.
        throw const HostFailure(
          'pin_unconfigured',
          'Le serveur ne fournit pas de PIN pour ce caissier. Configurez son PIN côté web, puis synchronisez la caisse.',
        );
      }
    }
    var effectiveId = operationId;
    // Existing C read/reprint callers put the ID in arguments; B expects the
    // third parameter. Reject conflicting IDs instead of choosing silently.
    if (command == HostCommand.saleStatus || command == HostCommand.reprint) {
      final argumentId = arguments['operation_id'];
      if (argumentId != null &&
          (argumentId is! String ||
              (operationId != null && operationId != argumentId))) {
        throw const HostFailure('invalid_operation', 'Identifiant incohérent.');
      }
      effectiveId ??= argumentId as String?;
    }
    try {
      final result = await inner.execute(command.name, arguments, effectiveId);
      if (command == HostCommand.status) {
        return {...result, 'web_origin': await inner.engine.storedOrigin()};
      }
      return result;
    } on AdapterFailure catch (error) {
      throw HostFailure(
        error.code,
        error.message,
        outcomeUnknown: !error.notCommitted,
      );
    }
    // Unexpected errors propagate; the IPC server marks their outcome unknown.
  }
}
