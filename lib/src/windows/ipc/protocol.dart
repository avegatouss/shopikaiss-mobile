import 'dart:async';
import 'dart:convert';

const windowsIpcVersion = 1;
const maxIpcFrameBytes = 1024 * 1024;

/// Private local transport contract. This is not the server v2 contract.
enum HostCommand {
  pair,
  login,
  addProduct,
  clear,
  status,
  view,
  search,
  scan,
  changeQuantity,
  removeLine,
  preparePayment,
  setPayment,
  commitSale,
  saleStatus,
  history,
  reprint,
  synchronize,
}

class HostFailure implements Exception {
  const HostFailure(this.code, this.message, {this.outcomeUnknown = false});
  final String code;
  final String message;
  final bool outcomeUnknown;
  @override
  String toString() => message;
}

/// Bounds frames before decoding: LineSplitter alone allows unbounded memory.
Stream<Map<String, dynamic>> decodeFrames(Stream<List<int>> input) async* {
  var bytes = <int>[];
  await for (final chunk in input) {
    for (final byte in chunk) {
      if (byte == 10) {
        if (bytes.isEmpty) continue;
        final decoded = jsonDecode(utf8.decode(bytes));
        bytes = <int>[];
        if (decoded is! Map<String, dynamic> ||
            decoded['version'] != windowsIpcVersion) {
          throw const FormatException('Incompatible local protocol');
        }
        yield decoded;
      } else {
        if (bytes.length >= maxIpcFrameBytes) {
          throw const FormatException('Local frame too large');
        }
        bytes.add(byte);
      }
    }
  }
  if (bytes.isNotEmpty) throw const FormatException('Truncated local frame');
}

List<int> encodeFrame(Map<String, dynamic> data) {
  final bytes = utf8.encode(
    jsonEncode({'version': windowsIpcVersion, ...data}),
  );
  if (bytes.length > maxIpcFrameBytes) {
    throw const HostFailure('frame_limit', 'Réponse locale trop volumineuse.');
  }
  return [...bytes, 10];
}

abstract interface class WindowsHost {
  Stream<Map<String, dynamic>> get events;
  Future<Map<String, dynamic>> call(
    HostCommand command, {
    Map<String, dynamic> arguments = const {},
    String? operationId,
  });
  Future<void> close();
}
