import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'dart:ui' show PointerDeviceKind;

import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/touch_keyboard.dart';

void main() {
  testWidgets('mouse clicks keep keyboard and field focus across digits', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        builder: (_, child) => TouchKeyboard(child: child!),
        home: Scaffold(
          body: TextField(
            controller: controller,
            focusNode: focus,
            keyboardType: TextInputType.number,
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    for (final key in ['1', '2', '3']) {
      await mouse.down(
        tester.getCenter(find.widgetWithText(OutlinedButton, key)),
      );
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      await mouse.up();
      await tester.pumpAndSettle();
      expect(find.text('Pavé numérique'), findsOneWidget);
    }
    expect(controller.text, '123');
    await mouse.removePointer();
  });
  testWidgets('numeric keypad can be selected on a text field', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => TouchKeyboard(child: child!),
        home: const Scaffold(body: TextField()),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, '123'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextButton, 'ABC'), findsOneWidget);
    final seven = tester.getCenter(find.widgetWithText(OutlinedButton, '7'));
    final eight = tester.getCenter(find.widgetWithText(OutlinedButton, '8'));
    final four = tester.getCenter(find.widgetWithText(OutlinedButton, '4'));
    expect(seven.dy, eight.dy);
    expect(seven.dx, four.dx);
    expect(
      tester.getSize(find.widgetWithText(OutlinedButton, '7')).width,
      lessThan(100),
    );
    for (final key in ['1', '2', '3']) {
      await tester.tap(find.widgetWithText(OutlinedButton, key));
      await tester.pump();
    }
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller.text,
      '123',
    );
    await tester.tap(find.widgetWithText(TextButton, 'ABC'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(OutlinedButton, 'Espace'), findsOneWidget);
  });
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
