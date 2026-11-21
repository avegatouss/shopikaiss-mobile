import 'package:flutter/material.dart';

import '../ipc/protocol.dart';
import '../platform/restaurant_intent.dart';
import 'restaurant_forms.dart';
import 'restaurant_recovery.dart';

class RestaurantManagement extends StatefulWidget {
  const RestaurantManagement({
    super.key,
    required this.intent,
    required this.section,
  });
  final RestaurantIntent intent;
  final String section;
  @override
  State<RestaurantManagement> createState() => _ManagementState();
}

class _ManagementState extends State<RestaurantManagement> {
  Map data = {};
  String? message;
  bool busy = false;
  WindowsHost get host => widget.intent.host;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() => busy = true);
    try {
      data = await host.call(switch (widget.section) {
        'Bons de production' => HostCommand.restoTickets,
        'Registre' => HostCommand.restoRegister,
        'Remboursements' => HostCommand.restoSettledSales,
        _ => HostCommand.restaurantView,
      });
      message = data['blocker'] as String?;
    } catch (e) {
      message = '$e';
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> act(HostCommand command, Map<String, dynamic> args) async {
    if (busy) return;
    setState(() => busy = true);
    final result = await restaurantRun(context, widget.intent, command, args);
    if (mounted) {
      await load();
      if (mounted && result != null) {
        setState(
          () => message = command == HostCommand.restoRefund
              ? 'Remboursement enregistré : ${result['amount_label'] ?? ''}. Ne remboursez qu’une fois.'
              : 'Action enregistrée.',
        );
      }
    }
  }

  Future<void> refund(Map sale, bool cancel) async {
    try {
      final entered = await restaurantForm(
        context,
        cancel
            ? 'Annuler la vente ${sale['number']}'
            : 'Retour ${sale['number']}',
        {
          if (!cancel)
            for (final l in (sale['lines'] as List).cast<Map>())
              '${l['line_uuid']}':
                  '${l['label']} (reste ${l['remaining_label']})',
          'reason': 'Motif (3 à 500 caractères)',
        },
      );
      if (entered == null) return;
      final args = <String, dynamic>{
        'sale_uuid': sale['sale_uuid'],
        'type': cancel ? 'annulation' : 'retour',
        'reason': entered['reason'],
        'lines': {
          for (final e in entered.entries)
            if (e.key != 'reason' && e.value.isNotEmpty) e.key: e.value,
        },
      };
      final preview = await host.call(
        HostCommand.restoRefundPreview,
        arguments: args,
      );
      if (!mounted) return;
      if (preview['blocker'] != null) {
        throw HostFailure('refund_blocked', '${preview['blocker']}');
      }
      final approval = await restaurantApproval(context, host, 'refund', args);
      if (approval == null || !mounted) return;
      final yes = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Confirmer le remboursement'),
          content: Text('${preview['amount_label']}'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Rembourser'),
            ),
          ],
        ),
      );
      if (yes == true) {
        await act(HostCommand.restoRefund, {...args, ...approval});
      }
    } catch (e) {
      if (mounted) setState(() => message = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => Dialog.fullscreen(
    child: Scaffold(
      appBar: AppBar(
        title: Text(widget.section),
        actions: [
          IconButton(
            onPressed: busy ? null : load,
            icon: const Icon(Icons.refresh),
            tooltip: 'Actualiser',
          ),
        ],
      ),
      body: Column(
        children: [
          if (busy) const LinearProgressIndicator(),
          if (message != null)
            Padding(padding: const EdgeInsets.all(16), child: Text(message!)),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (widget.section == 'Bons de production') ...[
                  const Text(
                    '« Transmis » signifie accepté par le transport. Vérifiez physiquement le papier avant de solder un bon incertain.',
                  ),
                  for (final t in (data['tickets'] as List? ?? []).cast<Map>())
                    Card(
                      child: ListTile(
                        title: Text(
                          '${t['number']} · ${t['station_name']} · ${t['state']}',
                        ),
                        subtitle: Text(
                          '${t['order_number']} · ${t['table'] ?? ''}',
                        ),
                        trailing: PopupMenuButton<String>(
                          enabled: !busy,
                          onSelected: (action) async {
                            if (action == 'duplicate') {
                              final answer = await restaurantForm(
                                context,
                                'Duplicata du bon ${t['number']}',
                                {'reason': 'Motif de réimpression'},
                              );
                              if (answer != null) {
                                await act(HostCommand.restoDuplicateTicket, {
                                  'ticket_uuid': t['ticket_uuid'],
                                  ...answer,
                                });
                              }
                            } else {
                              await act(HostCommand.restoVerifyTicket, {
                                'ticket_uuid': t['ticket_uuid'],
                                'printed': action == 'printed',
                              });
                            }
                          },
                          itemBuilder: (_) => [
                            if (t['state'] == 'a_verifier') ...[
                              const PopupMenuItem(
                                value: 'printed',
                                child: Text('Vérifié : le bon est sorti'),
                              ),
                              const PopupMenuItem(
                                value: 'missing',
                                child: Text('Vérifié : le bon n’est pas sorti'),
                              ),
                            ],
                            const PopupMenuItem(
                              value: 'duplicate',
                              child: Text('Imprimer un duplicata…'),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
                if (widget.section == 'Imprimantes cuisine / bar') ...[
                  const Text(
                    'Adresse locale du poste : IP ou IP:port. Une adresse vide retire la configuration réseau.',
                  ),
                  for (final s in (data['stations'] as List? ?? []).cast<Map>())
                    ListTile(
                      title: Text('${s['name']}'),
                      subtitle: Text(
                        '${s['printer_address'] ?? 'Non configurée'}',
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.edit),
                        onPressed: busy
                            ? null
                            : () async {
                                final answer = await restaurantForm(
                                  context,
                                  '${s['name']}',
                                  {'address': 'Adresse de l’imprimante'},
                                  values: {
                                    'address': '${s['printer_address'] ?? ''}',
                                  },
                                );
                                if (answer != null) {
                                  await act(
                                    HostCommand.restoSetPrinterAddress,
                                    {
                                      'station_uuid':
                                          s['uuid'] ?? s['station_uuid'],
                                      ...answer,
                                    },
                                  );
                                }
                              },
                      ),
                    ),
                ],
                if (widget.section == 'Registre') ...[
                  Text(
                    data['register'] == null
                        ? 'Aucune journée ouverte.'
                        : 'Journée ${(data['register'] as Map)['business_day']} · ${(data['register'] as Map)['open'] == true ? 'ouverte' : 'close'}\nVentes : ${(data['register'] as Map)['sales_total_label']}\n${(data['register'] as Map)['server_message'] ?? ''}',
                  ),
                  FilledButton(
                    onPressed: busy || data['blocker'] != null
                        ? null
                        : () async {
                            final open =
                                (data['register'] as Map?)?['open'] == true;
                            final answer = await restaurantForm(
                              context,
                              open
                                  ? 'Clôturer le registre'
                                  : 'Ouvrir le registre',
                              {'note': 'Note (facultative)'},
                            );
                            if (answer != null) {
                              await act(
                                open
                                    ? HostCommand.restoRegisterClose
                                    : HostCommand.restoRegisterOpen,
                                answer,
                              );
                            }
                          },
                    child: Text(
                      (data['register'] as Map?)?['open'] == true
                          ? 'Clôturer le registre'
                          : 'Ouvrir le registre',
                    ),
                  ),
                ],
                if (widget.section == 'Remboursements')
                  for (final s in (data['sales'] as List? ?? []).cast<Map>())
                    ListTile(
                      title: Text('${s['number']} · ${s['total_label']}'),
                      subtitle: Text('${s['order_number']} · ${s['date']}'),
                      trailing: PopupMenuButton<bool>(
                        enabled:
                            !busy &&
                            data['blocker'] == null &&
                            s['cancelled'] != true,
                        onSelected: (cancel) => refund(s, cancel),
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: false,
                            child: Text('Retour de lignes…'),
                          ),
                          PopupMenuItem(
                            value: true,
                            child: Text('Annuler la vente…'),
                          ),
                        ],
                      ),
                    ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
