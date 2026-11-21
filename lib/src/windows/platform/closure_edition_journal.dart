import 'dart:convert';
import 'dart:io';

import '../ipc/protocol.dart';

/// Remembers an edition, never its print bytes. Recovery cannot print again.
class ClosureEditionJournal {
  ClosureEditionJournal(this.host, {this.file});
  final WindowsHost host;
  final File? file;
  Map<String, dynamic>? pending;

  Future<void> load() async {
    if (file != null && await file!.exists()) {
      final value = jsonDecode(await file!.readAsString());
      if (value is! Map ||
          value['edition_id'] is! String ||
          !const ['prepared', 'transmitted'].contains(value['state'])) {
        throw const FormatException('Journal des éditions illisible.');
      }
      pending = value.cast<String, dynamic>();
    }
    if (pending?['state'] == 'transmitted') await confirm();
  }

  Future<void> begin(String id) async {
    if (pending != null) throw StateError('Édition précédente à vérifier.');
    pending = {'edition_id': id, 'state': 'prepared'};
    await _save();
  }

  Future<void> confirm() async {
    if (pending == null) return;
    pending!['state'] = 'transmitted';
    await _save();
    final response = await host.call(
      HostCommand.cashClosureEdition,
      arguments: {'edition_id': pending!['edition_id']},
    );
    if (response['recorded'] != true) {
      if (const [
        'edition_inconnue',
        'caissier_inconnu',
      ].contains(response['reason'])) {
        await discard();
        throw const HostFailure(
          'edition_expired',
          'Le moteur ne peut plus confirmer cette édition. Le journal d’attente a été libéré ; aucune réimpression ni confirmation d’audit n’a été effectuée.',
        );
      }
      throw const HostFailure(
        'edition_unrecorded',
        'Édition non enregistrée par le moteur. Conservez ce journal pour vérification.',
      );
    }
    await discard();
  }

  Future<void> discard() async {
    if (file != null && await file!.exists()) await file!.delete();
    pending = null;
  }

  Future<void> _save() async {
    if (file == null) return;
    await file!.parent.create(recursive: true);
    await file!.writeAsString(jsonEncode(pending), flush: true);
  }
}
