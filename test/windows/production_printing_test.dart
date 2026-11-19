import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/platform/production_printing.dart';
import 'package:shopikaiss_terminal/src/restaurant/resto_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ci.khoga.shopikaiss/windows');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test(
    'two stations produce two separate cut jobs on counter printer',
    () async {
      final jobs = <List<int>>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'startRawPrint') {
          expect(call.arguments['printer'], 'POS-80');
          jobs.add(List<int>.from(call.arguments['bytes']));
          return '${jobs.length}';
        }
        return 'transmitted';
      });
      for (final station in ['CUISINE', 'BAR']) {
        expect(
          await const ProductionPrinting().send('POS-80', [
            'BON $station',
            'Table 2',
            '1 x Article',
          ]),
          RestoOutcome.transmis,
        );
      }
      expect(jobs, hasLength(2));
      for (final bytes in jobs) {
        expect(bytes.take(2), [27, 64]);
        expect(bytes, contains(29)); // GS cut sequence from the shared encoder.
      }
    },
  );
  test('uncertain spool result stays to verify, without a replay', () async {
    var submissions = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'startRawPrint') {
        submissions++;
        return 'job';
      }
      return 'unknown';
    });
    expect(
      await const ProductionPrinting().send('POS-80', ['AJOUT BAR']),
      RestoOutcome.aVerifier,
    );
    expect(submissions, 1);
    expect(
      await const ProductionPrinting().send('', ['BON']),
      RestoOutcome.nonEnvoye,
    );
    expect(submissions, 1);
  });
}
