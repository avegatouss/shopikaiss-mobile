import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/sync_v2/canonical_json.dart';
import 'package:shopikaiss_terminal/src/sync_v2/schema_validator.dart';

/// Contrat de synchronisation v2 (session A, révision 2.0.1, copie dans test/fixtures/contrat-v2) : le terminal fait
/// passer les MÊMES vecteurs de canonicalisation et les MÊMES fixtures que le serveur (`ContratV2Test`), preuve
/// d'interopérabilité attendue en P5.
void main() {
  const root = 'test/fixtures/contrat-v2';
  Object? json(String path) => jsonDecode(File('$root/$path').readAsStringSync());
  final validator = SchemaValidator((file) => File('$root/schemas/$file').readAsStringSync());

  group('Canonicalisation SK-JCS-1 : vecteurs interlangages', () {
    final vectors = (json('canonicalisation/vecteurs.json')! as Map)['vecteurs'] as List;
    test('20 vecteurs présents', () => expect(vectors, hasLength(20)));
    for (final raw in vectors) {
      final vector = raw as Map;
      test('${vector['nom']}', () {
        if (vector['refuse'] == true) {
          expect(() => CanonicalJson.fromJson(vector['entree'] as String), throwsA(isA<CanonicalJsonError>()));
          return;
        }
        final canonical = CanonicalJson.fromJson(vector['entree'] as String);
        expect(canonical, vector['canonique']);
        expect(sha256.convert(utf8.encode(canonical)).toString(), vector['sha256']);
      });
    }

    test('une demi-paire UTF-16 isolée est refusée (le serveur refuse une chaîne non UTF-8)', () {
      expect(() => CanonicalJson.encode({'s': '\uD83D'}), throwsA(isA<CanonicalJsonError>()));
    });
  });

  group('Schémas SK-SCHEMA-1 : fixtures valides et invalides', () {
    final fixtures = (json('fixtures/index.json')! as Map)['fixtures'] as List;
    test('221 fixtures présentes (révision 2.1 lots 10 à 15 + restaurant-1 R-1 à R-5 + lot Z local)', () => expect(fixtures, hasLength(221)));
    for (final raw in fixtures) {
      final fixture = raw as Map;
      test('${fixture['fichier']}', () {
        final data = json('fixtures/${fixture['fichier']}');
        final schema = fixture['schema'] as String;
        final control = fixture['controle'] as String?;
        final errors = validator.validate(data, schema);
        if (fixture['valide'] == true || control != null) {
          expect(errors, isEmpty, reason: errors.join(' ; '));
        } else {
          expect(errors, isNotEmpty, reason: 'la fixture invalide doit être refusée');
          expect(errors.join(' ; '), contains(fixture['erreur_attendue']));
        }
        if (schema == 'operation.json') {
          final operation = Map<String, dynamic>.from(data! as Map);
          final matches = CanonicalJson.operationFingerprint(operation) == operation['empreinte'];
          expect(matches, !(fixture['valide'] != true && control == 'empreinte'), reason: 'empreinte de l’opération');
        }
        if (schema == r'instantanes.json#/$defs/page') {
          final page = data! as Map;
          expect(CanonicalJson.sha256Of(page['entites']) == page['empreinte'], control != 'empreinte_page');
        }
      });
    }

    test('les empreintes de pages du manifeste correspondent aux pages', () {
      final manifest = json('fixtures/valides/instantane-manifeste--une-page.json')! as Map;
      final page = json('fixtures/valides/instantane-page--1.json')! as Map;
      expect((manifest['pages'] as Map)['empreintes'][0], page['empreinte']);
      expect(manifest['uuid'], page['instantane_uuid']);
    });

    test('un mot-clé hors profil est une erreur de schéma, jamais une donnée valide par défaut', () {
      final strict = SchemaValidator((_) => '{"type":"object","format":"uuid"}');
      expect(() => strict.validate({}, 'x.json'), throwsA(isA<SchemaProfileError>()));
    });
  });
}
