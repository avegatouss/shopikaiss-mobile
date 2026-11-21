import 'dart:io';

/// Resolve legacy servers without sending credentials or following redirects.
/// Authentication redirects and network failures keep the normal start route.
Future<Uri?> resolveCaisseStartWebsite(
  String? origin, {
  Future<int> Function(Uri)? status,
}) async {
  final uri = caisseStartWebsite(origin);
  if (uri == null) return null;
  try {
    final code = await (status ?? _status)(uri)
        .timeout(const Duration(seconds: 3));
    if (code == 404 || code == 405) return caisseWebsite(origin, '/caisse');
  } catch (_) {
    // The browser can still connect using its own authenticated session.
  }
  return uri;
}

Future<int> _status(Uri uri) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    return await (() async {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      return (await request.close()).statusCode;
    })().timeout(const Duration(seconds: 3));
  } finally {
    client.close(force: true);
  }
}

/// The server resolves the account/device terminal and restaurant profile.
Uri? caisseStartWebsite(String? origin) =>
    caisseWebsite(origin, '/caisse/demarrer');

/// Use the paired website only, without forwarding API credentials or codes.
Uri? caisseWebsite(String? origin, String path) {
  final uri = Uri.tryParse(origin ?? '');
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  return uri.replace(path: '${uri.path.replaceFirst(RegExp(r'/+$'), '')}$path');
}
