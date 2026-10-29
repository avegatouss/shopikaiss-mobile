import 'dart:io';
import 'dart:typed_data';

enum PrintOutcome { transmitted, notSent, unknown }

class NetworkPrintResult {
  const NetworkPrintResult(this.outcome, this.message);
  final PrintOutcome outcome;
  final String message;
}

/// Sends the engine's already-committed receipt, never constructs a sale.
/// TCP delivery cannot prove paper output. No automatic retries or drawer pulse.
class NetworkReceiptPrinter {
  const NetworkReceiptPrinter({this.timeout = const Duration(seconds: 5)});
  final Duration timeout;

  Future<NetworkPrintResult> send(
    InternetAddress address,
    int port,
    Uint8List receipt,
  ) async {
    if (receipt.isEmpty ||
        receipt.length > 1024 * 1024 ||
        port < 1 ||
        port > 65535) {
      return const NetworkPrintResult(
        PrintOutcome.notSent,
        'Ticket ou port invalide.',
      );
    }
    Socket? socket;
    var started = false;
    try {
      socket = await Socket.connect(address, port, timeout: timeout);
      started = true;
      socket.add(receipt);
      await socket.flush().timeout(timeout);
      await socket.close().timeout(timeout);
      return const NetworkPrintResult(
        PrintOutcome.transmitted,
        'Ticket transmis à l’imprimante. Vérifiez la sortie papier.',
      );
    } catch (_) {
      return NetworkPrintResult(
        started ? PrintOutcome.unknown : PrintOutcome.notSent,
        started
            ? 'Impression à vérifier avant de demander un duplicata.'
            : 'Imprimante injoignable. Vente conservée.',
      );
    } finally {
      socket?.destroy();
    }
  }
}
