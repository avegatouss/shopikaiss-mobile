import 'package:flutter/material.dart';

import '../ipc/protocol.dart';

Future<Map<String, String>?> restaurantForm(
  BuildContext context,
  String title,
  Map<String, String> fields, {
  Map<String, String> values = const {},
  Set<String> secret = const {},
}) async {
  final inputs = {
    for (final key in fields.keys)
      key: TextEditingController(text: values[key] ?? ''),
  };
  final route = DialogRoute<Map<String, String>>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final entry in fields.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: TextField(
                    controller: inputs[entry.key],
                    obscureText: secret.contains(entry.key),
                    decoration: InputDecoration(
                      labelText: entry.value,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, {
            for (final e in inputs.entries) e.key: e.value.text.trim(),
          }),
          child: const Text('Continuer'),
        ),
      ],
    ),
  );
  final result = await Navigator.of(context).push(route);
  await route.completed;
  for (final c in inputs.values) {
    c.dispose();
  }
  return result;
}

Future<Map?> restaurantChoose(
  BuildContext context,
  String title,
  List<Map> items, {
  String label = 'name',
}) => showDialog<Map>(
  context: context,
  builder: (context) => SimpleDialog(
    title: Text(title),
    children: [
      if (items.isEmpty)
        const Padding(
          padding: EdgeInsets.all(20),
          child: Text('Aucun choix disponible.'),
        ),
      for (final item in items)
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, item),
          child: Text('${item[label]}'),
        ),
    ],
  ),
);

Future<Map<String, dynamic>?> restaurantApproval(
  BuildContext context,
  WindowsHost host,
  String gesture,
  Map<String, dynamic> arguments,
) async {
  final info = await host.call(
    HostCommand.restoApprovalInfo,
    arguments: {'gesture': gesture, ...arguments},
  );
  if (info['required'] != true) return <String, dynamic>{};
  if (!context.mounted) return null;
  final person = await restaurantChoose(
    context,
    'Responsable · ${info['amount_label'] ?? ''}',
    (info['approvers'] as List? ?? []).cast<Map>(),
  );
  if (person == null || !context.mounted) return null;
  final entered = await restaurantForm(
    context,
    'Autorisation de ${person['name']}',
    {'code': 'Code responsable (8 chiffres)'},
    secret: {'code'},
  );
  if (entered == null) return null;
  return {
    'approval': {'approver_id': person['id'], 'code': entered['code']},
  };
}

Future<Map?> restaurantCustomer(BuildContext context, WindowsHost host) async {
  final search = await restaurantForm(context, 'Client (facultatif)', {
    'query': 'Nom ou téléphone — vide : client de passage',
  });
  if (search == null || search['query']!.isEmpty) return null;
  final found = await host.call(HostCommand.searchCustomers, arguments: search);
  if (!context.mounted) return null;
  return restaurantChoose(
    context,
    'Choisir le client',
    (found['customers'] as List? ?? []).cast<Map>(),
  );
}
