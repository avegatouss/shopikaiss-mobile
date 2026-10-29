import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/protocol.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/supervised_host.dart';

class _Host implements WindowsHost {
  final source = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  int calls = 0;
  int closes = 0;
  bool failClose = false;
  Completer<Map<String, dynamic>>? pending;
  @override
  Stream<Map<String, dynamic>> get events => source.stream;
  void disconnect() => source.add({'name': 'disconnected'});
  @override
  Future<Map<String, dynamic>> call(
    HostCommand command, {
    Map<String, dynamic> arguments = const {},
    String? operationId,
  }) async {
    calls++;
    return pending == null ? {'ok': true} : await pending!.future;
  }

  @override
  Future<void> close() async {
    closes++;
    if (failClose) throw TimeoutException('still writing');
    await source.close();
  }
}

void main() {
  test(
    'concurrent connects create one host and closing prevents startup',
    () async {
      final created = Completer<WindowsHost>();
      var starts = 0;
      final supervisor = SupervisedWindowsHost(() {
        starts++;
        return created.future;
      });
      final first = supervisor.connect();
      final second = supervisor.connect();
      expect(starts, 1);
      final closing = supervisor.close();
      final host = _Host();
      created.complete(host);
      await Future.wait([first, second, closing]);
      expect(host.closes, 1);
      await expectLater(supervisor.connect(), throwsA(isA<HostFailure>()));
    },
  );

  test(
    'failed shutdown blocks replacement until old process actually exits',
    () async {
      final old = _Host()..failClose = true;
      final next = _Host();
      var starts = 0;
      final supervisor = SupervisedWindowsHost(
        () async => starts++ == 0 ? old : next,
      );
      await supervisor.connect();
      old.disconnect();
      await expectLater(supervisor.connect(), throwsA(isA<HostFailure>()));
      expect(starts, 1);
      await expectLater(
        supervisor.call(HostCommand.scan),
        throwsA(isA<HostFailure>()),
      );
      old.failClose = false;
      await supervisor.connect();
      expect(starts, 2);
      expect(old.closes, 2);
      await supervisor.call(HostCommand.status);
      expect(next.calls, 1);
      await supervisor.close();
    },
  );

  test(
    'lost sale remains unknown and is never replayed after reconnect',
    () async {
      final old = _Host()..pending = Completer<Map<String, dynamic>>();
      final next = _Host();
      var starts = 0;
      final supervisor = SupervisedWindowsHost(
        () async => starts++ == 0 ? old : next,
      );
      await supervisor.connect();
      final sale = supervisor.call(
        HostCommand.commitSale,
        operationId: 'stable',
      );
      final assertion = expectLater(
        sale,
        throwsA(
          isA<HostFailure>().having(
            (error) => error.outcomeUnknown,
            'unknown',
            true,
          ),
        ),
      );
      old.pending!.completeError(
        const HostFailure('host_unavailable', 'lost', outcomeUnknown: true),
      );
      await assertion;
      await supervisor.connect();
      expect(old.calls, 1);
      expect(next.calls, 0);
      await supervisor.close();
    },
  );

  test('a failed close can be retried but never permits reconnect', () async {
    final host = _Host()..failClose = true;
    final supervisor = SupervisedWindowsHost(() async => host);
    await supervisor.connect();
    await expectLater(supervisor.close(), throwsA(isA<TimeoutException>()));
    await expectLater(supervisor.connect(), throwsA(isA<HostFailure>()));
    host.failClose = false;
    await supervisor.close();
    expect(host.closes, 2);
  });
}
