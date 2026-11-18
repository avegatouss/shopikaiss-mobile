import 'package:flutter/material.dart';

import '../ipc/protocol.dart';
import 'restaurant_workspace.dart';

class RestaurantDialog extends StatefulWidget {
  const RestaurantDialog({super.key, required this.host});
  final WindowsHost host;
  @override
  State<RestaurantDialog> createState() => _RestaurantDialogState();
}

class _RestaurantDialogState extends State<RestaurantDialog> {
  late Future<Map<String, dynamic>> result = load();
  Future<Map<String, dynamic>> load() =>
      widget.host.call(HostCommand.restaurantView);
  @override
  Widget build(BuildContext context) => Dialog.fullscreen(
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Salle et service de table'),
        actions: [
          IconButton(
            tooltip: 'Actualiser',
            onPressed: () => setState(() => result = load()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: result,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Salle indisponible : ${snapshot.error}'),
              ),
            );
          }
          final data = snapshot.data!;
          final rows = (data['tables'] as List? ?? const []).cast<Map>();
          return RestaurantWorkspace(
            availabilityMessage: data['message'] as String,
            tables: [
              for (final row in rows)
                RestaurantTableView(
                  id: row['id'] as String,
                  name: row['name'] as String,
                  room: row['room'] as String,
                  state: RestaurantTableState.values.byName(
                    row['state'] as String,
                  ),
                  orderLabel: [
                    row['order_label'],
                    row['sync_message'],
                  ].whereType<String>().join(' · '),
                  totalLabel: row['total_label'] as String?,
                  guestsLabel: row['guests_label'] as String?,
                  lines: [
                    for (final line in (row['lines'] as List).cast<Map>())
                      RestaurantLineView(
                        name: line['name'] as String,
                        quantityLabel: line['quantity_label'] as String,
                        totalLabel: line['total_label'] as String,
                        stateLabel: line['state_label'] as String,
                        note: line['note'] as String?,
                      ),
                  ],
                ),
            ],
          );
        },
      ),
    ),
  );
}
