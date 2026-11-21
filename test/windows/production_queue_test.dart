import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/protocol.dart';
import 'package:shopikaiss_terminal/src/windows/platform/production_queue.dart';

class _Host implements WindowsHost {
  final stream = StreamController<Map<String, dynamic>>.broadcast();
  final jobs = <Map<String, dynamic>>[];
  final results = <String>[];
  bool loseAck = false;
  @override
  Stream<Map<String, dynamic>> get events => stream.stream;
  @override
  Future<Map<String, dynamic>> call(
    HostCommand command, {
    Map<String, dynamic> arguments = const {},
    String? operationId,
  }) async {
    if (command == HostCommand.restoPrintJobs) {
      return {'jobs': jobs.map((j) => Map.of(j)).toList()};
    }
    final job = jobs.singleWhere((j) => j['job_id'] == arguments['job_id']);
    if (command == HostCommand.restoPrintStart) {
      final print = job['state'] == 'en_attente';
      job['state'] = 'en_cours';
      return {'print': print};
    }
    if (command == HostCommand.restoPrintResult) {
      if (loseAck) throw const HostFailure('offline', 'lost acknowledgement');
      results.add(arguments['result'] as String);
      jobs.remove(job);
      return {'journalized': true};
    }
    throw StateError('$command');
  }

  @override
  Future<void> close() => stream.close();
}

void main() {
  test(
    'restart replays persisted acknowledgement without touching the printer',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'production-results-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final journal = File('${directory.path}/results.json');
      final host = _Host()
        ..loseAck = true
        ..jobs.add({
          'job_id': 'a',
          'state': 'en_attente',
          'lines': ['BON'],
        });
      var prints = 0;
      final first = ProductionQueue(
        host,
        journal: journal,
        send: (_) async {
          prints++;
          return 'non_envoye';
        },
      );
      await first.drain();
      await first.close();
      expect(await journal.readAsString(), contains('non_envoye'));
      host.loseAck = false;
      final second = ProductionQueue(
        host,
        journal: journal,
        send: (_) async {
          prints++;
          return 'transmis';
        },
      );
      await second.drain();
      expect(prints, 1);
      expect(host.results, ['non_envoye']);
      await second.close();
      await host.close();
    },
  );
  test('lost acknowledgement never prints the same bon twice', () async {
    final host = _Host()
      ..jobs.add({
        'job_id': 'a',
        'state': 'en_attente',
        'lines': ['BON Cuisine'],
      })
      ..loseAck = true;
    var prints = 0;
    final queue = ProductionQueue(
      host,
      send: (_) async {
        prints++;
        return 'transmis';
      },
    );
    await queue.drain();
    expect(prints, 1);
    expect(queue.error, isNotNull);
    host.loseAck = false;
    await queue.drain();
    expect(prints, 1);
    expect(host.results, ['transmis']);
    await queue.close();
    await host.close();
  });
  test('startup recovers interrupted print and sends fresh bon once', () async {
    final host = _Host()
      ..jobs.addAll([
        {
          'job_id': 'a',
          'state': 'en_cours',
          'lines': ['Ancien'],
        },
        {
          'job_id': 'b',
          'state': 'en_attente',
          'lines': ['BON Bar'],
        },
      ]);
    final sent = <String>[];
    final queue = ProductionQueue(
      host,
      send: (lines) async {
        sent.addAll(lines);
        return 'transmis';
      },
    );
    await Future.wait([queue.drain(), queue.drain()]);
    expect(sent, ['BON Bar']);
    expect(host.results, ['a_verifier', 'transmis']);
    await queue.close();
    await host.close();
  });
}
