import 'dart:async';

import 'package:flutter/material.dart';

import '../ipc/protocol.dart';
import '../platform/restaurant_intent.dart';
import '../../restaurant/resto_interface.dart';
import 'restaurant_workspace.dart';
import 'restaurant_order.dart';
import 'restaurant_forms.dart';
import 'restaurant_management.dart';
import 'restaurant_recovery.dart';

class RestaurantDialog extends StatefulWidget {
  const RestaurantDialog({super.key, required this.host, this.intent});
  final WindowsHost host;
  final RestaurantIntent? intent;
  @override
  State<RestaurantDialog> createState() => _RestaurantDialogState();
}

class _RestaurantDialogState extends State<RestaurantDialog> {
  late final intent = widget.intent ?? RestaurantIntent(widget.host);
  bool opening = false;
  String? message;
  StreamSubscription<Map<String, dynamic>>? events;
  late Future<Map<String, dynamic>> result = load();
  Future<Map<String, dynamic>> load() async {
    await intent.load();
    return widget.host.call(HostCommand.restaurantView);
  }

  @override
  void initState() {
    super.initState();
    events = widget.host.events.listen((e) {
      if (mounted &&
          !opening &&
          e['name'] == 'committed' &&
          (e['data'] as Map?)?['reason'] == 'restaurant') {
        setState(() => result = load());
      }
    });
  }

  @override
  void dispose() {
    events?.cancel();
    super.dispose();
  }

  Future<void> open(Map row, Map data, {bool channel = false}) async {
    if (opening) return;
    setState(() => opening = true);
    try {
      final recovering = intent.pending != null;
      if (!await restaurantRecovery(context, intent) ||
          !mounted ||
          recovering) {
        return;
      }
      final settings = RestoInterface.fromJson(data['interface'] as Map?);
      Map? response;
      if (row['order_uuid'] != null) {
        response = await widget.host.call(
          HostCommand.restoOrder,
          arguments: {'order_uuid': row['order_uuid']},
        );
      } else {
        final values = await restaurantForm(context, 'Ouvrir une commande', {
          if (settings.askCovers) 'covers': 'Nombre de couverts (facultatif)',
          if (channel && row['requires_reference'] == true)
            'reference': 'Référence du canal',
          if (channel) 'customer_name': 'Nom du client (facultatif)',
        });
        if (values == null || !mounted) return;
        final customer = await restaurantCustomer(context, widget.host);
        if (!mounted) return;
        final coversText = values['covers'] ?? '';
        final covers = coversText.isEmpty ? 0 : int.tryParse(coversText);
        if (covers == null || covers < 0) {
          throw const FormatException('Nombre de couverts invalide.');
        }
        Map? table;
        if (channel && row['requires_table'] == true) {
          table = await restaurantChoose(
            context,
            'Table',
            (data['tables'] as List)
                .cast<Map>()
                .where((t) => t['state'] == 'free')
                .toList(),
          );
          if (table == null || !mounted) return;
        }
        response = await restaurantRun(
          context,
          intent,
          channel ? HostCommand.restoOpenOnChannel : HostCommand.restoOpen,
          {
            if (channel) 'channel': row['code'],
            if (!channel || table != null)
              'table_uuid': channel ? table!['table_uuid'] : row['table_uuid'],
            'covers': covers,
            if (!channel && customer != null) 'customer': customer,
            if (channel && customer != null) 'customer_uuid': customer['uuid'],
            if (values['reference']?.isNotEmpty == true)
              'reference': values['reference'],
            if (channel &&
                (customer != null ||
                    values['customer_name']?.isNotEmpty == true))
              'customer_name': customer?['name'] ?? values['customer_name'],
          },
        );
      }
      if (!mounted || response == null) return;
      await showDialog<void>(
        context: context,
        builder: (_) => RestaurantOrderDialog(
          host: widget.host,
          intent: intent,
          room: data,
          order: response!['order'] as Map,
          sendLabel: settings.sendButton(
            production:
                (data['settings'] as Map?)?['send_to_production'] == true,
          ),
        ),
      );
    } catch (e) {
      message = '$e';
    } finally {
      if (mounted) {
        setState(() {
          opening = false;
          result = load();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Dialog.fullscreen(
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Restaurant · salle et commandes'),
        actions: [
          IconButton(
            tooltip: 'Actualiser / reprendre',
            onPressed: opening
                ? null
                : () async {
                    try {
                      await restaurantRecovery(context, intent);
                    } catch (e) {
                      message = '$e';
                    }
                    if (mounted) setState(() => result = load());
                  },
            icon: const Icon(Icons.sync),
          ),
          PopupMenuButton<String>(
            enabled: !opening,
            onSelected: (section) async {
              await showDialog<void>(
                context: context,
                builder: (_) =>
                    RestaurantManagement(intent: intent, section: section),
              );
              if (mounted) setState(() => result = load());
            },
            itemBuilder: (_) => [
              for (final s in [
                'Bons de production',
                'Imprimantes cuisine / bar',
                'Registre',
                'Remboursements',
              ])
                PopupMenuItem(value: s, child: Text(s)),
            ],
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
              child: Text('Salle indisponible : ${snapshot.error}'),
            );
          }
          final data = snapshot.data!;
          final rows = (data['tables'] as List? ?? []).cast<Map>();
          final available =
              !opening && data['available'] == true && data['blocker'] == null;
          return Column(
            children: [
              if (intent.pending != null)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'Une action reste à vérifier. Utilisez « Actualiser / reprendre ».',
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final c
                        in (data['channels'] as List? ?? []).cast<Map>().where(
                          (c) => c['active'] == true,
                        ))
                      FilledButton.tonal(
                        onPressed: available
                            ? () => open(c, data, channel: true)
                            : null,
                        child: Text('+ ${c['name']}'),
                      ),
                    for (final o
                        in (data['orders'] as List? ?? []).cast<Map>().where(
                          (o) =>
                              o['status'] == 'open' && o['table_name'] == null,
                        ))
                      OutlinedButton(
                        onPressed: opening ? null : () => open(o, data),
                        child: Text(
                          '${o['local_number']} · ${o['channel_name']} · ${o['payable_label']}',
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: RestaurantWorkspace(
                  availabilityMessage: message ?? '${data['message'] ?? ''}',
                  onOpen: available
                      ? (t) =>
                            open(rows.singleWhere((r) => r['id'] == t.id), data)
                      : null,
                  tables: [
                    for (final row in rows)
                      RestaurantTableView(
                        id: '${row['id']}',
                        name: '${row['name']}',
                        room: '${row['room']}',
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
                          for (final l
                              in (row['lines'] as List? ?? []).cast<Map>())
                            RestaurantLineView(
                              name: '${l['name']}',
                              quantityLabel: '${l['quantity_label']}',
                              totalLabel: '${l['total_label']}',
                              stateLabel: '${l['state_label']}',
                              note: l['note'] as String?,
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}
