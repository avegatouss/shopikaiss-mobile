import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/pass_scan_dialog.dart';

const accepted = PassScanVerdict(
  allowed: true,
  passId: 'pass-1',
  holder: 'Invité démo',
  remainingToday: 2,
  remainingTotal: 4,
  verifiedOnline: true,
);

Future<void> open(
  WidgetTester tester, {
  required Future<PassScanVerdict> Function(String) verify,
  bool manual = true,
  Duration timeout = const Duration(seconds: 20),
  void Function(PassScanVerdict?)? selected,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final verdict = await showDialog<PassScanVerdict>(
                context: context,
                builder: (_) => PassScanDialog(
                  totalLabel: '1 500 F CFA',
                  manualEntryAllowed: manual,
                  verify: verify,
                  verificationTimeout: timeout,
                ),
              );
              selected?.call(verdict);
            },
            child: const Text('Ouvrir'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Ouvrir'));
  await tester.pumpAndSettle();
}

bool canUse(WidgetTester tester) =>
    tester
        .widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Utiliser ce pass'),
        )
        .onPressed !=
    null;

void main() {
  testWidgets(
    'preview renders holder and quotas, selects only explicit confirmed result',
    (tester) async {
      PassScanVerdict? selected;
      var calls = 0;
      await open(
        tester,
        verify: (code) async {
          calls++;
          expect(code, 'EVT-DEMO');
          return accepted;
        },
        selected: (v) => selected = v,
      );
      expect(canUse(tester), isFalse);
      await tester.enterText(find.byType(TextField), 'EVT-DEMO');
      await tester.tap(find.text('Vérifier le pass'));
      await tester.pumpAndSettle();
      expect(find.text('Pass autorisé'), findsOneWidget);
      expect(find.text('Invité démo'), findsOneWidget);
      expect(find.text('Restants aujourd’hui : 2'), findsOneWidget);
      expect(find.text('Restants au total : 4'), findsOneWidget);
      expect(find.text('1 500 F CFA'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      expect(selected, isNull);
      await tester.tap(find.text('Utiliser ce pass'));
      await tester.pumpAndSettle();
      expect(selected, same(accepted));
      expect(calls, 1);
    },
  );

  testWidgets('refusal keeps exact engine reason and cannot be selected', (
    tester,
  ) async {
    await open(
      tester,
      verify: (_) async => const PassScanVerdict(
        allowed: false,
        reason: 'Ce pass a été révoqué.',
        verifiedOnline: false,
      ),
    );
    await tester.enterText(find.byType(TextField), 'REFUSE');
    await tester.tap(find.text('Vérifier le pass'));
    await tester.pumpAndSettle();
    expect(find.text('Pass refusé'), findsOneWidget);
    expect(find.text('Ce pass a été révoqué.'), findsOneWidget);
    expect(canUse(tester), isFalse);
  });

  testWidgets(
    'editing another code invalidates the previous verdict immediately',
    (tester) async {
      await open(tester, verify: (_) async => accepted);
      await tester.enterText(find.byType(TextField), 'FIRST');
      await tester.tap(find.text('Vérifier le pass'));
      await tester.pumpAndSettle();
      expect(canUse(tester), isTrue);
      await tester.enterText(find.byType(TextField), 'SECOND');
      await tester.pump();
      expect(canUse(tester), isFalse);
      expect(find.text('Pass autorisé'), findsNothing);
    },
  );

  testWidgets(
    'slow verifier cannot double-submit; timeout ignores late approval',
    (tester) async {
      var calls = 0;
      final pending = Completer<PassScanVerdict>();
      await open(
        tester,
        timeout: const Duration(seconds: 1),
        verify: (_) {
          calls++;
          return pending.future;
        },
      );
      await tester.enterText(find.byType(TextField), 'SLOW');
      await tester.tap(find.text('Vérifier le pass'));
      await tester.pump();
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Vérifier le pass'),
            )
            .onPressed,
        isNull,
      );
      expect(canUse(tester), isFalse);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.textContaining('Vérification sans réponse'), findsOneWidget);
      pending.complete(accepted);
      await tester.pumpAndSettle();
      expect(canUse(tester), isFalse);
      expect(calls, 1);
    },
  );

  testWidgets(
    'scanner keyboard works without exposing manual input or bearer code',
    (tester) async {
      String? received;
      await open(
        tester,
        manual: false,
        verify: (code) async {
          received = code;
          return accepted;
        },
      );
      expect(find.byType(TextField), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: 'A');
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1, character: '1');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(received, 'A1');
      expect(find.text('A1'), findsNothing);
      expect(canUse(tester), isTrue);
    },
  );

  testWidgets(
    'unknown error does not leak raw code, approval without identity fails closed',
    (tester) async {
      var calls = 0;
      await open(
        tester,
        verify: (_) async {
          if (calls++ == 0) throw StateError('secret-code-in-url');
          return const PassScanVerdict(allowed: true, verifiedOnline: true);
        },
      );
      await tester.enterText(find.byType(TextField), 'TEST');
      await tester.tap(find.text('Vérifier le pass'));
      await tester.pumpAndSettle();
      expect(find.textContaining('secret-code-in-url'), findsNothing);
      expect(canUse(tester), isFalse);
      await tester.enterText(find.byType(TextField), 'TEST');
      await tester.tap(find.text('Vérifier le pass'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Réponse incomplète'), findsOneWidget);
      expect(canUse(tester), isFalse);
    },
  );
}
