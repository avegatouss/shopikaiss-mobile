import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/offline/caisse_engine.dart';
import 'package:shopikaiss_terminal/src/offline/models.dart';
import 'package:shopikaiss_terminal/src/offline/x_z_report.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/closure_document.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/protocol.dart';

import '../offline_test.dart' show sampleSnapshot;

class _FactsEngine implements CaisseEngine {
  _FactsEngine(this.facts);
  final ClosureFacts facts;
  @override
  Snapshot? snapshot = Snapshot(sampleSnapshot());
  @override
  DateTime get now => DateTime(2026, 11, 19, 12);
  @override
  Future<ClosureFacts?> closureFacts() async => facts;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected engine action: ${invocation.memberName}');
}

void main() {
  test(
    'local pre-X is blind and does not mutate the session or call the network',
    () async {
      final session = ClosureSession(
        uuid: 'session',
        openedAt: DateTime(2026, 11, 19),
        float: 5000,
      );
      final engine = _FactsEngine(
        ClosureFacts(sessions: [session], openSessionUuid: 'session'),
      );
      final result = await localClosureDocument(engine, {
        'kind': 'pre-x',
        'version': 'detailed',
      });
      final text = (result['lines'] as List).join('\n');
      expect(text, contains('PROVISOIRE'));
      expect(text.toLowerCase(), isNot(contains('theorique')));
      expect(session.closed, false);
      expect(base64Decode(result['escpos_base64'] as String).take(2), [27, 64]);
    },
  );
  test('local official day Z and invalid widths are refused', () async {
    final engine = _FactsEngine(ClosureFacts(sessions: []));
    for (final args in [
      {'kind': 'z-jour', 'version': 'detailed'},
      {'kind': 'pre-x', 'version': 'detailed', 'paper_width': 200},
      {'kind': 'pre-x', 'version': 'invented'},
    ]) {
      await expectLater(
        localClosureDocument(engine, args),
        throwsA(isA<HostFailure>()),
      );
    }
  });
  test('closed session reprint is explicitly a duplicate', () async {
    final session =
        ClosureSession(
            uuid: 'session',
            openedAt: DateTime(2026, 11, 19),
            float: 0,
          )
          ..closure = {
            'uuid': 'closure',
            'cree_le': '2026-11-19T10:00:00Z',
            'operateur_id': '7',
            'contenu': {'compte': 0},
          };
    final result = await localClosureDocument(
      _FactsEngine(ClosureFacts(sessions: [session])),
      {'kind': 'z-session', 'version': 'short'},
    );
    expect((result['lines'] as List).join('\n'), contains('DUPLICATA'));
  });
}
