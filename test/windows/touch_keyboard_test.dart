import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/touch_keyboard.dart';

void main() {
  testWidgets('automatic keyboard edits selection and respects formatters', (
    tester,
  ) async {
    final input = TextEditingController();
    addTearDown(input.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => TouchKeyboard(child: child!),
        home: Scaffold(
          body: TextField(
            controller: input,
            inputFormatters: [LengthLimitingTextInputFormatter(3)],
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    for (final key in ['a', 'z', 'e', 'r']) {
      await tester.tap(find.widgetWithText(OutlinedButton, key));
      await tester.pump();
    }
    expect(input.text, 'aze');
    input.selection = const TextSelection(baseOffset: 0, extentOffset: 2);
    await tester.tap(find.widgetWithText(OutlinedButton, 'q'));
    await tester.pump();
    expect(input.text, 'qe');
    await tester.tap(find.widgetWithText(OutlinedButton, '⌫'));
    await tester.pump();
    expect(input.text, 'e');
    expect(tester.takeException(), isNull);
  });

  testWidgets('scanner focus does not open keyboard', (tester) async {
    final focus = FocusNode(debugLabel: 'barcode');
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => TouchKeyboard(child: child!),
        home: Scaffold(body: TextField(focusNode: focus)),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(OutlinedButton, 'Espace'), findsNothing);
  });
}
