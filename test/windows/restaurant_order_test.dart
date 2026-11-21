import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/protocol.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/restaurant_order.dart';

class _Host implements WindowsHost {
  final writes = <(HostCommand, String?)>[];
  bool fail = false;
  final order = <String, dynamic>{
    'order_uuid': 'order',
    'local_number': 'R-1',
    'table_name': 'Table 1',
    'payable_label': '1 500 F',
    'status': 'open',
    'lines': <Map>[],
  };
  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();
  @override
  Future<void> close() async {}
  @override
  Future<Map<String, dynamic>> call(
    HostCommand command, {
    Map<String, dynamic> arguments = const {},
    String? operationId,
  }) async {
    if (command == HostCommand.restaurantCatalog) {
      return {
        'products': [
          {'id': 1, 'name': 'Garba', 'price_label': '1 500 F'},
        ],
      };
    }
    if (command == HostCommand.restoOrder) return {'order': order};
    writes.add((command, operationId));
    if (fail) throw const HostFailure('lost', 'lost', outcomeUnknown: true);
    return {'order': order};
  }
}

void main() {
  testWidgets(
    'draft adds no write until validation; uncertain batch blocks subsequent actions',
    (tester) async {
      final host = _Host();
      await tester.pumpWidget(
        MaterialApp(
          home: RestaurantOrderDialog(
            host: host,
            order: host.order,
            sendLabel: 'Mettre en attente',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Ajouter'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continuer'));
      await tester.pumpAndSettle();
      expect(host.writes, isEmpty);
      host.fail = true;
      await tester.tap(find.text('Valider les lignes'));
      await tester.pump(const Duration(seconds: 1));
      expect(host.writes.single.$1, HostCommand.restoEditLines);
      expect(host.writes.single.$2, matches(RegExp(r'^[a-f0-9-]{36}$')));
      expect(find.text('Résultat à vérifier'), findsOneWidget);
      await tester.tap(find.text('Fermer'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Ajouter'));
      await tester.pumpAndSettle();
      expect(host.writes.length, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
