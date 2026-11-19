import 'dart:convert';

import '../../offline/caisse_engine.dart';
import '../../offline/x_z_report.dart';
import 'protocol.dart';

/// Rendering uses B's frozen facts and rules; this command never closes a session.
Future<Map<String, dynamic>> localClosureDocument(
  CaisseEngine engine,
  Map<String, dynamic> arguments,
) async {
  final kind = arguments['kind'];
  final version = arguments['version'];
  final width = arguments['paper_width'] ?? 80;
  if (![ZKind.preX, ZKind.preZ, ZKind.session].contains(kind) ||
      ![ZVersion.detailed, ZVersion.short].contains(version) ||
      ![58, 80].contains(width)) {
    throw const HostFailure(
      'document_invalid',
      'Type ou format de document invalide.',
    );
  }
  final facts = await engine.closureFacts();
  final snapshot = engine.snapshot;
  if (facts == null || snapshot == null) {
    throw const HostFailure(
      'document_absent',
      'Données de clôture indisponibles sur ce poste.',
    );
  }
  final context = ZContext.of(snapshot);
  final now = engine.now;
  final Map<String, dynamic> model;
  if (kind == ZKind.preZ) {
    model = dayZModel(facts, context, day: now, now: now);
  } else {
    final session = kind == ZKind.preX ? facts.openSession : facts.lastClosed;
    if (session == null) {
      throw HostFailure(
        'document_absent',
        kind == ZKind.preX
            ? 'Aucune session ouverte sur ce poste.'
            : 'Aucune session clôturée sur ce poste.',
      );
    }
    // Reprinting from this screen is always identified as a duplicate.
    model = sessionZModel(
      facts,
      session,
      context,
      kind: kind as String,
      now: now,
      duplicate: kind == ZKind.session,
    );
  }
  final printout = layoutClosureTicket(
    closureTicket(model, version as String),
    paperWidth: width as int,
  );
  return {
    'kind': kind,
    'version': version,
    'lines': printout.lines,
    'escpos_base64': base64Encode(printout.bytes()),
  };
}
