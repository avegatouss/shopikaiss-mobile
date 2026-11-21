import 'package:flutter/material.dart';

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/protocol.dart';
import 'package:shopikaiss_terminal/src/windows/platform/restaurant_intent.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/restaurant_payment.dart';

class _Host implements WindowsHost {
  final calls = <(HostCommand, Map<String, dynamic>, String?)>[];
  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();
  @override
  Future<void> close() async {}
  @override
  Future<Map<String, dynamic>> call(
    HostCommand c, {
    Map<String, dynamic> arguments = const {},
    String? operationId,
  }) async {
    calls.add((c, arguments, operationId));
    if (c == HostCommand.restoPrepareSettlement) {
      return {
        'payable': 2500,
        'payable_label': '2 500 F',
        'shares': [],
        'methods': [
          {
            'code': 'cash',
            'name': 'Espèces',
            'cash': true,
            'reference': 'none',
          },
          {
            'code': 'wave',
            'name': 'Wave',
            'cash': false,
            'reference': 'required',
          },
        ],
      };
    }
    return {'state': 'committed', 'sale_id': operationId, 'number': 'R-001'};
  }
}

void main() {
  testWidgets(
    'mixed restaurant payment proposes remaining amount and submits one stable settlement',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final host = _Host();
      final intent = RestaurantIntent(host);
      final captureKey = GlobalKey();
      if (const bool.fromEnvironment('CAPTURE_RESTAURANT')) {
        await tester.runAsync(() async {
          final font = FontLoader('Segoe UI')
            ..addFont(
              File('C:/Windows/Fonts/segoeui.ttf')
                  .readAsBytes()
                  .then((b) => ByteData.sublistView(b)),
            );
          await font.load();
        });
      }
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            fontFamily: 'Segoe UI',
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xff164e42),
            ),
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => RepaintBoundary(
                    key: captureKey,
                    child: RestaurantPayment(
                      intent: intent,
                      order: const {
                        'order_uuid': 'table',
                        'profile': 'TABLE_SERVICE',
                        'lines': [],
                      },
                    ),
                  ),
                ),
                child: const Text('Ouvrir'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Ouvrir'));
      await tester.pumpAndSettle();
      expect(find.text('Par parts'), findsNothing);
      final amounts = find.widgetWithText(TextField, 'Montant (F CFA)');
      await tester.enterText(amounts.first, '1000');
      await tester.tap(find.textContaining('Ajouter un moyen'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(amounts.last).controller!.text, '1500');
      await tester.tap(find.byType(DropdownButtonFormField<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Wave').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Référence'),
        'W123',
      );
      await tester.pumpAndSettle();
      if (const bool.fromEnvironment('CAPTURE_RESTAURANT')) {
        await tester.runAsync(() async {
          final image =
              await (captureKey.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('build/restaurant-payment-preview.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.text('Encaisser'));
      await tester.pumpAndSettle();
      final settle = host.calls.singleWhere(
        (c) => c.$1 == HostCommand.restoSettle,
      );
      expect(settle.$3, matches(RegExp(r'^[a-f0-9-]{36}$')));
      expect(settle.$2['payments'], [
        {'method': 'cash', 'amount': 1000},
        {'method': 'wave', 'amount': 1500, 'reference': 'W123'},
      ]);
      expect(intent.pending, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
