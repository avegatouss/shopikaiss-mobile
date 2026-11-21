import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/protocol.dart';
import 'package:shopikaiss_terminal/src/windows/platform/catalogue_intent.dart';
import 'package:shopikaiss_terminal/src/windows/platform/site_profiles.dart';

class _Host implements WindowsHost {
  final calls = <(String?, Map<String, dynamic>)>[];
  HostFailure? failure;
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
    calls.add((operationId, arguments));
    if (failure != null) throw failure!;
    return {'product_id': 2};
  }
}

void main() {
  late Directory dir;
  late File file;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('catalogue-intent-');
    file = File('${dir.path}/pending-catalogue-v1.json');
  });
  tearDown(() async => dir.delete(recursive: true));
  test(
    'lost reply survives restart and keeps operator, ID and payload',
    () async {
      final host = _Host()
        ..failure = const HostFailure('lost', 'Lost', outcomeUnknown: true);
      final args = <String, dynamic>{'name': 'Pain', 'price': 250};
      await expectLater(
        CatalogueIntent(host, file).execute(HostCommand.createProduct, args, 7),
        throwsA(isA<HostFailure>()),
      );
      args['price'] = 900;
      expect(await hasUnresolvedSiteIntent(dir.path), isTrue);
      final restarted = CatalogueIntent(host, file);
      await restarted.load();
      await expectLater(restarted.retry(8), throwsA(isA<HostFailure>()));
      expect(host.calls, hasLength(1));
      host.failure = null;
      await restarted.retry(7);
      expect(host.calls.last.$1, host.calls.first.$1);
      expect(host.calls.last.$2['price'], 250);
      expect(await file.exists(), isFalse);
    },
  );
  test(
    'definitive validation refusal releases journal but corruption blocks',
    () async {
      final host = _Host()
        ..failure = const HostFailure('champ_invalide', 'Prix invalide');
      final intent = CatalogueIntent(host, file);
      await expectLater(
        intent.execute(HostCommand.createProduct, {}, 7),
        throwsA(isA<HostFailure>()),
      );
      expect(await file.exists(), isFalse);
      await file.writeAsString('{bad');
      await expectLater(
        intent.execute(HostCommand.createProduct, {}, 7),
        throwsFormatException,
      );
      expect(host.calls, hasLength(1));
    },
  );
}
