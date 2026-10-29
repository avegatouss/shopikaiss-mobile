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
                        trailing: const Icon(Icons.play_arrow),
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
