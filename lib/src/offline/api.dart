import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Réponse de l'API, ou panne réseau (`status == 0`).
class ApiResponse {
  const ApiResponse(this.status, this.body);

  final int status;
  final Map<String, dynamic> body;

  bool get ok => status >= 200 && status < 300;
  bool get unreachable => status == 0;
  bool get unauthorized => status == 401;
  String get message => (body['message'] ?? body['erreur'] ?? 'Réponse inattendue du serveur ($status).') as String;
}

/// Transport de l'API `/api/caisse/v1` (ADR-421). Abstrait pour les tests.
abstract class RegisterTransport {
  Future<ApiResponse> pair(String apiBase, String code, String model, String appVersion);
  Future<ApiResponse> status(String apiBase, String token);
  Future<ApiResponse> snapshot(String apiBase, String token);
  Future<ApiResponse> synchronize(String apiBase, String token, List<Map<String, dynamic>> operations);
}

class HttpRegisterTransport implements RegisterTransport {
  HttpRegisterTransport({http.Client? client, this.appVersion = ''}) : _client = client ?? http.Client();

  final http.Client _client;
  final String appVersion;

  static const _probeTimeout = Duration(seconds: 6);
  static const _dataTimeout = Duration(seconds: 45);

  Map<String, String> _headers(String? token) => {
    'Accept': 'application/json',
    'Content-Type': 'application/json',
    if (token != null) 'Authorization': 'Bearer $token',
    if (appVersion.isNotEmpty) 'X-Version-Application': appVersion,
  };

  Future<ApiResponse> _send(Future<http.Response> Function() call, Duration timeout) async {
    try {
      final response = await call().timeout(timeout);
      Map<String, dynamic> body = const {};
      if (response.body.isNotEmpty) {
        try {
          final decoded = jsonDecode(utf8.decode(response.bodyBytes));
          if (decoded is Map) body = Map<String, dynamic>.from(decoded);
        } on FormatException {
          body = {'message': 'Réponse illisible du serveur (${response.statusCode}).'};
        }
      }
      return ApiResponse(response.statusCode, body);
    } on TimeoutException {
      return const ApiResponse(0, {'message': 'Le serveur ne répond pas.'});
    } on SocketException {
      return const ApiResponse(0, {'message': 'Pas de connexion au serveur.'});
    } on http.ClientException catch (e) {
      return ApiResponse(0, {'message': 'Connexion impossible : ${e.message}'});
    } on HandshakeException {
      return const ApiResponse(0, {'message': 'Connexion sécurisée impossible (certificat ou date du terminal).'});
    }
  }

  @override
  Future<ApiResponse> pair(String apiBase, String code, String model, String appVersion) => _send(
    () => _client.post(
      Uri.parse('$apiBase/appairage'),
      headers: _headers(null),
      body: jsonEncode({'code': code, 'modele': model, 'version_application': appVersion}),
    ),
    _dataTimeout,
  );

  @override
  Future<ApiResponse> status(String apiBase, String token) =>
      _send(() => _client.get(Uri.parse('$apiBase/etat'), headers: _headers(token)), _probeTimeout);

  @override
  Future<ApiResponse> snapshot(String apiBase, String token) =>
      _send(() => _client.get(Uri.parse('$apiBase/referentiel'), headers: _headers(token)), _dataTimeout);

  @override
  Future<ApiResponse> synchronize(String apiBase, String token, List<Map<String, dynamic>> operations) => _send(
    () => _client.post(Uri.parse('$apiBase/synchronisation'), headers: _headers(token), body: jsonEncode({'operations': operations})),
    _dataTimeout,
  );
}
