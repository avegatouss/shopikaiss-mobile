import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/protocol.dart';
import 'package:shopikaiss_terminal/src/windows/platform/sale_intent.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/register_controller.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/cash_operations.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/suspended_drafts.dart';

class OperationsHost implements WindowsHost {
  final changes = StreamController<Map<String, dynamic>>.broadcast();
  final calls = <(HostCommand, Map<String, dynamic>, String?)>[];
  bool lose = false;
  bool refuse = false;
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
    calls.add((command, arguments, operationId));
    switch (command) {
      case HostCommand.preparePayment:
        return {'methods': []};
      case HostCommand.closeSession:
      case HostCommand.commitReturn:
        if (refuse) {
          throw const HostFailure('caissier_requis', 'Identifiez le caissier.');
        }
        if (lose) {
          lose = false;
          throw const HostFailure(
            'timeout',
            'Réponse perdue',
            outcomeUnknown: true,
          );
        }
        return {
          'operation_id': operationId,
          'amount_label': '500 F',
          'session_open': false,
        };
      case HostCommand.status:
        return {
          'capabilities': {
            'close_session': {'allowed': true},
            'returns': {'allowed': true},
          },
        };
      case HostCommand.view:
        return {'schema': 1, 'revision': 1, 'ready': true};
      case HostCommand.history:
        return {
          'items': [
            {'operation_id': 'sale-1', 'number': 'V1', 'total_label': '500 F'},
          ],
        };
      case HostCommand.returnableSale:
        return {
          'lines': [
            {'line_id': 'line-1', 'label': 'Riz', 'remaining': '2'},
          ],
        };
      case HostCommand.previewReturn:
        return {'amount_label': '500 F'};
      case HostCommand.drafts:
        return {
          'items': [],
          'shared': [
            {
              'shared_id': 'shared-1',
              'label': 'Rayon 1',
              'lines_count': 2,
              'taken_elsewhere': false,
            },
          ],
        };
      default:
        return {};
    }
  }
}

void main() {
  testWidgets('refusal during recovery never discards unknown operation', (
    tester,
  ) async {
    final host = OperationsHost()..lose = true;
    final c = WindowsRegisterController(host)
      ..ready = true
      ..capabilities = {
        'close_session': {'allowed': true},
      };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CashOperationsDialog(controller: c)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '0');
    await tester.tap(find.text('Clôturer la session'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirmer'));
    await tester.pumpAndSettle();
    host.refuse = true;
    await tester.tap(find.text('Vérifier / reprendre la même opération'));
    await tester.pumpAndSettle();
    expect(find.text('Vérifier / reprendre la même opération'), findsOneWidget);
    expect(find.text('Clôturer la session'), findsNothing);
    final calls = host.calls
        .where((x) => x.$1 == HostCommand.closeSession)
        .toList();
    expect(calls.first.$3, calls.last.$3);
    c.dispose();
  });
  Future<WindowsRegisterController> controller(
    OperationsHost host, {
    Directory? dir,
  }) async {
    final c = WindowsRegisterController(
      host,
      journal: dir == null
          ? null
          : SaleIntentJournal(File('${dir.path}/sale.json')),
    );
    await c.refresh();
    return c;
  }

  testWidgets('closure blind count and stable operation after lost reply', (
    tester,
  ) async {
    final host = OperationsHost()..lose = true;
    final c = await controller(host);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CashOperationsDialog(controller: c)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '1500');
    await tester.tap(find.text('Clôturer la session'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirmer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Vérifier / reprendre la même opération'));
    await tester.pumpAndSettle();
    final calls = host.calls
        .where((x) => x.$1 == HostCommand.closeSession)
        .toList();
    expect(calls.length, 2);
    expect(calls.first.$2['cash'], 1500);
    expect(calls.last.$3, calls.first.$3);
    expect(calls.last.$2, calls.first.$2);
    expect(
      find.textContaining('Clôture enregistrée localement'),
      findsOneWidget,
    );
    c.dispose();
  });
  testWidgets('return preview and motive precede commit', (tester) async {
    final host = OperationsHost();
    final c = await controller(host);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CashOperationsDialog(controller: c, returns: true),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('V1 · 500 F').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '1');
    await tester.enterText(find.byType(TextField).last, 'Article rapporté');
    await tester.tap(find.text('Calculer le remboursement'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enregistrer le retour'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirmer'));
    await tester.pumpAndSettle();
    final call = host.calls.firstWhere((x) => x.$1 == HostCommand.commitReturn);
    expect(call.$2['sale_id'], 'sale-1');
    expect(call.$2['reason'], 'Article rapporté');
    expect(call.$3, isNotNull);
    expect(find.textContaining('Retour enregistré'), findsOneWidget);
    c.dispose();
  });
  testWidgets('shared basket resumes with shared id', (tester) async {
    final host = OperationsHost();
    final c = await controller(host);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => SuspendedDraftsDialog(controller: c),
              ),
              child: const Text('Ouvrir'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Ouvrir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rayon 1'));
    await tester.pumpAndSettle();
    expect(host.calls.firstWhere((x) => x.$1 == HostCommand.resumeShared).$2, {
      'shared_id': 'shared-1',
    });
    c.dispose();
  });
  testWidgets('durable interrupted return restored unchanged', (tester) async {
    final dir = Directory.systemTemp.createTempSync('shopikaiss-op-test-');
    final file = File('${dir.path}/pending-return-v2.json');
    file.writeAsStringSync(
      jsonEncode({
        'command': 'commitReturn',
        'operation_id': 'kept-id',
        'arguments': {'sale_id': 'sale-old', 'reason': 'retour', 'lines': []},
      }),
    );
    final host = OperationsHost();
    final c = (await tester.runAsync(() => controller(host, dir: dir)))!;
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CashOperationsDialog(controller: c, returns: true),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Vérifier / reprendre la même opération'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(
      host.calls.firstWhere((x) => x.$1 == HostCommand.commitReturn).$3,
      'kept-id',
    );
    expect(file.existsSync(), false);
    c.dispose();
    dir.deleteSync(recursive: true);
  });
}
