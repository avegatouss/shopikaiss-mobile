import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/protocol.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/register_controller.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/multiple_payments.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/payment_message.dart';

class PaymentHost implements WindowsHost {
  final calls = <HostCommand>[];
  bool valid = false, committed = false;
  List<dynamic> payments = [];
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
    if (command == HostCommand.setPayments) {
      payments = arguments['payments'] as List;
      valid =
          payments.every((p) => p['method'] != '' && p['amount'] is int) &&
          payments.fold<int>(0, (sum, p) => sum + (p['amount'] as int)) ==
              10000;
    }
    if (command == HostCommand.commitSale) {
      expect(valid, isTrue);
      committed = true;
      return {
        'state': 'committed',
        'operation_id': operationId,
        'number': 'M-1',
      };
    }
    if (command == HostCommand.preparePayment) {
      return {
        'payable': 10000,
        'methods': [
          {'code': 'especes', 'name': 'Espèces', 'cash': true},
          {'code': 'carte', 'name': 'Carte', 'cash': false},
        ],
      };
    }
    return {
      'schema': 1,
      'revision': calls.length,
      'ready': true,
      'total_label': '10 000 F CFA',
      'payment_valid': valid,
      'can_pay': valid && !committed,
      'lines': committed
          ? []
          : [
              {'id': 'line'},
            ],
    };
  }
}

void main() {
  testWidgets(
    'mixed checkout prints once after the whole sale, never per method',
    (tester) async {
      final host = PaymentHost();
      final c = WindowsRegisterController(host)..ready = true;
      var prints = 0;
      c.saleTicket = (_) async {
        prints++;
        return 'Printed';
      };
      await c.command(HostCommand.preparePayment, {});
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  final committed = await showDialog<bool>(
                    context: context,
                    builder: (_) => MultiplePayments(controller: c),
                  );
                  if (committed == true) await c.printPendingTicket();
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, '3000');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(prints, 0);
      await tester.tap(find.text('Ajouter un paiement'));
      await tester.pumpAndSettle();
      final method = find.byType(DropdownButtonFormField<String>).last;
      await tester.ensureVisible(method);
      await tester.tap(method);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Carte').last);
      await tester.pumpAndSettle();
      expect(host.payments.map((p) => p['amount']), [3000, 7000]);
      expect(host.payments.map((p) => p['method']), ['especes', 'carte']);
      expect(prints, 0);
      await tester.tap(find.text('Confirmer ces paiements'));
      await tester.pumpAndSettle();
      expect(
        host.calls.where((command) => command == HostCommand.commitSale),
        hasLength(1),
      );
      expect(prints, 1);
      await c.printPendingTicket();
      expect(prints, 1);
      c.dispose();
    },
  );
  testWidgets('a full first payment can be split without manual subtraction', (
    tester,
  ) async {
    final c = WindowsRegisterController(PaymentHost())..ready = true;
    await c.command(HostCommand.preparePayment, {});
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MultiplePayments(controller: c)),
      ),
    );
    final add = find.text('Ajouter un paiement');
    await tester.ensureVisible(add);
    await tester.tap(add);
    await tester.pump();
    final second = find.byWidgetPredicate(
      (w) => w is TextFormField && w.controller?.text == '0',
    );
    expect(second, findsOneWidget);
    await tester.enterText(second, '5000');
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (w) => w is TextFormField && w.controller?.text == '5000',
      ),
      findsNWidgets(2),
    );
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
  testWidgets('desktop payment fields share one row', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final c = WindowsRegisterController(PaymentHost())..ready = true;
    await c.command(HostCommand.preparePayment, {});
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MultiplePayments(controller: c)),
      ),
    );
    final method = find.byType(DropdownButtonFormField<String>);
    final fields = find.byType(TextFormField);
    expect(fields, findsNWidgets(2));
    final y = tester.getTopLeft(method).dy;
    expect(tester.getTopLeft(fields.at(0)).dy, closeTo(y, 1));
    expect(tester.getTopLeft(fields.at(1)).dy, closeTo(y, 1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
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
