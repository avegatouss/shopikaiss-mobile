import 'package:flutter/material.dart';

import '../ipc/protocol.dart';
import 'restaurant_workspace.dart';
import 'restaurant_order.dart';

import 'package:uuid/uuid.dart';

import '../../restaurant/resto_interface.dart';

class RestaurantDialog extends StatefulWidget {
  const RestaurantDialog({super.key, required this.host});
  final WindowsHost host;
  @override
  State<RestaurantDialog> createState() => _RestaurantDialogState();
}

class _RestaurantDialogState extends State<RestaurantDialog> {
  bool opening = false;
  String? message;
  Future<void> open(Map row, Map data) async {
    if (opening) return;
    setState(() => opening = true);
    try {
      final settings = RestoInterface.fromJson(data['interface'] as Map?);
      Map response;
      if (row['order_uuid'] != null) {
        response = await widget.host.call(
          HostCommand.restoOrder,
          arguments: {'order_uuid': row['order_uuid']},
        );
      } else {
        int covers = 0;
        if (settings.askCovers) {
          final input = TextEditingController();
          final selected = await showDialog<int>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Nombre de couverts'),
              content: TextField(
                controller: input,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  hintText: 'Laisser vide si non renseigné',
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Annuler'),
                ),
                FilledButton(
                  onPressed: () {
                    final n = input.text.isEmpty ? 0 : int.tryParse(input.text);
                    if (n != null && n >= 0) Navigator.pop(context, n);
                  },
                  child: const Text('Ouvrir'),
                ),
              ],
            ),
          );
          input.dispose();
          if (selected == null) return;
          covers = selected;
        }
        response = await widget.host.call(
          HostCommand.restoOpen,
          arguments: {'table_uuid': row['table_uuid'], 'covers': covers},
          operationId: const Uuid().v4(),
        );
      }
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => RestaurantOrderDialog(
          host: widget.host,
          order: response['order'] as Map,
          sendLabel: settings.sendButton(
            production:
                (data['settings'] as Map?)?['send_to_production'] == true,
          ),
        ),
      );
    } catch (e) {
      message = e is HostFailure && !e.outcomeUnknown
          ? e.message
          : 'Résultat à vérifier : relisez la salle avant de réessayer.';
    } finally {
      if (mounted) {
        setState(() {
          opening = false;
          result = load();
        });
      }
    }
  }

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
            availabilityMessage: message ?? data['message'] as String,
            onOpen:
                opening || data['blocker'] != null || data['available'] != true
                ? null
                : (table) => open(
                    rows.singleWhere((row) => row['id'] == table.id),
                    data,
                  ),
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
