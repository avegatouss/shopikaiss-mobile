import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/process_host.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/supervised_host.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/protocol.dart';
import 'package:shopikaiss_terminal/src/windows/platform/sale_intent.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/register_controller.dart';

void main() {
  final exe =
      '${Directory.current.path}/build/windows-moteur/bundle/bin/shopikaiss_moteur.exe';
  test(
    'unpaired native startup loads a view without a technical error',
    () async {
      final dir = await Directory.systemTemp.createTemp('windows-startup-');
      final host = SupervisedWindowsHost(
        () => ProcessWindowsHost.start(
          exe,
          arguments: ['--dossier', dir.path, '--version', 'test'],
        ),
      );
      final c = WindowsRegisterController(
        host,
        journal: SaleIntentJournal(File('${dir.path}/pending-sale.json')),
      );
      try {
        await c.recoverIntent();
        await host.connect();
        expect((await host.call(HostCommand.status))['paired'], false);
        await c.refresh();
        expect(c.view['schema'], 1);
        expect(c.message, isNull);
        expect(c.canPay, false);
        final replies = await Future.wait(
          List.generate(
            20,
            (i) => host.call(i.isEven ? HostCommand.status : HostCommand.view),
          ),
        );
        expect(replies, hasLength(20));
        expect(replies.where((r) => r['schema'] == 1), hasLength(10));
      } finally {
        c.dispose();
        await host.close();
        await dir.delete(recursive: true);
      }
    },
    skip: !File(exe).existsSync(),
  );
}
