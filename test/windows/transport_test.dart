import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/host_server.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/process_host.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/protocol.dart';

class _Adapter implements WindowsEngineAdapter {
  final calls = <String>[];
  @override
  Stream<Map<String, dynamic>> get committedChanges => const Stream.empty();
  @override
  Future<Map<String, dynamic>> execute(
    HostCommand command,
    Map<String, dynamic> arguments,
    String? operationId,
  ) async {
    calls.add(command.name);
    if (arguments['fail'] == true) throw StateError('private secret');
    return {'state': 'committed', 'operation_id': operationId};
  }
}

void main() {
  test(
    'decodes fragmented UTF-8 frames and rejects unsupported versions',
    () async {
      final data = encodeFrame({'name': 'Épices'});
      final frames = await decodeFrames(
        Stream.fromIterable(data.map((b) => [b])),
      ).toList();
      expect(frames.single['name'], 'Épices');
      await expectLater(
        decodeFrames(Stream.value(utf8.encode('{"version":2}\n'))).toList(),
        throwsFormatException,
      );
    },
  );

  test(
    'rejects oversized and truncated frames before business execution',
    () async {
      await expectLater(
        decodeFrames(Stream.value(List.filled(maxIpcFrameBytes + 1, 65)))
            .toList(),
        throwsFormatException,
      );
      await expectLater(
        decodeFrames(Stream.value(utf8.encode('{"version":1}'))).toList(),
        throwsFormatException,
      );
    },
  );

  test(
    'host rejects missing sale ID and hides unexpected exception details',
    () async {
      final adapter = _Adapter();
      final replies = <List<int>>[];
      await WindowsHostServer(adapter).serve(
        Stream.fromIterable([
          encodeFrame({
            'kind': 'request',
            'id': '1',
            'command': 'commitSale',
            'arguments': {},
          }),
          encodeFrame({
            'kind': 'request',
            'id': '2',
            'command': 'commitSale',
            'operation_id': 'sale-2',
            'arguments': {'fail': true},
          }),
          encodeFrame({
            'kind': 'request',
            'id': '3',
            'command': 'status',
            'arguments': {},
          }),
        ]),
        replies.add,
      );
      final decoded = await decodeFrames(Stream.fromIterable(replies)).toList();
      expect(adapter.calls, ['commitSale', 'status']);
      expect(decoded[0]['error']['code'], 'operation_required');
      expect(decoded[1]['error']['not_committed'], false);
      expect(jsonEncode(decoded), isNot(contains('private secret')));
      expect(decoded[2]['ok'], true);
    },
  );

  final dart = Platform.environment['SHOPIKAISS_DART_EXECUTABLE'];
  test(
    'repeated close never reports success while child is still alive',
    () async {
      expect(dart, isNotNull);
      final directory = await Directory.systemTemp.createTemp(
        'shopikaiss-host-ready-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final ready = File('${directory.path}/ready');
      final host = await ProcessWindowsHost.start(
        dart!,
        arguments: [
          'test/windows/fixtures/host_process.dart',
          'slow-shutdown',
          '--ready-file=${ready.path}',
        ],
        timeout: const Duration(seconds: 3),
      );
      addTearDown(host.close);
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (!await ready.exists() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(
        await ready.exists(),
        isTrue,
        reason: 'The test child must be ready before timing shutdown.',
      );
      await host.call(HostCommand.status);
      await expectLater(host.close(), throwsA(isA<TimeoutException>()));
      await expectLater(host.close(), throwsA(isA<TimeoutException>()));
      await host.close();
    },
  );
  test('private child process responds without network listener', () async {
    expect(
      dart,
      isNotNull,
      reason: 'Set SHOPIKAISS_DART_EXECUTABLE to the Dart executable.',
    );
    final host = await ProcessWindowsHost.start(
      dart!,
      arguments: ['test/windows/fixtures/host_process.dart'],
    );
    addTearDown(host.close);
    expect((await host.call(HostCommand.status))['command'], 'status');
    await expectLater(
      host.call(HostCommand.commitSale),
      throwsA(
        isA<HostFailure>().having((e) => e.code, 'code', 'operation_required'),
      ),
    );
  });

  for (final mode in ['lose-reply', 'timeout']) {
    test(
      '$mode leaves sale uncertain, never invents success or retries',
      () async {
        expect(dart, isNotNull);
        final host = await ProcessWindowsHost.start(
          dart!,
          arguments: ['test/windows/fixtures/host_process.dart', mode],
          timeout: const Duration(seconds: 3),
        );
        addTearDown(host.close);
        await expectLater(
          host.call(HostCommand.commitSale, operationId: 'stable-sale'),
          throwsA(
            isA<HostFailure>().having(
              (e) => e.outcomeUnknown,
              'unknown outcome',
              true,
            ),
          ),
        );
      },
    );
  }

  for (final mode in [
    'bad-error-code',
    'bad-error-message',
    'bad-error-proof',
  ]) {
    test('$mode settles the sale as unknown and disconnects', () async {
      expect(dart, isNotNull);
      final host = await ProcessWindowsHost.start(
        dart!,
        arguments: ['test/windows/fixtures/host_process.dart', mode],
        timeout: const Duration(seconds: 15),
      );
      addTearDown(host.close);
      // Warm up the Dart child before measuring the malformed response. A cold
      // JIT startup must not turn this protocol test into a timeout test.
      await host.call(HostCommand.status);
      final disconnected = host.events.firstWhere(
        (event) => event['name'] == 'disconnected',
      );
      await expectLater(
        host
            .call(HostCommand.commitSale, operationId: 'stable-sale')
            .timeout(const Duration(seconds: 6)),
        throwsA(
          isA<HostFailure>().having(
            (error) => error.outcomeUnknown,
            'uncertain sale',
            true,
          ),
        ),
      );
      await disconnected.timeout(const Duration(seconds: 2));
      // The broken process must not accept another operation or replay a sale.
      await expectLater(
        host.call(HostCommand.status),
        throwsA(
          isA<HostFailure>().having(
            (error) => error.code,
            'closed transport',
            'host_unavailable',
          ),
        ),
      );
    });
  }
}
