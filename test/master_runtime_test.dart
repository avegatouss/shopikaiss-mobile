import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shopikaiss_terminal/src/app_settings.dart';
import 'package:shopikaiss_terminal/src/offline/store.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_backup.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_engine.dart';
import 'package:shopikaiss_terminal/src/terminal/master_runtime.dart';
import 'package:shopikaiss_terminal/src/terminal/master_settings_section.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_v2_server.dart';
import 'support/resto_master.dart';

class _FakePlatform implements MasterPlatform {
  ({int level, bool plugged})? level = (level: 80, plugged: true);
  final events = <String>[];

  @override
  Future<({int level, bool plugged})?> battery() async => level;

  @override
  Future<void> startService(String text) async => events.add('start $text');

  @override
  Future<void> stopService() async => events.add('stop');
}

/// Téléphone en caisse maîtresse (lot R-6) : afficheur, service de premier plan, batterie et sauvegardes suivent la
/// désignation et les réglages du poste.
void main() {
  sqfliteFfiInit();
  late Directory dir;
  late SqfliteOfflineStore base;
  late FakeV2Server server;
  var uuids = 0;
  String newUuid() => 'abcdef00-0000-4000-8000-${(++uuids).toString().padLeft(12, '0')}';

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('maitre_');
    base = await SqfliteOfflineStore.open(name: p.join(dir.path, 'caisse.db'), factory: databaseFactoryFfi);
    server = FakeV2Server.sellable();
  });
  tearDown(() async {
    await base.close();
    dir.deleteSync(recursive: true);
  });

  Future<int> freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  test('maître : page servie si réglée, service de premier plan, alerte batterie, sauvegarde ; retiré : tout s’arrête', () async {
    serveRestoMaster(server);
    final e = V2Engine.onStore(base, transport: server, appVersion: 'essai', platform: 'android', newUuid: newUuid,
        pinVerifier: FakeV2Server.pinVerifier, contract21: true, announceRestaurant: true, clock: () => DateTime.utc(2026, 11, 18, 19, 30));
    await e.load('https://boutique.exemple.ci');
    expect(await e.pair('ABCD-EFGH', model: 'Essai', appVersion: 'essai'), isNull);
    await e.sync();

    final settings = AppSettings(shopUrl: 'https://boutique.exemple.ci', driver: 'none', paperWidth: 0, serialPath: '', serialBaud: 0, bluetoothAddress: '', usbDevice: '', adminCode: '');
    final platform = _FakePlatform();
    final runtime = MasterRuntime(engine: e, settings: settings, platform: platform, backupDirectory: Directory(p.join(dir.path, 'sauvegardes')),
        clock: () => DateTime(2026, 11, 18, 19, 30));
    addTearDown(runtime.stop);

    // Maître, page éteinte par défaut : service seul, sans page servie.
    await runtime.apply();
    expect([runtime.master, runtime.display, platform.events], [true, null, ['start Bons envoyés aux imprimantes du lieu.']]);
    expect(runtime.batteryWarning, isNull, reason: 'sur secteur');

    // Le gérant allume la page sur ce poste.
    settings
      ..displayServer = true
      ..displayServerPort = await freePort();
    await runtime.apply();
    expect(runtime.display?.port, settings.displayServerPort);
    expect(e.restoStationScreen, isNotNull);
    expect(platform.events.last, startsWith('start Afficheurs servis'), reason: 'notification mise à jour');

    // Batterie faible sans secteur.
    platform.level = (level: 18, plugged: false);
    await runtime.apply();
    expect(runtime.batteryWarning, contains('18 %'));

    // Sauvegarde : fichier complet, relisible.
    final file = await runtime.backupNow();
    expect(CaisseBackup.inspect(file!.readAsBytesSync()).deviceUuid, fakeDevice);
    expect(runtime.lastBackupAt, isNotNull);

    // Port déjà pris : erreur lisible, rien ne casse.
    final busy = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    settings.displayServerPort = busy.port;
    await runtime.apply();
    expect(runtime.displayError, contains('Port ${busy.port}'));
    await busy.close();

    // Page éteinte : plus d'écran, service gardé tant que le poste est maître.
    settings.displayServer = false;
    await runtime.apply();
    expect([runtime.display, e.restoStationScreen], [null, null]);

    // Retiré par le serveur : service arrêté au prochain changement, plus d'alerte.
    server.restaurant = {'point_de_vente_uuid': restoPdv, 'profil': 'TABLE_SERVICE', 'maitre': false, 'generation': '4', 'derniers_numeros': null};
    await e.sync();
    await runtime.apply();
    expect([runtime.master, platform.events.last, runtime.batteryWarning], [false, 'stop', null]);
  });

  test('adresse du mode afficheur : réseau local seulement', () {
    expect(displayModeUrlOf('192.168.1.20:8787'), 'http://192.168.1.20:8787/');
    expect(displayModeUrlOf(' http://10.0.0.4 '), 'http://10.0.0.4:8787/');
    expect(displayModeUrlOf('http://caisse.local:9000/afficheur'), 'http://caisse.local:9000/');
    for (final bad in ['', 'https://192.168.1.20', 'http://8.8.8.8:8787', 'http://boutique.exemple.ci', 'http://127.0.0.1:8787', 'http://a@192.168.1.2']) {
      expect(displayModeUrlOf(bad), isNull, reason: bad);
    }
  });
}
