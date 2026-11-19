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
    this.sentCancelNeedsApprover = false,
    this.assistant = const RestoAssistantCaps(),
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
    // Absent d'un serveur R-2 : éteint (valeur par défaut du web).
    sentCancelNeedsApprover: m['annulation_envoye_responsable'] == true,
    assistant: m['assistant'] is Map ? RestoAssistantCaps.fromJson(m['assistant'] as Map) : const RestoAssistantCaps(),
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

  /// `annulation_envoye_responsable` (R-3) : annuler un article envoyé exige toujours un responsable, même avec le droit.
  final bool sentCancelNeedsApprover;
  final RestoAssistantCaps assistant;
}

/// Plafonds d'une autorisation donnée par un assistant manager (`restaurant.reglages.assistant`) ; 0 = illimité.
class RestoAssistantCaps {
  const RestoAssistantCaps({this.operationsPerDay = 0, this.amountPerOperation = 0, this.amountPerDay = 0, this.maxDiscountPercent = 0});

  factory RestoAssistantCaps.fromJson(Map m) => RestoAssistantCaps(
    operationsPerDay: m['max_operations_par_jour'] as int? ?? 0,
    amountPerOperation: m['max_montant_par_operation'] as int? ?? 0,
    amountPerDay: m['max_montant_par_jour'] as int? ?? 0,
    maxDiscountPercent: m['max_remise_pourcent'] as int? ?? 0,
  );

  final int operationsPerDay;
  final int amountPerOperation;
  final int amountPerDay;

  /// Remise (ligne ou commande) qu'un assistant peut autoriser, en % arrondi au supérieur (R-4,
  /// `approval.assistant.max_discount_percent`) ; contrairement aux autres plafonds, 0 = aucune remise.
  final int maxDiscountPercent;
}

/// Autorisation d'un approbateur restaurant (`autorisation_restaurant`, §4.3 bis) : code de 8 chiffres vérifié sur la
/// caisse. Jamais le code ni son empreinte.
class RestoApproval {
  const RestoApproval({required this.approverId, required this.type, required this.reason, required this.verifiedAt, required this.amount});

  final int approverId;

  /// `resto_modifier_envoye`, `resto_annuler_commande`, `resto_offrir` ou `remise` (R-4).
  final String type;
  final String reason;
  final String verifiedAt;

  /// Montant autorisé (article ou commande), compté dans les plafonds de l'assistant.
  final int amount;

  Map<String, dynamic> toJson() => {'type': type, 'approbateur_id': '$approverId', 'motif': reason, 'preuve': 'code_local|$verifiedAt'};
}

/// Où en est la livraison d'un bon sur ce terminal.
enum RestoDeliveryState {
  /// Au moins une cible a confirmé (`accuse`) ou reçu les octets (`transmis`).
  delivered,

  /// Issue inconnue (`a_verifier`) : à vérifier sur place, jamais relancé.
  toCheck,

  /// Aucune cible n'a reçu le bon (échec certain) : à réimprimer en duplicata.
  failed,

  /// Pas encore tenté.
  pending,
}

/// Bon de production vu par la caisse : contenu immuable et état de sa livraison.
class RestoTicketView {
  const RestoTicketView({required this.ticket, required this.stationName, required this.orderNumber, this.table, required this.state, this.checkAttempt, this.checked = false});

  final RestoTicket ticket;
  final String stationName;
  final String orderNumber;
  final String? table;
  final RestoDeliveryState state;

  /// Tentative `a_verifier` encore sans vérification, ou null.
  final String? checkAttempt;

  /// Vérifié sur place (sorti ou non).
  final bool checked;
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
    this.stations = const {},
    this.routes = const {},
    this.lastTicketNumbers = const {},
    this.channels = const [],
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

  /// Postes de production publiés (`restaurant.poste`, R-3), actifs ou non, par uuid.
  final Map<String, RestoStation> stations;

  /// Poste effectif de chaque produit (`restaurant.routage.poste_effectif_uuid`) ; absent ou null : rien ne part.
  final Map<String, String?> routes;

  /// Dernier numéro du jour reçu par le serveur, par poste (`derniers_numeros.bons`) : jamais réutilisé.
  final Map<String, String> lastTicketNumbers;

  bool get tableService => profile == 'TABLE_SERVICE';

  /// Canaux publiés (`restaurant.canal`, profil Restaurant, R-4), actifs ou non, dans l'ordre de la boutique.
  final List<RestoChannel> channels;

  /// Profil Restaurant (`PRODUCTION`, R-4) : commandes par canal, règlements `full`, `items` et `shares`.
  bool get production => profile == 'PRODUCTION';

  /// Point de vente restaurant (Service de table ou Restaurant) : l'écran restaurant s'ouvre après le PIN.
  bool get restaurantProfile => tableService || production;

  RestoChannel? channel(String? code) => channels.where((c) => c.code == code).firstOrNull;

  /// Libellé de l'action d'envoi : « Envoyer » vers les postes, « Valider » quand l'envoi en production est éteint.
  String get sendLabel => settings.sendToProduction ? 'Envoyer' : 'Valider';

  RestoTable? table(String? uuid) => tables.where((t) => t.uuid == uuid).firstOrNull;
}

/// Commande vue par l'écran de salle : dernière version, et où en est sa remontée.
class RestoOrderView {
  const RestoOrderView({required this.order, required this.payable, this.paid = false, this.pendingVersions = 0, this.serverMessage, this.waiting = false, this.serverNumber, this.tickets = const [], this.ticketsToCheck = 0});

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

  /// Bons créés par le dernier fait (à livrer), vide sinon.
  final List<RestoTicket> tickets;

  /// Bons de la commande à vérifier sur place (livraison d'issue inconnue) ou jamais livrés.
  final int ticketsToCheck;
}

/// Canal de vente du profil Restaurant (`restaurant.canal`, RESTAURANT-1 §3.6) : sur place, à emporter, livraison…
class RestoChannel {
  const RestoChannel({
    required this.uuid,
    required this.code,
    required this.name,
    required this.kind,
    this.requiresTable = false,
    this.requiresReference = false,
    this.tracksDelivery = false,
    this.order = 0,
    this.active = true,
  });

  factory RestoChannel.fromJson(String uuid, Map m) => RestoChannel(
    uuid: uuid,
    code: m['code'] as String,
    name: m['nom'] as String,
    kind: m['type'] as String,
    requiresTable: m['exige_table'] == true,
    requiresReference: m['exige_reference'] == true,
    tracksDelivery: m['suivi_livraison'] == true,
    order: m['ordre'] as int? ?? 0,
    active: m['actif'] == true,
  );

  final String uuid;

  /// Code porté par la commande (`etat.canal`).
  final String code;
  final String name;

  /// `dine_in`, `takeaway`, `delivery`… (`restaurant_channels.kind`).
  final String kind;

  /// Table obligatoire ; sinon la commande n'a pas de table.
  final bool requiresTable;

  /// Référence externe obligatoire (plateforme de livraison…).
  final bool requiresReference;

  /// Suivi de livraison : la vente reste possible hors ligne, le suivi est restreint (`restaurant.livraison`).
  final bool tracksDelivery;
  final int order;
  final bool active;
}

/// Part d'un règlement `shares` (`commande.parts[]`) : son montant et les index des paiements de la vente qui la
/// composent.
class RestoShare {
  const RestoShare({required this.label, required this.amount, required this.payments});

  final String label;
  final int amount;
  final List<int> payments;

  Map<String, dynamic> toJson() => {'libelle': label, 'montant': amount, 'paiements': payments};
}

/// Journée du registre de ce terminal (`resto_registre_ouvre` / `resto_registre_clos`, RESTAURANT-1 §4.7).
class RestoRegisterView {
  const RestoRegisterView({
    required this.uuid,
    required this.businessDay,
    required this.openedAt,
    this.note,
    this.closed = false,
    this.closedAt,
    this.zLocalNumber,
    this.salesTotal = 0,
    this.serverState,
    this.serverMessage,
    this.waiting = false,
    this.serverZNumber,
  });

  final String uuid;
  final String businessDay;
  final DateTime openedAt;
  final String? note;

  /// Clôture enregistrée sur ce terminal (remontée ou non).
  final bool closed;
  final DateTime? closedAt;

  /// Z local de la clôture (`z_local.numero`).
  final int? zLocalNumber;

  /// Ventes de ce terminal depuis l'ouverture (`z_local.total_ventes` à la clôture).
  final int salesTotal;

  /// État serveur de la dernière opération du registre (`a_envoyer`, `recue`, `integree`, `a_arbitrer`…).
  final String? serverState;
  final String? serverMessage;

  /// Clôture en attente des règlements (`restaurant.attente_reglement`) : le serveur la rejoue seul.
  final bool waiting;

  /// Numéro du Z registre du serveur (`details.z_restaurant.numero`), une fois la clôture intégrée.
  final int? serverZNumber;

  bool get open => !closed;
}
