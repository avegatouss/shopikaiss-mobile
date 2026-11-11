import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/platform/raw_receipt_printer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ci.khoga.shopikaiss/windows');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test(
    'one submission, polling only, exact bytes and selected printer',
    () async {
      var starts = 0, polls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'startRawPrint') {
          starts++;
          expect(call.arguments['printer'], 'POS-80');
          expect(call.arguments['bytes'], [27, 64, 65, 10]);
          return '1';
        }
        return ++polls == 1 ? 'pending' : 'transmitted';
      });
      final result = await const RawReceiptPrinter(poll: Duration.zero)
          .send('POS-80', Uint8List.fromList([27, 64, 65, 10]));
      expect(result, RawPrintOutcome.transmitted);
      expect(starts, 1);
    },
  );
  test('unknown and timeout never allow PDF fallback or retry', () async {
    var starts = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'startRawPrint') {
        starts++;
        return '1';
      }
      return 'pending';
    });
    final result = await const RawReceiptPrinter(
      timeout: Duration(milliseconds: 8),
      poll: Duration(milliseconds: 2),
    ).send('POS-80', Uint8List.fromList([65]));
    expect(result, RawPrintOutcome.unknown);
    expect(starts, 1);
    expect(usePdfFallback(result, true), false);
    expect(usePdfFallback(RawPrintOutcome.transmitted, true), false);
  });
  test('certain rejection permits configured fallback only', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'raw_not_sent'),
    );
    final result = await const RawReceiptPrinter().send(
      'POS-80',
      Uint8List.fromList([65]),
    );
    expect(result, RawPrintOutcome.notSent);
    expect(usePdfFallback(result, true), true);
    expect(usePdfFallback(result, false), false);
  });
  test('lost status channel after accepted job cannot trigger PDF', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'startRawPrint') return '1';
      throw MissingPluginException();
    });
    final outcome = await const RawReceiptPrinter().send('POS-80', Uint8List.fromList([65]));
    expect(outcome, RawPrintOutcome.unknown);
    expect(usePdfFallback(outcome, true), false);
  });
}
