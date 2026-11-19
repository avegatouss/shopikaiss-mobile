/// Interface simplifiée de la caisse restaurant (`restaurant.interface`, lot Z local, README §12.8) : trois réglages
/// d'affichage du web publiés par point de vente. Valeurs par défaut tant qu'aucune entité n'est reçue, et pour toute
/// valeur inconnue (un serveur plus récent peut en ajouter).
class RestoInterface {
  const RestoInterface({this.askCovers = true, this.sendLabel = sendDefault, this.catalogNavigation = navigationChips});

  /// Entité `restaurant.interface` (ou null : valeurs par défaut).
  factory RestoInterface.fromJson(Map? data) {
    if (data == null) return defaults;
    final send = data['libelle_envoi'];
    final navigation = data['navigation_carte'];
    return RestoInterface(
      askCovers: data['demander_couverts'] is bool ? data['demander_couverts'] as bool : true,
      sendLabel: sendLabels.contains(send) ? send as String : sendDefault,
      catalogNavigation: navigations.contains(navigation) ? navigation as String : navigationChips,
    );
  }

  static const defaults = RestoInterface();

  static const sendDefault = 'send';
  static const sendHold = 'hold';
  static const sendHoldShort = 'hold_short';
  static const sendLabels = {sendDefault, sendHold, sendHoldShort};

  static const navigationChips = 'chips';
  static const navigationTiles = 'tiles';
  static const navigationFamilies = 'families';
  static const navigations = {navigationChips, navigationTiles, navigationFamilies};

  /// `restaurant.ask_covers` : demander les couverts à l'ouverture d'une table ; faux = une table libre ouvre aussitôt
  /// la commande.
  final bool askCovers;

  /// `restaurant.send_button_label` : `send`, `hold` ou `hold_short`.
  final String sendLabel;

  /// `restaurant.catalog_navigation` : `chips` (puces de catégories), `tiles` (tuiles de catégories) ou `families`.
  final String catalogNavigation;

  /// Libellé du bouton d'envoi : « Envoyer » (« Valider » sans envoi en production), « Mettre en attente » ou « Mise en
  /// attente ».
  String sendButton({required bool production}) => switch (sendLabel) {
    sendHold => 'Mettre en attente',
    sendHoldShort => 'Mise en attente',
    _ => production ? 'Envoyer' : 'Valider',
  };

  /// Valeurs du contrat (`demander_couverts`, `libelle_envoi`, `navigation_carte`).
  Map<String, dynamic> toJson() => {'demander_couverts': askCovers, 'libelle_envoi': sendLabel, 'navigation_carte': catalogNavigation};
}
