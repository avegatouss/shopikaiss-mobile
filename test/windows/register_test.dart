import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/protocol.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/register_app.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/register_controller.dart';

class _Host implements WindowsHost {
  final changes = StreamController<Map<String, dynamic>>.broadcast();
  final calls = <HostCommand>[];
  String? committedId;
  bool loseReply = false;
  bool reconciled = false;
  final Map<String, dynamic> state = {
    'schema': 1,
    'revision': 1,
    'ready': true,
    'can_pay': true,
    'payment_valid': true,
    'draft_id': 'draft-1',
    'store_name': 'Boutique de test',
    'total_label': '2 000 F',
    'products': [
      {'id': 'p1', 'name': 'Produit de test', 'price_label': '2 000 F'},
    ],
    'lines': [
      {
        'id': 'l1',
        'name': 'Article en panier',
        'quantity_label': '1',
        'total_label': '2 000 F',
      },
    ],
  };
  @override
  Stream<Map<String, dynamic>> get events => changes.stream;
  @override
  Future<Map<String, dynamic>> call(
    HostCommand command, {
    Map<String, dynamic> arguments = const {},
    String? operationId,
  }) async {
    calls.add(command);
    if (command == HostCommand.commitSale) {
      committedId = operationId;
      if (loseReply) {
        throw const HostFailure(
          'host_unavailable',
          'Vérifier',
          outcomeUnknown: true,
        );
      }
      return {
        'state': 'committed',
        'operation_id': operationId,
        'number': 'TEST-1',
      };
    }
    if (command == HostCommand.saleStatus) {
      return {
        'state': reconciled ? 'committed' : 'not_found',
        'operation_id': arguments['operation_id'],
        'number': 'TEST-1',
      };
    }
    return Map.of(state);
  }

  @override
  Future<void> close() => changes.close();
}

void main() {
  test(
    'unknown sale locks further edits and only reconciles the same UUID',
    () async {
      final host = _Host()..loseReply = true;
      final c = WindowsRegisterController(host);
      addTearDown(() async {
        c.dispose();
        await host.close();
      });
      await c.refresh();
      await c.commitSale();
      final original = host.committedId;
      expect(c.uncertainOperation, original);
      expect(c.canPay, false);
      await c.commitSale();
      await c.command(HostCommand.scan, {'code': '123'});
      expect(host.calls.where((c) => c == HostCommand.commitSale).length, 1);
      expect(host.calls, isNot(contains(HostCommand.scan)));
      await c.reconcile();
      expect(
        c.uncertainOperation,
        original,
        reason: 'not_found is not proof of no commit',
      );
      host.reconciled = true;
      await c.reconcile();
      expect(c.uncertainOperation, null);
      expect(c.receipt, 'TEST-1');
    },
  );

  test('stale view cannot overwrite a newer draft', () async {
    final host = _Host();
    final c = WindowsRegisterController(host);
    addTearDown(() async {
      c.dispose();
      await host.close();
    });
    host.state['revision'] = 5;
    await c.refresh();
    host.state['revision'] = 3;
    host.state['total_label'] = 'incorrect';
    await c.refresh();
    expect(c.view['revision'], 5);
    expect(c.view['total_label'], '2 000 F');
  });

  testWidgets('production entry has no fake shop or enabled sale', (
    tester,
  ) async {
    await tester.pumpWidget(const WindowsRegisterApp());
    expect(find.text('Votre caisse doit être configurée'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });

  for (final size in [const Size(1280, 800), const Size(800, 600)]) {
    testWidgets('register and payment render without overflow at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final host = _Host();
      final c = WindowsRegisterController(host);
      addTearDown(() async {
        c.dispose();
        await host.close();
      });
      await tester.pumpWidget(WindowsRegisterApp(controller: c));
      await tester.pumpAndSettle();
      if (size.width < 900) {
        await tester.tap(find.text('Panier').first);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Encaisser · F4'));
      await tester.pumpAndSettle();
      expect(find.text('Paiement'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
