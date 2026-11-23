import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../offline/caisse_engine.dart';
import '../restaurant/resto_display_server.dart';
import '../sync_v2/v2_backup.dart';
import 'display_mode_page.dart';
import 'terminal_session.dart';

/// Réglages › Restaurant (lot R-6) : page d'afficheur servie par ce téléphone quand il est la caisse maîtresse, écrans
/// reliés, sauvegarde de la caisse (export, restauration sur un autre appareil) et mode « afficheur » d'une tablette.
class MasterSettingsSection extends StatefulWidget {
  const MasterSettingsSection({super.key, required this.session});

  final TerminalSession session;

  @override
  State<MasterSettingsSection> createState() => _MasterSettingsSectionState();
}

class _MasterSettingsSectionState extends State<MasterSettingsSection> {
  late final TextEditingController _port = TextEditingController(text: '${widget.session.settings.displayServerPort}');
  String? _message;
  bool _busy = false;

  TerminalSession get _session => widget.session;
  CaisseEngine get _engine => _session.offline;

  @override
  void initState() {
    super.initState();
    _session.master.addListener(_changed);
  }

  @override
  void dispose() {
    _session.master.removeListener(_changed);
    _port.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _run(Future<String?> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final message = await action();
      if (mounted) setState(() => _message = message);
    } on OfflineRefusal catch (e) {
      if (mounted) setState(() => _message = e.message);
    } catch (e) {
      if (mounted) setState(() => _message = 'Erreur : $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setServer(bool on) => _run(() async {
    final port = int.tryParse(_port.text.trim());
    if (on && (port == null || port < 1024 || port > 65535)) return 'Port entre 1024 et 65535.';
    _session.settings
      ..displayServer = on
      ..displayServerPort = port ?? _session.settings.displayServerPort;
    await _session.save();
    return null;
  });

  Future<void> _newCode() async {
    final display = _session.master.display;
    if (display == null) return;
    final code = display.newPairingCode();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Code pour relier un écran'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(child: SelectableText(code, style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w700, letterSpacing: 6))),
            const SizedBox(height: 12),
            Text('Sur la tablette, ouvrez ${_session.master.displayLinks.isEmpty ? 'l’adresse de ce téléphone' : _session.master.displayLinks.first} '
                'puis saisissez ce code. Valable 10 minutes, pour un seul écran.'),
          ],
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Fermer'))],
      ),
    );
  }

  Future<void> _export() => _run(() async {
    final (bytes, info) = await _engine.createBackup();
    String two(int v) => v.toString().padLeft(2, '0');
    final t = info.createdAt.toLocal();
    final name = 'caisse-${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}.${CaisseBackup.extension}';
    final result = await _session.channel.saveDocument(name, bytes);
    if (result.ok) return 'Sauvegarde enregistrée (${info.operations} opérations, dont ${info.unsent} non envoyées). Gardez-la hors de ce téléphone.';
    return result.error == 'cancelled' ? null : 'Sauvegarde non enregistrée : ${result.error}';
  });

  Future<void> _restore() async {
    final bytes = await _session.channel.openDocument();
    if (bytes == null || !mounted) return;
    final CaisseBackupInfo info;
    try {
      info = CaisseBackup.inspect(bytes);
    } on CaisseBackupRefusal catch (e) {
      setState(() => _message = e.message);
      return;
    }
    String when(DateTime d) {
      String two(int v) => v.toString().padLeft(2, '0');
      final t = d.toLocal();
      return '${two(t.day)}/${two(t.month)}/${t.year} à ${two(t.hour)}:${two(t.minute)}';
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restaurer cette sauvegarde ?'),
        content: SingleChildScrollView(
          child: Text(
            'Sauvegarde du ${when(info.createdAt)} (${info.platform == 'windows' ? 'poste Windows' : 'téléphone'}'
            '${info.terminalName == null ? '' : ', ${info.terminalName}'}${info.shopName == null ? '' : ', ${info.shopName}'}) : '
            '${info.operations} opérations, dont ${info.unsent} non envoyées.\n\n'
            'Tout ce que contient cette caisse sera remplacé. Avant de continuer, isolez l’ancienne caisse maîtresse (éteinte ou débranchée) : '
            'elle ne doit plus servir.\n\n'
            'Ensuite : appairez ce téléphone avec un nouveau code, puis le gérant le désigne caisse maîtresse au back-office. '
            'Les bons au résultat incertain se vérifient sur place : rien n’est réimprimé automatiquement.',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Restaurer')),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() async {
      // Copie de secours de cette caisse avant remplacement (audit M03), à part des sauvegardes automatiques.
      final (current, _) = await _engine.createBackup();
      await CaisseBackup.writeRotating(Directory(p.join(_session.backupDirectory.path, 'avant-restauration')), current, at: DateTime.now(), keep: 3);
      await _engine.restoreBackup(bytes);
      await _session.master.apply();
      return 'Sauvegarde restaurée. Appairez maintenant ce téléphone (Caisse hors ligne ci-dessus), puis faites-le désigner caisse maîtresse.';
    });
  }

  Future<void> _displayMode() async {
    final input = TextEditingController(text: 'http://192.168.');
    String? error;
    final url = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Utiliser cet appareil comme afficheur'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Adresse affichée sur la caisse maîtresse (Réglages › Restaurant), par exemple http://192.168.1.20:8787/. '
                  'Cet appareil n’est pas appairé à la boutique : il ne parle qu’à la caisse du lieu.'),
              TextField(controller: input, keyboardType: TextInputType.url, autocorrect: false, decoration: InputDecoration(errorText: error)),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
            FilledButton(
              onPressed: () {
                final normalized = displayModeUrlOf(input.text);
                if (normalized == null) {
                  setLocal(() => error = 'Adresse du réseau local attendue (http://IP:port/).');
                } else {
                  Navigator.pop(context, normalized);
                }
              },
              child: const Text('Ouvrir'),
            ),
          ],
        ),
      ),
    );
    input.dispose();
    if (url == null || !mounted) return;
    _session.settings.displayModeUrl = url;
    await _session.settings.save();
    if (!mounted) return;
    await Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute<void>(builder: (_) => DisplayModePage(session: _session)), (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    final master = _session.master;
    final settings = _session.settings;
    final display = master.display;
    final theme = Theme.of(context);
    String two(int v) => v.toString().padLeft(2, '0');
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Restaurant : caisse maîtresse et afficheurs', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                master.master
                    ? 'Ce téléphone est la caisse maîtresse du lieu. Gardez-le sur secteur, application ouverte, sans économiseur de batterie.'
                    : 'Ce téléphone n’est pas caisse maîtresse. Le gérant la désigne au back-office (Paramètres › Caisse maîtresse).',
                style: theme.textTheme.bodySmall,
              ),
              if (master.batteryWarning case final warning?)
                Padding(padding: const EdgeInsets.only(top: 8), child: Text(warning, style: const TextStyle(color: Colors.deepOrange, fontWeight: FontWeight.w600))),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Servir la page d’afficheur sur le Wi-Fi'),
                subtitle: const Text('Tablettes et télévisions du lieu, sans internet. Éteint par défaut.'),
                value: settings.displayServer,
                onChanged: _busy ? null : _setServer,
              ),
              Row(
                children: [
                  SizedBox(
                    width: 140,
                    child: TextField(
                      controller: _port,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(labelText: 'Port'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  TextButton(onPressed: _busy || !settings.displayServer ? null : () => _setServer(true), child: const Text('Appliquer le port')),
                ],
              ),
              if (master.displayError case final error?) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error, style: const TextStyle(color: Colors.red))),
              if (settings.displayServer && display == null && master.displayError == null)
                const Padding(padding: EdgeInsets.only(top: 8), child: Text('La page démarrera dès que ce téléphone sera caisse maîtresse.')),
              if (display != null) ...[
                const SizedBox(height: 8),
                Text('Adresse à ouvrir sur la tablette :', style: theme.textTheme.labelLarge),
                for (final link in master.displayLinks) SelectableText(link, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                if (master.displayLinks.isEmpty) const Text('Aucun réseau Wi-Fi local détecté : connectez ce téléphone au Wi-Fi du lieu.'),
                const SizedBox(height: 8),
                Align(alignment: Alignment.centerLeft, child: FilledButton.tonalIcon(onPressed: _newCode, icon: const Icon(Icons.link), label: const Text('Relier un écran (code)'))),
                const SizedBox(height: 8),
                Text('Écrans reliés', style: theme.textTheme.labelLarge),
                if (display.devices.isEmpty) const Text('Aucun.'),
                for (final d in display.devices)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(display.lastSeen(d.id) == null ? Icons.tv_off_outlined : Icons.tv_outlined),
                    title: Text(d.name),
                    subtitle: Text(switch (display.lastSeen(d.id)) {
                      final seen? => 'Dernier contact ${two(seen.hour)}:${two(seen.minute)}:${two(seen.second)}',
                      null => 'Pas encore connecté depuis le démarrage',
                    }),
                    trailing: TextButton(onPressed: () async {
                      await display.revoke(d.id);
                      _changed();
                    }, child: const Text('Retirer')),
                  ),
              ],
              const Divider(height: 32),
              Text('Sauvegarde de la caisse', style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              Text(
                master.master
                    ? 'Automatique toutes les 5 minutes sur ce téléphone${master.lastBackupAt == null ? '' : ' (dernière à ${two(master.lastBackupAt!.hour)}:${two(master.lastBackupAt!.minute)})'}. '
                        'Exportez-en une régulièrement hors du téléphone : elle se restaure sur un autre téléphone ou sur un poste Windows.'
                    : 'Une sauvegarde se restaure sur un autre téléphone ou sur un poste Windows, même version de l’application.',
                style: theme.textTheme.bodySmall,
              ),
              if (master.backupError case final error?) Text(error, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(onPressed: _busy || !Platform.isAndroid ? null : _export, icon: const Icon(Icons.save_alt), label: const Text('Exporter une sauvegarde')),
                  OutlinedButton.icon(onPressed: _busy || !Platform.isAndroid ? null : _restore, icon: const Icon(Icons.settings_backup_restore), label: const Text('Restaurer une sauvegarde')),
                ],
              ),
              const Divider(height: 32),
              Text('Tablette afficheur', style: theme.textTheme.labelLarge),
              Text('Cet appareil n’encaisse pas : il affiche les bons d’un poste, servis par la caisse maîtresse du lieu.', style: theme.textTheme.bodySmall),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(onPressed: _busy || _engine.paired ? null : _displayMode, icon: const Icon(Icons.tv), label: const Text('Utiliser cet appareil comme afficheur')),
              ),
              if (_engine.paired) Text('Indisponible sur une caisse appairée.', style: theme.textTheme.bodySmall),
              if (_message case final message?) Padding(padding: const EdgeInsets.only(top: 12), child: Text(message)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Adresse de la page d'afficheur saisie sur la tablette, ramenée à `http://hôte:port/` ; null si elle ne désigne pas
/// le réseau local (adresse IPv4 privée ou nom en `.local`).
String? displayModeUrlOf(String input) {
  var text = input.trim();
  if (text.isEmpty) return null;
  if (!text.contains('://')) text = 'http://$text';
  final uri = Uri.tryParse(text);
  if (uri == null || uri.scheme != 'http' || uri.host.isEmpty || uri.userInfo.isNotEmpty) return null;
  final host = uri.host.toLowerCase();
  final address = InternetAddress.tryParse(host);
  final local = address != null ? (address.type == InternetAddressType.IPv4 && RestoDisplayServer.isPrivateAddress(address) && !address.isLoopback) : host.endsWith('.local');
  if (!local) return null;
  final port = uri.hasPort ? uri.port : RestoDisplayServer.defaultPort;
  return 'http://$host:$port/';
}
