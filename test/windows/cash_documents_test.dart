import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/protocol.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/cash_documents.dart';

class _DocumentsHost implements WindowsHost {
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
    return {'items': <Map>[]};
  }
}

void main() {
  testWidgets(
    'documents expose provisional formats without closing or printing on selection',
    (tester) async {
      final host = _DocumentsHost();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: CashDocumentsDialog(host: host)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Pré-X de la session'), findsOneWidget);
      expect(find.textContaining('documents provisoires'), findsOneWidget);
      await tester.tap(find.text('Détaillé'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Court').last);
      await tester.pumpAndSettle();
      expect(host.calls, [HostCommand.cashDocuments]);
      expect(tester.takeException(), isNull);
    },
  );
}
