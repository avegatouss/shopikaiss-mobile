import 'dart:io';

import 'package:flutter/material.dart';

/// Local draft only. Does not connect, print, start a service or open a firewall.
class RestaurantStationDraft {
  const RestaurantStationDraft({
    required this.name,
    required this.address,
    required this.port,
  });
  final String name, address;
  final int port;
}

class RestaurantStationEditor extends StatefulWidget {
  const RestaurantStationEditor({super.key, this.initial});
  final RestaurantStationDraft? initial;
  @override
  State<RestaurantStationEditor> createState() =>
      _RestaurantStationEditorState();
}

class _RestaurantStationEditorState extends State<RestaurantStationEditor> {
  final form = GlobalKey<FormState>();
  late final name = TextEditingController(text: widget.initial?.name ?? '');
  late final address = TextEditingController(
    text: widget.initial?.address ?? '',
  );
  late final port = TextEditingController(
    text: '${widget.initial?.port ?? 9100}',
  );
  @override
  void dispose() {
    name.dispose();
    address.dispose();
    port.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Imprimante du poste'),
    scrollable: true,
    content: SizedBox(
      width: 460,
      child: Form(
        key: form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Préparer les coordonnées de la cuisine ou du bar. Aucun envoi ni test réseau n’est effectué ici.',
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: name,
              maxLength: 80,
              decoration: const InputDecoration(labelText: 'Nom du poste'),
              validator: (v) =>
                  (v?.trim().isEmpty ?? true) ? 'Indiquez un nom.' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: address,
              decoration: const InputDecoration(
                labelText: 'Adresse IP de l’imprimante',
                hintText: '192.168.1.50',
              ),
              validator: (v) =>
                  InternetAddress.tryParse(v?.trim() ?? '') == null
                  ? 'Indiquez une adresse IP valide, sans http:// ni chemin.'
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: port,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Port ESC/POS'),
              validator: (v) {
                final p = int.tryParse(v?.trim() ?? '');
                return p == null || p < 1 || p > 65535
                    ? 'Port compris entre 1 et 65535.'
                    : null;
              },
            ),
            const SizedBox(height: 16),
            const Text(
              'Le service d’affichage cuisine et l’envoi des bons seront activés après raccordement du moteur restaurant.',
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
        onPressed: () {
          if (!form.currentState!.validate()) return;
          Navigator.pop(
            context,
            RestaurantStationDraft(
              name: name.text.trim(),
              address: address.text.trim(),
              port: int.parse(port.text.trim()),
            ),
          );
        },
        child: const Text('Valider le brouillon'),
      ),
    ],
  );
}
