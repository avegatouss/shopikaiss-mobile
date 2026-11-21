import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/protocol.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/pass_payment.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/register_controller.dart';

class PassHost implements WindowsHost {
  final changes = StreamController<Map<String, dynamic>>.broadcast();
  final calls = <HostCommand>[];
  bool rejectSale = false;
  final state = <String, dynamic>{
    'schema': 1,
    'revision': 1,
    'ready': true,
    'can_pay': true,
    'total_label': '1 500 F',
    'lines': [
      <String, dynamic>{'id': 'line'},
    ],
    'passes': [
      <String, dynamic>{
        'pass_uuid': 'pass-1',
        'holder': 'Awa',
        'left_today': 1,
        'left_total': 3,
        'online': true,
      },
    ],
  };
  @override
  Stream<Map<String, dynamic>> get events => changes.stream;
  @override
  Future<void> close() async {}
  @override
  Future<Map<String, dynamic>> call(
    HostCommand command, {
    Map<String, dynamic> arguments = const {},
    String? operationId,
  }) async {
    calls.add(command);
    if (command == HostCommand.commitSale) {
      if (rejectSale) {
        throw const HostFailure('refused', 'Sale refused');
      }
      state['lines'] = [];
      state['passes'] = [];
      state['can_pay'] = false;
      return {
        'state': 'committed',
        'operation_id': operationId,
        'number': 'P-1',
      };
    }
    if (command == HostCommand.status) {
      return {
        'capabilities': {
          'pass': {'allowed': true, 'several_per_sale': false},
        },
      };
    }
    if (command == HostCommand.removePass) {
      expect(arguments['pass_uuid'], 'pass-1');
      state['passes'] = [];
      state['revision'] = 2;
    }
    return state;
  }
}

void main() {
  for (final rejected in [false, true]) {
    testWidgets(
      'pass checkout prints once only after success: rejected=$rejected',
      (tester) async {
        final host = PassHost()..rejectSale = rejected;
        final c = WindowsRegisterController(host);
        var prints = 0;
        c.saleTicket = (_) async {
          prints++;
          return 'Printed';
        };
        await c.refresh();
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => PassPaymentDialog(controller: c),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Valider la vente'));
        await tester.pumpAndSettle();
        expect(
          host.calls.where((command) => command == HostCommand.commitSale),
          hasLength(1),
        );
        expect(prints, rejected ? 0 : 1);
        await c.printPendingTicket();
        expect(prints, rejected ? 0 : 1);
        c.dispose();
      },
    );
  }
  testWidgets(
    'selected pass remains visible and removal reloads the authoritative draft',
    (tester) async {
      final host = PassHost();
      final c = WindowsRegisterController(host);
      await c.refresh();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PassPaymentDialog(controller: c)),
        ),
      );
      expect(find.text('Awa'), findsOneWidget);
      await tester.tap(find.byTooltip('Retirer ce pass'));
      await tester.pumpAndSettle();
      expect(find.text('Awa'), findsNothing);
      expect(host.calls, contains(HostCommand.removePass));
      final validate = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Valider la vente'),
      );
      expect(validate.onPressed, isNull);
      c.dispose();
    },
  );

  testWidgets(
    'uncertain sale exposes reconciliation instead of another checkout',
    (tester) async {
      final c = WindowsRegisterController(PassHost());
      await c.refresh();
      c.uncertainOperation = 'sale-1';
      c.message = 'Résultat inconnu';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PassPaymentDialog(controller: c)),
        ),
      );
      expect(find.text('Résultat inconnu'), findsOneWidget);
      expect(find.text('Vérifier la vente'), findsOneWidget);
      expect(find.text('Valider la vente'), findsNothing);
      c.dispose();
    },
  );
}
