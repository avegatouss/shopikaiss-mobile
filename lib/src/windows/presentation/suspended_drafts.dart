import 'package:flutter/material.dart';

import '../ipc/protocol.dart';
import 'register_controller.dart';

class SuspendedDraftsDialog extends StatefulWidget {
  const SuspendedDraftsDialog({super.key, required this.controller});
  final WindowsRegisterController controller;
  @override
  State<SuspendedDraftsDialog> createState() => _SuspendedDraftsDialogState();
}

class _SuspendedDraftsDialogState extends State<SuspendedDraftsDialog> {
  List<Map<String, dynamic>> items = [];
  bool busy = true;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.controller.host.call(HostCommand.drafts);
      if (mounted) {
        items = (result['items'] as List).cast<Map<String, dynamic>>();
      }
    } catch (_) {
      if (mounted) error = 'Impossible de lire les paniers locaux. Réessayez.';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> resume(Map<String, dynamic> item) async {
    setState(() => busy = true);
    await widget.controller.command(HostCommand.resumeDraft, {
      'draft_id': item['draft_id'],
    });
    if (!mounted) return;
    if (widget.controller.message == null) {
      Navigator.pop(context);
    } else {
      setState(() {
        busy = false;
        error = widget.controller.message;
      });
    }
  }

  Future<void> remove(Map<String, dynamic> item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Supprimer ce panier en attente ?'),
        content: Text(
          '${item['summary'] ?? 'Panier'}\nCette action retire ce panier local. Aucune vente ne sera annulée.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Conserver'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Supprimer ce panier'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    final c = widget.controller;
    if (!c.ready || c.busy || c.uncertainOperation != null) return;
    setState(() => busy = true);
    await c.command(HostCommand.deleteDraft, {'draft_id': item['draft_id']});
    if (!mounted) return;
    if (c.message != null) {
      setState(() {
        error = c.message;
        busy = false;
      });
    } else {
      await load();
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Paniers en attente sur ce poste'),
    content: SizedBox(
      width: 560,
      height: 340,
      child: busy
          ? const Center(child: CircularProgressIndicator())
          : error != null
          ? Center(child: Text(error!))
          : items.isEmpty
          ? const Center(child: Text('Aucun panier en attente.'))
          : Column(
              children: [
                const Text(
                  'À la reprise, le panier courant sera conservé en attente.',
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index];
                      return ListTile(
                        title: Text('${item['summary'] ?? "Panier"}'),
                        subtitle: Text(
                          '${item['lines_count']} ligne(s) · ${item['total_label'] ?? "—"}',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Reprendre ce panier',
                              icon: const Icon(Icons.play_arrow),
                              onPressed: () => resume(item),
                            ),
                            IconButton(
                              tooltip: 'Supprimer ce panier en attente',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => remove(item),
                            ),
                          ],
                        ),
                        onTap: () => resume(item),
                      );
                    },
                  ),
                ),
              ],
            ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : load,
        child: const Text('Actualiser'),
      ),
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('Fermer'),
      ),
    ],
  );
}
