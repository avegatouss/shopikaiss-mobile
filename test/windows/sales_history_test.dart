import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/protocol.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/sales_history.dart';

class _Host implements WindowsHost {
  final calls = <HostCommand>[];
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
    calls.add(command);
    if (command == HostCommand.history) {
      return {
        'items': [
          {'operation_id': 'sale-1', 'number': 'V-1', 'status': 'integree'},
        ],
      };
    }
    if (command == HostCommand.reprint) {
      return {
        'operation_id': 'sale-1',
        'lines': ['DUPLICATA', 'TOTAL 1500 F'],
        'compact': true,
      };
    }
    throw StateError('Unexpected financial command: $command');
  }
}

void main() {
  testWidgets(
    'duplicata preserves engine lines/compact and shows uncertain result inside dialog',
    (tester) async {
      final host = _Host();
      final completion = Completer<String>();
      var sends = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SalesHistoryDialog(
              host: host,
              printReceipt: (lines, {bool compact = false}) {
                sends++;
                expect(lines, ['DUPLICATA', 'TOTAL 1500 F']);
                expect(compact, isTrue);
                return completion.future;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('V-1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Imprimer le duplicata'));
      await tester.pump();
      expect(
        tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Imprimer le duplicata'),
            )
            .onPressed,
        isNull,
      );
      completion.complete('Impression à vérifier : aucun renvoi automatique.');
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(
            'Impression à vérifier : aucun renvoi automatique.',
          ),
        ),
        findsOneWidget,
      );
      expect(find.byType(SnackBar), findsNothing);
      expect(find.textContaining('TOTAL 1500 F'), findsOneWidget);
      expect(sends, 1);
      expect(host.calls, [HostCommand.history, HostCommand.reprint]);
    },
  );
}
