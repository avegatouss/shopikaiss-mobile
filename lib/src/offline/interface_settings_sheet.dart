import 'package:flutter/material.dart';

import 'register_interface.dart';

/// Réglage local de l'interface de la caisse (2.1 lot 13) : éléments visibles et ordre, tailles. Rend le nouveau
/// réglage, `RegisterInterface.defaults` pour « Revenir au réglage de la boutique » (réglage local effacé), ou null.
/// Verrouillée par le responsable : rien n'est modifiable, le réglage local est gardé tel quel.
Future<RegisterInterface?> showInterfaceSettings(BuildContext context, {required RegisterInterface published, RegisterInterface? local}) =>
    showModalBottomSheet<RegisterInterface>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _InterfaceSheet(published: published, local: local),
    );

class _InterfaceSheet extends StatefulWidget {
  const _InterfaceSheet({required this.published, this.local});

  final RegisterInterface published;
  final RegisterInterface? local;

  @override
  State<_InterfaceSheet> createState() => _InterfaceSheetState();
}

class _InterfaceSheetState extends State<_InterfaceSheet> {
  late List<String> _order;
  late Map<String, bool> _visible;
  late String _category, _product, _compact, _pay;

  bool get _locked => widget.published.locked;

  @override
  void initState() {
    super.initState();
    final start = _locked ? widget.published : (widget.local ?? widget.published);
    _order = start.sorted(RegisterInterface.known.keys.toList());
    _visible = {for (final k in _order) k: start.visible(k)};
    _category = start.categoryTile;
    _product = start.productTile;
    _compact = start.compactFont;
    _pay = start.payButton;
  }

  RegisterInterface get _result => RegisterInterface(
    origin: 'local',
    elements: {for (final (i, k) in _order.indexed) k: (_visible[k]!, i + 1)},
    categoryTile: _category,
    productTile: _product,
    compactFont: _compact,
    payButton: _pay,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget size(String label, String value, ValueChanged<String> onChanged) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 4),
          SegmentedButton<String>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: [for (final s in RegisterInterface.sizes) ButtonSegment(value: s, label: Text(RegisterInterface.sizeLabels[s]!))],
            selected: {value},
            onSelectionChanged: _locked ? null : (v) => setState(() => onChanged(v.single)),
          ),
        ],
      ),
    );
    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: .85,
        maxChildSize: .95,
        builder: (context, controller) => Column(
          children: [
            Expanded(
              child: ListView(
                controller: controller,
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                children: [
                  Text('Interface de la caisse', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(
                    _locked
                        ? 'Réglé par le responsable au back-office : ce poste applique son réglage.'
                        : widget.published.origin == 'defaut'
                        ? 'Réglage de ce poste. Le back-office peut aussi régler l’interface de toute la boutique.'
                        : 'Réglage de ce poste : il remplace celui du back-office tant que le responsable ne le verrouille pas.',
                    style: TextStyle(color: _locked ? const Color(0xFFE65100) : theme.textTheme.bodySmall?.color),
                  ),
                  const SizedBox(height: 12),
                  size('Tuiles de catégories', _category, (v) => _category = v),
                  size('Tuiles de produits', _product, (v) => _product = v),
                  size('Texte en vue compacte', _compact, (v) => _compact = v),
                  size('Bouton Payer', _pay, (v) => _pay = v),
                  const SizedBox(height: 12),
                  Text('Éléments affichés · glissez pour changer l’ordre', style: theme.textTheme.titleSmall),
                  ReorderableListView(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    buildDefaultDragHandles: !_locked,
                    onReorderItem: (from, to) => setState(() => _order.insert(to, _order.removeAt(from))),
                    children: [
                      for (final key in _order)
                        SwitchListTile(
                          key: ValueKey(key),
                          contentPadding: const EdgeInsets.only(right: 32),
                          dense: true,
                          title: Text(RegisterInterface.known[key]!),
                          value: _visible[key]!,
                          onChanged: _locked ? null : (v) => setState(() => _visible[key] = v),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Row(
                children: [
                  if (!_locked && widget.local != null)
                    TextButton(onPressed: () => Navigator.pop(context, RegisterInterface.defaults), child: const Text('Revenir au réglage de la boutique')),
                  const Spacer(),
                  TextButton(onPressed: () => Navigator.pop(context), child: Text(_locked ? 'Fermer' : 'Annuler')),
                  if (!_locked) ...[
                    const SizedBox(width: 8),
                    FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(0, 48)), onPressed: () => Navigator.pop(context, _result), child: const Text('Enregistrer')),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
