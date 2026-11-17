import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/restaurant_station_editor.dart';

void main() {
  testWidgets('station editor validates a draft without network or printing', (
    tester,
  ) async {
    RestaurantStationDraft? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showDialog<RestaurantStationDraft>(
                  context: context,
                  builder: (_) => const RestaurantStationEditor(),
                );
              },
              child: const Text('Configurer'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Configurer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Valider le brouillon'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.text('Indiquez un nom.'), findsOneWidget);
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Cuisine');
    await tester.enterText(fields.at(1), 'http://192.168.1.50');
    await tester.enterText(fields.at(2), '70000');
    await tester.tap(find.text('Valider le brouillon'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    await tester.enterText(fields.at(1), '192.168.1.50');
    await tester.enterText(fields.at(2), '9100');
    await tester.tap(find.text('Valider le brouillon'));
    await tester.pumpAndSettle();
    expect(result?.name, 'Cuisine');
    expect(result?.address, '192.168.1.50');
    expect(result?.port, 9100);
  });
}
