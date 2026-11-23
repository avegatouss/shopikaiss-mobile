import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../offline/caisse_engine.dart';
import '../offline/notifier.dart';
import '../sync_v2/decimal6.dart';
import 'resto_display_page.dart';
import 'resto_engine.dart';

/// Écran (tablette, télévision) relié à la page d'afficheur de la caisse maîtresse (R10, lot R-6). Jamais appairé au
/// serveur : il ne connaît que la caisse du lieu. Seule l'empreinte de son jeton est gardée.
class RestoDisplayDevice {
  const RestoDisplayDevice({required this.id, required this.name, required this.tokenHash, required this.createdAt});

  factory RestoDisplayDevice.fromJson(Map m) => RestoDisplayDevice(
    id: m['id'] as String,
    name: m['nom'] as String,
    tokenHash: m['empreinte'] as String,
    createdAt: DateTime.parse(m['cree_le'] as String),
  );

  final String id;
  final String name;
  final String tokenHash;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {'id': id, 'nom': name, 'empreinte': tokenHash, 'cree_le': createdAt.toUtc().toIso8601String()};
}

/// Bon en attente de l'accusé de l'afficheur.
class _Pending {
  _Pending(this.ticket, this.station);

  final RestoTicket ticket;
  final RestoStation station;
  final Completer<RestoOutcome> done = Completer();

  /// Le bon est parti dans une réponse à un afficheur : sans accusé, l'issue est inconnue (plan §7.1).
  bool fetched = false;
}

/// Service local de la page d'afficheur, servi par la caisse maîtresse (Android ou Windows) sur le réseau du lieu
/// (RESTAURANT-1 §5.6, plan §2 et §7.5, décision R10).
///
/// - Éteint par défaut ; port choisi sur le poste ; jamais d'adresse ni de port venus du serveur.
/// - Accès limité aux adresses privées du réseau local ; aucune ouverture publique.
/// - Un écran se relie une fois par un code à 6 chiffres affiché sur la caisse (usage unique, 10 minutes) ; il reçoit un
///   jeton gardé par son navigateur, envoyé en en-tête `Authorization` (jamais en cookie : une autre page ne peut pas
///   agir à sa place). Le jeton est révocable depuis la caisse.
/// - La page ne lit que les bons des postes à écran ; elle n'écrit que l'accusé de réception et « prêt ».
///
/// Livraison ([deliver], branchée sur `restoStationScreen`) : sans écran relié qui interroge ce poste, échec certain
/// (`non_envoye`, la chaîne de secours imprime) ; sinon attente de l'accusé [ackTimeout] : accusé → `accuse` ; bon parti
/// vers l'écran sans accusé → `a_verifier` (jamais réimprimé automatiquement) ; jamais parti → `non_envoye`.
class RestoDisplayServer extends EngineNotifier {
  RestoDisplayServer(
    this.engine, {
    required this.read,
    required this.write,
    this.ackTimeout = const Duration(seconds: 10),
    this.pollHold = const Duration(seconds: 20),
    this.aliveWindow = const Duration(seconds: 15),
    DateTime Function()? clock,
    Random? random,
  }) : _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure();

  /// Clé locale des écrans reliés (dans la base du poste : la sauvegarde les emporte).
  static const storageKey = 'v2.resto_afficheurs';

  static const defaultPort = 8787;

  /// Corps de requête accepté, en octets.
  static const maxBody = 8 * 1024;

  final CaisseEngine engine;
  final Future<String?> Function(String key) read;
  final Future<void> Function(String key, String value) write;
  final Duration ackTimeout;
  final Duration pollHold;
  final Duration aliveWindow;
  final DateTime Function() _clock;
  final Random _random;

  HttpServer? _http;
  final _devices = <String, RestoDisplayDevice>{};
  final _pending = <String, _Pending>{};
  final _waiters = <Completer<void>>[];
  final _seen = <String, DateTime>{};
  final _watching = <String, Set<String>>{};
  final _activePolls = <String, int>{};
  var _version = 1;
  String? _code;
  DateTime? _codeUntil;
  final _failures = <DateTime>[];
  DateTime? _lockedUntil;

  bool get running => _http != null;
  int? get port => _http?.port;

  /// Code de liaison en cours (usage unique) et sa fin de validité.
  String? get pairingCode => _code != null && _clock().isBefore(_codeUntil!) ? _code : null;
  DateTime? get pairingCodeUntil => pairingCode == null ? null : _codeUntil;

  List<RestoDisplayDevice> get devices => List.unmodifiable(_devices.values);

  /// Dernière requête de l'écran [deviceId], ou null.
  DateTime? lastSeen(String deviceId) => _seen[deviceId];

  /// Démarre le service sur [port] (toutes les interfaces IPv4 ; requêtes hors réseau privé refusées) et le branche sur
  /// le moteur.
  Future<void> start({int port = defaultPort}) async {
    await stop();
    await _load();
    final http = await HttpServer.bind(InternetAddress.anyIPv4, port);
    http.idleTimeout = const Duration(seconds: 30);
    _http = http;
    http.listen((request) => unawaited(_handle(request)), onError: (_) {});
    engine.addListener(_changed);
    engine.restoStationScreen = deliver;
    notifyListeners();
  }

  Future<void> stop() async {
    final http = _http;
    if (http == null) return;
    _http = null;
    engine.removeListener(_changed);
    if (engine.restoStationScreen == deliver) engine.restoStationScreen = null;
    for (final p in List.of(_pending.values)) {
      if (!p.done.isCompleted) p.done.complete(p.fetched ? RestoOutcome.aVerifier : RestoOutcome.nonEnvoye);
    }
    _wake();
    await http.close(force: true);
    _activePolls.clear();
    notifyListeners();
  }

  /// Nouveau code de liaison à 6 chiffres, valable 10 minutes, pour un seul écran.
  String newPairingCode() {
    _code = (_random.nextInt(900000) + 100000).toString();
    _codeUntil = _clock().add(const Duration(minutes: 10));
    notifyListeners();
    return _code!;
  }

  /// Retire un écran : son jeton est refusé dès sa prochaine requête.
  Future<void> revoke(String deviceId) async {
    if (_devices.remove(deviceId) == null) return;
    _seen.remove(deviceId);
    _watching.remove(deviceId);
    await _save();
    _wake();
    notifyListeners();
  }

  /// Un écran relié interroge ce poste en ce moment (requête en cours ou récente).
  bool stationAlive(String stationUuid) {
    final now = _clock();
    for (final entry in _watching.entries) {
      if (!entry.value.contains(stationUuid) || !_devices.containsKey(entry.key)) continue;
      if ((_activePolls[entry.key] ?? 0) > 0) return true;
      final seen = _seen[entry.key];
      if (seen != null && now.difference(seen) <= aliveWindow) return true;
    }
    return false;
  }

  /// Cible `ecran_poste` du moteur.
  Future<RestoOutcome> deliver(RestoTicket ticket, RestoStation station) async {
    if (_http == null || !stationAlive(station.uuid)) return RestoOutcome.nonEnvoye;
    final pending = _pending[ticket.uuid] ?? (_pending[ticket.uuid] = _Pending(ticket, station));
    _bump();
    try {
      return await pending.done.future.timeout(ackTimeout, onTimeout: () => pending.fetched ? RestoOutcome.aVerifier : RestoOutcome.nonEnvoye);
    } finally {
      if (identical(_pending[ticket.uuid], pending)) _pending.remove(ticket.uuid);
    }
  }

  // --- Requêtes ---

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers
      ..set('Cache-Control', 'no-store')
      ..set('X-Content-Type-Options', 'nosniff')
      ..set('Referrer-Policy', 'no-referrer')
      ..set('X-Frame-Options', 'DENY')
      ..set(
        'Content-Security-Policy',
        "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
      );
    try {
      final remote = request.connectionInfo?.remoteAddress;
      if (remote == null || !isPrivateAddress(remote)) {
        return await _json(response, 403, {'erreur': 'Réservé au réseau local du lieu.'});
      }
      final path = request.uri.path;
      final method = request.method;
      if (method == 'GET' && (path == '/' || path == '/afficheur')) {
        response.headers.contentType = ContentType.html;
        response.write(restoDisplayHtml);
        return await response.close();
      }
      if (method == 'GET' && path == '/app.js') {
        response.headers.contentType = ContentType('application', 'javascript', charset: 'utf-8');
        response.write(restoDisplayScript);
        return await response.close();
      }
      if (path.startsWith('/api/')) {
        if (method == 'POST') {
          final origin = request.headers.value('origin');
          final host = request.headers.value('host');
          if (origin != null && origin != 'http://$host') return await _json(response, 403, {'erreur': 'Origine refusée.'});
          if (request.headers.contentType?.mimeType != 'application/json') return await _json(response, 415, {'erreur': 'JSON attendu.'});
        }
        switch ((method, path)) {
          case ('POST', '/api/appairage'):
            return await _pair(request, response);
          case ('GET', '/api/bons'):
            return await _tickets(request, response);
          case ('POST', '/api/accuse'):
            return await _ack(request, response);
          case ('POST', '/api/pret'):
            return await _ready(request, response);
        }
      }
      return await _json(response, 404, {'erreur': 'Introuvable.'});
    } catch (_) {
      try {
        await _json(response, 500, {'erreur': 'Erreur de la caisse.'});
      } catch (_) {}
    }
  }

  Future<void> _pair(HttpRequest request, HttpResponse response) async {
    final now = _clock();
    if (_lockedUntil != null && now.isBefore(_lockedUntil!)) return _json(response, 429, {'erreur': 'Trop d’essais : patientez une minute.'});
    final body = await _body(request);
    if (body == null) return _json(response, 400, {'erreur': 'Requête illisible.'});
    final code = '${body['code'] ?? ''}'.trim();
    if (pairingCode == null || !_same(code, _code!)) {
      _failures
        ..removeWhere((f) => now.difference(f) > const Duration(minutes: 1))
        ..add(now);
      if (_failures.length >= 5) {
        _lockedUntil = now.add(const Duration(minutes: 1));
        _failures.clear();
      }
      return _json(response, 401, {'erreur': 'Code incorrect ou expiré : demandez un nouveau code sur la caisse.'});
    }
    _code = null;
    _codeUntil = null;
    final token = _secret(32);
    var name = '${body['nom'] ?? ''}'.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '').trim();
    if (name.length > 40) name = name.substring(0, 40);
    if (name.isEmpty) name = 'Écran ${_devices.length + 1}';
    final device = RestoDisplayDevice(id: _secret(8), name: name, tokenHash: _hash(token), createdAt: now);
    _devices[device.id] = device;
    await _save();
    notifyListeners();
    return _json(response, 200, {'jeton': token, 'ecran': device.name, 'postes': _stations()});
  }

  Future<void> _tickets(HttpRequest request, HttpResponse response) async {
    final device = _authorize(request);
    if (device == null) return _json(response, 401, {'erreur': 'Écran non relié.'});
    final screens = {for (final s in _screenStations()) s.uuid};
    final asked = (request.uri.queryParameters['postes'] ?? '').split(',').where(screens.contains).toSet();
    final watched = asked.isEmpty ? screens : asked;
    _watching[device.id] = watched;
    _seen[device.id] = _clock();
    final since = int.tryParse(request.uri.queryParameters['version'] ?? '');
    if (since != null && since == _version) {
      _activePolls[device.id] = (_activePolls[device.id] ?? 0) + 1;
      try {
        final waiter = Completer<void>();
        _waiters.add(waiter);
        await waiter.future.timeout(pollHold, onTimeout: () {});
        _waiters.remove(waiter);
      } finally {
        _activePolls[device.id] = (_activePolls[device.id] ?? 1) - 1;
        _seen[device.id] = _clock();
      }
      if (!_devices.containsKey(device.id) || _http == null) return _json(response, 401, {'erreur': 'Écran non relié.'});
    }
    final version = _version;
    final context = engine.restaurant;
    if (context == null || !context.master) {
      return _json(response, 200, {'version': version, 'heure': _stamp(), 'maitre': false, 'postes': _stations(), 'bons': const []});
    }
    final now = _clock();
    final views = await engine.restoTickets();
    final listed = <String>{};
    final tickets = <Map<String, dynamic>>[];
    for (final v in views.reversed) {
      if (!watched.contains(v.ticket.stationUuid)) continue;
      if (now.difference(v.ticket.createdAt) > const Duration(hours: 18)) continue;
      if (v.done && now.difference(v.statusAt ?? v.ticket.createdAt) > const Duration(minutes: 15)) continue;
      listed.add(v.ticket.uuid);
      tickets.add(_ticketJson(v.ticket, v.stationName, v.orderNumber, v.table, status: v.status, printed: v.printed, done: v.done));
    }
    for (final p in _pending.values) {
      if (watched.contains(p.station.uuid) && !listed.contains(p.ticket.uuid)) {
        tickets.add(_ticketJson(p.ticket, p.station.name, '', null, status: 'new', printed: false, done: false));
        listed.add(p.ticket.uuid);
      }
    }
    for (final p in _pending.values) {
      if (listed.contains(p.ticket.uuid)) p.fetched = true;
    }
    return _json(response, 200, {'version': version, 'heure': _stamp(), 'maitre': true, 'postes': _stations(), 'bons': tickets});
  }

  Future<void> _ack(HttpRequest request, HttpResponse response) async {
    final device = _authorize(request);
    if (device == null) return _json(response, 401, {'erreur': 'Écran non relié.'});
    final body = await _body(request);
    final ids = body?['bons'];
    if (ids is! List || ids.length > 200) return _json(response, 400, {'erreur': 'Requête illisible.'});
    _seen[device.id] = _clock();
    for (final id in ids) {
      final pending = _pending['$id'];
      if (pending != null && pending.fetched && !pending.done.isCompleted) pending.done.complete(RestoOutcome.accuse);
    }
    return _json(response, 200, {'ok': true});
  }

  Future<void> _ready(HttpRequest request, HttpResponse response) async {
    final device = _authorize(request);
    if (device == null) return _json(response, 401, {'erreur': 'Écran non relié.'});
    final body = await _body(request);
    final id = body?['bon'];
    if (id is! String || id.length > 64) return _json(response, 400, {'erreur': 'Requête illisible.'});
    _seen[device.id] = _clock();
    final view = (await engine.restoTickets()).where((t) => t.ticket.uuid == id).firstOrNull;
    final station = engine.restaurant?.stations[view?.ticket.stationUuid];
    if (view == null || station == null || !station.screen) return _json(response, 404, {'erreur': 'Bon introuvable.'});
    try {
      final updated = await engine.restoTicketStatus(id, station.flow == 'handover' ? 'served' : 'ready', source: 'afficheur');
      return await _json(response, 200, {'bon': _ticketJson(updated.ticket, updated.stationName, updated.orderNumber, updated.table, status: updated.status, printed: updated.printed, done: updated.done)});
    } on OfflineRefusal catch (e) {
      return _json(response, 409, {'erreur': e.message});
    }
  }

  // --- Outils ---

  List<RestoStation> _screenStations() {
    final stations = engine.restaurant?.stations.values.where((s) => s.active && s.screen).toList() ?? <RestoStation>[];
    return stations..sort((a, b) => a.order.compareTo(b.order));
  }

  List<Map<String, dynamic>> _stations() => [for (final s in _screenStations()) {'uuid': s.uuid, 'nom': s.name}];

  Map<String, dynamic> _ticketJson(RestoTicket t, String station, String order, String? table, {required String status, required bool printed, required bool done}) {
    String two(int v) => v.toString().padLeft(2, '0');
    final local = t.createdAt.toLocal();
    return {
      'uuid': t.uuid,
      'poste_uuid': t.stationUuid,
      'poste': station,
      'numero_jour': t.dayNumber,
      'titre': t.title,
      'type': t.type,
      'commande': order,
      'bon': t.number,
      'table': table,
      'heure': '${two(local.hour)}:${two(local.minute)}',
      'cree_le': t.createdAt.toUtc().toIso8601String(),
      'motif': t.reason,
      'lignes': [
        for (final l in t.lines) {'quantite': Decimal6.label(l.quantity), 'libelle': l.label, 'commentaire': l.comment, 'annule': l.action == 'cancel'},
      ],
      'statut': status,
      'deja_imprime': printed,
      'termine': done,
    };
  }

  RestoDisplayDevice? _authorize(HttpRequest request) {
    final header = request.headers.value('authorization') ?? '';
    if (!header.startsWith('Bearer ')) return null;
    final token = header.substring(7).trim();
    if (token.isEmpty || token.length > 128) return null;
    final hash = _hash(token);
    for (final d in _devices.values) {
      if (_same(hash, d.tokenHash)) return d;
    }
    return null;
  }

  Future<Map?> _body(HttpRequest request) async {
    final bytes = <int>[];
    await for (final chunk in request) {
      bytes.addAll(chunk);
      if (bytes.length > maxBody) return null;
    }
    try {
      final value = jsonDecode(utf8.decode(bytes));
      return value is Map ? value : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _json(HttpResponse response, int status, Object body) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }

  void _changed() => _bump();

  void _bump() {
    _version++;
    _wake();
  }

  void _wake() {
    for (final w in List.of(_waiters)) {
      if (!w.isCompleted) w.complete();
    }
    _waiters.clear();
  }

  Future<void> _load() async {
    _devices.clear();
    try {
      for (final m in (jsonDecode(await read(storageKey) ?? '[]') as List).cast<Map>()) {
        final d = RestoDisplayDevice.fromJson(m);
        _devices[d.id] = d;
      }
    } catch (_) {
      // Liste illisible : aucun écran relié, chacun se relie à nouveau par un code.
    }
  }

  Future<void> _save() => write(storageKey, jsonEncode([for (final d in _devices.values) d.toJson()]));

  String _stamp() => _clock().toUtc().toIso8601String();

  String _secret(int bytes) => base64Url.encode(List<int>.generate(bytes, (_) => _random.nextInt(256))).replaceAll('=', '');

  static String _hash(String token) => sha256.convert(utf8.encode(token)).toString();

  /// Comparaison à durée constante.
  static bool _same(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// Adresse du réseau local : boucle locale, 10/8, 172.16/12, 192.168/16, 169.254/16 ; IPv6 locale (fe80::/10,
  /// fc00::/7) ou IPv4 encapsulée.
  static bool isPrivateAddress(InternetAddress address) {
    if (address.isLoopback || address.isLinkLocal) return true;
    final raw = address.rawAddress;
    if (address.type == InternetAddressType.IPv4 && raw.length == 4) return _privateV4(raw);
    if (address.type == InternetAddressType.IPv6 && raw.length == 16) {
      final mapped = raw.sublist(0, 10).every((b) => b == 0) && raw[10] == 0xff && raw[11] == 0xff;
      if (mapped) return _privateV4(raw.sublist(12));
      return (raw[0] & 0xfe) == 0xfc || (raw[0] == 0xfe && (raw[1] & 0xc0) == 0x80);
    }
    return false;
  }

  static bool _privateV4(List<int> b) =>
      b[0] == 10 || b[0] == 127 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254);

  /// Adresses IPv4 privées de ce poste, pour l'adresse à saisir sur l'écran.
  static Future<List<String>> localAddresses() async {
    final found = <String>[];
    try {
      for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        for (final a in i.addresses) {
          if (!a.isLoopback && isPrivateAddress(a)) found.add(a.address);
        }
      }
    } catch (_) {}
    return found;
  }
}
