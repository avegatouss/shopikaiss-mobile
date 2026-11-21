import 'package:flutter/material.dart';

/// Presentation values only. The adapter will translate the published contract.
enum CatalogueChangeStatus {
  local,
  pending,
  sent,
  conflict,
  refused,
  linked,
  integrated,
}

class CatalogueChangeItem {
  const CatalogueChangeItem({
    required this.id,
    required this.name,
    required this.status,
    required this.creation,
    this.reason,
  });
  final String id;
  final String name;
  final CatalogueChangeStatus status;
  final bool creation;
  final String? reason;
}

/// Never retries a mutation or resolves a conflict from a display action.
class CatalogueChangesPanel extends StatelessWidget {
  const CatalogueChangesPanel({
    super.key,
    required this.items,
    this.onOpenArbitration,
  });
  final List<CatalogueChangeItem> items;
  final VoidCallback? onOpenArbitration;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Center(
        child: Text('Aucune modification de produit à afficher.'),
      );
    }
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final item = items[index];
        final label = switch (item.status) {
          CatalogueChangeStatus.local => 'Local',
          CatalogueChangeStatus.pending => 'À synchroniser',
          CatalogueChangeStatus.sent => 'Confirmation attendue',
          CatalogueChangeStatus.conflict => 'Arbitrage nécessaire',
          CatalogueChangeStatus.refused => 'Refusé',
          CatalogueChangeStatus.linked => 'Rattaché à un produit existant',
          CatalogueChangeStatus.integrated => 'Intégré',
        };
        return Card(
          key: ValueKey(item.id),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.name, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    Text(item.creation ? 'Création' : 'Modification'),
                    Text(label),
                  ],
                ),
                if (item.reason?.trim().isNotEmpty == true) ...[
                  const SizedBox(height: 8),
                  Text(item.reason!),
                ],
                if (item.status == CatalogueChangeStatus.conflict) ...[
                  const SizedBox(height: 12),
                  if (onOpenArbitration != null)
                    OutlinedButton.icon(
                      onPressed: onOpenArbitration,
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Ouvrir l’arbitrage en ligne'),
                    )
                  else
                    const Text(
                      'Arbitrage à effectuer dans la gestion en ligne.',
                    ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
