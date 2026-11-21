import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/catalogue_product_editor.dart';

void main() {
  Future<void> open(
    WidgetTester tester,
    Future<String?> Function(CatalogueProductDraft) save, {
    CatalogueProductDraft initial = const CatalogueProductDraft(),
    bool editing = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (_) => CatalogueProductEditor(
                  maxPrice: 1000000,
                  onSave: save,
                  initial: initial,
                  editing: editing,
                ),
              ),
              child: const Text('Ouvrir'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Ouvrir'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'lot 10 validates barcodes and preserves decimal wholesale quantity',
    (tester) async {
      CatalogueProductDraft? saved;
      await open(tester, (draft) async {
        saved = draft;
        return null;
      }, initial: const CatalogueProductDraft(name: 'Pain', price: 250));
      Future<void> enter(String label, String value) async {
        final field = find.widgetWithText(TextFormField, label);
        await tester.ensureVisible(field);
        await tester.enterText(field, value);
      }

      await enter('Codes-barres', 'CODE AVEC ESPACE');
      await tester.tap(find.text('Enregistrer localement'));
      await tester.pumpAndSettle();
      expect(saved, isNull);
      await enter('Codes-barres', '00123');
      await enter('Prix d’achat', '100');
      await enter('Prix de gros', '200');
      await enter('Quantité minimale de gros', '2,5');
      await tester.tap(find.text('Enregistrer localement'));
      await tester.pumpAndSettle();
      expect(saved!.purchasePrice, 100);
      expect(saved!.wholesalePrice, 200);
      expect(saved!.wholesaleMinimum, '2.500000');
      expect(saved!.unlimitedStock, false);
    },
  );

  testWidgets(
    'validates, preserves barcode zeros and submits once while saving',
    (tester) async {
      final completion = Completer<String?>();
      final saved = <CatalogueProductDraft>[];
      await open(tester, (draft) {
        saved.add(draft);
        return completion.future;
      });
      await tester.tap(find.text('Enregistrer localement'));
      await tester.pumpAndSettle();
      expect(saved, isEmpty);
      expect(find.text('Saisissez la désignation.'), findsOneWidget);
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), '  Café  ');
      await tester.enterText(fields.at(1), '  REF-1 ');
      await tester.enterText(fields.at(2), '00123\n00123\n00456');
      await tester.enterText(fields.at(3), '12.5');
      await tester.tap(find.text('Enregistrer localement'));
      await tester.pumpAndSettle();
      expect(saved, isEmpty);
      await tester.enterText(fields.at(3), '1500');
      await tester.tap(find.text('Enregistrer localement'));
      await tester.pump();
      expect(saved.single.name, 'Café');
      expect(saved.single.reference, 'REF-1');
      expect(saved.single.barcodes, ['00123', '00456']);
      expect(saved.single.price, 1500);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      completion.complete(null);
      await tester.pumpAndSettle();
      expect(find.byType(CatalogueProductEditor), findsNothing);
    },
  );

  testWidgets(
    'editing retains entered data and shows engine refusal in dialog',
    (tester) async {
      await open(
        tester,
        (_) async => 'Référence déjà utilisée.',
        editing: true,
        initial: const CatalogueProductDraft(
          name: 'Pain',
          reference: 'P1',
          price: 250,
        ),
      );
      expect(find.text('Modifier le produit'), findsOneWidget);
      await tester.tap(find.text('Enregistrer localement'));
      await tester.pumpAndSettle();
      expect(find.text('Référence déjà utilisée.'), findsOneWidget);
      expect(find.text('Pain'), findsOneWidget);
      expect(find.text('250'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unconfirmed save does not offer a fresh submission', (
    tester,
  ) async {
    var calls = 0;
    await open(tester, (_) async {
      calls++;
      throw StateError('storage');
    }, initial: const CatalogueProductDraft(name: 'Pain', price: 250));
    await tester.tap(find.text('Enregistrer localement'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.textContaining('Enregistrement non confirmé.'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(find.text('Pain'), findsOneWidget);
  });
}
