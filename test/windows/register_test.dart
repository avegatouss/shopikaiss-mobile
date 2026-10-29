import 'dart:async';
import 'dart:io';

import 'package:shopikaiss_terminal/src/windows/platform/sale_intent.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/protocol.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/register_app.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/register_controller.dart';

class _Host implements WindowsHost {
  final changes = StreamController<Map<String, dynamic>>.broadcast();
  final calls = <HostCommand>[];
  final argumentsByCommand = <HostCommand, Map<String, dynamic>>{};
  String? committedId;
  bool loseReply = false;
  bool reconciled = false;
  bool definitive = false;
  String? lookupId;
  Completer<Map<String, dynamic>>? pendingView;
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
    argumentsByCommand[command] = arguments;
    if (command == HostCommand.view && pendingView != null) {
      return pendingView!.future;
    }
    if (command == HostCommand.preparePayment) {
      return {
        'methods': [
          {'code': 'especes', 'name': 'Espèces', 'cash': true},
        ],
      };
    }
    if (command == HostCommand.setPayment) {
      state['payment_valid'] = true;
      state['payment_label'] = 'Espèces 2 000 F';
    }
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
        'operation_id': lookupId ?? arguments['operation_id'],
        'definitive': definitive,
        'number': 'TEST-1',
      };
    }
    return Map.of(state);
  }

  @override
  Future<void> close() => changes.close();
}

void main() {
  testWidgets(
    'quantity stays an engine command and clearing requires confirmation',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
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
      await tester.tap(find.text('Article en panier'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Nouvelle quantité'),
        '1,5',
      );
      await tester.tap(find.text('Appliquer'));
      await tester.pumpAndSettle();
      expect(host.argumentsByCommand[HostCommand.changeQuantity], {
        'line_id': 'l1',
        'quantity': '1,5',
      });
      await tester.tap(find.text('Vider le panier'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Conserver'));
      await tester.pumpAndSettle();
      expect(host.calls, isNot(contains(HostCommand.clear)));
      await tester.tap(find.text('Vider le panier'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Vider le panier'));
      await tester.pumpAndSettle();
      expect(host.calls.where((c) => c == HostCommand.clear), hasLength(1));
    },
  );

  testWidgets('pending sale blocks basket edits', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final host = _Host()..loseReply = true;
    final c = WindowsRegisterController(host);
    addTearDown(() async {
      c.dispose();
      await host.close();
    });
    await c.refresh();
    await c.commitSale();
    await tester.pumpWidget(WindowsRegisterApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Article en panier'));
    await tester.tap(find.text('Vider le panier'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(host.calls, isNot(contains(HostCommand.changeQuantity)));
    expect(host.calls, isNot(contains(HostCommand.clear)));
  });
  test(
    'durable intent survives UI disposal and resolves without recommit',
    () async {
      final dir = await Directory.systemTemp.createTemp('windows-intent-');
      final file = File('${dir.path}/pending.json');
      final host = _Host()..loseReply = true;
      final first = WindowsRegisterController(
        host,
        journal: SaleIntentJournal(file),
      );
      await first.refresh();
      await first.commitSale();
      final id = first.uncertainOperation;
      expect(await SaleIntentJournal(file).read(), id);
      first.dispose();
      final next = WindowsRegisterController(
        host,
        journal: SaleIntentJournal(file),
      );
      await next.refresh();
      expect(next.canPay, isFalse);
      expect(next.uncertainOperation, id);
      host.reconciled = true;
      await next.reconcile();
      expect(next.receipt, 'TEST-1');
      expect(await file.exists(), isFalse);
      expect(host.calls.where((c) => c == HostCommand.commitSale).length, 1);
      next.dispose();
      await host.close();
      await dir.delete(recursive: true);
    },
  );

  test('corrupt durable intent fails closed without sending sale', () async {
    final dir = await Directory.systemTemp.createTemp('windows-intent-');
    final file = File('${dir.path}/pending.json');
    await file.writeAsString('{');
    final host = _Host();
    final c = WindowsRegisterController(host, journal: SaleIntentJournal(file));
    await c.refresh();
    await c.commitSale();
    expect(c.canPay, isFalse);
    expect(host.calls, isNot(contains(HostCommand.commitSale)));
    expect(await file.readAsString(), '{');
    c.dispose();
    await host.close();
    await dir.delete(recursive: true);
  });

  test('failed durable write prevents sending sale', () async {
    final dir = await Directory.systemTemp.createTemp('windows-intent-');
    final host = _Host();
    final c = WindowsRegisterController(
      host,
      journal: SaleIntentJournal(File('${dir.path}/pending.json')),
    );
    await c.refresh();
    await dir.delete();
    await File(dir.path).writeAsString('blocked parent');
    await c.commitSale();
    expect(c.canPay, isFalse);
    expect(host.calls, isNot(contains(HostCommand.commitSale)));
    c.dispose();
    await host.close();
    await File(dir.path).delete();
  });

  testWidgets('catalogue and payment buttons use B commands', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final host = _Host();
    host.state['payment_valid'] = false;
    final c = WindowsRegisterController(host);
    addTearDown(() async {
      c.dispose();
      await host.close();
    });
    await tester.pumpWidget(WindowsRegisterApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Produit de test'));
    await tester.pumpAndSettle();
    expect(host.calls, contains(HostCommand.addProduct));
    expect(host.calls, isNot(contains(HostCommand.scan)));
    await tester.tap(find.text('Encaisser · F4'));
    await tester.pumpAndSettle();
    final confirm = find.widgetWithText(FilledButton, 'Confirmer le paiement');
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    await tester.tap(find.text('Espèces'));
    await tester.pumpAndSettle();
    expect(host.calls, contains(HostCommand.setPayment));
    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(
      host.calls.where((call) => call == HostCommand.commitSale).length,
      1,
    );
  });
  test(
    'only definitive absence for the same operation unlocks the basket',
    () async {
      final host = _Host()..loseReply = true;
      final c = WindowsRegisterController(host);
      addTearDown(() async {
        c.dispose();
        await host.close();
      });
      await c.refresh();
      await c.commitSale();
      final operation = c.uncertainOperation;
      host.definitive = true;
      host.lookupId = 'another-sale';
      await c.reconcile();
      expect(c.uncertainOperation, operation);
      expect(c.canPay, false);
      host.lookupId = null;
      await c.reconcile();
      expect(c.uncertainOperation, isNull);
      expect(c.canPay, true);
      expect(
        host.calls.where((call) => call == HostCommand.commitSale).length,
        1,
      );
    },
  );

  test('restarted engine may restart its view revision at zero', () async {
    final host = _Host();
    final c = WindowsRegisterController(host);
    addTearDown(() async {
      c.dispose();
      await host.close();
    });
    host.state['revision'] = 200;
    await c.refresh();
    host.state['revision'] = 0;
    host.state['total_label'] = 'Nouveau moteur';
    host.changes.add({'name': 'disconnected'});
    host.changes.add({'name': 'connected'});
    await Future<void>.delayed(Duration.zero);
    expect(c.view['revision'], 0);
    expect(c.view['total_label'], 'Nouveau moteur');
    expect(c.ready, true);
  });
  test('late view after disconnection cannot enable payment', () async {
    final host = _Host()..pendingView = Completer<Map<String, dynamic>>();
    final c = WindowsRegisterController(host);
    addTearDown(() async {
      c.dispose();
      await host.close();
    });
    final pending = c.refresh();
    host.changes.add({'name': 'disconnected'});
    await Future<void>.delayed(Duration.zero);
    host.pendingView!.complete(Map.of(host.state));
    await pending;
    expect(c.ready, false);
    expect(c.canPay, false);
    expect(c.view, isEmpty);
    await c.commitSale();
    expect(host.calls, isNot(contains(HostCommand.commitSale)));
    host.pendingView = null;
    host.changes.add({'name': 'connected'});
    await Future<void>.delayed(Duration.zero);
    expect(c.ready, true);
    expect(c.canPay, true);
  });

  test('reconnection reloads view but preserves an uncertain sale', () async {
    final host = _Host()..loseReply = true;
    final c = WindowsRegisterController(host);
    addTearDown(() async {
      c.dispose();
      await host.close();
    });
    await c.refresh();
    await c.commitSale();
    final operation = c.uncertainOperation;
    expect(operation, isNotNull);
    host.changes.add({'name': 'disconnected'});
    host.changes.add({'name': 'connected'});
    await Future<void>.delayed(Duration.zero);
    expect(c.ready, true);
    expect(c.uncertainOperation, operation);
    expect(c.canPay, false);
    await c.commitSale();
    expect(
      host.calls.where((call) => call == HostCommand.commitSale).length,
      1,
    );
  });

  test('closed event stream disables payment', () async {
    final host = _Host();
    final c = WindowsRegisterController(host);
    addTearDown(c.dispose);
    await c.refresh();
    expect(c.canPay, true);
    await host.close();
    expect(c.ready, false);
    expect(c.canPay, false);
  });

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
