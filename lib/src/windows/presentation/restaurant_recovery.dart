import 'package:flutter/material.dart';

import '../platform/restaurant_intent.dart';
import '../ipc/protocol.dart';
import 'restaurant_forms.dart';

Future<Map<String, dynamic>?> _retry(
  BuildContext context,
  RestaurantIntent intent,
) async {
  try {
    return await intent.retry();
  } on HostFailure catch (e) {
    if (e.code != 'autorisation_requise' || !context.mounted) rethrow;
    final gesture = const {
      'restoCancelLine': 'cancel_line',
      'restoCancel': 'cancel_order',
      'restoOffer': 'offer',
      'restoDiscountLine': 'discount_line',
      'restoDiscountOrder': 'discount_order',
      'restoStaffLines': 'staff',
      'restoRefund': 'refund',
    }[intent.pending?['command']];
    if (gesture == null) rethrow;
    final approved = await restaurantApproval(
      context,
      intent.host,
      gesture,
      Map<String, dynamic>.from(intent.pending!['arguments'] as Map),
    );
    if (approved == null) return null;
    return intent.retry(
      approval: approved['approval'] as Map<String, dynamic>?,
    );
  }
}

/// Recovery is explicit. Refreshing a view never replays a write.
Future<bool> restaurantRecovery(
  BuildContext context,
  RestaurantIntent intent,
) async {
  await intent.load();
  if (intent.pending == null) return true;
  if (!context.mounted) return false;
  var reviewed = false;
  var busy = false;
  var message =
      'Une action restaurant reste à vérifier. Aucun nouvel identifiant ne sera créé.';
  final done = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => StatefulBuilder(
      builder: (context, update) {
        final record = intent.pending;
        return AlertDialog(
          title: const Text('Résultat à vérifier'),
          content: SizedBox(
            width: 600,
            child: SingleChildScrollView(child: Text(message)),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(context, false),
              child: Text(record == null ? 'Fermer' : 'Fermer sans effacer'),
            ),
            TextButton(
              onPressed: busy || record == null
                  ? null
                  : () async {
                      update(() => busy = true);
                      try {
                        final args = record['arguments'] as Map;
                        final view = args['order_uuid'] != null
                            ? await intent.host.call(
                                HostCommand.restoOrder,
                                arguments: {'order_uuid': args['order_uuid']},
                              )
                            : await intent.host.call(
                                HostCommand.restaurantView,
                              );
                        final order = view['order'] as Map?;
                        final tickets = await intent.host.call(
                          HostCommand.restoTickets,
                          arguments: {
                            if (args['order_uuid'] != null)
                              'order_uuid': args['order_uuid'],
                          },
                        );
                        message = order == null
                            ? 'Salle relue : ${(view['orders'] as List? ?? []).map((o) => '${o['local_number']} — ${o['table_name'] ?? o['channel_name']} — ${o['payable_label']}').join('\n')}'
                            : '${order['local_number']} · ${order['status']} · ${order['payable_label']}\n${(order['lines'] as List).map((l) => '${l['quantity_label']} × ${l['label']} · ${l['state_label']}').join('\n')}';
                        message +=
                            '\nBons : ${(tickets['tickets'] as List? ?? []).map((t) => '${t['number']} ${t['state']}').join(', ')}';
                        reviewed = true;
                      } catch (e) {
                        message = '$e';
                      }
                      if (context.mounted) update(() => busy = false);
                    },
              child: const Text('Relire la commande et les bons'),
            ),
            FilledButton(
              onPressed: busy || record == null
                  ? null
                  : () async {
                      update(() => busy = true);
                      try {
                        final result = await _retry(context, intent);
                        if (result == null) {
                          if (context.mounted) update(() => busy = false);
                          return;
                        }
                        if (context.mounted) {
                          message =
                              'Action retrouvée : ${result['number'] ?? result['operation_id'] ?? 'confirmée'}. Vous pouvez consulter le reçu dans l’historique.';
                          Navigator.pop(context, true);
                        }
                      } catch (e) {
                        message = intent.pending == null
                            ? '$e\nLe moteur confirme que cette action n’a pas été enregistrée. Fermez puis relisez la commande avant de corriger.'
                            : '$e\nLe même identifiant reste conservé. Si une autorisation est requise, relisez avant de reprendre le geste.';
                      }
                      if (context.mounted) update(() => busy = false);
                    },
              child: const Text('Réessayer avec le même identifiant'),
            ),
            if (record != null &&
                !['restoSettle', 'restoRefund'].contains(record['command']))
              TextButton(
                onPressed: busy || !reviewed
                    ? null
                    : () async {
                        await intent.acknowledgeReviewed();
                        if (context.mounted) Navigator.pop(context, true);
                      },
                child: const Text('J’ai vérifié : reprendre sans rejouer'),
              ),
          ],
        );
      },
    ),
  );
  return done == true;
}

Future<Map<String, dynamic>?> restaurantRun(
  BuildContext context,
  RestaurantIntent intent,
  HostCommand command,
  Map<String, dynamic> args, {
  Map<String, dynamic>? preparation,
}) async {
  try {
    await intent.load();
    final recovering = intent.pending != null;
    if (!context.mounted) return null;
    if (!await restaurantRecovery(context, intent)) return null;
    // Resolving an old intent never automatically executes the new gesture.
    if (recovering) return null;
    return await intent.execute(command, args, preparation: preparation);
  } catch (e) {
    if (context.mounted) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            intent.pending != null ? 'Résultat à vérifier' : 'Action refusée',
          ),
          content: Text(
            intent.pending != null
                ? '$e\nL’identifiant est conservé. Utilisez la reprise avant toute nouvelle action.'
                : '$e',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Fermer'),
            ),
          ],
        ),
      );
    }
    return null;
  }
}
