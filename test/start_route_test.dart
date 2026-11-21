import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/web/start_route.dart';

/// Repli de `/caisse/demarrer` vers `/caisse` quand le serveur n'a pas la route (production sur une version ancienne).
void main() {
  const start = 'https://boutique.exemple.ci/caisse/demarrer';
  const register = 'https://boutique.exemple.ci/caisse';
  final now = DateTime.utc(2026, 11, 21, 10);
  final missing = StartRouteMemory('https://boutique.exemple.ci', now.subtract(const Duration(hours: 1)));

  String? fallback({String shopUrl = start, String? failed = start, int? status = 404, bool main = true, bool tried = false}) =>
      fallbackUrlFor(shopUrl: shopUrl, failedUrl: failed, statusCode: status, isMainFrame: main, alreadyTried: tried);

  group('fallbackUrlFor', () {
    test('404 ou 405 sur la route de démarrage du cadre principal : /caisse de la même origine', () {
      expect(fallback(), register);
      expect(fallback(status: 405), register);
      expect(fallback(failed: '$start/'), register);
      expect(fallback(shopUrl: 'http://10.0.0.5:8080/caisse/demarrer', failed: 'http://10.0.0.5:8080/caisse/demarrer?x=1'),
          'http://10.0.0.5:8080/caisse?x=1');
    });

    test('une seule tentative par chargement', () {
      expect(fallback(tried: true), isNull);
    });

    test('rien pour une autre erreur, une ressource, une autre page ou une autre origine', () {
      expect(fallback(status: 500), isNull);
      expect(fallback(status: 403), isNull);
      expect(fallback(status: null), isNull);
      expect(fallback(main: false), isNull);
      expect(fallback(failed: register), isNull, reason: '/caisse en 404 : pas de boucle');
      expect(fallback(failed: 'https://boutique.exemple.ci/restaurant/caisse'), isNull);
      expect(fallback(failed: 'https://autre.exemple.ci/caisse/demarrer'), isNull);
      expect(fallback(failed: null), isNull);
    });

    test('adresse personnalisée enregistrée : le repli vaut aussi pour une redirection vers la route', () {
      expect(fallback(shopUrl: 'https://boutique.exemple.ci/restaurant/caisse'), register);
    });
  });

  group('startUrlFor', () {
    test('sans souvenir : l’adresse enregistrée', () {
      expect(startUrlFor(start, null, now), start);
      expect(startUrlFor('', null, now), '');
    });

    test('route absente sur cette origine depuis moins de 24 h : /caisse directement', () {
      expect(startUrlFor(start, missing, now), register);
    });

    test('souvenir oublié après 24 h ou si l’origine change', () {
      expect(startUrlFor(start, StartRouteMemory('https://boutique.exemple.ci', now.subtract(const Duration(hours: 24))), now), start);
      expect(startUrlFor('https://autre.exemple.ci/caisse/demarrer', missing, now), 'https://autre.exemple.ci/caisse/demarrer');
    });

    test('adresse personnalisée laissée telle quelle', () {
      expect(startUrlFor('https://boutique.exemple.ci/restaurant/caisse', missing, now), 'https://boutique.exemple.ci/restaurant/caisse');
    });
  });

  test('souvenir : aller-retour JSON, lecture tolérante', () {
    final back = StartRouteMemory.fromJson(missing.toJson())!;
    expect([back.origin, back.at], [missing.origin, missing.at]);
    expect(StartRouteMemory.fromJson(null), isNull);
    expect(StartRouteMemory.fromJson({'origin': 'https://x', 'at': 'pas une date'}), isNull);
    expect(StartRouteMemory.fromJson('texte'), isNull);
  });
}
