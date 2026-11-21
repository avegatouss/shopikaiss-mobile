import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/protocol.dart';
import 'package:shopikaiss_terminal/src/windows/platform/closure_edition_journal.dart';

class _Host implements WindowsHost {
  final ids = <String>[];
  bool fail = false;
  String? refusal;
  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();
  @override
  Future<void> close() async {}
  @override
  Future<Map<String, dynamic>> call(
    HostCommand command, {
    Map<String, dynamic> arguments = const {},
    String? operationId,
  }) async {
    expect(command, HostCommand.cashClosureEdition);
    ids.add(arguments['edition_id'] as String);
    if (fail) throw const HostFailure('lost', 'Lost', outcomeUnknown: true);
    if (refusal != null) return {'recorded': false, 'reason': refusal};
    return {'recorded': true};
  }
}

void main() {
  late Directory dir;
  late File file;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('closure-edition-');
    file = File('${dir.path}/pending.json');
  });
  tearDown(() async => dir.delete(recursive: true));
  test(
    'expired transmitted edition frees journal and reports missing audit',
    () async {
      for (final reason in ['edition_inconnue', 'caissier_inconnu']) {
        final host = _Host()..refusal = reason;
        final journal = ClosureEditionJournal(host, file: file);
        await journal.begin('expired');
        await expectLater(
          journal.confirm(),
          throwsA(
            isA<HostFailure>().having((e) => e.code, 'code', 'edition_expired'),
          ),
        );
        expect(journal.pending, isNull);
        expect(await file.exists(), isFalse);
        await journal.load();
      }
    },
  );
  test(
    'lost confirmation resumes same edition after restart without printing',
    () async {
      final host = _Host()..fail = true;
      final journal = ClosureEditionJournal(host, file: file);
      await journal.begin('edition-1');
      await expectLater(journal.confirm(), throwsA(isA<HostFailure>()));
      host.fail = false;
      final restarted = ClosureEditionJournal(host, file: file);
      await restarted.load();
      expect(host.ids, ['edition-1', 'edition-1']);
      expect(restarted.pending, isNull);
      expect(await file.exists(), isFalse);
    },
  );
  test(
    'interrupted print requires human verification and blocks a new edition',
    () async {
      final host = _Host();
      await ClosureEditionJournal(host, file: file).begin('edition-2');
      final restarted = ClosureEditionJournal(host, file: file);
      await restarted.load();
      expect(host.ids, isEmpty);
      expect(restarted.pending?['state'], 'prepared');
      await expectLater(restarted.begin('edition-3'), throwsStateError);
      await restarted.discard();
      expect(host.ids, isEmpty);
    },
  );
}
