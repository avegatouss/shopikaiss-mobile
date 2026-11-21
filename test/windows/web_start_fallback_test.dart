import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/web_destinations.dart';

void main() {
  test(
    'missing start route falls back on same shop, preserving base path',
    () async {
      for (final code in [404, 405]) {
        expect(
          (await resolveCaisseStartWebsite(
            'https://shop.example/tenant',
            status: (_) async => code,
          )).toString(),
          'https://shop.example/tenant/caisse',
        );
      }
    },
  );
  test(
    'authentication redirect or network failure keeps server start route',
    () async {
      for (final code in [200, 302, 401, 403, 500]) {
        expect(
          (await resolveCaisseStartWebsite(
            'https://shop.example',
            status: (_) async => code,
          ))?.path,
          '/caisse/demarrer',
        );
      }
      expect(
        (await resolveCaisseStartWebsite(
          'https://shop.example',
          status: (_) async => throw StateError('offline'),
        ))?.path,
        '/caisse/demarrer',
      );
    },
  );
  test('invalid origin never triggers a request', () async {
    expect(
      await resolveCaisseStartWebsite(
        'https://user:secret@shop.example',
        status: (_) async => fail('No request expected'),
      ),
      isNull,
    );
  });
}
