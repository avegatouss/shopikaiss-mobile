import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../ipc/protocol.dart';
import '../platform/catalogue_intent.dart';
import 'register_controller.dart';
import 'catalogue_product_editor.dart';
import 'catalogue_changes_panel.dart';
import 'web_destinations.dart';

class CatalogueDialog extends StatefulWidget {
  const CatalogueDialog({
    super.key,
    required this.controller,
    this.productId,
    this.history = false,
  });
  final WindowsRegisterController controller;
  final int? productId;
  final bool history;
  @override
  State<CatalogueDialog> createState() => _CatalogueDialogState();
}

class _CatalogueDialogState extends State<CatalogueDialog> {
  WindowsRegisterController get c => widget.controller;
  CatalogueIntent? intent;
  Map<String, dynamic> form = {}, original = {};
  List<CatalogueChangeItem> items = [];
  Object? operatorId;
  bool loading = true, recovering = false, blocked = false;
  String? error;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      if (c.journal == null) throw StateError('Stockage local indisponible.');
      intent = CatalogueIntent(
        c.host,
        File('${c.journal!.file.parent.path}/pending-catalogue-v1.json'),
      );
      await intent!.load();
      final status = await c.host.call(HostCommand.status);
      operatorId = (status['operator'] as Map?)?['id'];
      if (operatorId == null) {
        throw const HostFailure('operator_required', 'Identifiez le caissier.');
      }
      if (intent!.pending != null) {
        recovering = true;
      } else if (widget.history) {
        await readChanges();
      } else {
        form = await c.host.call(HostCommand.catalogueForm);
        final access =
            form[widget.productId == null ? 'create' : 'edit'] as Map?;
        if (access?['allowed'] != true) {
          throw HostFailure(
            'produit_refuse',
            '${access?['reason'] ?? 'Action non autorisée.'}',
          );
        }
        if (widget.productId != null) {
          original = await c.host.call(
            HostCommand.productForEdit,
            arguments: {'product_id': widget.productId},
          );
          if (original['editable'] != true) {
            throw HostFailure(
              'produit_refuse',
              '${original['reason'] ?? 'Modification non autorisée.'}',
            );
          }
        }
      }
    } catch (e) {
      blocked = true;
      error = e is HostFailure ? e.message : 'Impossible de préparer le catalogue. Les données locales ont été conservées.';
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> readChanges() async {
    final result = await c.host.call(HostCommand.catalogueChanges);
    items = [
      for (final row in (result['items'] as List? ?? []).whereType<Map>())
        CatalogueChangeItem(
          id: '${row['operation_id']}',
          name: '${row['name'] ?? ''}',
          creation: row['kind'] == 'creation',
          reason: row['reason'] as String?,
          status: switch (row['state']) {
            'a_synchroniser' => CatalogueChangeStatus.pending,
            'conflit' => CatalogueChangeStatus.conflict,
            'refuse' => CatalogueChangeStatus.refused,
            'rattache' => CatalogueChangeStatus.linked,
            'integre' => CatalogueChangeStatus.integrated,
            _ => CatalogueChangeStatus.sent,
          },
        ),
    ];
  }

  Future<String?> save(CatalogueProductDraft draft) async {
    final fields = <String, dynamic>{
      'name': draft.name,
      'reference': draft.reference.isEmpty ? null : draft.reference,
      'category_uuid': draft.categoryUuid,
      'price': draft.price,
      'wholesale_price': draft.wholesalePrice,
      'wholesale_min': draft.wholesaleMinimum,
    };
    final creating = widget.productId == null;
    if (!creating) fields.removeWhere((key, value) => original[key] == value);
    if (!creating && fields.isEmpty) return 'Aucun changement à enregistrer.';
    final args = creating
        ? {
            ...fields,
            'barcodes': draft.barcodes,
            'purchase_price': draft.purchasePrice,
            'unlimited_stock': draft.unlimitedStock,
          }
        : {
            'product_id': widget.productId,
            'fields': fields,
            'expected_fields': {
              for (final key in fields.keys) key: original[key],
            },
          };
    try {
      await intent!.execute(
        creating ? HostCommand.createProduct : HostCommand.updateProduct,
        args,
        operatorId!,
      );
      await c.refresh();
      return null;
    } catch (e) {
      if (intent!.pending != null) {
        if (mounted) {
          setState(() {
            recovering = true;
            error = 'Résultat à vérifier. La demande initiale est conservée sur ce poste.';
          });
        }
      }
      return e is HostFailure
          ? e.message
          : 'Enregistrement non confirmé. Vérifiez la demande conservée.';
    }
  }

  Future<void> recover() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      await intent!.retry(operatorId!);
      await c.refresh();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          error = e is HostFailure
              ? e.message
              : 'Résultat toujours incertain. La demande est conservée.';
          blocked = intent!.pending == null;
        });
      }
    }
  }

  Future<void> arbitration() async {
    final uri = caisseWebsite(c.webOrigin, '/parametres/caisse-hors-ligne');
    if (uri == null ||
        !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) {
        setState(() => error = 'Impossible d’ouvrir la gestion en ligne.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!loading && !blocked && !recovering && !widget.history) {
      return CatalogueProductEditor(
        editing: widget.productId != null,
        onSave: save,
        maxPrice:
            (form['limits'] as Map?)?['max_amount'] as int? ?? 999999999999,
        categories: {
          for (final category
              in (form['categories'] as List? ?? []).whereType<Map>())
            '${category['uuid']}': '${category['name']}',
        },
        initial: CatalogueProductDraft(
          name: original['name'] as String? ?? '',
          reference: original['reference'] as String? ?? '',
          barcodes: (original['barcodes'] as List? ?? []).cast<String>(),
          price: original['price'] as int?,
          categoryUuid: original['category_uuid'] as String?,
          wholesalePrice: original['wholesale_price'] as int?,
          wholesaleMinimum: original['wholesale_min'] as String?,
          unlimitedStock: original['unlimited_stock'] == true,
        ),
      );
    }
    return PopScope(
      canPop: !loading,
      child: AlertDialog(
        title: Text(
          recovering
              ? 'Vérifier la modification du produit'
              : 'Produits créés ou modifiés ici',
        ),
        content: SizedBox(
          width: 700,
          height: widget.history && !recovering && !blocked ? 420 : null,
          child: loading
              ? const Center(
                  heightFactor: 2,
                  child: CircularProgressIndicator(),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(error!),
                      ),
                    if (recovering && !blocked)
                      const Text(
                        'Vérifiez la demande précédente avant toute nouvelle création ou modification. Le même identifiant sera utilisé, même après redémarrage.',
                      ),
                    if (widget.history && !recovering && !blocked)
                      Expanded(
                        child: CatalogueChangesPanel(
                          items: items,
                          onOpenArbitration: arbitration,
                        ),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: loading ? null : () => Navigator.of(context).pop(),
            child: const Text('Fermer'),
          ),
          if (recovering && !blocked)
            FilledButton(
              onPressed: loading ? null : recover,
              child: const Text('Vérifier la demande conservée'),
            ),
        ],
      ),
    );
  }
}
