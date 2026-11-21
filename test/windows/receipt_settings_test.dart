import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/platform/receipt_printing.dart';

void main() {
  testWidgets('logo and QR settings open and save without a selected printer', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('receipt-settings-');
    final file = File('${dir.path}/printer.json');
    addTearDown(() => dir.deleteSync(recursive: true));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  ReceiptPrinting.configure(context, settingsFile: file),
              child: const Text('Réglages'),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('Réglages'));
      for (var i = 0; i < 100 && find.text('Importer le logo').evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
    expect(find.text('Importer le logo'), findsOneWidget);
    expect(find.text('Aucune imprimante sélectionnée'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Enregistrer'));
      for (var i = 0; i < 100 && !file.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    await tester.pumpAndSettle();
    final saved = jsonDecode(file.readAsStringSync()) as Map;
    expect(saved['copies'], 1);
    expect(saved['qr_enabled'], true);
    expect(tester.takeException(), isNull);
  });
}
