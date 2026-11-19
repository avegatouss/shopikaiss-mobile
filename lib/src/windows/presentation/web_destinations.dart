/// The server resolves the account/device terminal and restaurant profile.
Uri? caisseStartWebsite(String? origin) => caisseWebsite(origin, '/caisse/demarrer');

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
