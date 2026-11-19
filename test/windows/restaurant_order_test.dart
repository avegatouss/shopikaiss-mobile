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
    if (command == HostCommand.search || command == HostCommand.view) {
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
    'order actions carry unique IDs; unknown outcome blocks further writes',
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
      expect(host.writes.single.$1, HostCommand.restoEditLines);
      expect(host.writes.single.$2, matches(RegExp(r'^[a-f0-9-]{36}$')));
      host.fail = true;
      await tester.tap(find.text('Mettre en attente'));
      await tester.pumpAndSettle();
      expect(host.writes.length, 2);
      expect(host.writes[0].$2, isNot(host.writes[1].$2));
      expect(find.textContaining('Résultat à vérifier'), findsOneWidget);
      await tester.tap(find.byTooltip('Ajouter'));
      await tester.pumpAndSettle();
      expect(host.writes.length, 2);
      expect(tester.takeException(), isNull);
    },
  );
}
