import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/protocol.dart';
import 'package:shopikaiss_terminal/src/windows/platform/restaurant_intent.dart';

class _Host implements WindowsHost {
  final calls = <(HostCommand, String?, Map<String, dynamic>)>[];
  HostFailure? failure;
  bool needsPreparation = false;
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
    calls.add((command, operationId, arguments));
    if (failure != null) throw failure!;
    if (command == HostCommand.restoPrepareSettlement) {
      needsPreparation = false;
      return {'payable': 100};
    }
    if (needsPreparation) {
      throw const HostFailure('reglement_a_preparer', 'Prepare');
    }
    return {'state': 'committed', 'sale_id': operationId};
  }
}

void main() {
  late Directory dir;
  late File file;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('resto-intent-');
    file = File('${dir.path}/intent.json');
  });
  tearDown(() async => dir.delete(recursive: true));
  test('unknown write survives restart with immutable arguments and identical ID; no PIN on disk', () async {
    final host = _Host()
      ..failure = const HostFailure('lost', 'Lost', outcomeUnknown: true);
    final intent = RestaurantIntent(host, file: file);
    final added = <Map<String, dynamic>>[
      {'product_id': 3, 'quantity': '2'},
    ];
    await expectLater(
      intent.execute(HostCommand.restoEditLines, {
        'order_uuid': 'table',
        'added': added,
        'approval': {'code': '12345678', 'approver_id': 2},
      }),
      throwsA(isA<HostFailure>()),
    );
    final id = host.calls.single.$2;
    expect(await file.readAsString(), isNot(contains('12345678')));
    added.clear();
    await expectLater(
      intent.execute(HostCommand.restoSend, {}),
      throwsStateError,
    );
    final restarted = RestaurantIntent(host, file: file);
    await restarted.load();
    host.failure = null;
    await restarted.retry();
    expect(host.calls.last.$2, id);
    expect(host.calls.last.$3['added'], hasLength(1));
    expect(await file.exists(), isFalse);
  });
  test(
    'certain rejection during recovery never erases the original uncertainty',
    () async {
      final host = _Host()
        ..failure = const HostFailure('lost', 'Lost', outcomeUnknown: true);
      final intent = RestaurantIntent(host, file: file);
      await expectLater(
        intent.execute(HostCommand.restoRefund, {}),
        throwsA(isA<HostFailure>()),
      );
      host.failure = const HostFailure('operator_required', 'PIN');
      await expectLater(intent.retry(), throwsA(isA<HostFailure>()));
      expect(intent.pending, isNotNull);
      expect(await file.exists(), isTrue);
      await expectLater(intent.acknowledgeReviewed(), throwsStateError);
    },
  );
  test(
    'recovered settlement is prepared again then uses the same financial ID',
    () async {
      final host = _Host()
        ..failure = const HostFailure('lost', 'Lost', outcomeUnknown: true);
      final intent = RestaurantIntent(host, file: file);
      await expectLater(
        intent.execute(
          HostCommand.restoSettle,
          {'order_uuid': 'table', 'payments': []},
          preparation: {'order_uuid': 'table', 'mode': 'full'},
        ),
        throwsA(isA<HostFailure>()),
      );
      final id = host.calls.single.$2;
      host.failure = null;
      host.needsPreparation = true;
      await RestaurantIntent(host, file: file).retry();
      expect(host.calls.map((c) => c.$1), [
        HostCommand.restoSettle,
        HostCommand.restoSettle,
        HostCommand.restoPrepareSettlement,
        HostCommand.restoSettle,
      ]);
      expect(
        host.calls
            .where((c) => c.$1 == HostCommand.restoSettle)
            .every((c) => c.$2 == id),
        isTrue,
      );
    },
  );
  test('corrupt journal blocks every new mutation', () async {
    await file.writeAsString(jsonEncode({'schema': 1, 'id': 'bad'}));
    final host = _Host();
    await expectLater(
      RestaurantIntent(host, file: file).execute(HostCommand.restoOpen, {}),
      throwsFormatException,
    );
    expect(host.calls, isEmpty);
    expect(await file.exists(), isTrue);
  });
}
