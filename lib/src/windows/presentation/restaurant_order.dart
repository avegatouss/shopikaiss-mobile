import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../ipc/protocol.dart';
import '../platform/receipt_printing.dart';

/// All order versions and amounts come from the serialized restaurant engine.
class RestaurantOrderDialog extends StatefulWidget {
  const RestaurantOrderDialog({
    super.key,
    required this.host,
    required this.order,
    required this.sendLabel,
  });
  final WindowsHost host;
  final Map order;
  final String sendLabel;
  @override
  State<RestaurantOrderDialog> createState() => _RestaurantOrderState();
}

class _RestaurantOrderState extends State<RestaurantOrderDialog> {
  late Map order = widget.order;
  bool busy = false, uncertain = false;
  bool reviewed = false;
  String? message;
  List<Map> products = [];
  bool hasMore = false;
  final search = TextEditingController();
  int searchGeneration = 0;

  @override
  void initState() {
    super.initState();
    loadProducts();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> loadProducts() async {
    final generation = ++searchGeneration;
    try {
      await widget.host.call(
        HostCommand.search,
        arguments: {'query': search.text},
      );
      final view = await widget.host.call(HostCommand.view);
      if (mounted && generation == searchGeneration) {
        setState(() {
          products = (view['products'] as List).cast<Map>();
          hasMore = view['has_more'] == true;
        });
      }
    } catch (e) {
      if (mounted) setState(() => message = '$e');
    }
  }

  Future<void> moreProducts() async {
    try {
      final view = await widget.host.call(HostCommand.moreProducts);
      if (mounted) {
        setState(() {
          products = (view['products'] as List).cast<Map>();
          hasMore = view['has_more'] == true;
        });
      }
    } catch (e) {
      if (mounted) setState(() => message = '$e');
    }
  }

  Future<void> mutate(
    HostCommand command,
    Map<String, dynamic> arguments,
  ) async {
    if (busy || uncertain) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final result = await widget.host.call(
        command,
        arguments: {'order_uuid': order['order_uuid'], ...arguments},
        operationId: const Uuid().v4(),
      );
      if (result['order'] is Map) order = result['order'] as Map;
      if (result['prebill_lines'] is List) {
        message = await ReceiptPrinting.printLines(
          (result['prebill_lines'] as List).cast<String>(),
        );
      }
    } catch (e) {
      uncertain = e is! HostFailure || e.outcomeUnknown;
      reviewed = false;
      message = uncertain
          ? 'Résultat à vérifier. Relisez la commande avant toute nouvelle action.'
          : e.toString();
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> reload() async {
    setState(() => busy = true);
    try {
      final result = await widget.host.call(
        HostCommand.restoOrder,
        arguments: {'order_uuid': order['order_uuid']},
      );
      order = result['order'] as Map;
      reviewed = true;
      // Human inspection is required after an uncertain non-financial mutation.
      message = uncertain
          ? 'Commande relue. Vérifiez les lignes et les bons avant de reprendre.'
          : null;
    } catch (e) {
      message = '$e';
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> quantity(Map line) async {
    final input = TextEditingController(text: '${line['quantity']}');
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${line['label']}'),
        content: TextField(
          controller: input,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Quantité'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text),
            child: const Text('Appliquer'),
          ),
        ],
      ),
    );
    input.dispose();
    if (value != null) {
      await mutate(HostCommand.restoEditLines, {
        'quantities': {line['line_uuid']: value},
      });
    }
  }

  @override
  Widget build(BuildContext context) => Dialog.fullscreen(
    child: Scaffold(
      appBar: AppBar(
        title: Text(
          '${order['table_name'] ?? order['channel_name'] ?? 'Commande'} · ${order['local_number']}',
        ),
        actions: [
          IconButton(
            onPressed: busy ? null : reload,
            tooltip: 'Relire la commande',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          if (busy) const LinearProgressIndicator(),
          if (message != null)
            Padding(padding: const EdgeInsets.all(12), child: Text(message!)),
          if (uncertain)
            TextButton(
              onPressed: busy || !reviewed
                  ? null
                  : () => setState(() {
                      uncertain = false;
                      message = null;
                    }),
              child: const Text('J’ai vérifié la commande et les bons'),
            ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: TextField(
                          controller: search,
                          onSubmitted: (_) => loadProducts(),
                          decoration: InputDecoration(
                            labelText: 'Rechercher un produit',
                            suffixIcon: IconButton(
                              onPressed: loadProducts,
                              icon: const Icon(Icons.search),
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: ListView.builder(
                          itemCount: products.length,
                          itemBuilder: (context, index) {
                            final product = products[index];
                            return ListTile(
                              title: Text('${product['name']}'),
                              subtitle: Text('${product['price_label']}'),
                              trailing: IconButton(
                                tooltip: 'Ajouter',
                                icon: const Icon(Icons.add_circle_outline),
                                onPressed: busy || uncertain
                                    ? null
                                    : () => mutate(HostCommand.restoEditLines, {
                                        'added': [
                                          {
                                            'product_id': product['id'],
                                            'quantity': '1',
                                          },
                                        ],
                                      }),
                              ),
                            );
                          },
                        ),
                      ),
                      if (hasMore)
                        TextButton(
                          onPressed: moreProducts,
                          child: const Text('Afficher plus'),
                        ),
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: ListView(
                          children: [
                            for (final line
                                in (order['lines'] as List).cast<Map>())
                              ListTile(
                                title: Text(
                                  '${line['quantity_label']} × ${line['label']}',
                                ),
                                subtitle: Text(
                                  '${line['state_label']}\n${line['comment'] ?? ''}',
                                ),
                                trailing: Text('${line['total_label']}'),
                                onTap:
                                    busy ||
                                        uncertain ||
                                        line['sent'] == true ||
                                        line['active'] != true
                                    ? null
                                    : () => quantity(line),
                              ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(
                          '${order['payable_label']}',
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            FilledButton.icon(
                              onPressed: busy || uncertain
                                  ? null
                                  : () => mutate(HostCommand.restoSend, {}),
                              icon: const Icon(Icons.send),
                              label: Text(widget.sendLabel),
                            ),
                            OutlinedButton.icon(
                              onPressed: busy || uncertain
                                  ? null
                                  : () => mutate(HostCommand.restoPrebill, {}),
                              icon: const Icon(Icons.receipt_long),
                              label: const Text('Préfacture'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
