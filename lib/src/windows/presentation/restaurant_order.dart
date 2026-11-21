import 'dart:async';

import 'package:flutter/material.dart';

import '../ipc/protocol.dart';
import '../platform/receipt_printing.dart';
import '../platform/restaurant_intent.dart';
import 'restaurant_forms.dart';
import 'restaurant_recovery.dart';
import 'restaurant_payment.dart';
import 'restaurant_management.dart';
import 'sales_history.dart';

class RestaurantOrderDialog extends StatefulWidget {
  const RestaurantOrderDialog({
    super.key,
    required this.host,
    required this.order,
    required this.sendLabel,
    this.intent,
    this.room = const {},
  });
  final WindowsHost host;
  final Map order, room;
  final String sendLabel;
  final RestaurantIntent? intent;
  @override
  State<RestaurantOrderDialog> createState() => _RestaurantOrderState();
}

class _RestaurantOrderState extends State<RestaurantOrderDialog> {
  late Map order = widget.order;
  late final intent = widget.intent ?? RestaurantIntent(widget.host);
  bool busy = false;
  String? message, category;
  List<Map> products = [];
  List<String> categories = [];
  bool hasMore = false;
  int generation = 0;
  final search = TextEditingController();
  final added = <Map<String, dynamic>>[];
  final quantities = <String, String>{};
  final comments = <String, String?>{};
  final removed = <String>[];
  StreamSubscription<Map<String, dynamic>>? events;
  bool get draft =>
      added.isNotEmpty ||
      quantities.isNotEmpty ||
      comments.isNotEmpty ||
      removed.isNotEmpty;
  bool get editable =>
      !busy && intent.pending == null && order['status'] == 'open';
  @override
  void initState() {
    super.initState();
    loadProducts();
    events = widget.host.events.listen((e) {
      if (!busy &&
          !draft &&
          e['name'] == 'committed' &&
          (e['data'] as Map?)?['reason'] == 'restaurant') {
        unawaited(reload());
      }
    });
  }

  @override
  void dispose() {
    events?.cancel();
    search.dispose();
    super.dispose();
  }

  void clearDraft() {
    added.clear();
    quantities.clear();
    comments.clear();
    removed.clear();
  }

  Future<void> loadProducts({bool more = false}) async {
    final current = ++generation;
    try {
      final view = await widget.host.call(
        HostCommand.restaurantCatalog,
        arguments: {
          'query': search.text,
          'category': category,
          'limit': 60,
          'offset': more ? products.length : 0,
        },
      );
      if (mounted && current == generation) {
        setState(() {
          products = [
            if (more) ...products,
            ...(view['products'] as List).cast<Map>(),
          ];
          categories = (view['categories'] as List? ?? []).cast<String>();
          hasMore = view['has_more'] == true;
        });
      }
    } catch (e) {
      if (mounted) setState(() => message = '$e');
    }
  }

  Future<void> reload() async {
    try {
      final value = await widget.host.call(
        HostCommand.restoOrder,
        arguments: {'order_uuid': order['order_uuid']},
      );
      if (mounted) setState(() => order = value['order'] as Map);
    } catch (e) {
      if (mounted) setState(() => message = '$e');
    }
  }

  Future<Map<String, dynamic>?> mutate(
    HostCommand command,
    Map<String, dynamic> args, {
    String? gesture,
  }) async {
    if (busy) return null;
    setState(() => busy = true);
    try {
      final arguments = <String, dynamic>{
        'order_uuid': order['order_uuid'],
        ...args,
      };
      if (gesture != null) {
        final approval = await restaurantApproval(
          context,
          widget.host,
          gesture,
          arguments,
        );
        if (approval == null) return null;
        arguments.addAll(approval);
      }
      if (!mounted) return null;
      final result = await restaurantRun(context, intent, command, arguments);
      if (result?['order'] is Map) order = result!['order'] as Map;
      if (result?['prebill_lines'] is List) {
        message = await ReceiptPrinting.printLines(
          (result!['prebill_lines'] as List).cast<String>(),
        );
      }
      return result;
    } catch (e) {
      message = '$e';
      return null;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> save({bool staff = false}) async {
    if (!draft) return true;
    final args = <String, dynamic>{
      'added': [
        for (final a in added) Map<String, dynamic>.from(a)..remove('label'),
      ],
      'quantities': quantities,
      'comments': comments,
      'removed': removed,
    };
    Map<String, dynamic>? result;
    if (staff) {
      final person = await restaurantChoose(
        context,
        'Tarif personnel',
        (widget.room['staff'] as List? ?? []).cast<Map>(),
      );
      if (person == null || !mounted) return false;
      final reason = await restaurantForm(context, 'Tarif personnel', {
        'reason': 'Motif',
      });
      if (reason == null) return false;
      result = await mutate(HostCommand.restoStaffLines, {
        'added': args['added'],
        'staff_id': person['id'],
        ...reason,
      }, gesture: 'staff');
    } else {
      result = await mutate(HostCommand.restoEditLines, args);
    }
    if (result != null && mounted) setState(clearDraft);
    return result != null;
  }

  Future<void> add(Map p) async {
    Map? packaging;
    final choices = (p['packagings'] as List? ?? []).cast<Map>();
    if (choices.isNotEmpty) {
      packaging = await restaurantChoose(context, 'Conditionnement', [
        {'id': null, 'name': 'Unité ? ${p['price_label']}'},
        ...choices,
      ]);
      if (packaging == null || !mounted) return;
    }
    final fields = await restaurantForm(
      context,
      '${p['name']}',
      {'quantity': 'Quantité', 'comment': 'Commentaire cuisine (facultatif)'},
      values: {'quantity': '1'},
    );
    if (fields == null || !mounted) return;
    setState(
      () => added.add({
        'product_id': p['id'],
        if (packaging?['id'] != null) 'packaging_id': packaging!['id'],
        ...fields,
        'label': p['name'],
      }),
    );
  }

  Future<void> lineAction(Map line, String action) async {
    if (action == 'edit') {
      final values = await restaurantForm(
        context,
        '${line['label']}',
        {'quantity': 'Quantité', 'comment': 'Commentaire'},
        values: {
          'quantity':
              quantities['${line['line_uuid']}'] ?? '${line['quantity']}',
          'comment':
              comments['${line['line_uuid']}'] ?? '${line['comment'] ?? ''}',
        },
      );
      if (values != null && mounted) {
        setState(() {
          quantities['${line['line_uuid']}'] = values['quantity']!;
          comments['${line['line_uuid']}'] = values['comment'];
        });
      }
      return;
    }
    if (action == 'remove') {
      setState(() => removed.add('${line['line_uuid']}'));
      return;
    }
    if (!await save() || !mounted) return;
    final values = await restaurantForm(
      context,
      action == 'cancel'
          ? 'Annuler la ligne'
          : action == 'offer'
          ? 'Offrir la ligne'
          : 'Remise sur la ligne',
      {
        if (action == 'cancel') 'quantity': 'Quantité à annuler',
        if (action == 'discount') ...{
          'value': 'Valeur de la remise',
          'unit': 'Unité : % ou F',
        },
        'reason': 'Motif (3 à 500 caractères)',
      },
      values: {
        if (action == 'cancel') 'quantity': '${line['rest']}',
        if (action == 'discount') 'unit': '%',
      },
    );
    if (values == null) return;
    final args = <String, dynamic>{
      'line_uuid': line['line_uuid'],
      'reason': values['reason'],
      if (action == 'cancel') 'quantity': values['quantity'],
      if (action == 'discount') ...{
        'value': int.tryParse(values['value']!),
        'percent': values['unit'] == '%',
      },
    };
    await mutate(
      action == 'cancel'
          ? HostCommand.restoCancelLine
          : action == 'offer'
          ? HostCommand.restoOffer
          : HostCommand.restoDiscountLine,
      args,
      gesture: action == 'cancel'
          ? 'cancel_line'
          : action == 'offer'
          ? 'offer'
          : 'discount_line',
    );
  }

  Future<void> commandAction(String action) async {
    try {
      if (!await save() || !mounted) return;
      final fresh = await widget.host.call(HostCommand.restaurantView);
      if (!mounted) return;
      if (action == 'transfer') {
        final table = await restaurantChoose(
          context,
          'Transférer vers une table',
          (fresh['tables'] as List).cast<Map>(),
        );
        if (table != null) {
          await mutate(HostCommand.restoTransfer, {
            'table_uuid': table['table_uuid'],
          });
        }
      } else if (action == 'merge' || action == 'move') {
        final target = await restaurantChoose(
          context,
          action == 'merge' ? 'Fusionner vers' : 'Déplacer vers',
          (fresh['orders'] as List)
              .cast<Map>()
              .where((o) => o['order_uuid'] != order['order_uuid'])
              .toList(),
          label: 'local_number',
        );
        if (target == null || !mounted) return;
        if (action == 'merge') {
          final reason = await restaurantForm(
            context,
            'Fusionner les commandes',
            {'reason': 'Motif'},
          );
          if (reason != null) {
            await mutate(HostCommand.restoMerge, {
              'target_uuid': target['order_uuid'],
              ...reason,
            });
          }
        } else {
          final selected = <String>{};
          final yes = await showDialog<bool>(
            context: context,
            builder: (context) => StatefulBuilder(
              builder: (context, update) => AlertDialog(
                title: const Text('Lignes à déplacer'),
                content: SizedBox(
                  width: 500,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final l in (order['lines'] as List).cast<Map>())
                          if (l['active'] == true)
                            CheckboxListTile(
                              title: Text('${l['label']}'),
                              value: selected.contains(l['line_uuid']),
                              onChanged: (v) => update(() {
                                if (v == true) {
                                  selected.add('${l['line_uuid']}');
                                } else {
                                  selected.remove(l['line_uuid']);
                                }
                              }),
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
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Déplacer'),
                  ),
                ],
              ),
            ),
          );
          if (yes == true) {
            await mutate(HostCommand.restoMoveLines, {
              'target_uuid': target['order_uuid'],
              'line_uuids': selected.toList(),
            });
          }
        }
      } else if (action == 'covers') {
        final staff = await restaurantChoose(
          context,
          'Serveur',
          (fresh['staff'] as List).cast<Map>(),
        );
        if (staff == null || !mounted) return;
        final values = await restaurantForm(
          context,
          'Couverts',
          {'covers': 'Nombre de couverts'},
          values: {'covers': '${order['covers'] ?? 0}'},
        );
        if (values != null) {
          await mutate(HostCommand.restoCoversAndServer, {
            'server_id': staff['id'],
            'covers': int.tryParse(values['covers']!),
          });
        }
      } else if (action == 'customer') {
        await mutate(HostCommand.restoValidateCustomer, {});
      } else if (action == 'close') {
        await mutate(HostCommand.restoClose, {});
      } else {
        final values = await restaurantForm(
          context,
          action == 'cancel' ? 'Annuler la commande' : 'Remise globale',
          {
            if (action != 'cancel')
              'value': 'Montant de la remise (F CFA, 0 pour retirer)',
            'reason': 'Motif',
          },
        );
        if (values != null) {
          await mutate(
            action == 'cancel'
                ? HostCommand.restoCancel
                : HostCommand.restoDiscountOrder,
            {
              'reason': values['reason'],
              if (action != 'cancel') 'value': int.tryParse(values['value']!),
            },
            gesture: action == 'cancel' ? 'cancel_order' : 'discount_order',
          );
        }
      }
    } catch (e) {
      if (mounted) setState(() => message = '$e');
    }
  }

  Future<void> payment() async {
    if (!await save() || !mounted) return;
    final value = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => RestaurantPayment(intent: intent, order: order),
    );
    if (value != null && mounted) {
      if (value['order'] is Map) setState(() => order = value['order'] as Map);
      final print = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Vente ${value['number']} enregistrée'),
          content: Text(
            'Monnaie : ${value['change_label'] ?? 'consulter le reçu'}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Sans ticket'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Imprimer le ticket'),
            ),
          ],
        ),
      );
      if (print == true) {
        try {
          message = await printOriginalTicket(
            widget.host,
            '${value['sale_id']}',
          );
        } catch (e) {
          message = 'Vente enregistrée. Impression à vérifier : $e';
        }
      }
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final folders =
        (widget.room['interface'] as Map?)?['navigation_carte'] != null &&
        (widget.room['interface'] as Map)['navigation_carte'] != 'chips';
    final canSend = (order['lines'] as List).cast<Map>().any(
      (l) => l['status'] == 'pending' && l['active'] == true,
    );
    return PopScope(
      canPop: !draft && !busy,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || busy || !draft) return;
        final yes = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Brouillon non validé'),
            content: const Text(
              'Abandonner uniquement les changements non validés ?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Continuer'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Abandonner'),
              ),
            ],
          ),
        );
        if (yes == true && mounted) {
          setState(clearDraft);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.pop(context);
          });
        }
      },
      child: Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            title: Text(
              '${order['table_name'] ?? order['channel_name'] ?? 'Commande'} · ${order['local_number']}',
            ),
            actions: [
              IconButton(
                onPressed: busy || (draft && intent.pending == null)
                    ? null
                    : () async {
                        final recovering = intent.pending != null;
                        if (await restaurantRecovery(context, intent)) {
                          if (mounted && recovering) setState(clearDraft);
                          await reload();
                        }
                      },
                icon: const Icon(Icons.sync),
                tooltip: 'Vérifier / reprendre',
              ),
              IconButton(
                onPressed: busy
                    ? null
                    : () => showDialog<void>(
                        context: context,
                        builder: (_) => RestaurantManagement(
                          intent: intent,
                          section: 'Bons de production',
                        ),
                      ),
                icon: const Icon(Icons.print),
                tooltip: 'Bons de production',
              ),
              PopupMenuButton<String>(
                enabled: editable && !draft,
                onSelected: commandAction,
                itemBuilder: (_) => [
                  for (final e in {
                    'transfer': 'Transférer la table',
                    'move': 'Déplacer des lignes',
                    'merge': 'Fusionner',
                    'covers': 'Couverts et serveur',
                    'customer': 'Appliquer la remise client',
                    'discount': 'Remise globale',
                    'cancel': 'Annuler la commande',
                    if (order['paid'] == true) 'close': 'Terminer la clôture',
                  }.entries)
                    PopupMenuItem(value: e.key, child: Text(e.value)),
                ],
              ),
            ],
          ),
          body: Column(
            children: [
              if (busy) const LinearProgressIndicator(),
              if (message != null)
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Text(message!),
                ),
              if (intent.pending != null)
                const Padding(
                  padding: EdgeInsets.all(10),
                  child: Text(
                    'Résultat à vérifier. Aucune nouvelle action avant la reprise.',
                  ),
                ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: TextField(
                              controller: search,
                              onSubmitted: (_) {
                                loadProducts();
                              },
                              decoration: InputDecoration(
                                labelText: 'Rechercher un produit',
                                suffixIcon: IconButton(
                                  onPressed: loadProducts,
                                  icon: const Icon(Icons.search),
                                ),
                              ),
                            ),
                          ),
                          if (!folders || category != null)
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  TextButton(
                                    onPressed: () {
                                      setState(() => category = null);
                                      loadProducts();
                                    },
                                    child: const Text('Toutes'),
                                  ),
                                  for (final c in categories)
                                    TextButton(
                                      onPressed: () {
                                        setState(() => category = c);
                                        loadProducts();
                                      },
                                      child: Text(c),
                                    ),
                                ],
                              ),
                            ),
                          Expanded(
                            child:
                                folders &&
                                    category == null &&
                                    search.text.isEmpty
                                ? GridView.extent(
                                    maxCrossAxisExtent: 180,
                                    childAspectRatio: 2,
                                    children: [
                                      for (final c in categories)
                                        Padding(
                                          padding: const EdgeInsets.all(6),
                                          child: FilledButton.tonal(
                                            onPressed: () {
                                              setState(() => category = c);
                                              loadProducts();
                                            },
                                            child: Text(c),
                                          ),
                                        ),
                                    ],
                                  )
                                : ListView(
                                    children: [
                                      for (final p in products)
                                        ListTile(
                                          title: Text('${p['name']}'),
                                          subtitle: Text('${p['price_label']}'),
                                          trailing: IconButton(
                                            icon: const Icon(
                                              Icons.add_circle_outline,
                                            ),
                                            tooltip: 'Ajouter',
                                            onPressed: editable
                                                ? () => add(p)
                                                : null,
                                          ),
                                        ),
                                    ],
                                  ),
                          ),
                          if (hasMore)
                            TextButton(
                              onPressed: () {
                                loadProducts(more: true);
                              },
                              child: const Text('Afficher plus'),
                            ),
                        ],
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: Column(
                        children: [
                          Expanded(
                            child: ListView(
                              children: [
                                for (final l
                                    in (order['lines'] as List).cast<Map>())
                                  ListTile(
                                    title: Text(
                                      '${quantities['${l['line_uuid']}'] ?? l['quantity_label']} × ${l['label']}${removed.contains(l['line_uuid']) ? ' · à retirer' : ''}',
                                    ),
                                    subtitle: Text(
                                      '${l['state_label']} · ${l['total_label']}\n${comments['${l['line_uuid']}'] ?? l['comment'] ?? ''}${l['promotion_name'] == null ? '' : '\n${l['promotion_name']}'}',
                                    ),
                                    trailing: PopupMenuButton<String>(
                                      enabled: editable && l['active'] == true,
                                      onSelected: (a) => lineAction(l, a),
                                      itemBuilder: (_) => [
                                        if (l['status'] == 'pending') ...[
                                          const PopupMenuItem(
                                            value: 'edit',
                                            child: Text(
                                              'Quantité / commentaire',
                                            ),
                                          ),
                                          const PopupMenuItem(
                                            value: 'remove',
                                            child: Text('Retirer du brouillon'),
                                          ),
                                        ] else
                                          const PopupMenuItem(
                                            value: 'cancel',
                                            child: Text('Annuler avec motif'),
                                          ),
                                        const PopupMenuItem(
                                          value: 'offer',
                                          child: Text('Offrir'),
                                        ),
                                        const PopupMenuItem(
                                          value: 'discount',
                                          child: Text('Remise'),
                                        ),
                                      ],
                                    ),
                                  ),
                                for (final (i, a) in added.indexed)
                                  ListTile(
                                    title: Text(
                                      '${a['quantity']} × ${a['label']} · non validé',
                                    ),
                                    subtitle: Text('${a['comment'] ?? ''}'),
                                    trailing: IconButton(
                                      onPressed: editable
                                          ? () => setState(
                                              () => added.removeAt(i),
                                            )
                                          : null,
                                      icon: const Icon(Icons.close),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Text(
                            '${order['payable_label']}',
                            style: Theme.of(context).textTheme.headlineMedium,
                          ),
                          if (draft)
                            const Text(
                              'Total des lignes validées. Le moteur recalculera après validation.',
                            ),
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                if (draft)
                                  FilledButton(
                                    onPressed: editable ? save : null,
                                    child: const Text('Valider les lignes'),
                                  ),
                                if (added.isNotEmpty &&
                                    quantities.isEmpty &&
                                    removed.isEmpty &&
                                    comments.isEmpty &&
                                    widget.room['staff_pricing'] == true)
                                  OutlinedButton(
                                    onPressed: editable
                                        ? () => save(staff: true)
                                        : null,
                                    child: const Text('Tarif personnel'),
                                  ),
                                FilledButton.icon(
                                  onPressed: editable && (draft || canSend)
                                      ? () async {
                                          if (await save()) {
                                            final result = await mutate(
                                              HostCommand.restoSend,
                                              {},
                                            );
                                            if (result != null &&
                                                context.mounted) {
                                              Navigator.pop(context);
                                            }
                                          }
                                        }
                                      : null,
                                  icon: const Icon(Icons.send),
                                  label: Text(widget.sendLabel),
                                ),
                                OutlinedButton(
                                  onPressed: editable
                                      ? () async {
                                          if (await save()) {
                                            await mutate(
                                              HostCommand.restoPrebill,
                                              {},
                                            );
                                          }
                                        }
                                      : null,
                                  child: const Text('Préfacture'),
                                ),
                                FilledButton(
                                  onPressed: editable ? payment : null,
                                  child: const Text('Encaisser'),
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
      ),
    );
  }
}
