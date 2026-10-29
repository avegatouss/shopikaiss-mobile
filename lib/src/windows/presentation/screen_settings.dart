import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

/// Local presentation preferences only; never changes shop policies or totals.
class ScreenSettings {
  bool compact = false;
  double tileWidth = 175;
  int cataloguePercent = 58;
  static const accents = <String, int>{
    'Vert': 0xff164e42,
    'Bleu': 0xff234e86,
    'Prune': 0xff713c70,
    'Terracotta': 0xff91462d,
  };
  String accent = 'Vert';
  String imageLayout = 'left';
  String imageFit = 'contain';
  Color get accentColor => Color(accents[accent] ?? accents['Vert']!);
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
      if (accents.containsKey(data['accent'])) {
        result.accent = data['accent'] as String;
      }
      if (['left', 'top', 'hidden'].contains(data['image_layout'])) {
        result.imageLayout = data['image_layout'] as String;
      }
      if (['contain', 'cover'].contains(data['image_fit'])) {
        result.imageFit = data['image_fit'] as String;
      }
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
        'accent': accent,
        'image_layout': imageLayout,
        'image_fit': imageFit,
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
          const SizedBox(height: 16),
          const Text('Couleur principale'),
          Wrap(
            spacing: 6,
            children: [
              for (final entry in ScreenSettings.accents.entries)
                ChoiceChip(
                  label: Text(entry.key),
                  avatar: CircleAvatar(
                    backgroundColor: Color(entry.value),
                    radius: 7,
                  ),
                  selected: settings.accent == entry.key,
                  onSelected: (_) {
                    settings.accent = entry.key;
                    onChanged();
                  },
                ),
            ],
          ),
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
          const Text('Disposition des images'),
          DropdownButton<String>(
            isExpanded: true,
            value: settings.imageLayout,
            items: const [
              DropdownMenuItem(value: 'left', child: Text('À gauche du nom')),
              DropdownMenuItem(value: 'top', child: Text('Au-dessus du nom')),
              DropdownMenuItem(value: 'hidden', child: Text('Masquées')),
            ],
            onChanged: (value) {
              if (value != null) {
                settings.imageLayout = value;
                onChanged();
              }
            },
          ),
          DropdownButton<String>(
            isExpanded: true,
            value: settings.imageFit,
            items: const [
              DropdownMenuItem(value: 'contain', child: Text('Image entière')),
              DropdownMenuItem(
                value: 'cover',
                child: Text('Remplir le cadre (recadrage)'),
              ),
            ],
            onChanged: (value) {
              if (value != null) {
                settings.imageFit = value;
                onChanged();
              }
            },
          ),
          Container(
            height: 72,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: settings.accentColor.withValues(alpha: .08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              settings.imageLayout == 'hidden'
                  ? 'Nom du produit · Prix'
                  : '▧  Aperçu : emplacement réservé à la photo',
            ),
          ),
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
