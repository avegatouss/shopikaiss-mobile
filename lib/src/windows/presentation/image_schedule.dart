import 'package:flutter/material.dart';

import '../ipc/protocol.dart';

/// Settings are persisted by the engine, beside its image cache.
class ImageSchedule extends StatefulWidget {
  const ImageSchedule({super.key, required this.host});
  final WindowsHost host;
  @override
  State<ImageSchedule> createState() => _ImageScheduleState();
}

class _ImageScheduleState extends State<ImageSchedule> {
  final start = TextEditingController(text: '22:00');
  final end = TextEditingController(text: '06:00');
  bool limited = false, busy = true, loaded = false;
  String? message;
  String counts = '';
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final value = await widget.host.call(HostCommand.imageSettings);
      if (!mounted) return;
      limited = value['start'] != null;
      start.text = value['start'] as String? ?? '22:00';
      end.text = value['end'] as String? ?? '06:00';
      counts =
          '${value['images_cached'] ?? 0} / ${value['images_total'] ?? 0} photos en cache';
      loaded = true;
    } catch (e) {
      message = e.toString();
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await widget.host.call(
        HostCommand.setImageSettings,
        arguments: limited
            ? {'start': start.text.trim(), 'end': end.text.trim()}
            : {},
      );
      if (mounted) {
        setState(() => message = 'Horaires enregistrés sur ce poste.');
      }
    } catch (e) {
      if (mounted) setState(() => message = e.toString());
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  void dispose() {
    start.dispose();
    end.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(counts),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Limiter les téléchargements à une plage horaire'),
        value: limited,
        onChanged: busy || !loaded ? null : (v) => setState(() => limited = v),
      ),
      if (limited)
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: start,
                enabled: !busy,
                keyboardType: TextInputType.datetime,
                decoration: const InputDecoration(labelText: 'Début · HH:MM'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: end,
                enabled: !busy,
                keyboardType: TextInputType.datetime,
                decoration: const InputDecoration(labelText: 'Fin · HH:MM'),
              ),
            ),
          ],
        ),
      const Text(
        'Heure locale du poste. Une plage 22:00–06:00 traverse minuit.',
      ),
      if (message != null) Semantics(liveRegion: true, child: Text(message!)),
      FilledButton(
        onPressed: busy || !loaded ? null : save,
        child: Text(busy ? 'Chargement…' : 'Enregistrer les horaires'),
      ),
    ],
  );
}
