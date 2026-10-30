import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/offline/engine.dart';
import 'package:shopikaiss_terminal/src/offline/store.dart';
import 'package:shopikaiss_terminal/src/register/register_adapter.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/b_engine_adapter.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/host_server.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/protocol.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/register_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../offline_test.dart' show FakeTransport;

/// Actual framing + C adapter + B engine + SQLite; HTTP alone is simulated.
class _FramedHost implements WindowsHost {
  _FramedHost(this.adapter);
  BEngineAdapter adapter;
  bool loseReply = false;
  final changes = StreamController<Map<String, dynamic>>.broadcast();
  @override
  Stream<Map<String, dynamic>> get events => changes.stream;
  @override
  Future<Map<String, dynamic>> call(
    HostCommand command, {
    Map<String, dynamic> arguments = const {},
    String? operationId,
  }) async {
    final output = <List<int>>[];
    await WindowsHostServer(adapter).serve(
      Stream.value(
        encodeFrame({
          'kind': 'request',
          'id': '1',
          'command': command.name,
          'arguments': arguments,
          'operation_id': ?operationId,
        }),
      ),
      output.add,
    );
    final frames = await decodeFrames(Stream.fromIterable(output)).toList();
    final response = frames.singleWhere((f) => f['kind'] == 'response');
    if (response['ok'] != true) {
      final error = response['error'] as Map;
      throw HostFailure(
        error['code'] as String,
        error['message'] as String,
        outcomeUnknown: error['not_committed'] != true,
      );
    }
    if (command == HostCommand.commitSale && loseReply) {
      throw const HostFailure(
        'host_unavailable',
        'lost response',
        outcomeUnknown: true,
      );
    }
    return response['result'] as Map<String, dynamic>;
  }

  @override
  Future<void> close() => changes.close();
}

void main() {
  sqfliteFfiInit();
  late Directory directory;
  late SqfliteOfflineStore store;
  late LocalRegisterAdapter inner;
  late _FramedHost host;
  late FakeTransport transport;
  var sequence = 0;
  String nextId() =>
      '00000000-0000-4000-8000-${(++sequence).toString().padLeft(12, '0')}';

  Future<void> boot() async {
    store = await SqfliteOfflineStore.open(
      name: '${directory.path}/register.db',
      factory: databaseFactoryFfi,
    );
    final engine = OfflineEngine(
      store: store,
      transport: transport,
      newUuid: nextId,
    );
    await engine.load('https://boutique.exemple.ci');
    inner = LocalRegisterAdapter(engine, newUuid: nextId);
    await inner.start();
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('windows_bridge_');
    transport = FakeTransport();
    await boot();
    host = _FramedHost(BEngineAdapter(inner));
    await host.call(
      HostCommand.pair,
      arguments: {
        'origin': 'https://boutique.exemple.ci',
        'code': 'ABCD-EFGH',
        'model': 'Windows test',
        'app_version': 'integration',
      },
    );
    await host.call(
      HostCommand.login,
      arguments: {'operator_id': 7, 'pin': '1234'},
    );
  });
  tearDown(() async {
    await host.close();
    await inner.close();
    await store.close();
    await directory.delete(recursive: true);
  });

  Future<void> prepare() async {
    final view = await host.call(HostCommand.view);
    final product = (view['products'] as List).first as Map;
    await host.call(
      HostCommand.addProduct,
      arguments: {'product_id': product['id']},
    );
    await host.call(HostCommand.setPayment, arguments: {'method': 'especes'});
  }

  test('framed C commands use B totals, persist basket and clear it', () async {
    await prepare();
    final before = await host.call(HostCommand.view);
    await inner.close();
    await store.close();
    await boot();
    host.adapter = BEngineAdapter(inner);
    final restored = await host.call(HostCommand.view);
    expect(restored['draft_id'], before['draft_id']);
    expect(restored['lines'], before['lines']);
    expect(restored['total_label'], before['total_label']);
    expect(restored['payment_valid'], true);
    await host.call(HostCommand.clear);
    expect((await host.call(HostCommand.view))['lines'], isEmpty);
  });

  test(
    'lost commit reply, restart, local lookup and replay produce one sale',
    () async {
      await prepare();
      final controller = WindowsRegisterController(host);
      addTearDown(controller.dispose);
      await controller.refresh();
      host.loseReply = true;
      await controller.commitSale();
      final operation = controller.uncertainOperation;
      expect(operation, isNotNull);
      expect(await store.operations(), hasLength(1));
      await inner.close();
      await store.close();
      await boot();
      host.adapter = BEngineAdapter(inner);
      host.loseReply = false;
      host.changes.add({'name': 'connected'});
      await Future<void>.delayed(Duration.zero);
      await controller.reconcile();
      expect(controller.uncertainOperation, isNull);
      expect(controller.receipt, isNotEmpty);
      final replay = await host.call(
        HostCommand.commitSale,
        operationId: operation,
      );
      expect(replay['number'], controller.receipt);
      expect(await store.operations(), hasLength(1));
      expect(transport.batches, isEmpty);
      expect(transport.stateCalls, isEmpty);
      final receipt = await host.call(
        HostCommand.reprint,
        arguments: {'operation_id': operation},
      );
      expect((receipt['lines'] as List).join('\n'), contains('REIMPRESSION'));
    },
  );

  test(
    'certain refusal and definitive local absence cross IPC unchanged',
    () async {
      const operation = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
      await expectLater(
        host.call(HostCommand.commitSale, operationId: operation),
        throwsA(
          isA<HostFailure>().having(
            (e) => e.outcomeUnknown,
            'certain refusal',
            false,
          ),
        ),
      );
      final status = await host.call(
        HostCommand.saleStatus,
        arguments: {'operation_id': operation},
      );
      expect(status, containsPair('definitive', true));
      expect(status, containsPair('operation_id', operation));
      expect(await store.operations(), isEmpty);
      await expectLater(
        host.call(
          HostCommand.saleStatus,
          operationId: operation,
          arguments: {'operation_id': 'different'},
        ),
        throwsA(
          isA<HostFailure>().having(
            (e) => e.code,
            'conflicting IDs',
            'invalid_operation',
          ),
        ),
      );
      expect(transport.batches, isEmpty);
      expect(transport.stateCalls, isEmpty);
    },
  );
}
