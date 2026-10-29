@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shopikaiss_terminal/src/windows/ipc/process_host.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/protocol.dart';
import 'package:uuid/uuid.dart';

/// Essai de la caisse Windows contre un serveur en ligne : l'exécutable réel du moteur (Build-Moteur.ps1), piloté par
/// le protocole de C comme le fait l'interface. Appairage (une fois, base gardée dans SK_HOTE_DOSSIER), identification
/// par PIN, panier d'une unité, encaissement, envoi au serveur, numéro serveur relu.
///
///   SK_ORIGINE=https://demo.khoga.ci SK_CODE=XXXX-XXXX SK_PIN=… SK_HOTE_DOSSIER=C:/chemin SK_PRODUIT=Allumettes \
///   SK_OPERATEUR=3 flutter test test/integration/hote_windows_test.dart
///
/// Enregistre UNE vente d'une unité sur le serveur.
void main() {
  final env = Platform.environment;
  final origin = env['SK_ORIGINE'];
  final dossier = env['SK_HOTE_DOSSIER'];
  final exe = p.join(Directory.current.path, 'build', 'windows-moteur', 'bundle', 'bin', 'shopikaiss_moteur.exe');

  test('caisse Windows : appairage, PIN, encaissement, envoi, numéro serveur', () async {
    void note(String line) {
      // ignore: avoid_print
      print(line);
    }

    Directory(dossier!).createSync(recursive: true);
    final host = await ProcessWindowsHost.start(exe, arguments: ['--dossier', dossier, '--version', 'essai-windows'], timeout: const Duration(seconds: 45));
    // 45 s : délai de l'interface Windows (bootstrap.dart) ; la vérification bcrypt du PIN peut être longue.
    try {
      var status = await host.call(HostCommand.status);
      if (status['paired'] != true) {
        await host.call(HostCommand.pair, arguments: {'origin': origin, 'code': env['SK_CODE'], 'model': 'Windows (poste de dev)', 'app_version': 'essai-windows'});
        status = await host.call(HostCommand.status);
      }
      note('État : appairé ${status['paired']}, prêt ${status['ready']} ${status['block_reason'] ?? ''}, session ${status['session_open']}, '
          'PIN ${status['pin_required']}, opérateurs ${status['operators']}');
      expect(status['ready'], isTrue, reason: '${status['block_reason']}');

      Object? lastError;
      final wanted = int.tryParse(env['SK_OPERATEUR'] ?? '');
      for (final o in (status['operators'] as List).cast<Map>().where((o) => wanted == null || o['id'] == wanted)) {
        try {
          final clock = Stopwatch()..start();
          await host.call(HostCommand.login, arguments: {'operator_id': o['id'], 'pin': env['SK_PIN']});
          note('Identifié : ${o['name']} (${o['id']}) en ${clock.elapsedMilliseconds} ms');
          lastError = null;
          break;
        } on HostFailure catch (e) {
          note('PIN refusé pour ${o['name']} : ${e.message}');
          lastError = e;
          if (e.code != 'pin_refuse') break;
        }
      }
      expect(lastError, isNull);

      await host.call(HostCommand.clear);
      var view = await host.call(HostCommand.search, arguments: {'query': env['SK_PRODUIT'] ?? ''});
      final product = (view['products'] as List).cast<Map>().firstWhere((x) => (x['packagings'] as List).isEmpty && x['stock_label'] != '');
      note('Produit : ${product['name']} ${product['price_label']}, stock affiché ${product['stock_label']}');
      await host.call(HostCommand.addProduct, arguments: {'product_id': product['id']});
      final prepared = await host.call(HostCommand.preparePayment);
      await host.call(HostCommand.setPayment, arguments: {'method': 'especes', 'received': prepared['payable']});
      view = await host.call(HostCommand.view);
      note('Panier : ${view['total_label']} ; paiement ${view['payment_label']} ; encaissable ${view['can_pay']}');
      expect(view['can_pay'], isTrue, reason: 'session ouverte et panier complet');

      final op = const Uuid().v4();
      final sale = await host.call(HostCommand.commitSale, operationId: op);
      note('Encaissée : ${sale['number']} (${sale['state']})');
      expect(sale['state'], 'committed');
      expect((await host.call(HostCommand.commitSale, operationId: op))['number'], sale['number'], reason: 'rejeu idempotent');

      await host.call(HostCommand.synchronize);
      Map<String, dynamic>? sent;
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        final items = ((await host.call(HostCommand.history))['items'] as List).cast<Map<String, dynamic>>();
        sent = items.firstWhere((x) => x['operation_id'] == op);
        if (sent['server_status'] != null) break;
      }
      note('Envoi : ${sent!['server_status']} ${sent['server_number'] ?? ''}');
      expect(sent['server_status'], 'integree');
      view = await host.call(HostCommand.search, arguments: {'query': env['SK_PRODUIT'] ?? ''});
      final after = (view['products'] as List).cast<Map>().firstWhere((x) => x['id'] == product['id']);
      note('Stock affiché après envoi : ${after['stock_label']} ; ${view['sync_label']}');
    } finally {
      await host.close();
    }
  }, skip: origin == null || dossier == null ? 'SK_ORIGINE / SK_HOTE_DOSSIER absents' : false, timeout: const Timeout(Duration(minutes: 3)));
}
