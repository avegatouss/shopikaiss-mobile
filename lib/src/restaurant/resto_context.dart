import 'resto_engine.dart';

/// Réglages restaurant résolus pour le point de vente (`restaurant.reglages`, RESTAURANT-1 §3.3).
class RestoSettings {
  const RestoSettings({
    this.sendToProduction = false,
    this.severalOrdersPerTable = false,
    this.orderPrefix = '',
    this.cancellationReason = false,
    this.registerRequired = false,
    this.prebillOnRequest = false,
    this.timezone,
    this.firstActiveFallback = false,
  });

  factory RestoSettings.fromJson(Map m) => RestoSettings(
    sendToProduction: m['envoi_production'] == true,
    severalOrdersPerTable: m['plusieurs_commandes_par_table'] == true,
    orderPrefix: m['prefixe_commande'] as String? ?? '',
    cancellationReason: m['motif_annulation_commande'] == true,
    registerRequired: m['registre_obligatoire'] == true,
    prebillOnRequest: m['prefacture_a_la_demande'] == true,
    timezone: m['fuseau'] as String?,
    firstActiveFallback: m['repli_premier_poste_actif'] == true,
  );

  /// Éteint : « Envoyer » devient « Valider », aucun bon (R-3).
  final bool sendToProduction;
  final bool severalOrdersPerTable;
  final String orderPrefix;
  final bool cancellationReason;
  final bool registerRequired;
  final bool prebillOnRequest;

  /// Fuseau de la journée métier (`date_metier`).
  final String? timezone;
  final bool firstActiveFallback;
}

class RestoRoom {
  const RestoRoom({required this.uuid, required this.code, required this.name, required this.order});

  final String uuid;
  final String code;
  final String name;
  final int order;
}

class RestoTable {
  const RestoTable({required this.uuid, this.roomUuid, required this.name, this.code, this.capacity, required this.order});

  final String uuid;
  final String? roomUuid;
  final String name;
  final String? code;
  final int? capacity;
  final int order;
}

class RestoMenu {
  const RestoMenu({required this.uuid, required this.name, required this.products, required this.categories});

  final String uuid;
  final String name;
  final Set<String> products;
  final Set<String> categories;
}

/// Ce que le terminal sait du restaurant de son point de vente (capacité `restaurant.v1`) : profil, désignation de la
/// caisse maîtresse, réglages, salles, tables et menus. Construit à chaque synchronisation depuis `/etat` et la projection.
class RestoContext {
  const RestoContext({
    required this.pointOfSaleUuid,
    required this.pointOfSaleName,
    required this.profile,
    required this.master,
    required this.generation,
    this.notMasterReason,
    this.settings = const RestoSettings(),
    this.rooms = const [],
    this.tables = const [],
    this.menus = const [],
    this.hiddenCategories = const {},
    this.lastOrderNumber,
  });

  final String? pointOfSaleUuid;
  final String? pointOfSaleName;

  /// `TABLE_SERVICE`, `PRODUCTION` ou null (Boutique).
  final String? profile;

  /// Caisse maîtresse : `/etat.restaurant.maitre` ET la désignation publiée citent cet appareil et cette époque.
  final bool master;

  /// Génération de la désignation, portée par chaque fait restaurant.
  final String generation;

  /// Pourquoi la caisse n'est pas maîtresse (lecture seule), ou null.
  final String? notMasterReason;
  final RestoSettings settings;
  final List<RestoRoom> rooms;
  final List<RestoTable> tables;
  final List<RestoMenu> menus;

  /// Catégories publiées masquées (`restaurant.categorie.visible` faux), par uuid.
  final Set<String> hiddenCategories;

  /// Dernier numéro local reçu par le serveur de cet appareil (`derniers_numeros.commande`) : jamais réutilisé.
  final String? lastOrderNumber;

  bool get tableService => profile == 'TABLE_SERVICE';

  RestoTable? table(String? uuid) => tables.where((t) => t.uuid == uuid).firstOrNull;
}

/// Commande vue par l'écran de salle : dernière version, et où en est sa remontée.
class RestoOrderView {
  const RestoOrderView({required this.order, required this.payable, this.paid = false, this.pendingVersions = 0, this.serverMessage, this.waiting = false, this.serverNumber});

  final RestoOrder order;

  /// À payer selon la règle du web (TVA de la boutique).
  final int payable;

  /// Réglée par une vente de ce terminal, clôture encore à enregistrer.
  final bool paid;

  /// Versions pas encore reçues par le serveur.
  final int pendingVersions;

  /// Message du serveur sur une version en attente ou à arbitrer (codes `restaurant.*`).
  final String? serverMessage;

  /// Une version attend la précédente (`restaurant.attente_version`) : rien à faire, le serveur la rejoue seul.
  final bool waiting;

  /// Numéro attribué par le serveur (`details.commande.numero`), une fois la version 1 intégrée.
  final String? serverNumber;
}
