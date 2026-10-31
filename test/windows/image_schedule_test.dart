import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/protocol.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/image_schedule.dart';

class _Host implements WindowsHost {
  Map<String, dynamic>? saved;
  bool refuse = false;
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
    if (command == HostCommand.imageSettings)
      return {
        'start': '23:00',
        'end': '05:00',
        'images_cached': 12,
        'images_total': 20,
      };
    if (refuse) throw const HostFailure('reglage_refuse', 'Heures invalides');
    saved = arguments;
    return arguments;
  }
}

void main() {
  testWidgets('restores engine schedule and saves edited night window', (
    tester,
  ) async {
    final host = _Host();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ImageSchedule(host: host)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('12 / 20 photos en cache'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '22:30');
    await tester.tap(find.text('Enregistrer les horaires'));
    await tester.pumpAndSettle();
    expect(host.saved, {'start': '22:30', 'end': '05:00'});
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enregistrer les horaires'));
    await tester.pumpAndSettle();
    expect(host.saved, isEmpty);
  });
  testWidgets('engine rejection remains visible without claiming saved', (
    tester,
  ) async {
    final host = _Host()..refuse = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ImageSchedule(host: host)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enregistrer les horaires'));
    await tester.pumpAndSettle();
    expect(find.text('Heures invalides'), findsOneWidget);
    expect(find.text('Horaires enregistrés sur ce poste.'), findsNothing);
  });
}
