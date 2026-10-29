import 'dart:io';

import 'package:shopikaiss_terminal/src/windows/host/engine_host.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Exécutable du moteur de caisse Windows, lancé par l'interface (`ProcessWindowsHost`, chemin absolu, sans shell).
///
///   shopikaiss_moteur.exe [--dossier <chemin absolu>] [--version <version de l'application>]
///
/// stdout est réservé aux trames du protocole privé ; stderr ne reçoit que des messages courts, sans donnée de vente
/// ni secret. Codes de sortie : 0 arrêt normal (EOF), 2 arguments invalides, 3 base déjà possédée par un autre hôte,
/// 1 échec de démarrage.
Future<void> main(List<String> args) async {
  String? directory;
  var version = '';
  for (var i = 0; i < args.length; i++) {
    final value = i + 1 < args.length ? args[i + 1] : null;
    switch (args[i]) {
      case '--dossier' when value != null:
        directory = value;
        i++;
      case '--version' when value != null:
        version = value;
        i++;
      default:
        stderr.writeln('Argument non reconnu.');
        exitCode = 2;
        return;
    }
  }
  final EngineHost host;
  try {
    sqfliteFfiInit();
    host = await EngineHost.open(directory: directory ?? EngineHost.defaultDirectory(), appVersion: version, factory: databaseFactoryFfi);
  } on EngineHostBusy {
    stderr.writeln('Moteur déjà démarré sur cette base.');
    exitCode = 3;
    return;
  } catch (e) {
    final detail = '$e';
    stderr.writeln('Démarrage du moteur impossible : ${detail.length > 300 ? detail.substring(0, 300) : detail}');
    exitCode = 1;
    return;
  }
  await host.serve(stdin, stdout.add);
  await stdout.flush();
}
