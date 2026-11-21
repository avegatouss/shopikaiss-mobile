import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../ipc/protocol.dart';

/// The engine owns the durable claim and acknowledgement. Never print a job
/// twice, including after an ambiguous transport response or a UI restart.
class ProductionQueue {
  ProductionQueue(this.host, {required this.send, this.journal, this.onStatus});
  final void Function(String?)? onStatus;
  final File? journal;
  final _outcomes = <String, String>{};
  bool _loaded = false;
  Timer? _retry;
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
    _retry ??= Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(drain()),
    );
  }

  Future<void> _save() async {
    if (journal == null) return;
    await journal!.parent.create(recursive: true);
    await journal!.writeAsString(jsonEncode(_outcomes), flush: true);
  }

  Future<void> drain() {
    if (_closed) return Future.value();
    _again = true;
    return _running ??= _drain().whenComplete(() => _running = null);
  }

  Future<void> _drain() async {
    try {
      if (!_loaded) {
        if (journal != null && await journal!.exists()) {
          final saved = jsonDecode(await journal!.readAsString()) as Map;
          for (final entry in saved.entries) {
            if (entry.key is! String ||
                ![
                  'transmis',
                  'non_envoye',
                  'a_verifier',
                ].contains(entry.value)) {
              throw const FormatException('Journal impression illisible');
            }
            _outcomes[entry.key as String] = entry.value as String;
          }
        }
        _loaded = true;
      }
      while (_again && !_closed) {
        _again = false;
        // Only retry acknowledgement, never the physical transmission.
        for (final entry in _outcomes.entries.toList()) {
          await _save();
          await host.call(
            HostCommand.restoPrintResult,
            arguments: {'job_id': entry.key, 'result': entry.value},
          );
          _outcomes.remove(entry.key);
          await _save();
        }
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
          _outcomes[id] = outcome;
          await _save();
          final ack = await host.call(
            HostCommand.restoPrintResult,
            arguments: {'job_id': id, 'result': outcome},
          );
          _outcomes.remove(id);
          await _save();
          if ((ack['print_jobs'] as List?)?.isNotEmpty == true) _again = true;
        }
      }
      error = null;
      onStatus?.call(null);
    } catch (_) {
      error = 'Impression restaurant à vérifier dans la liste des bons.';
      onStatus?.call(error);
      // Do not retry a possibly transmitted job. Next drain recovers its claim.
    }
  }

  Future<void> close() async {
    _closed = true;
    _retry?.cancel();
    await _events?.cancel();
    await _running;
  }
}
