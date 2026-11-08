import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/protocol.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/register_controller.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/lot_wholesale.dart';

class Host implements WindowsHost {
  final changes = StreamController<Map<String, dynamic>>.broadcast();
  HostCommand? command;
  Map<String, dynamic>? args;
  @override
  Stream<Map<String, dynamic>> get events => changes.stream;
  @override
  Future<void> close() => changes.close();
  @override
  Future<Map<String, dynamic>> call(
    HostCommand c, {
    Map<String, dynamic> arguments = const {},
    String? operationId,
  }) async {
    if (c == HostCommand.setWholesale || c == HostCommand.setLineLot) {
      command = c;
      args = arguments;
    }
    return {'schema': 1, 'revision': 1, 'ready': true};
  }
}

void main() {
  test(
    'expiration is by calendar day, not by hour; malformed dates are ignored',
    () {
      expect(expiredLot('2026-11-01', DateTime(2026, 11, 1, 23)), false);
      expect(expiredLot('2026-10-31', DateTime(2026, 11, 1)), true);
      expect(expiredLot(null, DateTime(2026)), false);
    },
  );
  testWidgets(
    'wholesale delegates to engine; forbidden toggle stays disabled',
    (tester) async {
      final host = Host();
      final c = WindowsRegisterController(host)
        ..ready = true
        ..capabilities = {
          'wholesale': {'allowed': true},
        };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: WholesaleButton(controller: c)),
        ),
      );
      await tester.tap(find.byType(TextButton));
      await tester.pumpAndSettle();
      expect(host.command, HostCommand.setWholesale);
      expect(host.args, {'active': true});
      c.capabilities = {
        'wholesale': {'allowed': false, 'reason': 'Panier repris'},
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WholesaleButton(key: const ValueKey(2), controller: c),
          ),
        ),
      );
      expect(
        tester.widget<TextButton>(find.byType(TextButton)).onPressed,
        isNull,
      );
      c.dispose();
      await host.close();
    },
  );
  testWidgets(
    'lot selection sends line and chosen lot, no calculation in screen',
    (tester) async {
      final host = Host();
      final c = WindowsRegisterController(host)..ready = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 420,
              child: LineLotChoice(
                controller: c,
                line: {
                  'id': 'line1',
                  'lots': [
                    {
                      'uuid': 'lot1',
                      'label': 'Lot A',
                      'expires_on': '2026-10-01',
                      'expiry_label': '01/10/2026',
                    },
                  ],
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      expect(find.textContaining('péremption 01/10/2026'), findsWidgets);
      expect(tester.widget<Text>(find.textContaining('Lot A').last).style?.color,
          Theme.of(tester.element(find.byType(LineLotChoice))).colorScheme.error);
      await tester.tap(find.textContaining('Lot A').last);
      await tester.pumpAndSettle();
      expect(host.command, HostCommand.setLineLot);
      expect(host.args, {'line_id': 'line1', 'lot_uuid': 'lot1'});
      c.dispose();
      await host.close();
    },
  );
}
