import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../platform/receipt_printing.dart';
import '../ipc/protocol.dart';
import 'image_schedule.dart';
import '../platform/customer_display.dart';
import 'customer_display_settings.dart';

/// Local presentation preferences only; never changes shop policies or totals.
class ScreenSettings {
  bool compact = false;
  bool scannerAutoFocus = true;
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
  String backOffice = '';

  /// Ticket après une vente : `ask` (demandé au caissier) ou `auto`.
  String ticketMode = 'ask';
  Uri? get backOfficeUri {
    final uri = Uri.tryParse(backOffice.trim());
    return uri != null &&
            uri.scheme == 'https' &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty &&
            !uri.hasQuery &&
            !uri.hasFragment
        ? uri
        : null;
  }

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
      backOfficeRead(result, data);
      if (accents.containsKey(data['accent'])) {
        result.accent = data['accent'] as String;
      }
      if (['left', 'top', 'hidden'].contains(data['image_layout'])) {
        result.imageLayout = data['image_layout'] as String;
      }
      if (['contain', 'cover'].contains(data['image_fit'])) {
        result.imageFit = data['image_fit'] as String;
      }
      if (data['ticket_mode'] == 'auto') result.ticketMode = 'auto';
      result.scannerAutoFocus = data['scanner_auto_focus'] != false;
      result.compact = data['compact'] == true;
      result.tileWidth = (data['tile_width'] as num).toDouble().clamp(150, 330);
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
        'scanner_auto_focus': scannerAutoFocus,
        'tile_width': tileWidth,
        'catalogue_percent': cataloguePercent,
        'accent': accent,
        'image_layout': imageLayout,
        'image_fit': imageFit,
        'back_office': backOffice,
        'ticket_mode': ticketMode,
      }),
      flush: true,
    );
  }

  static void backOfficeRead(ScreenSettings result, Map data) {
    if (data['back_office'] is String) {
      result.backOffice = data['back_office'] as String;
    }
  }
}

class ScreenSettingsPanel extends StatelessWidget {
  const ScreenSettingsPanel({
    super.key,
    required this.settings,
    required this.onChanged,
    this.host,
    this.display,
  });
  final ScreenSettings settings;
  final VoidCallback onChanged;
  final WindowsHost? host;
  final CustomerDisplayService? display;

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
          TextFormField(
            initialValue: settings.backOffice,
            decoration: const InputDecoration(
              labelText: 'Adresse HTTPS du back-office',
              helperText: 'Sans identifiant ni paramètre de connexion.',
            ),
            onChanged: (v) {
              settings.backOffice = v;
              onChanged();
            },
          ),
          if (settings.backOffice.isNotEmpty && settings.backOfficeUri == null)
            const Text(
              'Adresse HTTPS valide requise, sans paramètres ni identifiants.',
            ),
          DropdownButtonFormField<String>(
            initialValue: settings.ticketMode,
            decoration: const InputDecoration(
              labelText: 'Ticket après une vente',
            ),
            items: const [
              DropdownMenuItem(
                value: 'ask',
                child: Text('Demander avant d’imprimer'),
              ),
              DropdownMenuItem(
                value: 'auto',
                child: Text('Impression automatique'),
              ),
            ],
            onChanged: (value) {
              settings.ticketMode = value ?? 'ask';
              onChanged();
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.print_outlined),
            title: const Text('Imprimante par défaut de la caisse'),
            subtitle: const Text(
              'Choisir parmi les imprimantes Windows installées.',
            ),
            onTap: () async {
              try {
                await ReceiptPrinting.choose(context);
              } catch (_) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Liste des imprimantes indisponible. Vérifiez les pilotes Windows.',
                      ),
                    ),
                  );
                }
              }
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Mode d’impression : caisse ou A4'),
            subtitle: const Text(
              'ESC/POS brut par défaut ; PDF disponible en secours.',
            ),
            onTap: () async {
              try {
                await ReceiptPrinting.configure(context);
              } catch (_) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Réglage imprimante indisponible.'),
                    ),
                  );
                }
              }
            },
          ),
          const _TestReceiptButton(),
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
            title: const Text('Focus automatique du lecteur code-barres'),
            subtitle: const Text(
              'Désactiver pour privilégier la saisie tactile. F2 permet toujours de scanner.',
            ),
            value: settings.scannerAutoFocus,
            onChanged: (value) {
              settings.scannerAutoFocus = value;
              onChanged();
            },
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
          Text('Taille des produits : ${settings.tileWidth.round()} px'),
          Row(
            children: [
              IconButton(
                tooltip: 'Réduire les produits',
                icon: const Icon(Icons.remove),
                onPressed: () {
                  settings.tileWidth = (settings.tileWidth - 15).clamp(
                    150,
                    330,
                  );
                  onChanged();
                },
              ),
              const Expanded(
                child: Text('Petits ← → Grands', textAlign: TextAlign.center),
              ),
              IconButton(
                tooltip: 'Agrandir les produits',
                icon: const Icon(Icons.add),
                onPressed: () {
                  settings.tileWidth = (settings.tileWidth + 15).clamp(
                    150,
                    330,
                  );
                  onChanged();
                },
              ),
            ],
          ),
          Slider(
            value: settings.tileWidth,
            min: 150,
            max: 330,
            divisions: 12,
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
              'Photos conservées sur ce poste, téléchargées par petits lots. Le téléchargement se met en pause dès qu’un panier est actif. Les photos déjà reçues restent disponibles hors connexion.',
            ),
          ),
          if (host != null) ImageSchedule(host: host!),
          if (display != null) CustomerDisplaySettings(service: display!),
        ],
      ),
    ),
  );
}

class _TestReceiptButton extends StatefulWidget {
  const _TestReceiptButton();
  @override
  State<_TestReceiptButton> createState() => _TestReceiptButtonState();
}

class _TestReceiptButtonState extends State<_TestReceiptButton> {
  bool busy = false;
  String? message;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      OutlinedButton.icon(
        icon: const Icon(Icons.receipt_long_outlined),
        label: Text(
          busy
              ? 'Envoi du ticket…'
              : 'Imprimer un ticket d’essai (aucune vente)',
        ),
        onPressed: busy
            ? null
            : () async {
                setState(() {
                  busy = true;
                  message = null;
                });
                String result;
                try {
                  result = await ReceiptPrinting.testTicket();
                } catch (_) {
                  result =
                      'Impression à vérifier. Aucun second envoi automatique.';
                }
                if (mounted) {
                  setState(() {
                    busy = false;
                    message = result;
                  });
                }
              },
      ),
      if (message != null) Text(message!),
    ],
  );
}
