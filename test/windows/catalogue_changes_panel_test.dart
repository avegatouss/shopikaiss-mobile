import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/catalogue_changes_panel.dart';

void main() {
  testWidgets('empty catalogue history is explicit', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: CatalogueChangesPanel(items: [])),
      ),
    );
    expect(
      find.text('Aucune modification de produit à afficher.'),
      findsOneWidget,
    );
  });

  testWidgets('conflict displays reason and only opens arbitration on demand', (
    tester,
  ) async {
    var opened = 0;
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CatalogueChangesPanel(
            items: const [
              CatalogueChangeItem(
                id: 'change-1',
                name: 'Produit local',
                status: CatalogueChangeStatus.conflict,
                creation: true,
                reason: 'Référence déjà utilisée.',
              ),
            ],
            onOpenArbitration: () {
              opened++;
            },
          ),
        ),
      ),
    );
    expect(opened, 0);
    expect(find.text('Arbitrage nécessaire'), findsOneWidget);
    expect(find.text('Référence déjà utilisée.'), findsOneWidget);
    await tester.tap(find.text('Ouvrir l’arbitrage en ligne'));
    expect(opened, 1);
    expect(tester.takeException(), isNull);
  });
}
