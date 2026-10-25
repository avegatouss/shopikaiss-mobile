import 'dart:convert';
import 'dart:typed_data';

/// Encodage ESC/POS côté application : ticket de test et image raster (tickets HTML).
/// Les tickets de vente ESC/POS, eux, arrivent déjà encodés par la page (`escpos-ticket.js`).
class EscPos {
  EscPos._();

  static const int esc = 0x1B;
  static const int gs = 0x1D;

  /// Largeur imprimable en points (203 dpi) : 384 pour 58 mm, 576 pour 80 mm.
  static int dotsFor(int paperWidth) => paperWidth >= 80 ? 576 : 384;

  /// Colonnes en police A : 32 pour 58 mm, 48 pour 80 mm.
  static int columnsFor(int paperWidth) => paperWidth >= 80 ? 48 : 32;

  static List<int> init() => [esc, 0x40];

  static List<int> feedAndCut() => [esc, 0x64, 4, gs, 0x56, 66, 0];

  /// Ticket de test en ASCII (aucune table de caractères requise).
  static Uint8List testTicket({required int paperWidth, required List<String> lines}) {
    final cols = columnsFor(paperWidth);
    final out = BytesBuilder()
      ..add(init())
      ..add([esc, 0x61, 1]) // centré
      ..add([esc, 0x45, 1, gs, 0x21, 0x11]) // gras, double taille
      ..add(_ascii('SHOPIKAISS\n'))
      ..add([gs, 0x21, 0x00, esc, 0x45, 0])
      ..add(_ascii('Test d\'impression\n'))
      ..add([esc, 0x61, 0]) // gauche
      ..add(_ascii('${'-' * cols}\n'));
    for (final line in lines) {
      out.add(_ascii('${line.length > cols ? line.substring(0, cols) : line}\n'));
    }
    out
      ..add(_ascii('${'-' * cols}\n'))
      ..add([esc, 0x61, 1])
      ..add(_ascii('Imprimante OK\n'))
      ..add(feedAndCut());
    return out.toBytes();
  }

  /// Image monochrome → commandes `GS v 0` par bandes de 128 lignes, puis avance et coupe.
  /// [bits] : une ligne = `widthBytes` octets, bit de poids fort = point le plus à gauche, 1 = noir.
  static Uint8List raster(Uint8List bits, int widthDots, int height, {bool cut = true}) {
    final widthBytes = (widthDots + 7) >> 3;
    final out = BytesBuilder()..add(init());
    const band = 128;
    for (var y = 0; y < height; y += band) {
      final rows = (height - y) < band ? height - y : band;
      out.add([gs, 0x76, 0x30, 0, widthBytes & 0xFF, widthBytes >> 8, rows & 0xFF, rows >> 8]);
      out.add(Uint8List.sublistView(bits, y * widthBytes, (y + rows) * widthBytes));
    }
    out.add(cut ? feedAndCut() : [esc, 0x64, 4]);
    return out.toBytes();
  }

  static List<int> _ascii(String text) =>
      latin1.encode(text.replaceAll(RegExp(r'[^\x20-\x7E\n]'), '?'));
}

/// Page rastérisée (RGBA) → bitmap 1 bit à la largeur de l'imprimante.
class MonoBitmap {
  MonoBitmap(this.widthDots) : widthBytes = (widthDots + 7) >> 3;

  final int widthDots;
  final int widthBytes;
  final BytesBuilder _rows = BytesBuilder(copy: false);
  int height = 0;

  /// Ajoute une page : mise à l'échelle sur [widthDots] (moyenne des pixels couverts), seuil de
  /// luminance, puis suppression des lignes blanches de tête et de fin. Le rendu « impression » du
  /// navigateur laisse en haut de page l'espace des éléments masqués de la caisse : sans ce rognage,
  /// une longue bande blanche sortait avant le ticket.
  void addPage(Uint8List rgba, int width, int height, {int threshold = 170}) {
    if (width <= 0 || height <= 0) return;
    final scale = width / widthDots;
    final targetHeight = (height / scale).floor();
    final page = Uint8List(targetHeight * widthBytes);
    var firstInk = -1;
    var lastInk = -1;
    for (var ty = 0; ty < targetHeight; ty++) {
      final sy0 = (ty * scale).floor();
      final sy1 = ((ty + 1) * scale).ceil().clamp(sy0 + 1, height);
      for (var tx = 0; tx < widthDots; tx++) {
        final sx0 = (tx * scale).floor();
        final sx1 = ((tx + 1) * scale).ceil().clamp(sx0 + 1, width);
        var sum = 0;
        var count = 0;
        for (var sy = sy0; sy < sy1; sy++) {
          var i = (sy * width + sx0) * 4;
          for (var sx = sx0; sx < sx1; sx++, i += 4) {
            final a = rgba[i + 3];
            // Luminance (Rec. 601) composée sur fond blanc.
            final l = (rgba[i] * 299 + rgba[i + 1] * 587 + rgba[i + 2] * 114) ~/ 1000;
            sum += 255 - ((255 - l) * a ~/ 255);
            count++;
          }
        }
        if (count > 0 && sum ~/ count < threshold) {
          page[ty * widthBytes + (tx >> 3)] |= 0x80 >> (tx & 7);
          if (firstInk < 0) firstInk = ty;
          lastInk = ty;
        }
      }
    }
    if (lastInk < 0) return;
    final keep = lastInk - firstInk + 1;
    _rows.add(Uint8List.sublistView(page, firstInk * widthBytes, (lastInk + 1) * widthBytes));
    this.height += keep;
  }

  /// Ajoute des lignes déjà au format de [bits] (page convertie dans un autre fil).
  void append(Uint8List bits, int rows) {
    if (rows <= 0) return;
    _rows.add(bits);
    height += rows;
  }

  Uint8List get bits => _rows.toBytes();
}
