import 'dart:convert';

import 'v2_client.dart';
import 'v2_store.dart';

/// Bilan d'une synchronisation v2.
class V2SyncReport {
  int sent = 0;
  int integrated = 0;
  int arbitration = 0;
  int rejected = 0;
  int groups = 0;
  bool bootstrapped = false;

  /// Arrêt de la synchronisation (erreur de requête entière, incompatibilité) ; null si complète.
  V2Failure? failure;
  String? blockedBy;

  bool get complete => failure == null && blockedBy == null;

  @override
  String toString() =>
      'envoyées $sent, intégrées $integrated, à arbitrer $arbitration, quarantaine $rejected, groupes $groups'
      '${bootstrapped ? ', instantané' : ''}${failure != null ? ', arrêt : ${failure!.code}' : ''}${blockedBy != null ? ', bloquée : $blockedBy' : ''}';
}

/// Synchronisation v2 d'un terminal (contrat-v2/README.md) : état, bootstrap cohérent, envoi des opérations, états,
/// journal de changements, accusé. Chaque étape est idempotente : une coupure à n'importe quel moment se reprend en
/// relançant [run], sans perte ni doublon.
class V2Sync {
  V2Sync(this.client, this.store);

  final CaisseV2Client client;
  final V2Store store;

  /// Pages d'instantané retéléchargées au plus (même contenu immuable) avant d'abandonner la préparation.
  static const pageAttempts = 3;

  /// Appairage v2 : jeton, époque et identité rangés, séquence reprise après celle du serveur.
  Future<V2Pairing> pair(String code, {required String platform, String? model, required String Function() newUuid}) async {
    var installation = await store.read(V2Keys.installation);
    if (installation == null) {
      installation = newUuid();
      await store.write(V2Keys.installation, installation);
    }
    final pairing = await client.pair(code: code, installationUuid: installation, platform: platform, model: model);
    await store.savePairing(token: pairing.token, epoch: pairing.epoch, device: pairing.device);
    return pairing;
  }

  Future<V2SyncReport> run() async {
    final report = V2SyncReport();
    client.token ??= await store.read(V2Keys.token);
    if (client.token == null) {
      report.failure = const V2Failure(V2FailureKind.unauthorized, 'non_appaire', 'Terminal non appairé en v2.');
      return report;
    }
    try {
      final state = await client.state();
      await store.write(V2Keys.serverState, jsonEncode(state));
      // Forme des données : 2.1 si les deux côtés ont `contrat.2_1`. Changement de forme : nouvel instantané complet,
      // jamais un mélange des deux formes dans la projection.
      final contract21 = client.capabilities.contains(CaisseV2Client.contract21Capability) &&
          ((state['capacites_serveur'] as List?)?.contains(CaisseV2Client.contract21Capability) ?? false);
      store.contract21 = contract21;
      // Première obtention de `client.lecture` : le journal ne redonne pas les clients déjà publiés.
      bool shared(String capability) => client.capabilities.contains(capability) && ((state['capacites_serveur'] as List?)?.contains(capability) ?? false);
      final revision = '${contract21 ? '2.1' : '2.0'}'
          '${shared(CaisseV2Client.customerReadCapability) ? '+clients' : ''}${shared(CaisseV2Client.sharedCartCapability) ? '+paniers' : ''}${shared(CaisseV2Client.lotsCapability) ? '+lots' : ''}'
          '${shared(CaisseV2Client.ticketModelsCapability) ? '+tickets' : ''}${shared(CaisseV2Client.passesCapability) ? '+passes' : ''}';
      if (await store.read(V2Keys.cursor) == null) {
        await bootstrap('premier_demarrage', report);
      } else if ((await store.read(V2Keys.contractRevision) ?? '2.0') != revision) {
        await bootstrap('reparation', report);
      }
      await store.write(V2Keys.contractRevision, revision);
      await _push(report);
      await _reconcile(report);
      await _pull(report);
      // Journal lu jusqu'au bout après l'/etat : les politiques de cette version sont appliquées.
      if (report.blockedBy == null) await store.write(V2Keys.policiesVersion, (state['versions'] as Map)['politiques'] as String);
      await _acknowledge();
    } on V2Failure catch (failure) {
      report.failure = failure;
      if (failure.kind == V2FailureKind.unauthorized) await store.write(V2Keys.revoked, failure.code);
    } on V2Incompatible catch (e) {
      report.blockedBy = e.what;
      await store.write(V2Keys.blocked, e.what);
    }
    return report;
  }

  /// Bootstrap cohérent : manifeste, toutes les pages vérifiées en mémoire (zone temporaire), puis remplacement de la
  /// projection et du curseur en une transaction. Instantané expiré pendant le téléchargement : un nouveau, une fois.
  Future<void> bootstrap(String reason, [V2SyncReport? report]) async {
    for (var attempt = 0;; attempt++) {
      final manifest = await client.createSnapshot(reason);
      final pages = manifest['pages'] as Map;
      final fingerprints = (pages['empreintes'] as List).cast<String>();
      if (fingerprints.length != pages['nombre']) {
        throw const V2Failure(V2FailureKind.unavailable, 'reponse_non_conforme', 'Manifeste incohérent (pages et empreintes).');
      }
      try {
        final entities = <Map<String, dynamic>>[];
        for (var page = 1; page <= fingerprints.length; page++) {
          entities.addAll(await _page(manifest['uuid'] as String, page, fingerprints[page - 1]));
        }
        await store.replaceProjection(entities, manifest);
        report?.bootstrapped = true;
        return;
      } on V2Failure catch (failure) {
        if (failure.kind != V2FailureKind.expired || attempt > 0) rethrow;
        reason = 'curseur_expire';
      }
    }
  }

  Future<List<Map<String, dynamic>>> _page(String uuid, int page, String fingerprint) async {
    for (var attempt = 1;; attempt++) {
      try {
        return await client.snapshotPage(uuid, page, fingerprint);
      } on V2Failure catch (failure) {
        if (failure.kind != V2FailureKind.unavailable || attempt >= pageAttempts) rethrow;
      }
    }
  }

  /// Envoi par lots (≤ 50 opérations, ≤ 512 Kio). Issue inconnue : opérations marquées « envoi inconnu » et renvoyées à
  /// l'identique à la prochaine synchronisation. Une quarantaine n'empêche pas les autres.
  Future<void> _push(V2SyncReport report) async {
    final skipped = <String>{};
    while (true) {
      final pending = (await store.unsent(limit: CaisseV2Client.maxBatch + skipped.length)).where((o) => !skipped.contains(o['uuid'])).toList();
      if (pending.isEmpty) return;
      final batch = <Map<String, dynamic>>[];
      var bytes = 20;
      for (final op in pending.take(CaisseV2Client.maxBatch)) {
        final size = utf8.encode(jsonEncode(op)).length + 1;
        if (batch.isNotEmpty && bytes + size > CaisseV2Client.maxBodyBytes) break;
        batch.add(op);
        bytes += size;
      }
      final uuids = [for (final o in batch) o['uuid'] as String];
      try {
        final results = await client.submit(batch);
        await store.applyResults(results);
        report.sent += batch.length;
        for (final r in results) {
          switch (r['etat']) {
            case V2OperationState.integrated:
              report.integrated++;
            case V2OperationState.arbitration:
              report.arbitration++;
            case V2OperationState.rejected:
              report.rejected++;
          }
          // Un « inconnue » ne peut venir de /operations : ne pas boucler sur une telle réponse.
          if (r['etat'] == 'inconnue') skipped.add(r['uuid'] as String);
        }
      } on V2Failure catch (failure) {
        if (failure.outcomeUnknown) await store.markSendUnknown(uuids);
        if (failure.kind == V2FailureKind.tooLarge && batch.length > 1) {
          // Lot trop gros pour le serveur : envoi un par un au prochain tour.
          for (final op in batch) {
            await _pushOne(op, report);
          }
          continue;
        }
        rethrow;
      }
    }
  }

  Future<void> _pushOne(Map<String, dynamic> op, V2SyncReport report) async {
    final results = await client.submit([op]);
    await store.applyResults(results);
    report.sent++;
  }

  /// États des opérations reçues ou à arbitrer (lecture seule : rien n'est renvoyé ni retraité).
  Future<void> _reconcile(V2SyncReport report) async {
    final uuids = await store.awaitingServer();
    for (var i = 0; i < uuids.length; i += CaisseV2Client.maxStateUuids) {
      final chunk = uuids.sublist(i, i + CaisseV2Client.maxStateUuids > uuids.length ? uuids.length : i + CaisseV2Client.maxStateUuids);
      await store.applyResults(await client.operationStates(chunk));
    }
  }

  /// Journal après le curseur, page par page ; curseur expiré : instantané avec réconciliation, sans effacer la file.
  Future<void> _pull(V2SyncReport report) async {
    for (var round = 0; round < 1000; round++) {
      final cursor = await store.read(V2Keys.cursor);
      if (cursor == null) return;
      Map<String, dynamic> page;
      try {
        page = await client.changes(cursor);
      } on V2Failure catch (failure) {
        if (failure.kind != V2FailureKind.expired) rethrow;
        await bootstrap('curseur_expire', report);
        continue;
      }
      final result = await store.applyChanges(page);
      report.groups += result.groups;
      if (result.blockedBy != null) {
        report.blockedBy = result.blockedBy;
        return;
      }
      if (page['suite'] != true) return;
    }
  }

  Future<void> _acknowledge() async {
    await client.acknowledge({
      'curseur_applique': await store.read(V2Keys.cursor),
      'version_politiques_appliquee': await store.read(V2Keys.policiesVersion) ?? '0',
      'file': await store.queueStats(),
    });
  }
}
