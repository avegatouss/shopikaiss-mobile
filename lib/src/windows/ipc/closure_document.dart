import 'dart:convert';

import '../../offline/caisse_engine.dart';
import '../../offline/x_z_report.dart';
import 'protocol.dart';

/// Rendering uses B's frozen facts and rules; this command never closes a session.
Future<Map<String, dynamic>> localClosureDocument(
  CaisseEngine engine,
  Map<String, dynamic> arguments, {
  void Function(ClosureDocument)? onPrepared,
}) async {
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
  final ClosureDocument? document;
  try {
    document = await engine.closureDocument(
      kind as String,
      version as String,
      duplicate: kind == ZKind.session,
    );
  } on ClosureUnavailable catch (e) {
    throw HostFailure('document_absent', e.message);
  }
  if (document == null) {
    throw const HostFailure(
      'document_absent',
      'Document indisponible sur ce poste.',
    );
  }
  onPrepared?.call(document);
  final printout = document.layout(paperWidth: width as int);
  return {
    'kind': kind,
    'version': version,
    'lines': printout.lines,
    'escpos_base64': base64Encode(printout.bytes()),
  };
}
