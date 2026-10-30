import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/calculator.dart';

void main() {
  testWidgets('calculator accepts comma and refuses division by zero', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: DeskCalculator())),
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Premier nombre'),
      '12,5',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Deuxième nombre'),
      '2',
    );
    await tester.pump();
    expect(find.text('14,5'), findsOneWidget);
    await tester.tap(find.text('÷'));
    await tester.pump();
    expect(find.text('6,25'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Deuxième nombre'),
      '0',
    );
    await tester.pump();
    expect(find.text('Division par zéro impossible'), findsOneWidget);
  });
}
