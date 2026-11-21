import 'package:flutter/material.dart';

import '../ipc/protocol.dart';
import '../platform/restaurant_intent.dart';
import 'restaurant_recovery.dart';
import 'restaurant_forms.dart';

class RestaurantPayment extends StatefulWidget {
  const RestaurantPayment({
    super.key,
    required this.intent,
    required this.order,
  });
  final RestaurantIntent intent;
  final Map order;
  @override
  State<RestaurantPayment> createState() => _RestaurantPaymentState();
}

class _Payment {
  _Payment(this.method, int amount, this.share)
    : amount = TextEditingController(text: '$amount');
  String method;
  final int share;
  final TextEditingController amount;
  final received = TextEditingController();
  final reference = TextEditingController();
  void dispose() {
    amount.dispose();
    received.dispose();
    reference.dispose();
  }
}

class _RestaurantPaymentState extends State<RestaurantPayment> {
  Map<String, dynamic>? plan;
  Map<String, dynamic>? preparation;
  List<_Payment> rows = [];
  String? message;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    prepare('full');
  }

  @override
  void dispose() {
    for (final r in rows) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> prepare(String mode) async {
    if (busy) return;
    try {
      final args = <String, dynamic>{
        'order_uuid': widget.order['order_uuid'],
        'mode': mode,
      };
      if (mode != 'full') {
        final fields = mode == 'shares'
            ? {'shares': 'Nombre de parts'}
            : {
                for (final l in (widget.order['lines'] as List).cast<Map>())
                  if (l['active'] == true)
                    '${l['line_uuid']}': '${l['label']} (reste ${l['rest']})',
              };
        final values = await restaurantForm(
          context,
          'Répartition du règlement',
          fields,
        );
        if (values == null) return;
        if (mode == 'shares') {
          args['shares'] = int.tryParse(values['shares']!);
        } else {
          args['items'] = {
            for (final e in values.entries)
              if (e.value.isNotEmpty) e.key: e.value,
          };
        }
      }
      setState(() => busy = true);
      final value = await widget.intent.host.call(
        HostCommand.restoPrepareSettlement,
        arguments: args,
      );
      final methods = (value['methods'] as List).cast<Map>();
      if (methods.isEmpty && value['payable'] != 0) {
        throw StateError('Aucun moyen de paiement disponible.');
      }
      for (final row in rows) {
        row.dispose();
      }
      rows = [];
      plan = value;
      preparation = args;
      final shares = (value['shares'] as List).cast<Map>();
      if (value['payable'] != 0) {
        if (shares.isEmpty) {
          rows.add(
            _Payment(
              methods.first['code'] as String,
              value['payable'] as int,
              0,
            ),
          );
        } else {
          for (final s in shares) {
            rows.add(
              _Payment(
                methods.first['code'] as String,
                s['amount'] as int,
                s['index'] as int,
              ),
            );
          }
        }
      }
      message = null;
    } catch (e) {
      message = '$e';
    }
    if (mounted) setState(() => busy = false);
  }

  int remaining(int share) {
    final shares = (plan!['shares'] as List).cast<Map>();
    final due = shares.isEmpty
        ? plan!['payable'] as int
        : shares.firstWhere((s) => s['index'] == share)['amount'] as int;
    return due -
        rows
            .where((r) => r.share == share)
            .fold(0, (n, r) => n + (int.tryParse(r.amount.text) ?? 0));
  }

  Future<void> pay() async {
    if (busy || plan == null) return;
    setState(() => busy = true);
    try {
      final payments = [
        for (final r in rows)
          {
            'method': r.method,
            'amount': int.parse(r.amount.text.trim()),
            if (r.received.text.trim().isNotEmpty)
              'received': int.parse(r.received.text.trim()),
            if (r.reference.text.trim().isNotEmpty)
              'reference': r.reference.text.trim(),
            if ((plan!['shares'] as List).isNotEmpty) 'share': r.share,
          },
      ];
      final result = await restaurantRun(
        context,
        widget.intent,
        HostCommand.restoSettle,
        {'order_uuid': widget.order['order_uuid'], 'payments': payments},
        preparation: preparation,
      );
      if (result != null && mounted) {
        Navigator.pop(context, result);
      } else {
        message = widget.intent.pending != null
            ? 'Résultat à vérifier : le règlement reste conservé avec son identifiant.'
            : 'Règlement non confirmé. Corrigez les champs si nécessaire.';
      }
    } catch (e) {
      message = '$e';
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(title: const Text('Régler la commande')),
        body: Column(
          children: [
            if (busy) const LinearProgressIndicator(),
            if (message != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  message!,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            Wrap(
              spacing: 12,
              children: [
                OutlinedButton(
                  onPressed: busy ? null : () => prepare('full'),
                  child: const Text('Tout régler'),
                ),
                if (widget.order['profile'] != 'TABLE_SERVICE') ...[
                  OutlinedButton(
                    onPressed: busy ? null : () => prepare('items'),
                    child: const Text('Par articles'),
                  ),
                  OutlinedButton(
                    onPressed: busy ? null : () => prepare('shares'),
                    child: const Text('Par parts'),
                  ),
                ],
              ],
            ),
            if (plan != null)
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Text(
                      '${plan!['payable_label']}',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    for (final (index, r) in rows.indexed)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            children: [
                              if ((plan!['shares'] as List).isNotEmpty)
                                Text('Part ${r.share + 1}'),
                              LayoutBuilder(
                                builder: (context, constraints) {
                                  final methods = (plan!['methods'] as List)
                                      .cast<Map>();
                                  final cash = methods.any(
                                    (m) =>
                                        m['code'] == r.method &&
                                        m['cash'] == true,
                                  );
                                  final fields = <Widget>[
                                    DropdownButtonFormField<String>(
                                      initialValue: r.method,
                                      isExpanded: true,
                                      decoration: const InputDecoration(
                                        labelText: 'Moyen',
                                      ),
                                      items: [
                                        for (final m in methods)
                                          DropdownMenuItem(
                                            value: '${m['code']}',
                                            child: Text('${m['name']}'),
                                          ),
                                      ],
                                      onChanged: busy
                                          ? null
                                          : (v) => setState(() {
                                              r.method = v!;
                                              r.reference.clear();
                                              r.received.clear();
                                            }),
                                    ),
                                    TextField(
                                      controller: r.amount,
                                      enabled: !busy,
                                      keyboardType: TextInputType.number,
                                      onChanged: (_) => setState(() {}),
                                      decoration: const InputDecoration(
                                        labelText: 'Montant (F CFA)',
                                      ),
                                    ),
                                    TextField(
                                      controller: cash
                                          ? r.received
                                          : r.reference,
                                      enabled: !busy,
                                      decoration: InputDecoration(
                                        labelText: cash
                                            ? 'Espèces reçues (facultatif)'
                                            : 'Référence',
                                      ),
                                      keyboardType: cash
                                          ? TextInputType.number
                                          : TextInputType.text,
                                    ),
                                    IconButton(
                                      onPressed: busy
                                          ? null
                                          : () => setState(() {
                                              rows.removeAt(index);
                                              r.dispose();
                                            }),
                                      icon: const Icon(Icons.delete_outline),
                                      tooltip: 'Retirer ce paiement',
                                    ),
                                  ];
                                  return constraints.maxWidth < 550
                                      ? Wrap(
                                          spacing: 12,
                                          runSpacing: 12,
                                          children: [
                                            for (final f in fields)
                                              SizedBox(width: 220, child: f),
                                          ],
                                        )
                                      : Row(
                                          children: [
                                            for (final f in fields.take(3))
                                              Expanded(
                                                child: Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        right: 12,
                                                      ),
                                                  child: f,
                                                ),
                                              ),
                                            fields.last,
                                          ],
                                        );
                                },
                              ),
                              if ((plan!['methods'] as List).any(
                                (m) =>
                                    m['code'] == r.method && m['cash'] == true,
                              ))
                                Wrap(
                                  spacing: 8,
                                  children: [
                                    for (final amount in [
                                      1000,
                                      2000,
                                      5000,
                                      10000,
                                      20000,
                                    ])
                                      ActionChip(
                                        label: Text('$amount F'),
                                        onPressed: busy
                                            ? null
                                            : () => setState(
                                                () =>
                                                    r.received.text = '$amount',
                                              ),
                                      ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                      ),
                    for (final share
                        in (plan!['shares'] as List).isEmpty
                            ? [0]
                            : (plan!['shares'] as List).map(
                                (s) => s['index'] as int,
                              ))
                      TextButton.icon(
                        onPressed: busy
                            ? null
                            : () => setState(
                                () => rows.add(
                                  _Payment(
                                    '${(plan!['methods'] as List).first['code']}',
                                    remaining(share).clamp(0, 1 << 50),
                                    share,
                                  ),
                                ),
                              ),
                        icon: const Icon(Icons.add),
                        label: Text(
                          'Ajouter un moyen · ${remaining(share)} F restant${(plan!['shares'] as List).isEmpty ? '' : ' pour la part ${share + 1}'}',
                        ),
                      ),
                    const Text(
                      'Vérifiez les montants et les références avant de confirmer.',
                    ),
                  ],
                ),
              )
            else
              const Spacer(),
            Padding(
              padding: const EdgeInsets.all(20),
              child: FilledButton.icon(
                onPressed: busy || plan == null ? null : pay,
                icon: const Icon(Icons.check),
                label: const Text('Encaisser'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
