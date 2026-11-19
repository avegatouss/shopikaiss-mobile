import '../sync_v2/canonical_json.dart';
import '../offline/web_rules.dart';
import '../sync_v2/decimal6.dart';

/// Moteur partagé du restaurant hors connexion (plan PLAN-RESTAURANT-HORS-LIGNE.md, proposition RESTAURANT-1 de A) :
/// commandes, lignes, routage vers les postes, bons de production par différence, annulations, et planification de la
/// livraison des bons sans doublon. Pur et déterministe (horloge et uuid injectés) : chaque fait rend la version suivante
/// de la commande, au format `resto_commande` (RESTAURANT-1 validé, lots R-1 et R-2), que la caisse maîtresse enregistre
/// dans sa file v2. Envoi, annulation de ligne et bons : lot R-3 (postes, routage, `resto_bons_etats`).
///
/// Quantités en millionièmes (comme le contrat v2), montants en francs entiers.
class RestoRefusal implements Exception {
  const RestoRefusal(this.message);

  final String message;

  @override
  String toString() => message;
}

// ------------------------------------------------------------------ référentiel publié

/// Poste de production (`restaurant.poste`) : écran et/ou papier.
class RestoStation {
  const RestoStation({
    required this.uuid,
    required this.code,
    required this.name,
    this.screen = false,
    this.paper = true,
    this.active = true,
    this.order = 0,
    this.flow = 'preparation',
  });

  final String uuid;
  final String code;
  final String name;
  final bool screen;
  final bool paper;
  final bool active;
  final int order;

  /// `preparation` (new → in_progress → ready → served) ou `handover` (new → served).
  final String flow;

  /// Code du poste pour le numéro du jour : majuscules, lettres et chiffres seulement, 10 au plus (contrat §4.2).
  String get dayCode {
    final normalized = code.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');
    if (normalized.isEmpty) return 'POSTE';
    return normalized.length > 10 ? normalized.substring(0, 10) : normalized;
  }
}

/// Routage d'un produit (`restaurant.routage`) : `station`, `none` ou `inherit` (catégorie).
class RestoRouting {
  const RestoRouting({this.mode = 'inherit', this.stationUuid, this.categoryStationUuid});

  final String mode;
  final String? stationUuid;
  final String? categoryStationUuid;

  /// Poste qui reçoit l'article, ou null (rien ne part). Un poste inactif ou disparu renvoie au niveau suivant (règle
  /// d'ECAS retenue au plan §2 bis) ; le repli « premier poste actif » est un paramètre, éteint par défaut.
  RestoStation? resolve(Map<String, RestoStation> stations, {bool firstActiveFallback = false}) {
    RestoStation? usable(String? uuid) => uuid == null ? null : (stations[uuid]?.active == true ? stations[uuid] : null);
    if (mode == 'none') return null;
    final chosen = (mode == 'station' ? usable(stationUuid) : null) ?? usable(categoryStationUuid);
    if (chosen != null || !firstActiveFallback) return chosen;
    final active = stations.values.where((s) => s.active).toList()..sort((a, b) => a.order.compareTo(b.order));
    return active.firstOrNull;
  }
}

// ------------------------------------------------------------------ commande

enum RestoLineStatus { pending, sent, cancelled }

/// Ligne de commande (`ligne_commande`, RESTAURANT-1 §4.3) : produit, libellé, prix et coefficient figés à l'ajout.
class RestoLine {
  RestoLine({
    required this.uuid,
    required this.productUuid,
    this.packagingUuid,
    this.lotUuid,
    required String label,
    required this.quantity,
    this.coefficient = Decimal6.scale,
    required this.unitPrice,
    this.discount = 0,
    this.comment,
    this.stationUuid,
    this.parentLineUuid,
    this.free = false,
    this.status = RestoLineStatus.pending,
    this.sent = 0,
    this.settled = 0,
  }) : label = label.length > 160 ? label.substring(0, 160) : label;

  final String uuid;
  final String productUuid;
  final String? packagingUuid;
  final String? lotUuid;

  /// Libellé figé (160 caractères au plus, colonne `product_name` du serveur).
  final String label;

  /// Quantité active (millionièmes).
  int quantity;

  /// Coefficient du conditionnement (millionièmes), figé.
  final int coefficient;
  final int unitPrice;
  int discount;
  String? comment;

  /// Poste de la ligne, choisi au premier envoi (Service de table, règle du web) ; null = rien ne part.
  String? stationUuid;
  final String? parentLineUuid;
  bool free;
  RestoLineStatus status;

  /// Quantité nette annoncée aux postes (Σ ajouts − Σ annulations des bons).
  int sent;

  /// Quantité réglée.
  int settled;

  bool get active => status != RestoLineStatus.cancelled;
  int get gross => Decimal6.amount(unitPrice, quantity);
  int get lineDiscount => free ? gross : discount;
  int get total => gross - lineDiscount;
  /// Reste à annoncer : seule une ligne en attente part ; une ligne `sent` sans bon (sans poste, envoi éteint) est figée.
  int get toSend => status == RestoLineStatus.pending ? quantity - sent : 0;

  RestoLine copy() => RestoLine(
    uuid: uuid,
    productUuid: productUuid,
    packagingUuid: packagingUuid,
    lotUuid: lotUuid,
    label: label,
    quantity: quantity,
    coefficient: coefficient,
    unitPrice: unitPrice,
    discount: discount,
    comment: comment,
    stationUuid: stationUuid,
    parentLineUuid: parentLineUuid,
    free: free,
    status: status,
    sent: sent,
    settled: settled,
  );

  Map<String, dynamic> toJson() => {
    'ligne_uuid': uuid,
    'produit_uuid': productUuid,
    'conditionnement_uuid': packagingUuid,
    'lot_uuid': lotUuid,
    'libelle': label,
    'quantite': Decimal6.format(quantity),
    'coefficient': Decimal6.format(coefficient),
    'prix_unitaire': unitPrice,
    'remise': lineDiscount,
    'tarif': free ? 'free' : (discount > 0 ? 'manual_discount' : 'standard'),
    'statut': status.name,
    'poste_uuid': stationUuid,
    'commentaire': comment,
    'parent_ligne_uuid': parentLineUuid,
    'envoye': Decimal6.format(sent),
    'reglee': Decimal6.format(settled),
  };

  static RestoLine fromJson(Map m) => RestoLine(
    uuid: m['ligne_uuid'] as String,
    productUuid: m['produit_uuid'] as String,
    packagingUuid: m['conditionnement_uuid'] as String?,
    lotUuid: m['lot_uuid'] as String?,
    label: m['libelle'] as String,
    quantity: Decimal6.parse(m['quantite'] as String),
    coefficient: Decimal6.parse(m['coefficient'] as String),
    unitPrice: m['prix_unitaire'] as int,
    discount: m['tarif'] == 'free' ? 0 : m['remise'] as int,
    free: m['tarif'] == 'free',
    comment: m['commentaire'] as String?,
    stationUuid: m['poste_uuid'] as String?,
    parentLineUuid: m['parent_ligne_uuid'] as String?,
    status: RestoLineStatus.values.byName(m['statut'] as String),
    sent: Decimal6.parse(m['envoye'] as String),
    settled: Decimal6.parse(m['reglee'] as String),
  );
}

/// Étape du service (`ServiceStage` du web) : seule règle de passage, appliquée à chaque fait.
class RestoStage {
  RestoStage._();

  static const waiting = 'waiting';
  static const billPrinted = 'bill_printed';
  static const customerValidated = 'customer_validated';
  static const amended = 'amended';

  /// Contenu modifié : une commande déjà préfacturée ou validée par le client devient « modifiée ».
  static String? afterChange(String? current) => current == billPrinted || current == customerValidated ? amended : current;

  /// Préfacture : une commande validée ou modifiée garde son étape.
  static String? afterPrebill(String? current) => current == customerValidated || current == amended ? current : billPrinted;
}

/// TVA de la boutique pour les totaux de la commande (règle du web, `SaleCalculator`).
class RestoVat {
  const RestoVat({this.rate = '0.000000', this.included = true});

  final String rate;
  final bool included;
}

class RestoOrder {
  RestoOrder({
    required this.uuid,
    required this.localNumber,
    required this.businessDay,
    required this.profile,
    this.channel,
    this.tableUuid,
    this.menuUuid,
    this.covers,
    this.serverId,
    this.customerUuid,
    this.customerName,
    this.externalReference,
    this.comment,
    this.status = 'open',
    this.stage,
    this.version = 0,
    this.prebills = 0,
    this.globalDiscount = 0,
    List<RestoLine>? lines,
  }) : lines = lines ?? [];

  final String uuid;

  /// Numéro que la salle connaît : préfixe, date, `L` et 4 chiffres (contrat §4.2).
  final String localNumber;
  final String businessDay;

  /// `TABLE_SERVICE` ou `PRODUCTION`.
  final String profile;
  final String? channel;
  String? tableUuid;
  final String? menuUuid;
  int? covers;
  String? serverId;
  final String? customerUuid;
  final String? customerName;
  final String? externalReference;
  String? comment;

  /// `open`, `settled` ou `cancelled`.
  String status;

  /// Étape du service ([RestoStage]) ; null hors Service de table.
  String? stage;
  int version;
  int prebills;
  int globalDiscount;
  final List<RestoLine> lines;

  bool get isOpen => status == 'open';
  List<RestoLine> get activeLines => [for (final l in lines) if (l.active) l];

  RestoLine line(String uuid) => lines.where((l) => l.uuid == uuid).firstOrNull ?? (throw const RestoRefusal('Ligne introuvable dans la commande.'));

  RestoOrder copy() => RestoOrder(
    uuid: uuid,
    localNumber: localNumber,
    businessDay: businessDay,
    profile: profile,
    channel: channel,
    tableUuid: tableUuid,
    menuUuid: menuUuid,
    covers: covers,
    serverId: serverId,
    customerUuid: customerUuid,
    customerName: customerName,
    externalReference: externalReference,
    comment: comment,
    status: status,
    stage: stage,
    version: version,
    prebills: prebills,
    globalDiscount: globalDiscount,
    lines: [for (final l in lines) l.copy()],
  );

  /// Totaux par la règle du web (`CommandesCaisse::totaux`) : brut = Σ prix × quantité des lignes actives, remises =
  /// Σ remises de ligne + remise globale, à payer = total de la vente avec la TVA de la boutique.
  ({int gross, int discounts, int payable, int settled}) totals(RestoVat vat) {
    final active = activeLines;
    if (active.isEmpty) return (gross: 0, discounts: globalDiscount, payable: 0, settled: 0);
    final web = webTotals(
      lineBases: [for (final l in active) l.gross],
      lineDiscounts: [for (final l in active) l.lineDiscount],
      globalDiscount: globalDiscount,
      vatRate: vat.rate,
      vatIncluded: vat.included,
    );
    final gross = active.fold<int>(0, (sum, l) => sum + l.gross);
    final payable = web.payable;
    final quantity = active.fold<int>(0, (sum, l) => sum + l.quantity);
    final settledQuantity = active.fold<int>(0, (sum, l) => sum + (l.settled > l.quantity ? l.quantity : l.settled));
    // Réglé : part du total à payer au prorata des quantités réglées (non contrôlé par le serveur, affichage).
    final settled = quantity == 0 ? 0 : (settledQuantity >= quantity ? payable : (BigInt.from(payable) * BigInt.from(settledQuantity) ~/ BigInt.from(quantity)).toInt());
    return (gross: gross, discounts: active.fold<int>(globalDiscount, (sum, l) => sum + l.lineDiscount), payable: payable, settled: settled);
  }

  /// État complet de la commande APRÈS le fait (`etat_commande`, operation.json, lot R-2).
  Map<String, dynamic> state(RestoVat vat) {
    final t = totals(vat);
    return {
      'profil': profile,
      'numero_local': localNumber,
      'date_metier': businessDay,
      'canal': channel,
      'table_uuid': tableUuid,
      'menu_uuid': menuUuid,
      'couverts': covers,
      'serveur_id': serverId,
      'client_uuid': customerUuid,
      'client_nom': customerName,
      'reference_externe': externalReference,
      'commentaire': comment,
      'statut': status,
      'etape': stage,
      'prefactures': prebills,
      'remise_globale': globalDiscount,
      'lignes': [for (final l in lines) l.toJson()],
      'totaux': {'brut': t.gross, 'remises': t.discounts, 'a_payer': t.payable, 'regle': t.settled},
    };
  }

  /// Commande relue depuis l'état de sa dernière version (la file des opérations fait foi).
  static RestoOrder fromState(String uuid, int version, Map m) => RestoOrder(
    uuid: uuid,
    localNumber: m['numero_local'] as String,
    businessDay: m['date_metier'] as String,
    profile: m['profil'] as String,
    channel: m['canal'] as String?,
    tableUuid: m['table_uuid'] as String?,
    menuUuid: m['menu_uuid'] as String?,
    covers: m['couverts'] as int?,
    serverId: m['serveur_id'] as String?,
    customerUuid: m['client_uuid'] as String?,
    customerName: m['client_nom'] as String?,
    externalReference: m['reference_externe'] as String?,
    comment: m['commentaire'] as String?,
    status: m['statut'] as String,
    stage: m['etape'] as String?,
    version: version,
    prebills: m['prefactures'] as int,
    globalDiscount: m['remise_globale'] as int,
    lines: [for (final l in (m['lignes'] as List).cast<Map>()) RestoLine.fromJson(l)],
  );
}

/// Article à ajouter à une commande (prix, libellé et coefficient lus au catalogue au moment de l'ajout).
class RestoNewLine {
  const RestoNewLine({
    required this.productUuid,
    this.packagingUuid,
    required this.label,
    required this.quantity,
    this.coefficient = Decimal6.scale,
    required this.unitPrice,
    this.routing = const RestoRouting(),
    this.comment,
  });

  final String productUuid;
  final String? packagingUuid;
  final String label;
  final int quantity;
  final int coefficient;
  final int unitPrice;
  final RestoRouting routing;
  final String? comment;
}

// ------------------------------------------------------------------ bons

/// Ligne d'un bon : `add` (à préparer) ou `cancel` (à ne plus préparer).
class RestoTicketLine {
  const RestoTicketLine({required this.lineUuid, required this.label, required this.quantity, this.comment, required this.action});

  final String lineUuid;
  final String label;
  final int quantity;
  final String? comment;
  final String action;

  Map<String, dynamic> toJson() => {'ligne_uuid': lineUuid, 'libelle': label, 'quantite': Decimal6.format(quantity), 'commentaire': comment, 'action': action};
}

/// Bon de production : créé une fois par la caisse maîtresse, immuable, même uuid sur toutes les cibles.
class RestoTicket {
  /// Bon relu dans le fait d'une commande de la file (`fait.bons[]`).
  factory RestoTicket.fromJson(String orderUuid, Map m) => RestoTicket(
    uuid: m['bon_uuid'] as String,
    orderUuid: orderUuid,
    stationUuid: m['poste_uuid'] as String,
    number: m['numero'] as int,
    dayNumber: m['numero_jour'] as String,
    type: m['type'] as String,
    firstSend: m['premier_envoi'] as bool,
    createdAt: DateTime.parse(m['cree_le'] as String),
    lines: [
      for (final l in (m['lignes'] as List).cast<Map>())
        RestoTicketLine(lineUuid: l['ligne_uuid'] as String, label: l['libelle'] as String, quantity: Decimal6.parse(l['quantite'] as String), comment: l['commentaire'] as String?, action: l['action'] as String),
    ],
  );

  RestoTicket({
    required this.uuid,
    required this.orderUuid,
    required this.stationUuid,
    required this.number,
    required this.dayNumber,
    required this.type,
    required this.firstSend,
    required this.createdAt,
    required this.lines,
    this.reason,
  });

  final String uuid;
  final String orderUuid;
  final String stationUuid;

  /// Numéro du bon dans (commande, poste) : 1, 2, 3…
  final int number;

  /// Numéro du jour, celui que la cuisine appelle : `CUI-20261107-0001`.
  final String dayNumber;

  /// `envoi` ou `annulation`.
  final String type;
  final bool firstSend;
  final DateTime createdAt;
  final List<RestoTicketLine> lines;

  /// Motif d'une annulation (imprimé « ANNULÉ : motif »).
  final String? reason;

  /// Titre imprimé : premier envoi, « AJOUT » ensuite, « ANNULATION ».
  String get title => type == 'annulation' ? 'ANNULATION' : (firstSend ? 'BON' : 'AJOUT');

  Map<String, dynamic> _content() => {
    'bon_uuid': uuid,
    'poste_uuid': stationUuid,
    'numero': number,
    'numero_jour': dayNumber,
    'type': type,
    'premier_envoi': firstSend,
    'cree_le': '${createdAt.toUtc().toIso8601String().substring(0, 19)}Z',
    'lignes': [for (final l in lines) l.toJson()],
  };

  /// SHA-256 SK-JCS-1 du bon sans ce champ : prouve que le contenu est le même sur toutes les cibles.
  String get fingerprint => CanonicalJson.sha256Of(_content());

  Map<String, dynamic> toJson() => {..._content(), 'empreinte_contenu': fingerprint};

  /// Texte imprimé du bon (même contenu sur toutes les cibles ; [duplicate] : réimpression demandée par un opérateur).
  List<String> printLines({required String stationName, required String orderNumber, String? table, int columns = 32, bool duplicate = false}) {
    String two(int v) => v.toString().padLeft(2, '0');
    final local = createdAt.toLocal();
    return [
      if (duplicate) '*** DUPLICATA ***',
      '$title - $stationName',
      dayNumber,
      'Commande $orderNumber${number > 1 ? ' - bon $number' : ''}',
      if (table != null && table.isNotEmpty) 'Table $table',
      '${two(local.day)}/${two(local.month)} ${two(local.hour)}:${two(local.minute)}',
      '-' * columns,
      for (final l in lines) ...[
        '${l.action == 'cancel' ? '-' : ''}${Decimal6.label(l.quantity)} x ${l.label}',
        if (l.comment != null) '  > ${l.comment}',
      ],
      '-' * columns,
    ];
  }
}

/// Compteurs des bons, persistés par la caisse maîtresse : numéro par (commande, poste) et numéro du jour par poste.
class RestoCounters {
  RestoCounters([Map<String, int>? values]) : values = values ?? {};

  final Map<String, int> values;

  int next(String key) => values[key] = (values[key] ?? 0) + 1;
}

/// Fait d'une commande (forme `resto_commande` : version, action, fait, motif, état résultant), gardé pour la remontée.
class RestoEvent {
  const RestoEvent({
    required this.uuid,
    required this.version,
    required this.action,
    required this.fact,
    this.reason,
    required this.state,
    this.tickets = const [],
    this.authorizations = const [],
  });

  final String uuid;
  final int version;
  final String action;
  final Map<String, dynamic> fact;
  final String? reason;
  final Map<String, dynamic> state;
  final List<RestoTicket> tickets;

  /// Autorisations d'un approbateur (`autorisation_restaurant`), code vérifié sur la caisse.
  final List<Map<String, dynamic>> authorizations;
}

/// Résultat d'une action : nouvelle commande, fait à remonter, bons à livrer.
class RestoResult {
  const RestoResult(this.order, this.event, [this.tickets = const []]);

  final RestoOrder order;
  final RestoEvent event;
  final List<RestoTicket> tickets;
}

// ------------------------------------------------------------------ moteur

class RestoEngine {
  RestoEngine({
    required this.newUuid,
    required this.now,
    required this.stations,
    required this.counters,
    this.sendToStations = true,
    this.vat = const RestoVat(),
    this.cancellationReasonRequired = false,
  });

  final String Function() newUuid;
  final DateTime Function() now;

  /// Postes publiés, par uuid.
  final Map<String, RestoStation> stations;
  final RestoCounters counters;

  /// Paramètre d'envoi (`restaurant.reglages.envoi_production`) : éteint, « Envoyer » devient « Valider » : la commande
  /// est figée et aucun bon ne part.
  final bool sendToStations;

  /// TVA de la boutique, pour les totaux de l'état (`a_payer`).
  final RestoVat vat;

  /// `restaurant.reglages.motif_annulation_commande`.
  final bool cancellationReasonRequired;

  RestoResult _record(
    RestoOrder order,
    String action,
    Map<String, dynamic> fact, {
    String? reason,
    List<RestoTicket> tickets = const [],
    List<Map<String, dynamic>> authorizations = const [],
  }) {
    // R-4 : une remise de commande ne dépasse jamais le montant après remises de ligne (offert, déplacement, annulation).
    if (order.isOpen && order.activeLines.isNotEmpty && order.globalDiscount > orderDiscountBase(order)) {
      throw RestoRefusal('La remise de la commande (${order.globalDiscount} F) dépasserait son montant (${orderDiscountBase(order)} F) : réduisez-la d’abord.');
    }
    order.version++;
    return RestoResult(
      order,
      RestoEvent(
        uuid: newUuid(),
        version: order.version,
        action: action,
        fact: fact,
        reason: reason,
        state: order.state(vat),
        tickets: tickets,
        authorizations: authorizations,
      ),
      tickets,
    );
  }

  void _requireOpen(RestoOrder order) {
    if (!order.isOpen) throw const RestoRefusal('Cette commande est close : elle ne se modifie plus.');
  }

  /// Numéro local d'une commande : préfixe normalisé (majuscules, A-Z et 0-9, 23 caractères au plus), date métier, `L` et
  /// 4 chiffres (6 au plus) ; compté par jour sur la caisse maîtresse.
  static String localNumber(String prefix, String businessDay, int sequence) {
    var clean = prefix.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');
    if (clean.isEmpty) clean = 'CMD';
    if (clean.length > 23) clean = clean.substring(0, 23);
    return '$clean-${businessDay.replaceAll('-', '')}-L${sequence.toString().padLeft(4, '0')}';
  }

  /// Rang d'un numéro local (`…-L0012` → 12) et sa date (`AAAAMMJJ`), ou null.
  static (String, int)? parseLocalNumber(String? number) {
    final m = RegExp(r'-([0-9]{8})-L([0-9]{4,6})$').firstMatch(number ?? '');
    return m == null ? null : (m.group(1)!, int.parse(m.group(2)!));
  }

  /// Ouverture : commande vide, en attente (Service de table : table obligatoire). Profil Restaurant (R-4) : canal
  /// obligatoire, table et référence selon le canal (vérifiés par l'appelant), étape initiale null.
  RestoResult open({
    required String prefix,
    required String businessDay,
    required String profile,
    String? tableUuid,
    int? covers,
    String? serverId,
    String? menuUuid,
    String? channel,
    String? externalReference,
    String? customerName,
  }) {
    if (profile == 'TABLE_SERVICE' && tableUuid == null) throw const RestoRefusal('Choisissez la table de la commande.');
    if (profile == 'PRODUCTION' && (channel == null || channel.isEmpty)) throw const RestoRefusal('Choisissez le canal de la commande.');
    if ((externalReference?.length ?? 0) > 80) throw const RestoRefusal('Référence trop longue (80 caractères au plus).');
    if ((customerName?.length ?? 0) > 160) throw const RestoRefusal('Nom du client trop long (160 caractères au plus).');
    if (covers != null && (covers < 1 || covers > 500)) throw const RestoRefusal('Nombre de couverts invalide (1 à 500).');
    final day = businessDay.replaceAll('-', '');
    final sequence = counters.next('commande|$day');
    if (sequence > 999999) throw const RestoRefusal('Nombre maximal de commandes du jour atteint.');
    final order = RestoOrder(
      uuid: newUuid(),
      localNumber: localNumber(prefix, businessDay, sequence),
      businessDay: businessDay,
      profile: profile,
      tableUuid: tableUuid,
      menuUuid: menuUuid,
      covers: covers,
      serverId: serverId,
      channel: profile == 'PRODUCTION' ? channel : null,
      externalReference: _clean(externalReference),
      customerName: _clean(customerName),
      // Règle ServiceStage du web : `waiting` au Service de table, null au Restaurant (la préaddition la passe
      // `bill_printed`).
      stage: profile == 'TABLE_SERVICE' ? RestoStage.waiting : null,
    );
    return _record(order, 'ouverture', const {});
  }

  /// Une validation de l'opérateur = une version `lignes` : articles ajoutés, quantités ou commentaires changés, articles
  /// retirés. Seules les lignes jamais envoyées se modifient ou se retirent ; une ligne envoyée s'annule ([cancelLine]).
  RestoResult editLines(
    RestoOrder order, {
    List<RestoNewLine> added = const [],
    Map<String, int> quantities = const {},
    Map<String, String?> comments = const {},
    Set<String> removed = const {},
    bool firstActiveFallback = false,
  }) {
    _requireOpen(order);
    final next = order.copy();
    final addedUuids = <String>[], changed = <String>[], removedUuids = <String>[];
    for (final item in added) {
      if (item.quantity <= 0) throw const RestoRefusal('Quantité invalide.');
      if (item.unitPrice < 0) throw const RestoRefusal('Prix invalide.');
      final line = RestoLine(
        uuid: newUuid(),
        productUuid: item.productUuid,
        packagingUuid: item.packagingUuid,
        label: item.label,
        quantity: item.quantity,
        coefficient: item.coefficient,
        unitPrice: item.unitPrice,
        comment: _clean(item.comment),
        stationUuid: item.routing.resolve(stations, firstActiveFallback: firstActiveFallback)?.uuid,
      );
      next.lines.add(line);
      addedUuids.add(line.uuid);
    }
    for (final uuid in {...quantities.keys, ...comments.keys}) {
      if (removed.contains(uuid)) continue;
      final line = next.line(uuid);
      if (!line.active) throw const RestoRefusal('Cette ligne est annulée.');
      var touched = false;
      if (quantities.containsKey(uuid) && quantities[uuid] != line.quantity) {
        final quantity = quantities[uuid]!;
        if (quantity <= 0) throw const RestoRefusal('Quantité invalide : retirez l’article.');
        if (quantity < line.settled) throw RestoRefusal('« ${line.label} » est déjà en partie réglé : sa quantité ne descend plus sous le réglé.');
        // Une ligne envoyée ne change plus par `lignes` (contrat §4.3) : on ajoute l'article à nouveau, ou on annule avec
        // un motif.
        if (line.status == RestoLineStatus.sent) {
          throw RestoRefusal(quantity < line.quantity
              ? '« ${line.label} » est déjà envoyé : annulez la quantité avec un motif.'
              : '« ${line.label} » est déjà envoyé : ajoutez l’article à nouveau.');
        }
        line.quantity = quantity;
        touched = true;
      }
      if (comments.containsKey(uuid) && _clean(comments[uuid]) != line.comment) {
        if (line.status != RestoLineStatus.pending) throw RestoRefusal('« ${line.label} » est déjà envoyé : son commentaire ne change plus.');
        line.comment = _clean(comments[uuid]);
        touched = true;
      }
      if (touched) changed.add(uuid);
    }
    for (final uuid in removed) {
      final line = next.line(uuid);
      if (!line.active) continue;
      if (line.sent > 0 || line.status == RestoLineStatus.sent) throw RestoRefusal('« ${line.label} » est déjà envoyé : annulez-le avec un motif.');
      if (line.settled > 0) throw RestoRefusal('« ${line.label} » est déjà réglé : il ne se retire plus.');
      line.status = RestoLineStatus.cancelled;
      removedUuids.add(uuid);
    }
    if (addedUuids.isEmpty && changed.isEmpty && removedUuids.isEmpty) throw const RestoRefusal('Aucune modification à enregistrer.');
    if (next.lines.length > 200) throw const RestoRefusal('Une commande compte 200 lignes au plus.');
    next.stage = RestoStage.afterChange(next.stage);
    return _record(next, 'lignes', {'ajoutees': addedUuids, 'modifiees': changed, 'retirees': removedUuids},
        reason: removedUuids.isEmpty ? null : 'Retiré de la commande');
  }

  static String? _clean(String? comment) {
    final text = comment?.trim() ?? '';
    if (text.isEmpty) return null;
    return text.length > 500 ? text.substring(0, 500) : text;
  }

  /// Ajout d'un article : poste figé à l'ajout (règle du Restaurant), prix et libellé figés.
  RestoResult addLine(
    RestoOrder order, {
    required String productUuid,
    String? packagingUuid,
    required String label,
    required int quantity,
    required int unitPrice,
    required RestoRouting routing,
    String? comment,
    bool firstActiveFallback = false,
  }) => editLines(
    order,
    added: [RestoNewLine(productUuid: productUuid, packagingUuid: packagingUuid, label: label, quantity: quantity, unitPrice: unitPrice, routing: routing, comment: comment)],
    firstActiveFallback: firstActiveFallback,
  );

  /// Changement de quantité d'une ligne pas encore envoyée. Une ligne envoyée ne baisse que par [cancelLine].
  RestoResult changeQuantity(RestoOrder order, String lineUuid, int quantity) =>
      quantity <= 0 ? removeLine(order, lineUuid) : editLines(order, quantities: {lineUuid: quantity});

  /// Retrait d'une ligne jamais envoyée.
  RestoResult removeLine(RestoOrder order, String lineUuid) => editLines(order, removed: {lineUuid});

  RestoTicket _ticket(RestoOrder order, String stationUuid, String type, List<RestoTicketLine> lines, {String? reason}) {
    final station = stations[stationUuid]!;
    final number = counters.next('bon|${order.uuid}|$stationUuid');
    final day = order.businessDay.replaceAll('-', '');
    final daily = counters.next('jour|${station.uuid}|$day');
    return RestoTicket(
      uuid: newUuid(),
      orderUuid: order.uuid,
      stationUuid: stationUuid,
      number: number,
      dayNumber: '${station.dayCode}-$day-${daily.toString().padLeft(4, '0')}',
      type: type,
      firstSend: type == 'envoi' && number == 1,
      createdAt: now(),
      lines: lines,
      reason: reason,
    );
  }

  /// Envoi par différence (lot R-3) : chaque ligne en attente annonce à son poste quantité − envoyé net, un bon par poste
  /// et par envoi. Le poste d'une ligne qui n'en a pas encore est choisi à l'envoi par [route] (`poste_effectif_uuid`,
  /// règle du Service de table) ; un poste inconnu ou inactif = rien ne part. Les articles sans poste, et tous les
  /// articles quand l'envoi en production est éteint, sont figés (`sent`) sans bon : « Valider ».
  RestoResult send(RestoOrder order, {String? Function(String productUuid)? route}) {
    _requireOpen(order);
    final next = order.copy();
    final waiting = [for (final l in next.lines) if (l.toSend > 0) l];
    if (waiting.isEmpty) throw const RestoRefusal('Rien de nouveau à envoyer.');
    final byStation = <String, List<RestoLine>>{};
    if (sendToStations) {
      for (final l in waiting) {
        if (l.stationUuid == null && route != null) {
          final chosen = route(l.productUuid);
          if (chosen != null && stations[chosen]?.active == true) l.stationUuid = chosen;
        }
        if (l.stationUuid != null && stations.containsKey(l.stationUuid)) (byStation[l.stationUuid!] ??= []).add(l);
      }
    }
    final ordered = byStation.entries.toList()
      ..sort((a, b) {
        final sa = stations[a.key]!, sb = stations[b.key]!;
        return sa.order != sb.order ? sa.order.compareTo(sb.order) : sa.code.compareTo(sb.code);
      });
    final tickets = [
      for (final entry in ordered)
        _ticket(next, entry.key, 'envoi', [
          for (final l in entry.value) RestoTicketLine(lineUuid: l.uuid, label: l.label, quantity: l.toSend, comment: l.comment, action: 'add'),
        ]),
    ];
    final announced = {for (final e in byStation.values) for (final l in e) l.uuid};
    for (final l in waiting) {
      // `envoye` = Σ des bons : une ligne figée sans bon garde son envoyé net.
      if (announced.contains(l.uuid)) l.sent = l.quantity;
      l.status = RestoLineStatus.sent;
    }
    return _record(next, 'envoi', {'bons': [for (final t in tickets) t.toJson()]}, tickets: tickets);
  }

  /// « Valider » (action `validation`, R-4) quand l'envoi en production est éteint : les lignes en attente sont figées
  /// (`sent`) sans aucun bon, comme `OrderService::send` du web. L'envoyé net ne change pas.
  RestoResult validate(RestoOrder order) {
    _requireOpen(order);
    final next = order.copy();
    final waiting = [for (final l in next.lines) if (l.toSend > 0) l];
    if (waiting.isEmpty) throw const RestoRefusal('Rien de nouveau à valider.');
    if (waiting.length > 100) throw const RestoRefusal('Validez au plus 100 articles à la fois.');
    for (final l in waiting) {
      l.status = RestoLineStatus.sent;
    }
    return _record(next, 'validation', {'lignes': [for (final l in waiting) l.uuid]});
  }

  /// Annulation d'une quantité envoyée (lot R-3) : seulement sur une ligne `sent`, motif d'au moins 3 caractères ; droit
  /// `resto_modifier_envoye` ou autorisation d'un approbateur, vérifiés par l'appelant et joints en [authorizations]. Bon
  /// d'ANNULATION pour ce qui part de l'envoyé net (envoyé − quantité restante), aucun si la ligne n'a jamais été annoncée.
  RestoResult cancelLine(RestoOrder order, String lineUuid, int quantity, String reason, {List<Map<String, dynamic>> authorizations = const []}) {
    _requireOpen(order);
    final motive = reason.trim();
    if (motive.length < 3) throw const RestoRefusal('Indiquez le motif de l’annulation (3 caractères au moins).');
    if (motive.length > 500) throw const RestoRefusal('Motif trop long (500 caractères au plus).');
    final next = order.copy();
    final line = next.line(lineUuid);
    if (!line.active) throw const RestoRefusal('Cette ligne est déjà annulée.');
    if (line.status != RestoLineStatus.sent) throw const RestoRefusal('Article pas encore envoyé : retirez-le ou changez sa quantité.');
    if (quantity <= 0 || quantity > line.quantity) throw const RestoRefusal('Quantité à annuler invalide.');
    final remaining = line.quantity - quantity;
    if (remaining < line.settled) throw const RestoRefusal('La partie réglée d’un article ne s’annule pas.');
    final announced = line.sent > remaining ? line.sent - remaining : 0;
    final tickets = <RestoTicket>[];
    if (announced > 0) {
      if (line.stationUuid == null || !stations.containsKey(line.stationUuid)) {
        throw const RestoRefusal('Poste de cet article inconnu sur ce terminal : synchronisez avant d’annuler.');
      }
      tickets.add(_ticket(next, line.stationUuid!, 'annulation', [
        RestoTicketLine(lineUuid: line.uuid, label: line.label, quantity: announced, comment: _cancelComment(motive), action: 'cancel'),
      ], reason: motive));
    }
    // Lot R-4 (RemisesCaisse::remiseApresReduction) : une réduction garde la remise proportionnelle (arrondie vers le bas,
    // au plus le brut) ; un offert reste offert en entier. Une ligne annulée en entier garde sa quantité et sa remise
    // (le serveur ne passe que son statut à `cancelled`).
    if (remaining > 0) {
      if (!line.free && line.discount > 0) {
        final part = (BigInt.from(line.discount) * BigInt.from(remaining) ~/ BigInt.from(line.quantity)).toInt();
        final gross = Decimal6.amount(line.unitPrice, remaining);
        line.discount = part > gross ? gross : part;
      }
      line.quantity = remaining;
    }
    line.sent -= announced;
    if (remaining == 0) line.status = RestoLineStatus.cancelled;
    next.stage = RestoStage.afterChange(next.stage);
    return _record(next, 'annulation_ligne', {'ligne_uuid': lineUuid, 'quantite': Decimal6.format(quantity), 'bons': [for (final t in tickets) t.toJson()]},
        reason: motive, tickets: tickets, authorizations: authorizations);
  }

  static String _cancelComment(String motive) {
    final text = 'ANNULÉ : $motive';
    return text.length > 500 ? text.substring(0, 500) : text;
  }

  /// Annulation de la commande : motif exigé si la boutique le demande ou si des articles sont annoncés (3 caractères au
  /// moins) ; un bon d'ANNULATION par poste couvrant l'envoyé net de chaque article annoncé (lot R-3). Droit ou
  /// autorisation vérifiés par l'appelant, joints en [authorizations].
  RestoResult cancelOrder(RestoOrder order, String? reason, {List<Map<String, dynamic>> authorizations = const []}) {
    _requireOpen(order);
    final motive = reason?.trim() ?? '';
    if (motive.length > 500) throw const RestoRefusal('Motif trop long (500 caractères au plus).');
    final next = order.copy();
    final announced = <String, List<RestoLine>>{};
    for (final l in next.activeLines) {
      if (l.sent <= 0) continue;
      if (l.stationUuid == null || !stations.containsKey(l.stationUuid)) {
        throw RestoRefusal('Poste de « ${l.label} » inconnu sur ce terminal : synchronisez avant d’annuler.');
      }
      (announced[l.stationUuid!] ??= []).add(l);
    }
    if (announced.isNotEmpty && motive.length < 3) throw const RestoRefusal('Des articles sont déjà envoyés : indiquez le motif de l’annulation (3 caractères au moins).');
    if (cancellationReasonRequired && motive.isEmpty) throw const RestoRefusal('Indiquez le motif de l’annulation de la commande.');
    // Profil Restaurant (R-4, OrderModificationService::cancelOrder) : motif de 3 caractères toujours exigé.
    if (order.profile == 'PRODUCTION' && motive.length < 3) throw const RestoRefusal('Indiquez le motif de l’annulation (3 caractères au moins).');
    if (next.activeLines.any((l) => l.settled > 0)) throw const RestoRefusal('Des articles sont déjà réglés : la commande ne s’annule plus.');
    final ordered = announced.entries.toList()..sort((a, b) => stations[a.key]!.order.compareTo(stations[b.key]!.order));
    final tickets = [
      for (final entry in ordered)
        _ticket(next, entry.key, 'annulation', [
          for (final l in entry.value) RestoTicketLine(lineUuid: l.uuid, label: l.label, quantity: l.sent, comment: _cancelComment(motive), action: 'cancel'),
        ], reason: motive),
    ];
    for (final l in next.activeLines) {
      l
        ..sent = 0
        ..status = RestoLineStatus.cancelled;
    }
    next.status = 'cancelled';
    return _record(next, 'annulation', {'bons': [for (final t in tickets) t.toJson()]},
        reason: motive.isEmpty ? null : motive, tickets: tickets, authorizations: authorizations);
  }

  /// Articles annoncés aux postes (envoyé net > 0) : leur annulation exige le droit ou une autorisation.
  static bool hasAnnounced(RestoOrder order) => order.activeLines.any((l) => l.sent > 0);

  /// Préfacture : compteur d'impressions et étape (rien n'est imprimé par le serveur).
  RestoResult prebill(RestoOrder order) {
    _requireOpen(order);
    if (order.activeLines.isEmpty) throw const RestoRefusal('Commande vide : rien à préfacturer.');
    final next = order.copy()
      ..prebills += 1
      ..stage = RestoStage.afterPrebill(order.stage);
    return _record(next, 'prefacture', {'numero_local': next.localNumber});
  }

  RestoResult transfer(RestoOrder order, String tableUuid) {
    _requireOpen(order);
    final from = order.tableUuid;
    if (from == null) throw const RestoRefusal('Cette commande n’est pas à une table.');
    if (from == tableUuid) throw const RestoRefusal('La commande est déjà à cette table.');
    final next = order.copy()..tableUuid = tableUuid;
    return _record(next, 'transfert_table', {'table_uuid_source': from, 'table_uuid_cible': tableUuid});
  }

  /// Couverts et serveur (lot R-4).
  RestoResult coversAndServer(RestoOrder order, {int? covers, String? serverId}) {
    _requireOpen(order);
    if (covers != null && (covers < 1 || covers > 500)) throw const RestoRefusal('Nombre de couverts invalide (1 à 500).');
    final next = order.copy()
      ..covers = covers
      ..serverId = serverId;
    return _record(next, 'couverts_serveur', {'couverts': covers, 'serveur_id': serverId});
  }

  // ---------------------------------------------------------------- gestes sur une commande (lot R-4)

  static String _motive(String? reason, String gesture) {
    final motive = reason?.trim() ?? '';
    if (motive.length < 3) throw RestoRefusal('Indiquez le motif $gesture (3 caractères au moins).');
    if (motive.length > 500) throw const RestoRefusal('Motif trop long (500 caractères au plus).');
    return motive;
  }

  /// Ligne dont le prix peut encore changer : active, rien de réglé (RemisesCaisse::ligne).
  static RestoLine _priceable(RestoOrder order, String lineUuid) {
    final line = order.line(lineUuid);
    if (!line.active) throw const RestoRefusal('Cet article est annulé.');
    if (line.settled > 0) throw RestoRefusal('« ${line.label} » est déjà en partie réglé : son prix ne change plus.');
    return line;
  }

  /// Montant d'une remise de ligne saisie : francs, ou pourcentage du brut arrondi vers le bas (RemisesCaisse::remiserLigne).
  static int lineDiscountOf(RestoLine line, {required bool percent, required int value}) =>
      percent ? (BigInt.from(line.gross) * BigInt.from(value) ~/ BigInt.from(100)).toInt() : value;

  /// Pourcentage d'une remise sur sa base, arrondi au supérieur (plafond de l'assistant, jamais contourné par l'arrondi).
  static int percentOf(int discount, int base) => base <= 0 ? 100 : (discount * 100 + base - 1) ~/ base;

  /// Base de la remise de commande : Σ (brut − remise de ligne) des lignes actives.
  static int orderDiscountBase(RestoOrder order) => order.activeLines.fold<int>(0, (sum, l) => sum + l.total);

  /// Plafond de la remise de commande : [maxPercent] % de [orderDiscountBase], arrondi vers le bas.
  static int orderDiscountCeiling(RestoOrder order, int maxPercent) => orderDiscountBase(order) * maxPercent ~/ 100;

  /// Offert (R-4) : remise = brut de la ligne, quantité inchangée ; droit `resto_offrir` ou autorisation vérifiés par
  /// l'appelant et joints en [authorizations] ; motif de 3 caractères au moins dans les deux cas.
  RestoResult offer(RestoOrder order, String lineUuid, String reason, {List<Map<String, dynamic>> authorizations = const []}) {
    _requireOpen(order);
    final motive = _motive(reason, 'de l’offert');
    final next = order.copy();
    final line = _priceable(next, lineUuid);
    if (line.free) throw RestoRefusal('« ${line.label} » est déjà offert.');
    line
      ..free = true
      ..discount = 0;
    next.stage = RestoStage.afterChange(next.stage);
    return _record(next, 'offert', {'ligne_uuid': lineUuid}, reason: motive, authorizations: authorizations);
  }

  /// Remise de ligne (R-4) : en francs ou en pourcentage (1 à 100, arrondi vers le bas) du brut, de 1 F au brut, jamais
  /// sur un article offert ; quantité inchangée. Droit `remise` ou autorisation, motif dans les deux cas.
  RestoResult discountLine(RestoOrder order, String lineUuid, {required bool percent, required int value, required String reason, List<Map<String, dynamic>> authorizations = const []}) {
    _requireOpen(order);
    final motive = _motive(reason, 'de la remise');
    final next = order.copy();
    final line = _priceable(next, lineUuid);
    if (line.free) throw RestoRefusal('« ${line.label} » est offert : il ne reçoit pas de remise.');
    if (value < 1 || (percent && value > 100)) throw const RestoRefusal('Remise invalide.');
    final amount = lineDiscountOf(line, percent: percent, value: value);
    if (amount < 1 || amount > line.gross) throw RestoRefusal('La remise doit être comprise entre 1 F et le montant de la ligne (${line.gross} F).');
    line.discount = amount;
    next.stage = RestoStage.afterChange(next.stage);
    return _record(next, 'remise_ligne', {'ligne_uuid': lineUuid, 'saisie': {'type': percent ? 'pourcentage' : 'montant', 'valeur': value}},
        reason: motive, authorizations: authorizations);
  }

  /// Remise de commande (R-4, action `remise`) : en francs, plafonnée à [maxPercent] % du montant après remises de ligne,
  /// impossible une fois un article réglé ; 0 la retire (droit REMISE, sans motif). Motif exigé pour une remise > 0.
  RestoResult discountOrder(RestoOrder order, int amount, {String? reason, int maxPercent = 100, List<Map<String, dynamic>> authorizations = const []}) {
    _requireOpen(order);
    if (amount < 0) throw const RestoRefusal('Remise invalide.');
    if (order.activeLines.any((l) => l.settled > 0)) throw const RestoRefusal('Cette commande a déjà un règlement : la remise de commande n’est plus possible.');
    if (amount == order.globalDiscount) {
      throw RestoRefusal(amount == 0 ? 'Cette commande n’a pas de remise à retirer.' : 'La remise de la commande est déjà de $amount F.');
    }
    final ceiling = orderDiscountCeiling(order, maxPercent);
    if (amount > ceiling) throw RestoRefusal('La remise de commande est plafonnée à $ceiling F.');
    final motive = amount > 0 ? _motive(reason, 'de la remise') : (reason?.trim() ?? '');
    if (motive.length > 500) throw const RestoRefusal('Motif trop long (500 caractères au plus).');
    final next = order.copy()..globalDiscount = amount;
    next.stage = RestoStage.afterChange(next.stage);
    return _record(next, 'remise', {'montant': amount}, reason: motive.isEmpty ? null : motive, authorizations: amount > 0 ? authorizations : const []);
  }

  /// Validation de la préfacture par le client (Service de table seulement) : étape `customer_validated`.
  RestoResult validateCustomer(RestoOrder order) {
    _requireOpen(order);
    if (order.profile != 'TABLE_SERVICE') throw const RestoRefusal('La validation client est propre au Service de table.');
    if (order.prebills == 0) throw const RestoRefusal('Imprimez d’abord la préfacture : le client la valide.');
    if (order.stage == RestoStage.customerValidated) throw const RestoRefusal('Le client a déjà validé cette commande.');
    final next = order.copy()..stage = RestoStage.customerValidated;
    return _record(next, 'validation_client', const {});
  }

  /// Contrôles communs du déplacement et de la fusion (DeplacementsCaisse) : deux commandes ouvertes distinctes, même
  /// profil, même canal au Restaurant.
  static void _checkPair(RestoOrder source, RestoOrder target) {
    if (source.uuid == target.uuid) throw const RestoRefusal('Choisissez une autre commande de destination.');
    if (!target.isOpen) throw const RestoRefusal('La commande de destination est fermée.');
    if (source.profile != target.profile) throw const RestoRefusal('Les deux commandes ne sont pas du même profil.');
    if (source.profile == 'PRODUCTION' && source.channel != target.channel) throw const RestoRefusal('Les articles ne passent qu’entre commandes du même canal de vente.');
  }

  /// Lignes déplaçables : ni annulées, ni réglées ; un offert lié suit son article acheté, dans les deux sens.
  static void _checkMovable(RestoOrder source, Set<String> moved) {
    for (final uuid in moved) {
      final line = source.line(uuid);
      if (!line.active) throw RestoRefusal('« ${line.label} » est annulé : il ne se déplace pas.');
      if (line.settled > 0) throw RestoRefusal('« ${line.label} » est déjà en partie réglé : il ne change plus de commande.');
      if (line.parentLineUuid != null && !moved.contains(line.parentLineUuid)) {
        throw RestoRefusal('L’article offert « ${line.label} » suit l’article acheté : déplacez l’article acheté.');
      }
    }
    for (final line in source.activeLines) {
      if (line.parentLineUuid != null && moved.contains(line.parentLineUuid) && !moved.contains(line.uuid)) {
        throw RestoRefusal('L’article offert « ${line.label} » suit l’article acheté : déplacez-le avec lui.');
      }
    }
  }

  /// Déplacement de lignes (R-4, Q9) : une seule opération, sur la SOURCE, qui cite la cible et sa version courante
  /// (`version_cible`). La cible ne consomme pas de version : sa version suivante porte les lignes reçues ([receive]).
  RestoResult moveLines(RestoOrder source, RestoOrder target, Set<String> lineUuids) {
    _requireOpen(source);
    _checkPair(source, target);
    if (lineUuids.isEmpty) throw const RestoRefusal('Choisissez au moins un article à déplacer.');
    if (lineUuids.length > 100) throw const RestoRefusal('Déplacez 100 articles au plus à la fois.');
    _checkMovable(source, lineUuids);
    if (target.lines.length + lineUuids.length > 200) throw const RestoRefusal('La commande de destination compterait plus de 200 lignes.');
    final next = source.copy()..lines.removeWhere((l) => lineUuids.contains(l.uuid));
    next.stage = RestoStage.afterChange(next.stage);
    final cited = [for (final l in source.lines) if (lineUuids.contains(l.uuid)) l.uuid];
    return _record(next, 'deplacement_lignes', {'vers_commande_uuid': target.uuid, 'version_cible': target.version, 'lignes': cited});
  }

  /// Fusion (R-4, Q9) : toutes les lignes actives passent à la cible, la source est annulée (son état ne porte plus que
  /// ses lignes annulées ; sa remise de commande s'ajoute à la cible). Refusée si la source a un règlement, ou si sa
  /// remise irait sur une cible déjà en partie réglée.
  RestoResult merge(RestoOrder source, RestoOrder target, {String? reason}) {
    _requireOpen(source);
    _checkPair(source, target);
    if (source.activeLines.any((l) => l.settled > 0)) throw RestoRefusal('La commande ${source.localNumber} a déjà un règlement : encaissez-la séparément.');
    if (source.globalDiscount > 0 && target.activeLines.any((l) => l.settled > 0)) {
      throw const RestoRefusal('La commande de destination a déjà un règlement : la remise de cette commande ne peut plus s’y ajouter.');
    }
    final moved = {for (final l in source.activeLines) l.uuid};
    _checkMovable(source, moved);
    if (target.lines.length + moved.length > 200) throw const RestoRefusal('La commande de destination compterait plus de 200 lignes.');
    final motive = reason?.trim() ?? '';
    if (motive.length > 500) throw const RestoRefusal('Motif trop long (500 caractères au plus).');
    final next = source.copy()
      ..lines.removeWhere((l) => moved.contains(l.uuid))
      ..status = 'cancelled';
    // `merged_into` ne change pas l'étape (ServiceStage::next).
    return _record(next, 'fusion', {'vers_commande_uuid': target.uuid, 'version_cible': target.version}, reason: motive.isEmpty ? null : motive);
  }

  /// Cible après réception d'un déplacement ou d'une fusion (DeplacementsCaisse::deplacer), SANS nouvelle version : lignes
  /// reçues telles qu'elles étaient dans [sourceBefore] (état de la source juste avant le geste), étape « modifiée »
  /// après une préfacture ; fusion : couverts additionnés (500 au plus, null si aucun), remises de commande additionnées,
  /// client, nom et commentaire de la source repris quand la cible n'en a pas.
  static RestoOrder receive(RestoOrder target, RestoOrder sourceBefore, String action, Map fact) {
    final merge = action == 'fusion';
    final moved = merge ? {for (final l in sourceBefore.activeLines) l.uuid} : {...(fact['lignes'] as List).cast<String>()};
    bool empty(String? v) => v == null || v.isEmpty;
    final covers = (target.covers ?? 0) + (sourceBefore.covers ?? 0);
    return RestoOrder(
      uuid: target.uuid,
      localNumber: target.localNumber,
      businessDay: target.businessDay,
      profile: target.profile,
      channel: target.channel,
      tableUuid: target.tableUuid,
      menuUuid: target.menuUuid,
      covers: merge ? (covers > 0 ? (covers > 500 ? 500 : covers) : null) : target.covers,
      serverId: target.serverId,
      customerUuid: merge && empty(target.customerUuid) && !empty(sourceBefore.customerUuid) ? sourceBefore.customerUuid : target.customerUuid,
      customerName: merge && empty(target.customerName) && !empty(sourceBefore.customerName) ? sourceBefore.customerName : target.customerName,
      externalReference: target.externalReference,
      comment: merge && empty(target.comment) && !empty(sourceBefore.comment) ? sourceBefore.comment : target.comment,
      status: target.status,
      stage: RestoStage.afterChange(target.stage),
      version: target.version,
      prebills: target.prebills,
      globalDiscount: merge ? target.globalDiscount + sourceBefore.globalDiscount : target.globalDiscount,
      lines: [
        for (final l in target.lines) l.copy(),
        for (final l in sourceBefore.lines)
          if (moved.contains(l.uuid)) l.copy(),
      ],
    );
  }

  /// Clôture après le règlement complet (`full`) par la vente v2 qui le précède dans la file : toutes les lignes actives
  /// réglées, commande soldée.
  RestoResult close(RestoOrder order) {
    _requireOpen(order);
    if (order.activeLines.isEmpty) throw const RestoRefusal('Commande vide : annulez-la plutôt que de la clôturer.');
    final next = order.copy();
    for (final l in next.activeLines) {
      l.settled = l.quantity;
    }
    next.status = 'settled';
    return _record(next, 'cloture', const {});
  }
}

// ------------------------------------------------------------------ livraison sans doublon

/// Cibles d'un bon, dans l'ordre de secours : écran du poste, imprimante du poste, imprimante de la caisse.
enum RestoTarget {
  ecranPoste('ecran_poste'),
  imprimantePoste('imprimante_poste'),
  imprimanteCaisse('imprimante_caisse');

  const RestoTarget(this.code);

  /// Valeur du contrat (`evenement_bon.cible`).
  final String code;
}

/// Issue d'une tentative : `accuse` (l'afficheur a confirmé CE bon), `transmis` (octets partis, sans preuve de papier),
/// `nonEnvoye` (échec certain avant tout octet : seul cas qui autorise le secours), `aVerifier` (issue inconnue : jamais
/// relancé automatiquement).
enum RestoOutcome {
  accuse('accuse'),
  transmis('transmis'),
  nonEnvoye('non_envoye'),
  aVerifier('a_verifier');

  const RestoOutcome(this.code);

  /// Valeur du contrat (`evenement_bon.resultat`).
  final String code;
}

class RestoAttempt {
  const RestoAttempt(this.target, this.outcome, {this.fallback = false});

  final RestoTarget target;
  final RestoOutcome outcome;
  final bool fallback;
}

/// Planification de la livraison d'un bon (plan §2) : il part vers toutes les cibles de son poste ; une cible en échec
/// certain passe au secours suivant ; « à vérifier » n'est jamais relancé ; le bon est livré dès la première réponse
/// positive. Un renvoi manuel est un DUPLICATA, avec un autre identifiant.
class RestoDelivery {
  RestoDelivery._();

  static List<RestoTarget> targetsOf(RestoStation station) => [
    if (station.screen) RestoTarget.ecranPoste,
    if (station.paper) RestoTarget.imprimantePoste,
    if (!station.screen && !station.paper) RestoTarget.imprimanteCaisse,
  ];

  /// Cibles à tenter maintenant, compte tenu des tentatives déjà faites pour ce bon.
  static List<(RestoTarget, bool)> next(RestoStation station, List<RestoAttempt> attempts) {
    final tried = {for (final a in attempts) a.target};
    // Une issue inconnue gèle le bon : vérification humaine, jamais de relance qui risquerait un plat en double.
    if (attempts.any((a) => a.outcome == RestoOutcome.aVerifier)) return const [];
    final plan = <(RestoTarget, bool)>[for (final t in targetsOf(station)) if (!tried.contains(t)) (t, false)];
    if (plan.isNotEmpty) return plan;
    if (delivered(attempts)) return const [];
    // Toutes les cibles du poste ont échoué avant tout octet : secours suivant dans la chaîne (l'écran seulement si le
    // poste en a un).
    for (final t in [if (station.screen) RestoTarget.ecranPoste, RestoTarget.imprimantePoste, RestoTarget.imprimanteCaisse]) {
      if (!tried.contains(t)) return [(t, true)];
    }
    return const [];
  }

  static bool delivered(List<RestoAttempt> attempts) => attempts.any((a) => a.outcome == RestoOutcome.accuse || a.outcome == RestoOutcome.transmis);

  static bool needsCheck(List<RestoAttempt> attempts) => attempts.any((a) => a.outcome == RestoOutcome.aVerifier);
}

/// Côté afficheur : un bon déjà reçu (même uuid) ne s'affiche qu'une fois, quel que soit le nombre de réceptions.
class RestoReceivedTickets {
  final _seen = <String>{};

  /// Vrai la première fois seulement.
  bool accept(String ticketUuid) => _seen.add(ticketUuid);
}
