enum ShopNavigation { internal, external, blocked }

class ShopBrowserPolicy {
  ShopBrowserPolicy(String address) {
    final uri = Uri.tryParse(address);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException(
        'Configurez une adresse de boutique HTTPS valide.',
      );
    }
    origin = Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    );
  }
  late final Uri origin;
  Uri get site => origin.resolve('/');
  Uri get admin => origin.resolve('/accueil');
  ShopNavigation navigation(Uri uri) {
    if (uri.userInfo.isNotEmpty) return ShopNavigation.blocked;
    if (uri.scheme == 'https' && uri.origin == origin.origin) {
      return ShopNavigation.internal;
    }
    if (['https', 'http', 'tel', 'mailto', 'whatsapp'].contains(uri.scheme)) {
      return ShopNavigation.external;
    }
    return ShopNavigation.blocked;
  }
}
