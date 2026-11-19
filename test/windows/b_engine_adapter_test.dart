import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/offline/engine.dart';
import 'package:shopikaiss_terminal/src/offline/models.dart';
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

  test('restaurant consultation requires login and never creates an operation', () async {
    final before = (await store.operations()).length;
    final result = await host.call(HostCommand.restaurantView);
    expect(result['available'], false);
    expect((await store.operations()).length, before);
    await host.call(HostCommand.logout);
    await expectLater(host.call(HostCommand.restaurantView), throwsA(isA<HostFailure>().having((e) => e.code, 'code', 'operator_required')));
  });

  test('closure documents require a logged-in operator and never enqueue a closure', () async {
    final before = (await store.operations()).length;
    await expectLater(host.call(HostCommand.cashClosureDocument, arguments: {'kind': 'pre-x', 'version': 'detailed'}), throwsA(isA<HostFailure>()));
    await host.call(HostCommand.logout);
    await expectLater(host.call(HostCommand.cashClosureDocument, arguments: {'kind': 'pre-x', 'version': 'detailed'}), throwsA(isA<HostFailure>().having((e) => e.code, 'code', 'operator_required')));
    expect((await store.operations()).length, before);
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

  test('cash documents are read-only and Z cannot disclose an unconfirmed count', () async {
    final operation = OfflineOperation(uuid: nextId(), sequence: 1, type: 'cloture_session', number: null, date: DateTime(2026, 11, 1), operatorId: 7, content: {'compte': 5000});
    await store.append(operation);
    var list = await host.call(HostCommand.cashDocuments);
    expect((list['items'] as List).single['available'], false);
    await expectLater(host.call(HostCommand.cashDocument, arguments: {'operation_id': operation.uuid}), throwsA(isA<HostFailure>()));
    operation.content['z'] = {'compte': 5000, 'theorique': 4900, 'ecart': 100};
    await store.update(operation);
    list = await host.call(HostCommand.cashDocuments);
    expect((list['items'] as List).single['available'], true);
    final before = (await store.operations()).length;
    final document = await host.call(HostCommand.cashDocument, arguments: {'operation_id': operation.uuid});
    expect((document['lines'] as List).join('\n'), contains('RAPPORT Z'));
    expect((await store.operations()).length, before);
  });

  test(
    'missing server PIN is configuration failure without consuming attempts',
    () async {
      final operators = transport.snapshotBody['caissiers'] as List;
      (operators.first as Map).remove('pin');
      await inner.engine.refreshSnapshot();
      final before = await store.read('${StoreKeys.pinFailures}7');
      await expectLater(
        host.call(
          HostCommand.login,
          arguments: {'operator_id': 7, 'pin': '1234'},
        ),
        throwsA(
          isA<HostFailure>().having((e) => e.code, 'code', 'pin_unconfigured'),
        ),
      );
      expect(await store.read('${StoreKeys.pinFailures}7'), before);
    },
  );

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

  test('ticket imprimé une fois après la vente ; une panne d’impression ne touche pas la vente', () async {
    await prepare();
    final controller = WindowsRegisterController(host);
    addTearDown(controller.dispose);
    await controller.refresh();
    final printed = <String>[];
    controller.saleTicket = (operation) async {
      printed.add(operation);
      throw StateError('imprimante débranchée');
    };
    await controller.commitSale();
    expect(printed, isEmpty, reason: 'jamais pendant l’encaissement');
    await controller.printPendingTicket();
    await controller.printPendingTicket();
    expect(printed, hasLength(1));
    expect(controller.receipt, isNotEmpty);
    expect(controller.uncertainOperation, isNull);
    expect(controller.ticketMessage, contains('Impression à vérifier'));
    expect(await store.operations(), hasLength(1));
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
      final original = await host.call(
        HostCommand.printTicket,
        operationId: operation,
      );
      expect(original['duplicate'], false);
      final printedAgain = await host.call(
        HostCommand.printTicket,
        operationId: operation,
      );
      expect(printedAgain['duplicate'], true);
      expect(await store.operations(), hasLength(1));
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
