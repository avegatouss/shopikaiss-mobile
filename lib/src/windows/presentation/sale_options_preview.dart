import 'package:flutter/material.dart';

import '../ipc/protocol.dart';
import 'register_controller.dart';

class SaleOptionsPreview extends StatefulWidget {
  const SaleOptionsPreview({super.key, required this.controller});
  final WindowsRegisterController controller;
  @override
  State<SaleOptionsPreview> createState() => _SaleOptionsState();
}

class _SaleOptionsState extends State<SaleOptionsPreview> {
  WindowsRegisterController get c => widget.controller;
  late final TextEditingController discount;
  late final TextEditingController delivery;
  late final TextEditingController note;
  late bool percent;
  String? validation;
  @override
  void initState() {
    super.initState();
    final entry = c.view['global_discount_entry'] as Map?;
    percent = entry?['type'] == 'pourcentage';
    discount = TextEditingController(text: '${entry?['valeur'] ?? 0}');
    delivery = TextEditingController(text: '${c.view['delivery'] ?? 0}');
    note = TextEditingController(text: c.view['note'] as String? ?? '');
  }

  @override
  void dispose() {
    discount.dispose();
    delivery.dispose();
    note.dispose();
    super.dispose();
  }

  bool allowed(String name) =>
      c.ready &&
      !c.busy &&
      c.uncertainOperation == null &&
      (c.capabilities[name] as Map?)?['allowed'] == true;
  String reason(String name) =>
      (c.capabilities[name] as Map?)?['reason'] as String? ??
      'Fonction non disponible sur ce terminal.';
  Future<void> apply(HostCommand command, Map<String, dynamic> args) async {
    setState(() => validation = null);
    await c.command(command, args);
    if (mounted) {
      setState(
        () => validation =
            c.message ?? 'Modification enregistrée dans le panier.',
      );
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) => AlertDialog(
      scrollable: true,
      title: const Text('Client, remise et livraison'),
      content: SizedBox(
        width: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.person_outline),
              title: Text('Client de passage'),
              subtitle: Text(
                'Sélection et création de client : prochain lot du moteur.',
              ),
            ),
            const Divider(),
            const Text('Remise globale'),
            DropdownButton<bool>(
              value: percent,
              items: const [
                DropdownMenuItem(value: false, child: Text('Montant (F CFA)')),
                DropdownMenuItem(value: true, child: Text('Pourcentage (%)')),
              ],
              onChanged: allowed('global_discount')
                  ? (v) => setState(() => percent = v!)
                  : null,
            ),
            TextField(
              controller: discount,
              enabled: allowed('global_discount'),
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Remise globale (0 pour retirer)',
              ),
            ),
            if (!allowed('global_discount') && !c.busy)
              Text(reason('global_discount')),
            TextButton(
              onPressed: allowed('global_discount')
                  ? () {
                      final value = discount.text.trim();
                      final amount = int.tryParse(value);
                      if (!percent && (amount == null || amount < 0)) {
                        setState(
                          () => validation =
                              'Saisissez un montant entier positif.',
                        );
                        return;
                      }
                      apply(
                        HostCommand.setGlobalDiscount,
                        percent ? {'percent': value} : {'amount': amount},
                      );
                    }
                  : null,
              child: const Text('Appliquer la remise globale'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: delivery,
              enabled: allowed('delivery'),
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Frais de livraison (F CFA)',
              ),
            ),
            if (!allowed('delivery') && !c.busy) Text(reason('delivery')),
            TextButton(
              onPressed: allowed('delivery')
                  ? () {
                      final amount = int.tryParse(delivery.text.trim());
                      if (amount == null || amount < 0) {
                        setState(
                          () => validation =
                              'Saisissez un montant entier positif.',
                        );
                        return;
                      }
                      apply(HostCommand.setDelivery, {'amount': amount});
                    }
                  : null,
              child: const Text('Appliquer la livraison'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: note,
              enabled: allowed('note'),
              maxLength: 2000,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Note sur le ticket',
              ),
            ),
            if (!allowed('note') && !c.busy) Text(reason('note')),
            TextButton(
              onPressed: allowed('note')
                  ? () => apply(HostCommand.setNote, {'text': note.text})
                  : null,
              child: const Text('Enregistrer la note'),
            ),
            if (validation != null) Text(validation!),
            Text(
              'À payer : ${c.view['total_label'] ?? '—'}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: c.busy ? null : () => Navigator.pop(context),
          child: const Text('Fermer'),
        ),
      ],
    ),
  );
}
