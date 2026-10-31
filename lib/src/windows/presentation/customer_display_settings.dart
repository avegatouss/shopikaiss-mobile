import 'package:flutter/material.dart';

import '../platform/customer_display.dart';

class CustomerDisplaySettings extends StatefulWidget {
  const CustomerDisplaySettings({super.key, required this.service});
  final CustomerDisplayService service;
  @override
  State<CustomerDisplaySettings> createState() =>
      _CustomerDisplaySettingsState();
}

class _CustomerDisplaySettingsState extends State<CustomerDisplaySettings> {
  late Map<String, String> values;
  late TextEditingController port;
  List<int> monitors = [];
  bool busy = false;
  String? message;
  @override
  void initState() {
    super.initState();
    values = Map.of(widget.service.settings);
    port = TextEditingController(text: values['port']);
    widget.service
        .monitors()
        .then((v) {
          if (mounted) setState(() => monitors = v);
        })
        .catchError((Object e) {
          if (mounted) setState(() => message = e.toString());
        });
  }

  @override
  void dispose() {
    port.dispose();
    super.dispose();
  }

  Future<void> apply({bool test = false}) async {
    setState(() {
      busy = true;
      message = null;
    });
    values['port'] = port.text.trim().toUpperCase();
    try {
      await widget.service.configure(values);
      final result = test
          ? await widget.service.test()
          : 'Configuration enregistrée.';
      if (mounted) setState(() => message = result);
    } catch (e) {
      if (mounted) setState(() => message = e.toString());
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Divider(),
      const Text(
        'Afficheur client',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      ),
      DropdownButton<String>(
        isExpanded: true,
        value: values['mode'],
        items: const [
          DropdownMenuItem(value: 'off', child: Text('Désactivé')),
          DropdownMenuItem(
            value: 'screen',
            child: Text('Second écran Windows'),
          ),
          DropdownMenuItem(
            value: 'serial',
            child: Text('USB / série · ESC/POS 20 × 2'),
          ),
        ],
        onChanged: busy ? null : (v) => setState(() => values['mode'] = v!),
      ),
      if (values['mode'] == 'screen') ...[
        const Text(
          'Windows doit être en mode Étendre. L’écran de la caisse est exclu.',
        ),
        DropdownButton<String>(
          isExpanded: true,
          hint: const Text('Choisir le second écran'),
          value: monitors.map((m) => '$m').contains(values['monitor'])
              ? values['monitor']
              : null,
          items: monitors
              .map(
                (m) => DropdownMenuItem(
                  value: '$m',
                  child: Text('Écran ${m + 1}'),
                ),
              )
              .toList(),
          onChanged: busy
              ? null
              : (v) => setState(() => values['monitor'] = v!),
        ),
      ],
      if (values['mode'] == 'serial') ...[
        const Text(
          'Uniquement les afficheurs compatibles ESC/POS 20 × 2, exposés en port COM. Les modèles USB HID ou à protocole propriétaire demandent un pilote adapté.',
        ),
        TextField(
          controller: port,
          enabled: !busy,
          decoration: const InputDecoration(labelText: 'Port · exemple COM3'),
        ),
        DropdownButton<String>(
          value: values['baud'],
          items: ['9600', '19200', '38400', '115200']
              .map(
                (v) =>
                    DropdownMenuItem(value: v, child: Text('$v bauds · 8N1')),
              )
              .toList(),
          onChanged: busy ? null : (v) => setState(() => values['baud'] = v!),
        ),
      ],
      if (message != null) Text(message!),
      Wrap(
        spacing: 8,
        children: [
          FilledButton(
            onPressed: busy ? null : apply,
            child: const Text('Appliquer'),
          ),
          OutlinedButton(
            onPressed: busy || values['mode'] == 'off'
                ? null
                : () => apply(test: true),
            child: const Text('Tester sans vente'),
          ),
        ],
      ),
    ],
  );
}
