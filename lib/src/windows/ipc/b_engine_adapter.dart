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
      return await inner.execute(command.name, arguments, effectiveId);
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
