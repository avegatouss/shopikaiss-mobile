import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:shopikaiss_terminal/src/offline/receipt_settings.dart';
import 'package:shopikaiss_terminal/src/offline/store.dart';
import 'package:shopikaiss_terminal/src/register/register_adapter.dart';
import 'package:shopikaiss_terminal/src/sync_v2/v2_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_v2_server.dart';
import 'sync_v2_engine_test.dart' show serve21;

/// Logo de la boutique publié aux postes (capacité boutique.logo, note A LOGO-BOUTIQUE-POUR-B-ET-C.md).
void main() {
  sqfliteFfiInit();
  late Directory dir;
  late SqfliteOfflineStore base;
  late FakeV2Server server;
  var uuids = 0;
  String newUuid() => 'abcdef00-0000-4000-8000-${(++uuids).toString().padLeft(12, '0')}';
  const logo1 = 'abcdef00-0000-4000-8000-00000000a001';
  const logo2 = 'abcdef00-0000-4000-8000-00000000a002';

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('logo_boutique_');
    base = await SqfliteOfflineStore.open(name: p.join(dir.path, 'caisse.db'), factory: databaseFactoryFfi);
    server = FakeV2Server.sellable();
  });
  tearDown(() async {
    await base.close();
    dir.deleteSync(recursive: true);
  });

  Uint8List jpeg(int width) => Uint8List.fromList(img.encodeJpg(img.Image(width: width, height: 40)..clear(img.ColorRgb8(0, 0, 0))));
  Map<String, dynamic> meta(String uuid, List<int> bytes, {String? hash}) =>
      {'uuid': uuid, 'empreinte': hash ?? sha256.convert(bytes).toString(), 'octets': bytes.length, 'largeur': 120, 'hauteur': 40};

  /// Boutique publiant [logo] (absent : clé omise) ; capacité boutique.logo si [capability].
  void serve({Object? logo = const _Absent(), bool capability = true}) {
    serve21(server);
    server.capabilities = [...server.capabilities, if (capability) 'boutique.logo'];
    final shop = server.entities['boutique|$fakeShop']!['donnees'] as Map<String, dynamic>;
    if (logo is! _Absent) shop['ticket'] = {...(shop['ticket'] as Map), 'logo': logo, 'logo_carre': null};
  }

  void republish(Object? logo, int revision) {
    final shop = Map<String, dynamic>.from(server.entities['boutique|$fakeShop']!['donnees'] as Map);
    shop['ticket'] = {...(shop['ticket'] as Map), 'logo': logo, 'logo_carre': null};
    server.publish([{'type': 'boutique', 'critique': true, 'cle': fakeShop, 'revision': '$revision', 'action': 'upsert', 'donnees': shop}]);
  }

  Future<V2Engine> engine() async {
    final e = V2Engine.onStore(base, transport: server, appVersion: 'essai', platform: 'android', newUuid: newUuid, pinVerifier: FakeV2Server.pinVerifier, contract21: true);
    await e.load('https://boutique.exemple.ci');
    expect(await e.pair('ABCD-EFGH', model: 'Essai', appVersion: 'essai'), isNull);
    await e.sync();
    return e;
  }

  test('logo publié : téléchargé une fois, vérifié, imprimé à la place de la copie locale, gardé si le suivant est altéré', () async {
    final first = jpeg(120);
    server.logos[logo1] = first;
    serve(logo: meta(logo1, first));
    final e = await engine();
    expect(e.shopLogoPublished, isTrue);
    expect(e.shopLogoUuid, logo1);
    expect(server.requests.where((r) => r.path == '/logos/$logo1'), hasLength(1));

    // Une copie locale importée avant reste enregistrée, mais c'est le logo de la boutique qui s'imprime.
    final local = Uint8List.fromList(img.encodePng(img.Image(width: 10, height: 10)));
    await ReceiptSettings(logoPng: local).write(e);
    var settings = await ReceiptSettings.read(e);
    expect(settings.shopLogo, isTrue);
    expect(settings.localLogoPng, local);
    expect(settings.logoPng, isNot(local));
    expect(img.decodePng(settings.logoPng!), isNotNull);
    await settings.copyWith(copies: 2).write(e);
    expect((await ReceiptSettings.read(e)).localLogoPng, local, reason: 'le logo de la boutique n’écrase pas la copie locale');

    await e.sync();
    expect(server.requests.where((r) => r.path.startsWith('/logos/')), hasLength(1), reason: 'même uuid : pas de nouveau téléchargement');

    // Nouveau logo dont l'empreinte ne correspond pas : refusé, l'ancien reste.
    final second = jpeg(200);
    server.logos[logo2] = second;
    republish(meta(logo2, second, hash: 'a' * 64), 900);
    await e.sync();
    expect(e.shopLogoUuid, logo1);
    expect(e.shopLogoError, contains('altéré'));

    // Corrigé au serveur : remplacé.
    republish(meta(logo2, second), 901);
    await e.sync();
    expect((e.shopLogoUuid, e.shopLogoError), (logo2, null));

    // Adaptateur : uuid au statut, PNG par la commande.
    final adapter = LocalRegisterAdapter(e, newUuid: newUuid);
    await adapter.start();
    expect(((await adapter.execute('status', {}, null))['shop_logo'] as Map)['uuid'], logo2);
    final shown = await adapter.execute('shopLogo', {}, null);
    expect((shown['source'], shown['png_base64'] is String), ('boutique', true));
    await adapter.close();

    // Logo retiré au web : plus aucun logo, même avec la copie locale.
    republish(null, 902);
    await e.sync();
    expect(e.shopLogoUuid, isNull);
    settings = await ReceiptSettings.read(e);
    expect((settings.shopLogo, settings.logoPng), (true, null));
  });

  test('sans la capacité : la copie locale importée sur le poste reste le logo imprimé', () async {
    serve(capability: false);
    final e = await engine();
    expect(e.shopLogoPublished, isFalse);
    final local = Uint8List.fromList(img.encodePng(img.Image(width: 10, height: 10)));
    await ReceiptSettings(logoPng: local).write(e);
    final settings = await ReceiptSettings.read(e);
    expect(settings.shopLogo, isFalse);
    expect(settings.logoPng, local);
    expect(server.requests.where((r) => r.path.startsWith('/logos/')), isEmpty);
  });
}

class _Absent {
  const _Absent();
}
