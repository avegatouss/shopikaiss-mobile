import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/restaurant_workspace.dart';

const tables = [
  RestaurantTableView(
    id: '1',
    name: 'Table 1',
    room: 'Terrasse',
    state: RestaurantTableState.free,
  ),
  RestaurantTableView(
    id: '2',
    name: 'Table 2',
    room: 'Salle',
    state: RestaurantTableState.occupied,
    totalLabel: '7 500 F',
    orderLabel: 'Commande 42',
    guestsLabel: '3 couverts',
    lines: [
      RestaurantLineView(
        name: 'Plat du jour',
        quantityLabel: '3',
        totalLabel: '7 500 F',
        stateLabel: 'À envoyer',
        note: 'Sans piment',
      ),
    ],
  ),
];

void main() {
  for (final width in [600.0, 1280.0]) {
    testWidgets('tables read-only, filtering and detail at $width', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: RestaurantWorkspace(
              tables: tables,
              availabilityMessage: 'Préparation — moteur non raccordé',
            ),
          ),
        ),
      );
      await tester.tap(find.text('Table 2'));
      await tester.pump();
      expect(find.text('Commande 42'), findsOneWidget);
      expect(find.text('Sans piment'), findsOneWidget);
      for (final button in tester.widgetList<ButtonStyleButton>(
        find.byType(FilledButton),
      )) {
        expect(button.onPressed, isNull);
      }
      await tester.enterText(find.byType(TextField), 'Table 1');
      await tester.pump();
      expect(find.byWidgetPredicate((w) => w is Text && w.data == 'Table 1'), findsOneWidget);
      expect(
        find.text('Commande 42'),
        findsOneWidget,
        reason: 'filtering does not modify the selected order',
      );
      await tester.enterText(find.byType(TextField), 'absente');
      await tester.pump();
      expect(find.text('Aucune table à afficher.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
