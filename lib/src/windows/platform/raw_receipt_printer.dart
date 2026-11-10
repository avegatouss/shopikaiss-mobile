import 'package:flutter/services.dart';

enum RawPrintOutcome { transmitted, notSent, unknown }

class RawReceiptPrinter {
  const RawReceiptPrinter({
    this.channel = const MethodChannel('ci.khoga.shopikaiss/windows'),
    this.timeout = const Duration(seconds: 30),
    this.poll = const Duration(milliseconds: 150),
  });
  final MethodChannel channel;
  final Duration timeout;
  final Duration poll;

  Future<RawPrintOutcome> send(String printer, Uint8List bytes) async {
    if (printer.isEmpty || bytes.isEmpty || bytes.length > 1024 * 1024) {
      return RawPrintOutcome.notSent;
    }
    var submitted = false;
    try {
      final id = await channel
          .invokeMethod<String>('startRawPrint', {
            'printer': printer,
            'bytes': bytes,
          })
          .timeout(timeout);
      if (id == null) return RawPrintOutcome.unknown;
      submitted = true;
      final watch = Stopwatch()..start();
      while (watch.elapsed < timeout) {
        final status = await channel
            .invokeMethod<String>('rawPrintStatus', id)
            .timeout(timeout);
        switch (status) {
          case 'transmitted':
            return RawPrintOutcome.transmitted;
          case 'not_sent':
            return RawPrintOutcome.notSent;
          case 'pending':
            await Future<void>.delayed(poll);
          default:
            return RawPrintOutcome.unknown;
        }
      }
    } on MissingPluginException {
      return submitted ? RawPrintOutcome.unknown : RawPrintOutcome.notSent;
    } on PlatformException catch (e) {
      if (!submitted && e.code == 'raw_not_sent') return RawPrintOutcome.notSent;
    } catch (_) {
      // The spooler may finish after a timeout. Never replay automatically.
    }
    return RawPrintOutcome.unknown;
  }
}

bool usePdfFallback(RawPrintOutcome outcome, bool enabled) =>
    enabled && outcome == RawPrintOutcome.notSent;
