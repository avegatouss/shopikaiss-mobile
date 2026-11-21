import 'package:flutter/material.dart';

/// UI-only draft. No wire format or product identity is invented here: the
/// shared engine must persist and validate it before [onSave] completes.
class CatalogueProductDraft {
  const CatalogueProductDraft({
    this.name = '',
    this.reference = '',
    this.barcodes = const [],
    this.price,
  });

  final String name;
  final String reference;
  final List<String> barcodes;
  final int? price;
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
  });

  final CatalogueProductDraft initial;
  final bool editing;
  final int maxPrice;

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
  bool uncertain = false;
  String? error;

  @override
  void dispose() {
    name.dispose();
    reference.dispose();
    barcodes.dispose();
    price.dispose();
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
          barcodes: barcodes.text
              .split('\n')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toSet()
              .toList(growable: false),
          price: int.parse(price.text.trim()),
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

  @override
  Widget build(BuildContext context) {
    Widget field(
      TextEditingController controller,
      String label, {
      String? helper,
      int lines = 1,
      bool numeric = false,
      String? Function(String?)? validate,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextFormField(
        controller: controller,
        enabled: !saving,
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
                        : null,
                  ),
                  field(reference, 'Référence', helper: 'Facultative'),
                  field(
                    barcodes,
                    'Codes-barres',
                    lines: 3,
                    helper: 'Facultatifs, un code par ligne. Les zéros initiaux sont conservés.',
                  ),
                  field(
                    price,
                    'Prix de vente',
                    numeric: true,
                    helper: 'Montant entier, dans la devise de la boutique.',
                    validate: (value) {
                      final text = (value ?? '').trim();
                      final amount = int.tryParse(text);
                      return !RegExp(r'^\d+$').hasMatch(text) ||
                              amount == null ||
                              amount > widget.maxPrice
                          ? 'Saisissez un montant entier entre 0 et ${widget.maxPrice}.'
                          : null;
                    },
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
