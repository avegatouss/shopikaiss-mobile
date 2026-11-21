import 'dart:async';

import '../ipc/protocol.dart';

/// The engine owns the durable claim and acknowledgement. Never print a job
/// twice, including after an ambiguous transport response or a UI restart.
class ProductionQueue {
  ProductionQueue(this.host, {required this.send});
  final WindowsHost host;
  final Future<String> Function(List<String>) send;
  StreamSubscription<Map<String, dynamic>>? _events;
  Future<void>? _running;
  bool _again = false, _closed = false;
  String? error;

  void start() {
    _events ??= host.events.listen((event) {
      if (event['name'] == 'connected' ||
          (event['name'] == 'committed' &&
              (event['data'] as Map?)?['reason'] == 'resto_impression')) {
        unawaited(drain());
      }
    });
    unawaited(drain());
  }

  Future<void> drain() {
    if (_closed) return Future.value();
    _again = true;
    return _running ??= _drain().whenComplete(() => _running = null);
  }

  Future<void> _drain() async {
    try {
      while (_again && !_closed) {
        _again = false;
        final result = await host.call(HostCommand.restoPrintJobs);
        for (final job in (result['jobs'] as List).cast<Map>()) {
          if (_closed) break;
          final id = job['job_id'] as String;
          var outcome = 'a_verifier';
          if (job['state'] == 'en_attente') {
            final claim = await host.call(
              HostCommand.restoPrintStart,
              arguments: {'job_id': id},
            );
            if (claim['print'] != true) continue;
            try {
              outcome = await send((job['lines'] as List).cast<String>());
              if (!['transmis', 'non_envoye', 'a_verifier'].contains(outcome)) {
                outcome = 'a_verifier';
              }
            } catch (_) {
              // Sending may already have reached the spooler.
              outcome = 'a_verifier';
            }
          } else if (job['state'] != 'en_cours') {
            continue;
          }
          final ack = await host.call(
            HostCommand.restoPrintResult,
            arguments: {'job_id': id, 'result': outcome},
          );
          if ((ack['print_jobs'] as List?)?.isNotEmpty == true) _again = true;
        }
      }
      error = null;
    } catch (_) {
      error = 'Impression restaurant à vérifier dans la liste des bons.';
      // Do not retry a possibly transmitted job. Next drain recovers its claim.
    }
  }

  Future<void> close() async {
    _closed = true;
    await _events?.cancel();
    await _running;
  }
}
