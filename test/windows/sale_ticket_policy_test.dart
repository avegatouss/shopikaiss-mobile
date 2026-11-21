import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/sale_ticket_policy.dart';

void main() {
  test(
    'automatic setting prints without prompting, other mode respects refusal',
    () async {
      var prompts = 0;
      var printed = 0;
      Future<bool?> ask() async {
        prompts++;
        return false;
      }

      Future<String> print() async {
        printed++;
        return 'Envoyé';
      }

      expect(
        await dispatchSaleTicket(mode: 'auto', confirm: ask, print: print),
        'Envoyé',
      );
      expect((prompts, printed), (0, 1));
      expect(
        await dispatchSaleTicket(mode: 'ask', confirm: ask, print: print),
        contains('Ventes récentes'),
      );
      expect((prompts, printed), (1, 1));
      await dispatchSaleTicket(
        mode: 'ask',
        confirm: () async => true,
        print: print,
      );
      expect(printed, 2);
    },
  );
  test('printer failure is not automatically retried', () async {
    var attempts = 0;
    await expectLater(
      dispatchSaleTicket(
        mode: 'auto',
        confirm: () async => false,
        print: () async {
          attempts++;
          throw StateError('spooler');
        },
      ),
      throwsStateError,
    );
    expect(attempts, 1);
  });
}
