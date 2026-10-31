import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/protocol.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/register_controller.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/multiple_payments.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/payment_message.dart';

class PaymentHost implements WindowsHost {
  final calls = <HostCommand>[];
  final changes = StreamController<Map<String, dynamic>>.broadcast();
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
    if (command == HostCommand.preparePayment) {
      return {
        'payable': 10000,
        'methods': [
          {'code': 'especes', 'name': 'Espèces', 'cash': true},
        ],
      };
    }
    return {
      'schema': 1,
      'revision': calls.length,
      'ready': true,
      'total_label': '10 000 F CFA',
      'payment_valid': false,
    };
  }
}

void main() {
  testWidgets(
    'remaining is proposed for next payment and feedback stays in dialog',
    (tester) async {
      final host = PaymentHost();
      final c = WindowsRegisterController(host)..ready = true;
      await c.command(HostCommand.preparePayment, {});
      expect(host.calls, [HostCommand.preparePayment]);
      c.view = {'schema': 1, 'revision': 0, 'total_label': '10 000 F CFA'};
      c.message = 'Le montant reçu est insuffisant.';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MultiplePayments(controller: c)),
        ),
      );
      expect(
        find.widgetWithText(PaymentMessage, 'Le montant reçu est insuffisant.'),
        findsOneWidget,
      );
      final amount = find.byWidgetPredicate(
        (w) => w is TextFormField && w.initialValue == '10000',
      );
      await tester.enterText(amount, '3000');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(host.calls, [HostCommand.preparePayment, HostCommand.setPayments]);
      expect(find.text('Reste à répartir : 7000 F CFA'), findsOneWidget);
      final add = find.text('Ajouter un paiement');
      await tester.ensureVisible(add);
      await tester.tap(add);
      await tester.pump();
      expect(
        find.byWidgetPredicate(
          (w) => w is TextFormField && w.initialValue == '7000',
        ),
        findsOneWidget,
      );
      expect(find.text('Reste à répartir : 0 F CFA'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      c.dispose();
    },
  );
}
