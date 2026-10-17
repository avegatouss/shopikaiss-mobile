import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/app_settings.dart';
import 'package:shopikaiss_terminal/src/printer/escpos.dart';

void main() {
  group('normalizeShopUrl', () {
    test('ajoute https et /caisse', () {
      expect(normalizeShopUrl('boutique.exemple.ci'), 'https://boutique.exemple.ci/caisse');
      expect(normalizeShopUrl(' https://boutique.exemple.ci/ '), 'https://boutique.exemple.ci/caisse');
    });

    test('garde un chemin et un port explicites', () {
      expect(normalizeShopUrl('http://192.168.1.10:8000/connexion'), 'http://192.168.1.10:8000/connexion');
    });

    test('refuse une adresse invalide', () {
      expect(normalizeShopUrl(''), isNull);
      expect(normalizeShopUrl('ftp://exemple.ci'), isNull);
    });

    test('origine sans port par défaut', () {
      expect(originOf('https://Boutique.Exemple.ci:443/caisse'), 'https://boutique.exemple.ci');
      expect(originOf('http://10.0.0.5:8080/x'), 'http://10.0.0.5:8080');
    });
  });

  group('MonoBitmap', () {
    Uint8List rgba(int w, int h, bool Function(int x, int y) black) {
      final out = Uint8List(w * h * 4);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = (y * w + x) * 4;
          final v = black(x, y) ? 0 : 255;
          out[i] = v;
          out[i + 1] = v;
          out[i + 2] = v;
          out[i + 3] = 255;
        }
      }
      return out;
    }

    test('seuil, ordre des bits et suppression du blanc de tête et de fin', () {
      // 16 px de large, 6 lignes : seule la ligne 1 porte deux points noirs (x=0 et x=9).
      final bitmap = MonoBitmap(16)..addPage(rgba(16, 6, (x, y) => y == 1 && (x == 0 || x == 9)), 16, 6);
      expect(bitmap.height, 1);
      expect(bitmap.bits, [0x80, 0x40]);
    });

    test('longue bande blanche avant le ticket rognée (impression du navigateur)', () {
      // 300 lignes blanches puis 3 lignes de ticket, puis 50 lignes blanches : seules les 3 lignes restent.
      final bitmap = MonoBitmap(8)..addPage(rgba(8, 353, (x, y) => y >= 300 && y < 303), 8, 353);
      expect(bitmap.height, 3);
      expect(bitmap.bits, [0xFF, 0xFF, 0xFF]);
    });

    test('mise à l’échelle à la largeur de l’imprimante', () {
      final bitmap = MonoBitmap(8)..addPage(rgba(16, 4, (x, y) => true), 16, 4);
      expect(bitmap.height, 2);
      expect(bitmap.bits, [0xFF, 0xFF]);
    });

    test('page blanche ignorée', () {
      final bitmap = MonoBitmap(8)..addPage(rgba(8, 8, (x, y) => false), 8, 8);
      expect(bitmap.height, 0);
    });
  });

  group('EscPos.raster', () {
    test('en-tête GS v 0 par bandes de 128 lignes', () {
      final bytes = EscPos.raster(Uint8List(48 * 200), 384, 200, cut: false);
      expect(bytes.sublist(0, 2), [0x1B, 0x40]);
      expect(bytes.sublist(2, 10), [0x1D, 0x76, 0x30, 0, 48, 0, 128, 0]);
      final second = 10 + 48 * 128;
      expect(bytes.sublist(second, second + 8), [0x1D, 0x76, 0x30, 0, 48, 0, 72, 0]);
      expect(bytes.length, 2 + 8 + 48 * 128 + 8 + 48 * 72 + 3);
    });

    test('ticket de test : 32 colonnes en 58 mm, coupe finale', () {
      final bytes = EscPos.testTicket(paperWidth: 58, lines: const ['é']);
      expect(bytes.sublist(bytes.length - 7), [0x1B, 0x64, 4, 0x1D, 0x56, 66, 0]);
      expect(String.fromCharCodes(bytes).contains('-' * 32), isTrue);
      expect(String.fromCharCodes(bytes).contains('?\n'), isTrue);
    });
  });
}
