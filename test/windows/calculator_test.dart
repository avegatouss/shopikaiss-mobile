import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/calculator.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/calculator_engine.dart';

void main() {
  test(
    'chains, precedence, parentheses, decimal precision and percentages',
    () {
      for (final entry in {
        '1500+2000+750-250': '4000',
        '2+3×4': '14',
        '(2+3)×4': '20',
        '0,1+0,2': '0,3',
        '1÷3': '0,333333333333',
        '200+10%': '220',
        '200-10%': '180',
        '200×10%': '20',
        '50%': '0,5',
        '-(5+2)': '-7',
        '(-2)×(-3)': '6',
        '1-1': '0',
        '100000000000000000000+1': '100000000000000000001',
      }.entries) {
        expect(calculateExpression(entry.key), entry.value, reason: entry.key);
      }
      for (final input in ['1÷0', '1+', '(1+2', '1..2', 'abc', '']) {
        expect(() => calculateExpression(input), throwsFormatException);
      }
    },
  );
  testWidgets('touch keypad chains results, memory, correction and history', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: DeskCalculator())),
    );
    Future<void> press(String key) async {
      await tester.tap(find.text(key));
      await tester.pump();
    }

    String value() =>
        tester.widget<TextField>(find.byType(TextField)).controller!.text;
    for (final key in ['1', '0', '+', '2', '0', '+', '3', '0', '=']) {
      await press(key);
    }
    expect(value(), '60');
    for (final key in ['×', '2', '=']) {
      await press(key);
    }
    expect(value(), '120');
    await press('M+');
    await press('AC');
    await press('MR');
    expect(value(), '120');
    await press('⌫');
    expect(value(), '12');
    await press('AC');
    await press('7');
    await press('÷');
    await press('0');
    await press('=');
    expect(find.text('Division par zéro impossible'), findsOneWidget);
    await tester.tap(find.byTooltip('Historique des calculs'));
    await tester.pump();
    expect(find.text('= 120'), findsOneWidget);
    await tester.tap(find.text('= 120'));
    await tester.pump();
    expect(value(), '120');
    await press('4');
    expect(value(), '4');
    await press('AC');
    for (final key in ['1', '0', '+', '2', '±', '=']) {
      await press(key);
    }
    expect(value(), '8');
    await press('AC');
    for (final key in ['2', '±', '±', '=']) {
      await press(key);
    }
    expect(value(), '2');
    await press('MC');
    expect(find.text('Mémoire : 120'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'small touch screen keeps calculator scrollable without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: DeskCalculator())),
      );
      await tester.ensureVisible(find.widgetWithText(FilledButton, '='));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
