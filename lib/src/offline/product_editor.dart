import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../sync_v2/decimal6.dart';
import 'catalogue_edit.dart';
import 'engine.dart';
import 'models.dart';

/// Fiche produit hors connexion (2.1 lot 10), caisse Android : création, ou modification d'une fiche existante
/// ([existing]). Le moteur décide de tout (droits, bornes, codes déjà connus) ; la fenêtre affiche ses refus et garde la
/// saisie. Rend le produit enregistré, ou null si l'on annule.
Future<Product?> showProductEditor(BuildContext context, CaisseEngine engine, Operator operator, {ProductFields? existing}) =>
    showDialog<Product>(context: context, barrierDismissible: false, builder: (_) => _ProductEditor(engine: engine, operator: operator, existing: existing));

class _ProductEditor extends StatefulWidget {
  const _ProductEditor({required this.engine, required this.operator, this.existing});

  final CaisseEngine engine;
  final Operator operator;
  final ProductFields? existing;

  @override
  State<_ProductEditor> createState() => _ProductEditorState();
}

class _ProductEditorState extends State<_ProductEditor> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _reference = TextEditingController(text: widget.existing?.reference ?? '');
  late final _barcodes = TextEditingController(text: widget.existing?.barcodes.join(' ') ?? '');
  late final _price = TextEditingController(text: widget.existing == null ? '' : '${widget.existing!.price}');
  final _purchase = TextEditingController();
  late final _wholesale = TextEditingController(text: widget.existing?.wholesalePrice?.toString() ?? '');
  late final _minimum = TextEditingController(
    text: widget.existing?.wholesaleMin == null ? '' : Decimal6.label(Decimal6.parse(widget.existing!.wholesaleMin!)),
  );
  late String? _category = widget.existing?.categoryUuid;
  String? _error;
  bool _saving = false;

  bool get _editing => widget.existing != null;

  @override
  void dispose() {
    for (final c in [_name, _reference, _barcodes, _price, _purchase, _wholesale, _minimum]) {
      c.dispose();
    }
    super.dispose();
  }

  int? _amount(TextEditingController c) => c.text.trim().isEmpty ? null : int.tryParse(c.text.trim());

  Future<void> _save() async {
    final price = _amount(_price);
    if (price == null) return setState(() => _error = 'Indiquez le prix de vente (nombre entier de francs).');
    if (_wholesale.text.trim().isNotEmpty && _amount(_wholesale) == null) return setState(() => _error = 'Prix de gros invalide.');
    if (_purchase.text.trim().isNotEmpty && _amount(_purchase) == null) return setState(() => _error = 'Prix d’achat invalide.');
    setState(() => (_saving = true, _error = null));
    try {
      final Product product;
      if (_editing) {
        final e = widget.existing!;
        final minimum = CatalogueValidation.quantity(_minimum.text);
        final changes = <String, Object?>{
          if (_name.text.trim() != e.name) 'nom': _name.text,
          if ((_reference.text.trim().isEmpty ? null : _reference.text.trim()) != e.reference) 'reference': _reference.text,
          if (_category != e.categoryUuid) 'categorie_uuid': _category,
          if (price != e.price) 'prix': price,
          if (_amount(_wholesale) != e.wholesalePrice) 'prix_gros': _amount(_wholesale),
          if (minimum != e.wholesaleMin) 'gros_quantite_min': _minimum.text,
        };
        if (changes.isEmpty) {
          if (mounted) Navigator.pop(context);
          return;
        }
        // Valeurs lues à l'ouverture (protection de C, `c31c0c9`) : refus si une synchronisation les a changées depuis.
        final read = <String, Object?>{
          'nom': e.name,
          'reference': e.reference,
          'categorie_uuid': e.categoryUuid,
          'prix': e.price,
          'prix_gros': e.wholesalePrice,
          'gros_quantite_min': e.wholesaleMin,
        };
        product = await widget.engine.updateProduct(
          widget.operator,
          e.productId,
          changes,
          expected: {for (final k in changes.keys) k: read[k]},
        );
      } else {
        product = await widget.engine.createProduct(
          widget.operator,
          NewProduct(
            name: _name.text,
            reference: _reference.text,
            barcodes: _barcodes.text.split(RegExp(r'[\s,;]+')),
            categoryUuid: _category,
            price: price,
            purchasePrice: _amount(_purchase),
            wholesalePrice: _amount(_wholesale),
            wholesaleMin: _minimum.text,
            unlimitedStock: true,
          ),
        );
      }
      if (mounted) Navigator.pop(context, product);
    } on OfflineRefusal catch (e) {
      if (mounted) setState(() => (_saving = false, _error = e.message));
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories = widget.engine.productCategories;
    final digits = [FilteringTextInputFormatter.digitsOnly];
    return AlertDialog(
      title: Text(_editing ? 'Modifier « ${widget.existing!.name} »' : 'Nouveau produit'),
      scrollable: true,
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _editing
                  ? 'La modification s’applique tout de suite sur ce terminal et part au serveur à la prochaine synchronisation. '
                        'Si la fiche a changé entre-temps sur le web, un responsable arbitre.'
                  : 'Vendable tout de suite sur ce terminal, sans stock initial. Envoyé au serveur à la prochaine synchronisation ; '
                        'un code-barres ou une référence déjà utilisés dans la boutique passent en arbitrage sur le web.',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
            TextField(controller: _name, maxLength: CatalogueLimits.name, decoration: const InputDecoration(labelText: 'Nom *')),
            TextField(controller: _reference, maxLength: CatalogueLimits.reference, decoration: const InputDecoration(labelText: 'Référence')),
            if (!_editing)
              TextField(
                controller: _barcodes,
                decoration: const InputDecoration(labelText: 'Codes-barres (5 au plus, séparés par un espace)', helperText: 'Vide : code interne attribué par le serveur.'),
              )
            else if (widget.existing!.barcodes.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('Codes-barres : ${widget.existing!.barcodes.join(', ')} (non modifiables ici)', style: const TextStyle(fontSize: 12)),
              ),
            DropdownButtonFormField<String?>(
              initialValue: categories.any((c) => c.uuid == _category) ? _category : null,
              decoration: const InputDecoration(labelText: 'Catégorie'),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('Aucune')),
                for (final c in categories) DropdownMenuItem<String?>(value: c.uuid, child: Text(c.name)),
              ],
              onChanged: (v) => setState(() => _category = v),
            ),
            TextField(controller: _price, keyboardType: TextInputType.number, inputFormatters: digits, decoration: const InputDecoration(labelText: 'Prix de vente (F) *')),
            if (!_editing)
              TextField(
                controller: _purchase,
                keyboardType: TextInputType.number,
                inputFormatters: digits,
                decoration: const InputDecoration(labelText: 'Prix d’achat (F)', helperText: 'Vide : 0 au serveur.'),
              ),
            Row(
              children: [
                Expanded(
                  child: TextField(controller: _wholesale, keyboardType: TextInputType.number, inputFormatters: digits, decoration: const InputDecoration(labelText: 'Prix de gros (F)')),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _minimum,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'À partir de (quantité)'),
                  ),
                ),
              ],
            ),
            if (!_editing)
              const ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.all_inclusive),
                title: Text('Stock illimité'),
                subtitle: Text('Un produit créé sur le poste n’a pas de suivi de stock ; la boutique le règle ensuite au back-office.'),
              ),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: Colors.red))),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton(onPressed: _saving ? null : _save, child: Text(_editing ? 'Enregistrer' : 'Créer le produit')),
      ],
    );
  }
}

/// Libellé court d'un état local de fiche (`products[].local_state`).
String? productLocalLabel(String? state) => switch (state) {
  'cree_local' => 'Créé ici, à synchroniser',
  'modifie_local' => 'Modifié ici, à synchroniser',
  'conflit' => 'À arbitrer sur le web',
  'refuse' => 'Refusé par le serveur',
  _ => null,
};

String _when(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// Créations et modifications de ce terminal, avec leur état (note A §6).
Future<void> showCatalogueChanges(BuildContext context, CaisseEngine engine) async {
  final changes = await engine.catalogueChanges();
  if (!context.mounted) return;
  String label(String state) => switch (state) {
    'a_synchroniser' => 'À synchroniser',
    'conflit' => 'À arbitrer par un responsable sur le web',
    'refuse' => 'Refusé',
    'rattache' => 'Rattaché à un produit existant',
    _ => 'Intégré',
  };
  Color color(String state) => switch (state) {
    'conflit' => Colors.deepOrange,
    'refuse' => Colors.red,
    'a_synchroniser' => Colors.blueGrey,
    _ => Colors.green,
  };
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Produits créés ou modifiés ici'),
      content: SizedBox(
        width: 520,
        child: changes.isEmpty
            ? const Text('Aucune création ni modification sur ce terminal.')
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final c in changes)
                    ListTile(
                      dense: true,
                      leading: Icon(c.kind == 'creation' ? Icons.add_box_outlined : Icons.edit_outlined, color: color(c.state)),
                      title: Text(c.name),
                      subtitle: Text([
                        '${c.kind == 'creation' ? 'Création' : 'Modification'} · ${label(c.state)}',
                        ?c.reason,
                        if (c.createdAt != null) _when(c.createdAt!.toLocal()),
                      ].join('\n')),
                    ),
                ],
              ),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Fermer'))],
    ),
  );
}
