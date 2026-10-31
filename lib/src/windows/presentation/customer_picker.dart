import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../ipc/protocol.dart';
import 'register_controller.dart';

String customerLabel(WindowsRegisterController c) =>
    (c.view['customer'] as Map?)?['name'] as String? ?? 'Client de passage';

class CustomerPicker extends StatefulWidget {
  const CustomerPicker({super.key, required this.controller});
  final WindowsRegisterController controller;
  @override
  State<CustomerPicker> createState() => _CustomerPickerState();
}

class _CustomerPickerState extends State<CustomerPicker> {
  WindowsRegisterController get c => widget.controller;
  final query = TextEditingController();
  final name = TextEditingController();
  final phone = TextEditingController();
  Timer? timer;
  int generation = 0;
  bool loading = false;
  bool creating = false;
  String? error;
  List<Map<String, dynamic>> customers = [];

  bool allowed(String capability) =>
      c.ready &&
      !c.busy &&
      c.uncertainOperation == null &&
      (c.capabilities[capability] as Map?)?['allowed'] == true;

  @override
  void initState() {
    super.initState();
    search();
  }

  Future<void> search() async {
    final request = ++generation;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await c.host.call(
        HostCommand.searchCustomers,
        arguments: {'query': query.text.trim()},
      );
      if (!mounted || request != generation) return;
      setState(
        () => customers = (result['customers'] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .toList(),
      );
    } catch (e) {
      if (!mounted || request != generation) return;
      setState(
        () => error = e is HostFailure
            ? e.message
            : 'Recherche indisponible. Réessayez.',
      );
    } finally {
      if (mounted && request == generation) setState(() => loading = false);
    }
  }

  Future<void> select(Map<String, dynamic> customer) async {
    final result = await c.command(HostCommand.setCustomer, customer);
    if (!mounted) return;
    if (result != null) {
      Navigator.pop(context);
    } else {
      setState(() => error = c.message ?? 'Sélection indisponible.');
    }
  }

  Future<void> create() async {
    if (name.text.trim().isEmpty) {
      setState(() => error = 'Saisissez le nom du client.');
      return;
    }
    final result = await c.command(HostCommand.createCustomer, {
      'name': name.text.trim(),
      if (phone.text.trim().isNotEmpty) 'phone': phone.text.trim(),
    }, operationId: const Uuid().v4());
    if (!mounted) return;
    if (result == null) {
      // A lost response may hide a completed creation. Return to search,
      // rather than offering a blind retry that could duplicate the client.
      setState(() {
        creating = false;
        error =
            '${c.message ?? 'Création non confirmée.'} Recherchez le client avant de le créer à nouveau.';
      });
      return;
    }
    name.clear();
    phone.clear();
    setState(() {
      creating = false;
      customers = [result];
    });
    await select(result);
  }

  @override
  void dispose() {
    timer?.cancel();
    generation++;
    query.dispose();
    name.dispose();
    phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) => PopScope(
      canPop: !c.busy,
      child: AlertDialog(
        scrollable: true,
        title: Text(creating ? 'Créer un client' : 'Sélectionner un client'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (creating) ...[
                TextField(
                  controller: name,
                  enabled: !c.busy,
                  maxLength: 160,
                  decoration: const InputDecoration(labelText: 'Nom du client'),
                ),
                TextField(
                  controller: phone,
                  enabled: !c.busy,
                  maxLength: 40,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Téléphone (facultatif)',
                  ),
                ),
                const Text(
                  'Le client sera conservé localement puis synchronisé et sélectionné dans ce panier.',
                ),
              ] else ...[
                Text('Client actuel : ${customerLabel(c)}'),
                TextField(
                  controller: query,
                  maxLength: 100,
                  decoration: const InputDecoration(
                    labelText: 'Rechercher par nom ou téléphone',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (_) {
                    timer?.cancel();
                    generation++;
                    setState(() {
                      customers = [];
                      loading = true;
                    });
                    timer = Timer(const Duration(milliseconds: 250), search);
                  },
                ),
                if (loading) const LinearProgressIndicator(),
                TextButton.icon(
                  onPressed: allowed('customer') ? () => select({}) : null,
                  icon: const Icon(Icons.person_outline),
                  label: const Text('Client de passage'),
                ),
                if (!loading && customers.isEmpty)
                  const Text('Aucun client trouvé dans le répertoire local.'),
                SizedBox(
                  height: 240,
                  child: ListView.builder(
                    itemCount: customers.length,
                    itemBuilder: (_, i) {
                      final customer = customers[i];
                      return ListTile(
                        title: Text(customer['name'] as String? ?? ''),
                        subtitle: Text(
                          [
                                customer['phone'],
                                if (customer['pending'] == true)
                                  'À synchroniser',
                              ]
                              .whereType<String>()
                              .where((s) => s.isNotEmpty)
                              .join(' · '),
                        ),
                        onTap: allowed('customer')
                            ? () => select(customer)
                            : null,
                      );
                    },
                  ),
                ),
              ],
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (!allowed(creating ? 'customer_create' : 'customer') &&
                  !c.busy)
                Text(
                  (c.capabilities[creating ? 'customer_create' : 'customer']
                              as Map?)?['reason']
                          as String? ??
                      'Fonction indisponible sur ce terminal.',
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: c.busy ? null : () => Navigator.pop(context),
            child: const Text('Fermer'),
          ),
          if (creating)
            TextButton(
              onPressed: c.busy ? null : () => setState(() => creating = false),
              child: const Text('Retour à la liste'),
            ),
          FilledButton.icon(
            onPressed: allowed('customer_create')
                ? (creating
                      ? create
                      : () => setState(() {
                          creating = true;
                          error = null;
                        }))
                : null,
            icon: Icon(creating ? Icons.check : Icons.person_add_alt),
            label: Text(creating ? 'Créer et sélectionner' : 'Nouveau client'),
          ),
        ],
      ),
    ),
  );
}
