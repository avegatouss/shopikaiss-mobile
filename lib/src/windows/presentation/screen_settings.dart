import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

/// Local presentation preferences only; never changes shop policies or totals.
class ScreenSettings {
  bool compact = false;
  double tileWidth = 175;
  int cataloguePercent = 58;
  static File? get file {
    final root = Platform.environment['LOCALAPPDATA'];
    if (root == null || Platform.environment.containsKey('FLUTTER_TEST')) {
      return null;
    }
    return File('$root/ShopiKaiss/screen-settings.json');
  }

  static ScreenSettings load() {
    final result = ScreenSettings();
    try {
      final source = file;
      if (source == null || !source.existsSync()) return result;
      final data = jsonDecode(source.readAsStringSync()) as Map;
      result.compact = data['compact'] == true;
      result.tileWidth = (data['tile_width'] as num).toDouble().clamp(150, 240);
      result.cataloguePercent = (data['catalogue_percent'] as num)
          .toInt()
          .clamp(45, 65);
    } catch (_) {
      /* A broken preference file never blocks selling. */
    }
    return result;
  }

  Future<void> save() async {
    final target = file;
    if (target == null) return;
    await target.parent.create(recursive: true);
    await target.writeAsString(
      jsonEncode({
        'compact': compact,
        'tile_width': tileWidth,
        'catalogue_percent': cataloguePercent,
      }),
      flush: true,
    );
  }
}

class ScreenSettingsPanel extends StatelessWidget {
  const ScreenSettingsPanel({
    super.key,
    required this.settings,
    required this.onChanged,
  });
  final ScreenSettings settings;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => Drawer(
    width: 360,
    child: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Réglages de l’écran',
                  style: TextStyle(fontSize: 22),
                ),
              ),
              IconButton(
                tooltip: 'Fermer les réglages',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const Text('Réglages propres à ce poste. Aperçu immédiat.'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Catalogue en liste'),
            value: settings.compact,
            onChanged: (v) {
              settings.compact = v;
              onChanged();
            },
          ),
          const Text('Taille des fiches produits'),
          Slider(
            value: settings.tileWidth,
            min: 150,
            max: 240,
            divisions: 6,
            label: '${settings.tileWidth.round()} px',
            onChanged: (v) {
              settings.tileWidth = v;
              onChanged();
            },
          ),
          Text('Largeur du catalogue : ${settings.cataloguePercent} %'),
          Slider(
            value: settings.cataloguePercent.toDouble(),
            min: 45,
            max: 65,
            divisions: 20,
            onChanged: (v) {
              settings.cataloguePercent = v.round();
              onChanged();
            },
          ),
          const Text(
            'Sur petit écran, les onglets Articles et Panier sont conservés.',
          ),
          const Divider(height: 32),
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.image_outlined),
            title: Text('Images des produits'),
            subtitle: Text(
              'Synchronisation par lots nocturnes en préparation. Elle ne sera pas lancée à chaque vente. Le moteur ne fournit pas encore les images.',
            ),
          ),
        ],
      ),
    ),
  );
}
