import '../../offline/money.dart';
import '../../restaurant/resto_context.dart';

/// Read-only IPC projection. Master designation and monetary amounts come from B.
Map<String, dynamic> restaurantProjection(
  RestoContext? context,
  List<RestoOrderView> orders,
) {
  if (context == null) {
    return {
      'available': false,
      'message': 'Le mode restaurant n’est pas disponible sur cet appareil.',
      'tables': <Object>[],
    };
  }
  final tables = <Map<String, dynamic>>[];
  for (final table in context.tables) {
    final matching = orders
        .where((o) => o.order.tableUuid == table.uuid)
        .toList();
    final room = context.rooms
        .where((r) => r.uuid == table.roomUuid)
        .firstOrNull;
    if (matching.isEmpty) {
      tables.add({
        'id': table.uuid,
        'name': table.name,
        'room': room?.name ?? 'Sans salle',
        'state': 'free',
        'lines': <Object>[],
      });
    }
    // Several orders on one table must never be collapsed into one payable total.
    for (final entry in matching) {
      tables.add({
        'id': '${table.uuid}:${entry.order.uuid}',
        'name': table.name,
        'room': room?.name ?? 'Sans salle',
        'state': entry.order.prebills > 0 ? 'payment' : 'occupied',
        'order_label': entry.serverNumber ?? entry.order.localNumber,
        'total_label': formatFcfa(entry.payable),
        'guests_label': entry.order.covers == null
            ? null
            : '${entry.order.covers} couverts',
        'sync_message':
            entry.serverMessage ??
            (entry.waiting
                ? 'En attente d’une version précédente'
                : entry.pendingVersions > 0
                ? 'Synchronisation en attente'
                : null),
        'lines': [
          for (final line in entry.order.lines)
            {
              'name': line.label,
              'quantity_label': '${line.quantity / 1000000}',
              'total_label': formatFcfa(line.total),
              'state_label': line.active ? 'En commande' : 'Annulée',
              'note': line.comment,
            },
        ],
      });
    }
  }
  return {
    'available': true,
    'profile': context.profile,
    'master': context.master,
    'message': context.notMasterReason ?? 'Consultation de la salle — les actions attendent le raccordement des commandes du moteur.',
    'tables': tables,
  };
}
