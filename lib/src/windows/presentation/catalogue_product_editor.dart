import 'package:flutter/material.dart';

/// UI-only draft. No wire format or product identity is invented here: the
/// shared engine must persist and validate it before [onSave] completes.
class CatalogueProductDraft {
  const CatalogueProductDraft({
    this.name = '',
    this.reference = '',
    this.barcodes = const [],
    this.price,
    this.categoryUuid,
    this.purchasePrice,
    this.wholesalePrice,
    this.wholesaleMinimum,
    this.unlimitedStock = false,
  });

  final String name;
  final String reference;
  final List<String> barcodes;
  final int? price;
  final String? categoryUuid;
  final int? purchasePrice;
  final int? wholesalePrice;
  final String? wholesaleMinimum;
  final bool unlimitedStock;
}

/// Prepared independently of the pending catalogue contract. Intentionally not
/// reachable from the register until capabilities and engine storage exist.
class CatalogueProductEditor extends StatefulWidget {
  const CatalogueProductEditor({
    super.key,
    required this.onSave,
    required this.maxPrice,
    this.initial = const CatalogueProductDraft(),
    this.editing = false,
    this.categories = const {},
  });

  final CatalogueProductDraft initial;
  final bool editing;
  final int maxPrice;
  final Map<String, String> categories;

  /// Return a user-facing validation/storage error, or null after durable save.
  /// Network uncertainty must be reconciled by the engine, not retried here.
  final Future<String?> Function(CatalogueProductDraft draft) onSave;

  @override
  State<CatalogueProductEditor> createState() => _CatalogueProductEditorState();
}

class _CatalogueProductEditorState extends State<CatalogueProductEditor> {
  final form = GlobalKey<FormState>();
  late final name = TextEditingController(text: widget.initial.name);
  late final reference = TextEditingController(text: widget.initial.reference);
  late final barcodes = TextEditingController(
    text: widget.initial.barcodes.join('\n'),
  );
  late final price = TextEditingController(
    text: widget.initial.price?.toString() ?? '',
  );
  bool saving = false;
  late String? categoryUuid = widget.initial.categoryUuid;
  late bool unlimitedStock = widget.initial.unlimitedStock;
  late final purchase = TextEditingController(
    text: widget.initial.purchasePrice?.toString() ?? '',
  );
  late final wholesale = TextEditingController(
    text: widget.initial.wholesalePrice?.toString() ?? '',
  );
  late final minimum = TextEditingController(
    text: widget.initial.wholesaleMinimum ?? '',
  );
  bool uncertain = false;
  String? error;

  @override
  void dispose() {
    name.dispose();
    reference.dispose();
    barcodes.dispose();
    price.dispose();
    purchase.dispose();
    wholesale.dispose();
    minimum.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (saving || uncertain || !form.currentState!.validate()) return;
    setState(() {
      saving = true;
      error = null;
    });
    String? failure;
    try {
      failure = await widget.onSave(
        CatalogueProductDraft(
          name: name.text.trim(),
          reference: reference.text.trim(),
          barcodes: widget.editing
              ? widget.initial.barcodes
              : barcodes.text
                    .split('\n')
                    .map((s) => s.trim())
                    .where((s) => s.isNotEmpty)
                    .toSet()
                    .toList(growable: false),
          price: int.parse(price.text.trim()),
          categoryUuid: categoryUuid,
          purchasePrice: widget.editing
              ? widget.initial.purchasePrice
              : int.tryParse(purchase.text.trim()),
          wholesalePrice: int.tryParse(wholesale.text.trim()),
          wholesaleMinimum: normalizeMinimum(minimum.text),
          unlimitedStock: unlimitedStock,
        ),
      );
    } catch (_) {
      uncertain = true;
      // Do not expose raw exceptions or report a successful save.
      failure =
          'Enregistrement non confirmé. Vos saisies sont conservées '
          'dans cette fenêtre. Vérifiez l’état du catalogue avant de réessayer.';
    }
    if (!mounted) return;
    if (failure == null) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        saving = false;
        error = failure;
      });
    }
  }

  String? normalizeMinimum(String value) {
    final input = value.trim().replaceAll(',', '.');
    if (input.isEmpty) return null;
    final parts = input.split('.');
    return '${parts[0]}.${(parts.length > 1 ? parts[1] : '').padRight(6, '0')}';
  }

  String? amountError(String? value, {bool optional = false}) {
    final text = (value ?? '').trim();
    if (optional && text.isEmpty) return null;
    final amount = int.tryParse(text);
    final limit = widget.maxPrice < 999999999999
        ? widget.maxPrice
        : 999999999999;
    return !RegExp(r'^\d+$').hasMatch(text) || amount == null || amount > limit
        ? 'Saisissez un montant entier entre 0 et $limit.'
        : null;
  }

  @override
  Widget build(BuildContext context) {
    Widget field(
      TextEditingController controller,
      String label, {
      String? helper,
      int lines = 1,
      bool numeric = false,
      bool readOnly = false,
      String? Function(String?)? validate,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextFormField(
        controller: controller,
        enabled: !saving,
        readOnly: readOnly,
        minLines: lines,
        maxLines: lines,
        keyboardType: numeric ? TextInputType.number : TextInputType.text,
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          helperMaxLines: 3,
          border: const OutlineInputBorder(),
        ),
        validator: validate,
      ),
    );

    return PopScope(
      canPop: !saving,
      child: AlertDialog(
        title: Text(
          widget.editing ? 'Modifier le produit' : 'Créer un produit',
        ),
        content: SizedBox(
          width: 620,
          child: SingleChildScrollView(
            child: Form(
              key: form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(bottom: 20),
                    child: Text(
                      'Enregistrement sur ce poste, puis synchronisation. '
                      'Une correspondance ou un conflit pourra nécessiter un arbitrage.',
                    ),
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ),
                  field(
                    name,
                    'Désignation',
                    validate: (value) => (value ?? '').trim().isEmpty
                        ? 'Saisissez la désignation.'
                        : value!.trim().runes.length > 160
                        ? '160 caractères maximum.'
                        : null,
                  ),
                  field(
                    reference,
                    'Référence',
                    helper: 'Facultative',
                    validate: (value) => (value ?? '').trim().runes.length > 80
                        ? '80 caractères maximum.'
                        : null,
                  ),
                  field(
                    barcodes,
                    'Codes-barres',
                    lines: 3,
                    readOnly: widget.editing,
                    helper: 'Facultatifs, un code par ligne. Les zéros initiaux sont conservés.',
                    validate: widget.editing
                        ? null
                        : (value) {
                            final codes = (value ?? '')
                                .split('\n')
                                .map((s) => s.trim())
                                .where((s) => s.isNotEmpty)
                                .toSet();
                            if (codes.length > 5) {
                              return '5 codes-barres maximum.';
                            }
                            if (codes.any(
                              (s) => !RegExp(r'^[!-~]{1,80}$').hasMatch(s),
                            )) {
                              return 'Chaque code doit contenir 1 à 80 caractères ASCII sans espace.';
                            }
                            return null;
                          },
                  ),
                  field(
                    price,
                    'Prix de vente',
                    numeric: true,
                    helper: 'Montant entier, dans la devise de la boutique.',
                    validate: amountError,
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: DropdownButtonFormField<String>(
                      initialValue: categoryUuid ?? '',
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Catégorie',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: '',
                          child: Text('Sans catégorie'),
                        ),
                        if (categoryUuid != null &&
                            !widget.categories.containsKey(categoryUuid))
                          DropdownMenuItem(
                            value: categoryUuid,
                            child: const Text('Catégorie actuelle'),
                          ),
                        for (final entry in widget.categories.entries)
                          DropdownMenuItem(
                            value: entry.key,
                            child: Text(entry.value),
                          ),
                      ],
                      onChanged: saving
                          ? null
                          : (value) => setState(
                              () => categoryUuid = value == '' ? null : value,
                            ),
                    ),
                  ),
                  if (!widget.editing)
                    field(
                      purchase,
                      'Prix d’achat',
                      numeric: true,
                      helper: 'Facultatif. Non saisi : coût enregistré à 0.',
                      validate: (value) => amountError(value, optional: true),
                    ),
                  field(
                    wholesale,
                    'Prix de gros',
                    numeric: true,
                    helper: 'Facultatif',
                    validate: (value) => amountError(value, optional: true),
                  ),
                  field(
                    minimum,
                    'Quantité minimale de gros',
                    numeric: true,
                    helper: 'Facultative, jusqu’à 6 décimales.',
                    validate: (value) {
                      final text = (value ?? '').trim().replaceAll(',', '.');
                      if (text.isEmpty) return null;
                      return RegExp(r'^(0|[1-9][0-9]{0,8})(\.[0-9]{1,6})?$')
                              .hasMatch(text)
                          ? null
                          : 'Saisissez une quantité avec au plus 6 décimales.';
                    },
                  ),
                  if (!widget.editing)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Stock illimité'),
                      subtitle: const Text(
                        'Sinon, le stock démarre à 0. Aucun stock initial n’est ajouté.',
                      ),
                      value: unlimitedStock,
                      onChanged: saving
                          ? null
                          : (value) => setState(() => unlimitedStock = value),
                    ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: saving ? null : () => Navigator.of(context).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton.icon(
            onPressed: saving || uncertain ? null : save,
            icon: saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: Text(saving ? 'Enregistrement…' : 'Enregistrer localement'),
          ),
        ],
      ),
    );
  }
}
