import 'dart:convert';
import 'dart:io';

/// Single UI writer, same directory as the engine database. No customer data.
/// An interrupted/corrupt write blocks sales; it is never silently discarded.
class SaleIntentJournal {
  SaleIntentJournal(this.file);
  final File file;
  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );

  Future<String?> read() async {
    if (!await file.exists()) return null;
    if (await file.length() > 1024) throw const FormatException('Intent size');
    final data = jsonDecode(await file.readAsString());
    if (data is! Map ||
        data['schema'] != 1 ||
        data['operation_id'] is! String ||
        !_uuid.hasMatch(data['operation_id'] as String)) {
      throw const FormatException('Intent invalid');
    }
    return data['operation_id'] as String;
  }

  Future<void> begin(String operation) async {
    if (!_uuid.hasMatch(operation)) throw const FormatException('UUID');
    final pending = await read();
    if (pending != null) throw StateError('Unresolved sale');
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({'schema': 1, 'operation_id': operation}),
      flush: true,
    );
  }

  Future<void> resolve(String operation) async {
    if (await read() != operation) throw StateError('Intent mismatch');
    await file.delete();
  }
}
