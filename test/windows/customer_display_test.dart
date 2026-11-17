import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/platform/customer_display.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/register_controller.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/protocol.dart';

class _Host implements WindowsHost {
  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();
  @override
  Future<void> close() async {}
  @override
  Future<Map<String, dynamic>> call(
    HostCommand command, {
    Map<String, dynamic> arguments = const {},
    String? operationId,
  }) async => {};
}

void main() {
  test('invalid saved settings cannot poison the settings dropdowns', () async {
    final controller = WindowsRegisterController(_Host());
    final display = CustomerDisplayService(controller);
    await expectLater(
      display.configure({'mode': 'corrupt', 'baud': 'invalid'}),
      throwsFormatException,
    );
    expect(display.settings['mode'], 'off');
    expect(display.settings['baud'], '9600');
    display.dispose();
    controller.dispose();
  });
  test(
    'public display never exposes customer identity and strips controls',
    () {
      final frame = customerFrame({
        'customer': {'name': 'Secret client'},
        'lines': [
          {'name': 'Café\x1b\n', 'quantity_label': '2', 'total_label': '500 F'},
        ],
        'totals': {'payable_label': '500 F'},
      });
      expect(frame['screen'], contains('TOTAL : 500 F'));
      expect(frame['screen'], isNot(contains('Secret client')));
      expect(frame['screen'], isNot(contains('\x1b')));
      expect(frame['serial']!.length, 43);
      expect(frame['serial']!.substring(3), startsWith('Cafe'));
      expect(
        frame['serial']!
            .substring(3)
            .codeUnits
            .every((c) => c >= 32 && c <= 126),
        isTrue,
      );
    },
  );
  test('screen keeps all rows and separates quantity name and amount', () {
    final frame = customerFrame({
      'lines': List.generate(
        15,
        (i) => {
          'name': 'Article $i',
          'quantity_label': '2',
          'total_label': '500 F',
        },
      ),
      'totals': {'payable_label': '7 500 F'},
    });
    expect(frame['screen'], contains('2\tArticle 14\t500 F'));
    expect(frame['screen'], contains('2\tArticle 0\t500 F'));
    expect(frame['screen'], contains('TOTAL : 7 500 F'));
  });
  test('empty basket clears previous amount with welcome message', () {
    final frame = customerFrame({});
    expect(frame['screen'], contains('Bienvenue'));
    expect(frame['screen'], isNot(contains('TOTAL')));
    expect(frame['serial']!.length, 43);
  });
}
