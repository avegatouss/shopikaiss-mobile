import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:http/http.dart' as http;

/// Réponse brute de l'API v2. `status == 0` : aucune réponse (réseau, délai, corps tronqué) — résultat inconnu.
class V2Response {
  const V2Response(this.status, this.body, {this.retryAfter, this.raw, this.bytes});

  final int status;

  /// Corps décodé ; `null` pour un 204 ou un corps illisible.
  final Object? body;

  /// En-tête `Retry-After` (secondes), s'il est présent.
  final int? retryAfter;

  /// Texte exact du corps (pages d'instantané : l'empreinte se vérifie sur le contenu décodé, le texte sert au diagnostic).
  final String? raw;

  /// Corps binaire exact ([V2Transport.fetchBytes]).
  final List<int>? bytes;

  bool get ok => status >= 200 && status < 300;
}

/// Transport de l'API `/api/caisse/v2` (contrat-v2/openapi.json). Abstrait pour les tests.
abstract class V2Transport {
  /// [path] relatif au préfixe v2 (`/etat`, `/operations`…), requête déjà construite.
  Future<V2Response> send(String method, String apiBase, String path, {Map<String, String> headers, Object? body, Duration? timeout});

  /// GET d'un contenu binaire (images) : corps non décodé dans [V2Response.bytes].
  Future<V2Response> fetchBytes(String apiBase, String path, {Map<String, String> headers, Duration? timeout});
}

class HttpV2Transport implements V2Transport {
  HttpV2Transport({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const defaultTimeout = Duration(seconds: 45);

  @override
  Future<V2Response> fetchBytes(String apiBase, String path, {Map<String, String> headers = const {}, Duration? timeout}) async {
    try {
      final response = await _client.get(Uri.parse('$apiBase$path'), headers: headers).timeout(timeout ?? defaultTimeout);
      return V2Response(response.statusCode, null, retryAfter: int.tryParse(response.headers['retry-after'] ?? ''), bytes: response.bodyBytes);
    } on TimeoutException {
      return const V2Response(0, null);
    } on SocketException {
      return const V2Response(0, null);
    } on http.ClientException {
      return const V2Response(0, null);
    } on HandshakeException {
      return const V2Response(0, null);
    }
  }

  @override
  Future<V2Response> send(String method, String apiBase, String path, {Map<String, String> headers = const {}, Object? body, Duration? timeout}) async {
    try {
      final request = http.Request(method, Uri.parse('$apiBase$path'))
        ..headers.addAll({'Accept': 'application/json', if (body != null) 'Content-Type': 'application/json', ...headers});
      if (body != null) request.bodyBytes = utf8.encode(jsonEncode(body));
      final streamed = await _client.send(request).timeout(timeout ?? defaultTimeout);
      final response = await http.Response.fromStream(streamed).timeout(timeout ?? defaultTimeout);
      final retry = int.tryParse(response.headers['retry-after'] ?? '');
      if (response.bodyBytes.isEmpty) return V2Response(response.statusCode, null, retryAfter: retry);
      final bytes = response.bodyBytes;
      try {
        final text = utf8.decode(bytes);
        // Pages d'instantané (jusqu'à 1 000 entités) décodées hors du fil de l'écran.
        final decoded = bytes.length > 65536 ? await Isolate.run(() => jsonDecode(text)) : jsonDecode(text);
        return V2Response(response.statusCode, decoded, retryAfter: retry, raw: text);
      } on FormatException {
        // Corps tronqué ou illisible : traité comme une absence de réponse fiable.
        return V2Response(response.statusCode >= 200 && response.statusCode < 300 ? 0 : response.statusCode, null, retryAfter: retry);
      }
    } on TimeoutException {
      return const V2Response(0, null);
    } on SocketException {
      return const V2Response(0, null);
    } on http.ClientException {
      return const V2Response(0, null);
    } on HandshakeException {
      return const V2Response(0, null);
    }
  }
}
