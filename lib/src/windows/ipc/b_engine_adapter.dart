import '../../register/register_adapter.dart';
import '../../offline/ticket.dart';
import '../../offline/money.dart';
import 'host_server.dart';
import 'protocol.dart';
import 'restaurant_projection.dart';
import 'closure_document.dart';

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
    if (command == HostCommand.cashClosureDocument) {
      final status = await inner.execute('status', const {}, null);
      if (status['operator'] == null) {
        throw const HostFailure('operator_required', 'Identifiez le caissier pour consulter les documents.');
      }
      final operator = inner.engine.snapshot?.operatorById((status['operator'] as Map)['id'] as int);
      if (operator == null ||
          (arguments['kind'] == 'pre-z' && !inner.engine.hasRight(operator, 'caisse_cloturer'))) {
        throw const HostFailure('document_forbidden', 'Vous ne pouvez pas éditer ce document sur ce poste.');
      }
      return localClosureDocument(inner.engine, arguments);
    }
    if (command == HostCommand.restaurantView) {
      final status = await inner.execute('status', const {}, null);
      if (status['operator'] == null) {
        throw const HostFailure('operator_required', 'Identifiez le caissier pour consulter la salle.');
      }
      return restaurantProjection(inner.engine.restaurant, await inner.engine.restaurantOrders());
    }
    if (command == HostCommand.cashDocuments || command == HostCommand.cashDocument) {
      final documents = (await inner.engine.history()).where((o) => o.type == 'retour' || o.type == 'cloture_session').toList().reversed;
      if (command == HostCommand.cashDocuments) {
        return {'items': [for (final o in documents) {'operation_id': o.uuid, 'title': o.type == 'retour' ? 'Bon de retour' : 'Rapport Z', 'date': o.date.toIso8601String(), 'available': o.type == 'retour' || o.content['z'] is Map, 'status': o.serverStatus ?? o.status}]};
      }
      final matches = documents.where((o) => o.uuid == arguments['operation_id']);
      if (matches.isEmpty) throw const HostFailure('document_absent', 'Document introuvable sur ce poste.');
      final o = matches.first;
      final snapshot = inner.engine.snapshot;
      if (snapshot == null) throw const HostFailure('document_absent', 'Référentiel indisponible.');
      final rows = <(String, String)>[('Operation', o.uuid), ('Etat', o.serverStatus ?? o.status)];
      if (o.type == 'retour') {
        rows.add(('Remboursement especes', formatFcfa(o.content['montant'] as int)));
        rows.add(('Motif', '${o.content['motif'] ?? ''}'));
      } else {
        final z = o.content['z'];
        if (z is! Map) throw const HostFailure('z_attendu', 'Le rapport Z sera disponible après synchronisation.');
        for (final entry in {'compte': 'Compte', 'theorique': 'Theorique', 'ecart': 'Ecart'}.entries) {
          rows.add((entry.value, formatFcfa(z[entry.key] as int)));
        }
      }
      return {'operation_id': o.uuid, 'lines': offlineSlipLines(snapshot: snapshot, title: o.type == 'retour' ? 'BON DE RETOUR' : 'RAPPORT Z', date: o.date, operatorName: snapshot.operatorById(o.operatorId)?.name ?? '', paperWidth: 80, rows: rows)};
    }
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
        return {...result, 'web_origin': await inner.engine.storedOrigin(), 'terminal_name': inner.engine.snapshot?.terminal.name};
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
