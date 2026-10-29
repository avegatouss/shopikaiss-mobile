import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/platform/network_printer.dart';

void main() {
  test('transmits exact receipt without adding a drawer command', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final received = server.first.then(
      (socket) => socket.fold<List<int>>([], (all, part) => all..addAll(part)),
    );
    final ticket = Uint8List.fromList([27, 64, 65, 10]);
    final result = await const NetworkReceiptPrinter().send(
      InternetAddress.loopbackIPv4,
      server.port,
      ticket,
    );
    expect(result.outcome, PrintOutcome.transmitted);
    expect(await received.timeout(const Duration(seconds: 3)), ticket);
    await server.close();
  });
  test('invalid ticket is not sent', () async {
    final result = await const NetworkReceiptPrinter().send(
      InternetAddress.loopbackIPv4,
      0,
      Uint8List(0),
    );
    expect(result.outcome, PrintOutcome.notSent);
  });
}
