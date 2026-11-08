import 'package:flutter/material.dart';

import '../ipc/protocol.dart';
import 'register_controller.dart';

class WholesaleButton extends StatelessWidget {
  const WholesaleButton({super.key, required this.controller});
  final WindowsRegisterController controller;
  @override
  Widget build(BuildContext context) {
    final cap = controller.capabilities['wholesale'] as Map?;
    final active = controller.view['wholesale'] == true;
    return Tooltip(
      message: cap?['reason'] as String? ?? 'Changer le tarif du panier',
      child: TextButton.icon(
        icon: const Icon(Icons.price_change_outlined),
        label: Text(
          active
              ? 'Tarif gros · passer au détail'
              : 'Tarif détail · passer au gros',
        ),
        onPressed:
            controller.ready &&
                !controller.busy &&
                controller.uncertainOperation == null &&
                cap?['allowed'] == true
            ? () => controller.command(HostCommand.setWholesale, {
                'active': !active,
              })
            : null,
      ),
    );
  }
}

class LineLotChoice extends StatelessWidget {
  const LineLotChoice({
    super.key,
    required this.controller,
    required this.line,
  });
  final WindowsRegisterController controller;
  final Map<String, dynamic> line;
  @override
  Widget build(BuildContext context) {
    final lots = (line['lots'] as List? ?? []).whereType<Map>().toList();
    final selected = line['lot_uuid'] as String?;
    final selectedExists = lots.any((l) => l['uuid'] == selected);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (line['wholesale'] == true)
          const Text(
            'Prix de gros (panier ou seuil atteint)',
            style: TextStyle(fontSize: 11),
          ),
        if (line['wholesale_refused'] == true)
          Text(
            'Tarif gros refusé pour ce lot : vendez au détail ou par un conditionnement',
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        if (lots.isNotEmpty || selected != null)
          DropdownButton<String>(
            isExpanded: true,
            value: selected ?? '',
            hint: const Text('Lot à vendre'),
            items: [
              const DropdownMenuItem(
                value: '',
                child: Text('Lot à vendre : automatique'),
              ),
              if (selected != null && !selectedExists)
                DropdownMenuItem(
                  value: selected,
                  child: const Text('Lot sélectionné indisponible'),
                ),
              for (final lot in lots)
                DropdownMenuItem(
                  value: lot['uuid'] as String,
                  child: Text(
                    '${lot['label']}${lot['expires_on'] == null ? '' : ' · péremption ${lot['expiry_label'] ?? lot['expires_on']}'}',
                    style: expiredLot(lot['expires_on'], DateTime.now())
                        ? TextStyle(color: Theme.of(context).colorScheme.error)
                        : null,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged:
                controller.ready &&
                    !controller.busy &&
                    controller.uncertainOperation == null
                ? (value) => controller.command(HostCommand.setLineLot, {
                    'line_id': line['id'],
                    'lot_uuid': value == '' ? null : value,
                  })
                : null,
          ),
        if (line['lot_label'] != null)
          Text(
            'Lot : ${line['lot_label']}',
            style: const TextStyle(fontSize: 11),
          ),
        if (expiredLot(line['lot_expires_on'], DateTime.now()) ||
            lots.any(
              (lot) =>
                  lot['uuid'] == selected &&
                  expiredLot(lot['expires_on'], DateTime.now()),
            ))
          Text(
            'Lot périmé — vérifiez le produit.',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    );
  }
}

bool expiredLot(Object? value, DateTime now) {
  final date = value is String ? DateTime.tryParse(value) : null;
  return date != null &&
      DateTime(
        date.year,
        date.month,
        date.day,
      ).isBefore(DateTime(now.year, now.month, now.day));
}
