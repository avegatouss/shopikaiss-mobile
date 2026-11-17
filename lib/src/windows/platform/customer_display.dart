import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../presentation/register_controller.dart';

String displayText(Object? value, [int limit = 120]) {
  final text = '${value ?? ''}'.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ');
  return text.length <= limit ? text : text.substring(0, limit);
}

Map<String, String> customerFrame(Map<String, dynamic> view) {
  final lines = (view['lines'] as List? ?? []).whereType<Map>().toList();
  final totals = view['totals'] as Map? ?? {};
  final total = displayText(totals['payable_label'] ?? view['total_label']);
  final screen = lines.isEmpty
      ? 'SHOPIKAISS\n\nBienvenue'
      : 'SHOPIKAISS\n\n${lines.map((l) => '${displayText(l['quantity_label'], 20)}\t${displayText(l['name'], 65)}\t${displayText(l['total_label'], 30)}').join('\n')}\n\nTOTAL : $total';
  String ascii(String text) {
    const accented = 'àâäéèêëîïôöùûüçÀÂÄÉÈÊËÎÏÔÖÙÛÜÇ';
    const plain = 'aaaeeeeiioouuucAAAEEEEIIOOUUUC';
    for (var i = 0; i < accented.length; i++) {
      text = text.replaceAll(accented[i], plain[i]);
    }
    text = text.replaceAll(RegExp(r'[^ -~]'), '?');
    return text.length > 20 ? text.substring(0, 20) : text.padRight(20);
  }

  final first = lines.isEmpty ? 'SHOPIKAISS' : displayText(lines.last['name']);
  final second = lines.isEmpty ? 'Bienvenue' : 'TOTAL $total';
  // ESC/POS VFD 20x2 profile: clear + home, then two fixed-width rows.
  return {
    'screen': screen,
    'serial': '\x0c\x1b\x40${ascii(first)}${ascii(second)}',
  };
}

class CustomerDisplayService {
  CustomerDisplayService(this.controller);
  final WindowsRegisterController controller;
  static const channel = MethodChannel('ci.khoga.shopikaiss/windows');
  Map<String, String> settings = {
    'mode': 'off',
    'port': 'COM1',
    'baud': '9600',
    'monitor': '1',
  };
  String? error;
  Timer? timer;
  bool disposed = false;
  String? lastFrame;
  File? get file {
    final root = Platform.environment['LOCALAPPDATA'];
    if (root == null || Platform.environment.containsKey('FLUTTER_TEST')) {
      return null;
    }
    return File('$root/ShopiKaiss/customer-display.json');
  }

  Future<void> start() async {
    controller.addListener(changed);
    try {
      final source = file;
      if (source != null && await source.exists()) {
        final data = jsonDecode(await source.readAsString()) as Map;
        final restored = {
          ...settings,
          ...data.map((k, v) => MapEntry('$k', '$v')),
        };
        if (!disposed) await configure(restored, save: false);
      }
    } catch (e) {
      error = e.toString();
    }
  }

  Future<List<int>> monitors() async =>
      (await channel.invokeListMethod<int>('displayMonitors')) ?? [];
  Future<void> configure(Map<String, String> value, {bool save = true}) async {
    if (!['off', 'screen', 'serial'].contains(value['mode']) ||
        !['9600', '19200', '38400', '115200'].contains(value['baud'])) {
      throw const FormatException('Configuration d’afficheur invalide.');
    }
    await channel.invokeMethod<void>('configureDisplay', value);
    settings = Map.of(value);
    lastFrame = null;
    error = null;
    if (save && file != null) {
      await file!.parent.create(recursive: true);
      await file!.writeAsString(jsonEncode(settings), flush: true);
    }
    changed();
  }

  void changed() {
    if (disposed || settings['mode'] == 'off') return;
    timer?.cancel();
    timer = Timer(const Duration(milliseconds: 100), () async {
      final frame = controller.ready
          ? customerFrame(controller.view)
          : customerFrame({});
      final encoded = jsonEncode(frame);
      if (lastFrame == encoded || disposed) return;
      try {
        await channel.invokeMethod<void>('updateDisplay', frame);
        lastFrame = encoded;
      } catch (e) {
        error = e.toString();
      }
    });
  }

  Future<String> test() async {
    await channel.invokeMethod<void>('updateDisplay', {
      'screen': 'SHOPIKAISS\n\nTEST AFFICHEUR\nAUCUNE VENTE',
      'serial': '\x0c\x1b\x40SHOPIKAISS TEST      AUCUNE VENTE        ',
    });
    await Future<void>.delayed(const Duration(milliseconds: 350));
    final failure = await channel.invokeMethod<String>('displayError');
    lastFrame = null;
    return failure == null || failure.isEmpty
        ? 'Test transmis. Vérifiez le résultat sur l’afficheur.'
        : failure;
  }

  void dispose() {
    disposed = true;
    timer?.cancel();
    controller.removeListener(changed);
    if (settings['mode'] != 'off') {
      unawaited(
        channel
            .invokeMethod<void>('configureDisplay', {'mode': 'off'})
            .catchError((Object _) {}),
      );
    }
  }
}
