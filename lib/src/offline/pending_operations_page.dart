import 'package:flutter/material.dart';

import 'engine.dart';
import 'models.dart';
import 'money.dart';

/// Journal des opérations hors ligne du terminal : en attente d'envoi, transmises (intégrées ou à arbitrer par la
/// boutique), refusées. Les opérations transmises restent visibles 30 jours.
class PendingOperationsPage extends StatefulWidget {
  const PendingOperationsPage({super.key, required this.engine, this.onReprint});

  final OfflineEngine engine;

  /// Réimpression d'un ticket de vente (caisse hors ligne) ; absent depuis les réglages.
  final Future<void> Function(OfflineOperation operation)? onReprint;

  @override
  State<PendingOperationsPage> createState() => _PendingOperationsPageState();
}

class _PendingOperationsPageState extends State<PendingOperationsPage> {
  late Future<List<OfflineOperation>> _operations = widget.engine.history();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Opérations hors ligne'),
        actions: [
          IconButton(
            tooltip: 'Envoyer maintenant',
            onPressed: () async {
              final report = await widget.engine.sync();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    report.reachable
                        ? '${report.sent} envoyée(s), ${report.integrated} intégrée(s), ${report.pending} à arbitrer, ${report.refused} refusée(s).'
                        : (report.message ?? 'Boutique injoignable.'),
                  ),
                ),
              );
              setState(() => _operations = widget.engine.history());
            },
            icon: const Icon(Icons.sync),
          ),
        ],
      ),
      body: FutureBuilder<List<OfflineOperation>>(
        future: _operations,
        builder: (context, snapshot) {
          final items = (snapshot.data ?? const <OfflineOperation>[]).reversed.toList();
          if (snapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (items.isEmpty) return const Center(child: Text('Aucune opération hors ligne.'));
          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final o = items[index];
              final (icon, color, label) = switch ((o.status, o.serverStatus)) {
                (OperationStatus.pending, _) => (Icons.schedule, Colors.orange, 'En attente d’envoi'),
                (OperationStatus.refused, _) => (Icons.error, Colors.red, 'Refusée : ${o.message ?? ''}'),
                (_, 'a_arbitrer') => (Icons.gavel, Colors.amber.shade800, 'Reçue, à arbitrer par la boutique : ${o.message ?? ''}'),
                (_, 'ecartee') => (Icons.block, Colors.grey, 'Écartée par la boutique'),
                _ => (Icons.check_circle, Colors.green, 'Intégrée${o.serverNumber != null ? ' : vente ${o.serverNumber}' : ''}'),
              };
              final d = o.date;
              String two(int v) => v.toString().padLeft(2, '0');
              return ListTile(
                leading: Icon(icon, color: color),
                title: Text(o.isSale ? 'Vente ${o.number}' : 'Ouverture de session (fond ${formatFcfa((o.content['fond'] as num?)?.toInt() ?? 0)})'),
                subtitle: Text('${two(d.day)}/${two(d.month)} ${two(d.hour)}:${two(d.minute)} · $label'),
                trailing: !o.isSale
                    ? null
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(formatFcfa(o.total), style: const TextStyle(fontWeight: FontWeight.w600)),
                          if (widget.onReprint != null)
                            IconButton(tooltip: 'Réimprimer le ticket', icon: const Icon(Icons.print), onPressed: () => widget.onReprint!(o)),
                        ],
                      ),
              );
            },
          );
        },
      ),
    );
  }
}
