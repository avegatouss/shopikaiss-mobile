import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/quantity_step.dart';

void main() {
  test('quantity steps preserve fractions without binary rounding', () {
    expect(steppedQuantity('1,125', 1), '2.125');
    expect(steppedQuantity('2.000001', -1), '1.000001');
    expect(steppedQuantity('1', -1), isNull);
    expect(steppedQuantity('0.5', -1), isNull);
    expect(steppedQuantity('1 sachet', 1), isNull);
  });
}
