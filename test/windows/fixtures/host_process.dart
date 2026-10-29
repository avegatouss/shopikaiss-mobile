// Test-only child process. Never included by the Windows entrypoint.
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final request = jsonDecode(line) as Map;
    if (request['command'] == 'commitSale') {
      if (args.contains('lose-reply')) exit(0);
      if (args.contains('timeout')) continue;
    }
    stdout.writeln(
      jsonEncode({
        'version': 1,
        'kind': 'response',
        'id': request['id'],
        'ok': true,
        'result': {
          'command': request['command'],
          'operation_id': request['operation_id'],
        },
      }),
    );
  }
}
