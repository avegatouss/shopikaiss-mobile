import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

/// Never moves, deletes or reuses a database when changing server.
class SiteProfiles {
  SiteProfiles(this.root);
  final String root;
  String active = 'default';
  Map<String, String> names = {'default': 'Connexion existante'};
  File get file => File(p.join(root, 'sites.json'));
  String get dataDirectory => directory(active);
  String directory(String id) {
    if (id != 'default' && !RegExp(r'^[a-f0-9-]{36}$').hasMatch(id)) {
      throw const FormatException('Identifiant de site invalide.');
    }
    return id == 'default' ? p.join(root, 'caisse') : p.join(root, 'sites', id);
  }

  Future<void> load() async {
    if (!await file.exists()) return;
    final json = jsonDecode(await file.readAsString()) as Map;
    if (json['schema'] != 1) {
      throw const FormatException('Registre de sites incompatible.');
    }
    final entries = Map<String, String>.from(json['names'] as Map);
    final selected = json['active'] as String;
    for (final id in entries.keys) {
      directory(id);
    }
    if (!entries.containsKey(selected) || !entries.containsKey('default')) {
      throw const FormatException('Registre de sites incomplet.');
    }
    names = entries;
    active = selected;
  }

  Future<void> select(String? id) async {
    final next = id ?? const Uuid().v4();
    if (id != null && !names.containsKey(id)) {
      throw const FormatException('Site inconnu.');
    }
    directory(next);
    final entries = {...names, if (id == null) next: 'Nouvelle connexion'};
    await _write(next, entries);
    names = entries;
    active = next;
  }

  Future<void> labelOrigin(String origin, {String? terminal}) async {
    final uri = Uri.tryParse(origin);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return;
    }
    final label = terminal == null || terminal.isEmpty
        ? uri.origin
        : '${uri.origin} · $terminal';
    final entries = {...names, active: label};
    if (names[active] == label) return;
    await _write(active, entries);
    names = entries;
  }

  Future<void> _write(String selected, Map<String, String> entries) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.${const Uuid().v4()}.tmp');
    await temporary.writeAsString(
      jsonEncode({'schema': 1, 'active': selected, 'names': entries}),
      flush: true,
    );
    await temporary.rename(file.path);
  }
}

String? siteSwitchRefusal(
  Map<String, dynamic> status,
  Map<String, dynamic> view, {
  required bool uncertain,
}) {
  if (uncertain) {
    return 'Une opération reste à vérifier. Résolvez-la avant de changer de site.';
  }
  if (status['pending'] is! int ||
      status['arbitration'] is! int ||
      view['lines'] is! List) {
    return 'État du moteur incomplet. Le changement de site est bloqué.';
  }
  if (status['pending'] != 0) {
    return 'Synchronisez toutes les opérations en attente avant de changer de site.';
  }
  if (status['arbitration'] != 0) {
    return 'Résolvez les opérations à arbitrer avant de changer de site.';
  }
  if ((view['lines'] as List).isNotEmpty) {
    return 'Terminez ou mettez le panier en attente avant de changer de site.';
  }
  return null;
}

Future<bool> hasUnresolvedSiteIntent(String directory) async {
  for (final name in [
    'pending-sale.json',
    'pending-sale-v2.json',
    'pending-return-v2.json',
    'pending-close-v2.json',
    'pending-restaurant-v1.json',
    'pending-closure-edition-v1.json',
  ]) {
    if (await File(p.join(directory, name)).exists()) return true;
  }
  return false;
}
