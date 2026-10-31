import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/protocol.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/customer_picker.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/register_controller.dart';

class CustomerHost implements WindowsHost {
  final eventsController = StreamController<Map<String, dynamic>>.broadcast();
  Map<String, dynamic>? selected;
  String? operation;
  bool lost = false;
  int creations = 0;
  final queries = <String>[];
  @override
  Stream<Map<String, dynamic>> get events => eventsController.stream;
  @override
  Future<void> close() async {}
  @override
  Future<Map<String, dynamic>> call(
    HostCommand command, {
    Map<String, dynamic> arguments = const {},
    String? operationId,
  }) async {
    switch (command) {
      case HostCommand.status:
        return {
          'capabilities': {
            'customer': {'allowed': true},
            'customer_create': {'allowed': true},
          },
        };
      case HostCommand.view:
        return {
          'schema': 1,
          'revision': 1,
          'ready': true,
          'customer': selected,
        };
      case HostCommand.searchCustomers:
        queries.add(arguments['query'] as String);
        return {
          'customers': [
            {'uuid': 'existing', 'name': 'Awa', 'phone': '010203'},
          ],
        };
      case HostCommand.createCustomer:
        creations++;
        operation = operationId;
        if (lost) throw const HostFailure('host_unavailable', 'Réponse perdue');
        return {'uuid': 'new', ...arguments, 'pending': true};
      case HostCommand.setCustomer:
        selected = arguments['uuid'] == null ? null : arguments;
        return {};
      default:
        return {};
    }
  }
}

void main() {
  Future<WindowsRegisterController> open(
    WidgetTester tester,
    CustomerHost host,
  ) async {
    final c = WindowsRegisterController(host);
    await c.refresh();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => CustomerPicker(controller: c),
              ),
              child: const Text('Clients'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Clients'));
    await tester.pumpAndSettle();
    return c;
  }

  testWidgets('search, select and restore walk-in customer', (tester) async {
    final host = CustomerHost();
    final c = await open(tester, host);
    await tester.enterText(find.byType(TextField), 'Awa');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(host.queries.last, 'Awa');
    await tester.tap(find.widgetWithText(ListTile, 'Awa'));
    await tester.pumpAndSettle();
    expect(customerLabel(c), 'Awa');
    await tester.tap(find.text('Clients'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Client de passage'));
    await tester.pumpAndSettle();
    expect(host.selected, isNull);
    expect(customerLabel(c), 'Client de passage');
    c.dispose();
  });

  testWidgets('create with operation id and select once', (tester) async {
    final host = CustomerHost();
    final c = await open(tester, host);
    await tester.tap(find.text('Nouveau client'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Fatou');
    await tester.enterText(find.byType(TextField).last, '070809');
    await tester.tap(find.text('Créer et sélectionner'));
    await tester.pumpAndSettle();
    expect(host.creations, 1);
    expect(host.operation, isNotEmpty);
    expect(host.selected?['name'], 'Fatou');
    expect(host.selected?['phone'], '070809');
    expect(customerLabel(c), 'Fatou');
    c.dispose();
  });

  testWidgets('lost creation reply does not blindly retry or select', (
    tester,
  ) async {
    final host = CustomerHost()..lost = true;
    final c = await open(tester, host);
    await tester.tap(find.text('Nouveau client'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Fatou');
    await tester.tap(find.text('Créer et sélectionner'));
    await tester.pumpAndSettle();
    expect(host.creations, 1);
    expect(host.selected, isNull);
    expect(find.textContaining('Recherchez le client avant'), findsOneWidget);
    expect(find.text('Créer et sélectionner'), findsNothing);
    c.dispose();
  });
}
