import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/platform/customer_display.dart';

void main() {
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
  test('empty basket clears previous amount with welcome message', () {
    final frame = customerFrame({});
    expect(frame['screen'], contains('Bienvenue'));
    expect(frame['screen'], isNot(contains('TOTAL')));
    expect(frame['serial']!.length, 43);
  });
}
