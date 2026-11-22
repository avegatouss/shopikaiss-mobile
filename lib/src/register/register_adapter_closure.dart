part of 'register_adapter.dart';

/// Éditions de clôture rendues et pas encore confirmées imprimées, conservées sur le terminal :
/// `{"attente": [{edition_id, kind, version, operateur_id, contenu, le}], "faites": [{edition_id, reponse}]}`.
const _closureEditionsKey = 'adaptateur.editions_cloture';

/// Au-delà, les éditions en attente les plus anciennes sont oubliées (jamais émises).
const _closurePendingMax = 100;

/// Une édition non confirmée dans ce délai est oubliée (jamais émise).
const _closurePendingTtl = Duration(hours: 24);

/// Confirmations gardées pour répondre à l'identique à un rejeu de `recordEdition`.
const _closureDoneKept = 200;

/// Documents de clôture de l'adaptateur (pré-X, pré-Z, duplicata du Z de session) et audit durable de leurs éditions.
///
/// `closureDocument` rend le document sans réseau et, pour un pré-X ou un pré-Z, enregistre l'édition EN ATTENTE dans le
/// stockage du moteur (survit au redémarrage de l'hôte). `recordEdition` la confirme une fois le ticket imprimé : l'opération
/// d'audit (`edition_pre_x`, `edition_pre_z`) est émise une seule fois, sous l'UUID `edition_id`. Une édition jamais
/// confirmée n'est jamais émise (le papier n'est peut-être pas sorti) : elle est oubliée après 24 h ou au-delà de 100.
extension _ClosureCommands on LocalRegisterAdapter {
  Future<Map<String, dynamic>> _closureDocument(Map<String, dynamic> args) async {
    final operator = _operator;
    if (operator == null) throw const AdapterFailure('caissier_requis', 'Identifiez le caissier pour consulter les documents.');
    final kind = args['kind'];
    final version = args['version'];
    if (kind is! String || !const [ZKind.preX, ZKind.preZ, ZKind.session, ZKind.terminalDay].contains(kind)) {
      throw const AdapterFailure('argument_invalide', 'Argument « kind » invalide (pre-x, pre-z, z-session ou z-jour-terminal).');
    }
    if (version is! String || !const [ZVersion.detailed, ZVersion.short].contains(version)) {
      throw const AdapterFailure('argument_invalide', 'Argument « version » invalide (detailed ou short).');
    }
    // Pré-Z : même droit que la clôture (comme l'écran Android et l'hôte Windows).
    if ((kind == ZKind.preZ || kind == ZKind.terminalDay) && !engine.hasRight(operator, 'caisse_cloturer')) {
      throw AdapterFailure('document_interdit', '${operator.name} n’a pas le droit d’éditer le pré-Z.');
    }
    // Z de session : toujours une réimpression (duplicata) par défaut.
    final duplicate = args['duplicate'] ?? (kind == ZKind.session || kind == ZKind.terminalDay);
    if (duplicate is! bool) throw const AdapterFailure('argument_invalide', 'Argument « duplicate » invalide.');
    final (paper, columns) = _closureWidth(args);

    final ClosureDocument? document;
    try {
      document = await engine.closureDocument(kind, version, duplicate: duplicate);
    } on ClosureUnavailable catch (e) {
      throw AdapterFailure('document_absent', e.message);
    }
    if (document == null) throw const AdapterFailure('document_absent', 'Documents de clôture indisponibles sur ce terminal.');
    final printout = document.layout(paperWidth: paper, columns: columns);

    String? editionId;
    if (document.editionType != null && document.edition != null) {
      editionId = _newUuid();
      final state = await _closureState();
      (state['attente'] as List).add({
        'edition_id': editionId,
        'kind': kind,
        'version': version,
        'operateur_id': operator.id,
        'contenu': document.edition,
        'le': engine.now.toUtc().toIso8601String(),
      });
      await _closureSave(state);
    }
    return {
      'kind': kind,
      'version': version,
      'paper_width': paper,
      'columns': columns,
      'partial': document.partial,
      'ticket': document.ticket,
      'lines': printout.lines,
      'escpos_base64': base64Encode(printout.bytes()),
      'edition_id': editionId,
    };
  }

  /// Confirme l'impression d'une édition : émise une fois, rejeu = même réponse. Sans caissier identifié : l'édition reste
  /// attribuée à celui qui l'a rendue (un hôte redémarré confirme avant toute reconnexion).
  Future<Map<String, dynamic>> _recordEdition(Map<String, dynamic> args) async {
    final id = LocalRegisterAdapter._text(args, 'edition_id', max: 64);
    final state = await _closureState();
    final done = (state['faites'] as List).cast<Map>();
    for (final d in done) {
      if (d['edition_id'] == id) return (d['reponse'] as Map).cast<String, dynamic>();
    }
    final pending = (state['attente'] as List).cast<Map>();
    final entry = pending.where((e) => e['edition_id'] == id).firstOrNull;
    if (entry == null) {
      // Inconnue, expirée ou oubliée (au-delà de 100) : rien n'est émis.
      await _closureSave(state);
      return {'edition_id': id, 'recorded': false, 'reason': 'edition_inconnue'};
    }
    final operator = engine.snapshot?.operatorById((entry['operateur_id'] as num).toInt());
    final Map<String, dynamic> response;
    if (operator == null) {
      response = {'edition_id': id, 'recorded': false, 'reason': 'caissier_inconnu'};
    } else {
      final document = ClosureDocument(
        kind: entry['kind'] as String,
        version: entry['version'] as String,
        model: const {},
        ticket: const {},
        edition: (entry['contenu'] as Map).cast<String, dynamic>(),
      );
      // UUID imposé : un arrêt entre l'émission et l'écriture ci-dessous ne produit jamais de seconde opération.
      await engine.recordEdition(operator, document, operationUuid: id);
      response = {'edition_id': id, 'recorded': true};
    }
    pending.remove(entry);
    done.add({'edition_id': id, 'reponse': response});
    if (done.length > _closureDoneKept) done.removeRange(0, done.length - _closureDoneKept);
    await _closureSave({'attente': pending, 'faites': done});
    return response;
  }

  /// Largeur du rendu : `columns` (32, 42, 48) ou `paper_width` (58, 80), sinon la largeur de l'adaptateur.
  (int, int) _closureWidth(Map<String, dynamic> args) {
    final columns = args['columns'];
    final paper = args['paper_width'];
    if (columns != null && !const [32, 42, 48].contains(columns)) {
      throw const AdapterFailure('argument_invalide', 'Argument « columns » invalide (32, 42 ou 48).');
    }
    if (paper != null && !const [58, 80].contains(paper)) {
      throw const AdapterFailure('argument_invalide', 'Argument « paper_width » invalide (58 ou 80).');
    }
    if (columns is int) return (columns >= 42 ? 80 : 58, columns);
    final width = paper is int ? paper : paperWidth;
    return (width, EscPos.columnsFor(width));
  }

  /// État lu et purgé : éditions en attente de plus de 24 h oubliées, puis les plus anciennes au-delà de 100.
  Future<Map<String, dynamic>> _closureState() async {
    final raw = await engine.store.read(_closureEditionsKey);
    final decoded = raw == null ? const <String, dynamic>{} : (jsonDecode(raw) as Map).cast<String, dynamic>();
    final limit = engine.now.toUtc().subtract(_closurePendingTtl);
    final pending = <Map>[
      for (final e in ((decoded['attente'] as List?) ?? const []).cast<Map>())
        if (DateTime.tryParse('${e['le']}')?.isAfter(limit) ?? false) e,
    ];
    return {'attente': pending, 'faites': <Map>[...((decoded['faites'] as List?) ?? const []).cast<Map>()]};
  }

  Future<void> _closureSave(Map<String, dynamic> state) async {
    final pending = state['attente'] as List;
    if (pending.length > _closurePendingMax) pending.removeRange(0, pending.length - _closurePendingMax);
    await engine.store.write(_closureEditionsKey, jsonEncode(state));
  }
}
