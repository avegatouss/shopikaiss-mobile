import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shopikaiss_terminal/src/windows/host/engine_host.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/process_host.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/protocol.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/fake_v2_server.dart';

/// Hôte du moteur v2 (C-REQ-002/003/005) : propriétaire unique de la base, protocole C de bout en bout, fermeture propre.
void main() {
  sqfliteFfiInit();
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('hote_moteur_'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<EngineHost> open(FakeV2Server transport) => EngineHost.open(
    directory: dir.path,
    appVersion: 'essai',
    factory: databaseFactoryFfi,
    transport: transport,
    syncEvery: null,
    pinVerifier: FakeV2Server.pinVerifier,
  );

  /// Envoie [requests] dans le canal de l'hôte, rend les réponses par identifiant ; l'EOF ferme l'hôte.
  Future<Map<String, Map<String, dynamic>>> exchange(EngineHost host, List<Map<String, dynamic>> requests) async {
    final output = <int>[];
    await host.serve(Stream.fromIterable([for (final r in requests) encodeFrame({'kind': 'request', 'arguments': <String, dynamic>{}, ...r})]), output.addAll);
    final frames = await decodeFrames(Stream.value(output)).toList();
    return {for (final f in frames.where((f) => f['kind'] == 'response')) f['id'] as String: f};
  }

  test('appairage, identification, panier, encaissement par trames ; panier et vente retrouvés après redémarrage de l’hôte', () async {
    final transport = FakeV2Server.sellable();
    var host = await open(transport);
    final first = await exchange(host, [
      {'id': 'a', 'command': 'pair', 'arguments': {'origin': 'https://boutique.exemple.ci', 'code': 'ABCD-EFGH', 'model': 'Windows', 'app_version': '1.2.0'}},
      {'id': 'b', 'command': 'login', 'arguments': {'operator_id': 7, 'pin': '1234'}},
      {'id': 'c', 'command': 'scan', 'arguments': {'code': '6190000000011'}},
      {'id': 'd', 'command': 'setPayment', 'arguments': {'method': 'especes', 'received': 1000}},
    ]);
    expect(first.values.every((r) => r['ok'] == true), isTrue, reason: '$first');
    final draft = (first['c']!['result'] as Map)['draft_id'];

    // Hôte arrêté (EOF) puis relancé sur la même base : l'origine, l'appairage et le panier sont restaurés.
    host = await open(transport);
    const op = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
    final second = await exchange(host, [
      {'id': 'v', 'command': 'view'},
      {'id': 'l', 'command': 'login', 'arguments': {'operator_id': 7, 'pin': '1234'}},
      {'id': 's', 'command': 'commitSale', 'operation_id': op},
      {'id': 'r', 'command': 'commitSale', 'operation_id': op},
      {'id': 'q', 'command': 'saleStatus', 'operation_id': op},
    ]);
    expect((second['v']!['result'] as Map)['draft_id'], draft);
    expect((second['v']!['result'] as Map)['ready'], isTrue);
    expect((second['s']!['result'] as Map)['state'], 'committed');
    expect((second['r']!['result'] as Map)['number'], (second['s']!['result'] as Map)['number'], reason: 'rejeu idempotent');
    expect((second['q']!['result'] as Map)['state'], 'committed');

    host = await open(transport);
    final third = await exchange(host, [
      {'id': 'h', 'command': 'history'},
    ]);
    expect(((third['h']!['result'] as Map)['items'] as List), hasLength(1));
  });

  test('un seul hôte par base : le second s’arrête sans ouvrir la base ; libérée à la fermeture', () async {
    final host = await open(FakeV2Server());
    await expectLater(open(FakeV2Server()), throwsA(isA<EngineHostBusy>()));
    await host.close();
    final again = await open(FakeV2Server());
    await again.close();
  });

  test('dossier relatif refusé (aucun chemin implicite)', () async {
    await expectLater(
      EngineHost.open(directory: 'relatif', appVersion: 'x', factory: databaseFactoryFfi, transport: FakeV2Server()),
      throwsA(isA<ArgumentError>()),
    );
  });

  // Exécutable réel construit par tool/windows/moteur/Build-Moteur.ps1 (ignoré s'il n'est pas construit).
  final exe = p.join(Directory.current.path, 'build', 'windows-moteur', 'bundle', 'bin', 'shopikaiss_moteur.exe');
  test('exécutable réel : ProcessWindowsHost de C, état, vue, refus certain, verrou entre processus, arrêt propre', () async {
    final args = ['--dossier', dir.path, '--version', 'essai'];
    final host = await ProcessWindowsHost.start(exe, arguments: args);
    final status = await host.call(HostCommand.status);
    expect(status['paired'], isFalse);
    final view = await host.call(HostCommand.view);
    expect(view['schema'], 1);
    final refused = await host.call(HostCommand.commitSale, operationId: 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee').then<Object>((v) => v, onError: (Object e) => e);
    expect(refused, isA<HostFailure>().having((f) => f.outcomeUnknown, 'résultat inconnu', isFalse));

    final second = await Process.run(exe, args);
    expect(second.exitCode, 3, reason: 'base déjà possédée par le premier hôte');

    await host.close();
    expect(File(p.join(dir.path, 'caisse.db')).existsSync(), isTrue);
    final third = await Process.start(exe, args);
    await third.stdin.close();
    expect(await third.exitCode.timeout(const Duration(seconds: 20)), 0, reason: 'verrou libéré à la sortie du premier');
    await third.stdout.drain<void>();
    await utf8.decoder.bind(third.stderr).join();
  }, skip: File(exe).existsSync() ? false : 'hôte non construit (tool/windows/moteur/Build-Moteur.ps1)');
}
