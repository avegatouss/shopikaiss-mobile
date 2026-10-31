import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/web_destinations.dart';

void main() {
  test(
    'paired origin gives distinct safe web destinations without credentials',
    () {
      expect(
        caisseWebsite('https://demo.khoga.ci/', '/accueil').toString(),
        'https://demo.khoga.ci/accueil',
      );
      expect(
        caisseWebsite('https://example.test/shop/', '/caisse').toString(),
        'https://example.test/shop/caisse',
      );
      for (final value in [
        null,
        '',
        'https://user:secret@example.test',
        'https://example.test/?token=secret',
        'file:///test',
        'https://example.test/#secret',
      ]) {
        expect(caisseWebsite(value, '/caisse'), isNull);
      }
    },
  );
}
