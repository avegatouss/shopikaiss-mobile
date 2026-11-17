import '../sync_v2/canonical_json.dart';
import '../sync_v2/decimal6.dart';

/// Moteur partagé du restaurant hors connexion (plan PLAN-RESTAURANT-HORS-LIGNE.md, proposition RESTAURANT-1 de A) :
/// commandes, lignes, routage vers les postes, bons de production par différence, annulations, et planification de la
/// livraison des bons sans doublon. Pur et déterministe (horloge et uuid injectés) : la caisse maîtresse (Windows ou
/// Android) le persiste et l'affiche ; rien n'est envoyé au serveur tant que `restaurant.v1` n'est pas validé.
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
  const RestoStation({required this.uuid, required this.code, required this.name, this.screen = false, this.paper = true, this.active = true, this.order = 0});

  final String uuid;
  final String code;
  final String name;
  final bool screen;
  final bool paper;
  final bool active;
  final int order;

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

class RestoLine {
  RestoLine({
    required this.uuid,
    required this.productUuid,
    this.packagingUuid,
    required this.label,
    required this.quantity,
    required this.unitPrice,
    this.discount = 0,
    this.comment,
    this.stationUuid,
    this.free = false,
    this.status = RestoLineStatus.pending,
    this.sent = 0,
    this.settled = 0,
  });

  final String uuid;
  final String productUuid;
  final String? packagingUuid;
  final String label;

  /// Quantité active (millionièmes).
  int quantity;
  final int unitPrice;
  int discount;
  String? comment;

  /// Poste figé à l'ajout de la ligne ; null = rien ne part.
  final String? stationUuid;
  bool free;
  RestoLineStatus status;

  /// Quantité nette annoncée aux postes (Σ ajouts − Σ annulations des bons).
  int sent;

  /// Quantité réglée.
  int settled;

  int get gross => Decimal6.amount(unitPrice, quantity);
  int get total => free ? 0 : gross - discount;
  int get toSend => status == RestoLineStatus.cancelled ? 0 : quantity - sent;

  RestoLine copy() => RestoLine(
    uuid: uuid,
    productUuid: productUuid,
    packagingUuid: packagingUuid,
    label: label,
    quantity: quantity,
    unitPrice: unitPrice,
    discount: discount,
    comment: comment,
    stationUuid: stationUuid,
    free: free,
    status: status,
    sent: sent,
    settled: settled,
  );

  Map<String, dynamic> toJson() => {
    'ligne_uuid': uuid,
    'produit_uuid': productUuid,
    'conditionnement_uuid': packagingUuid,
    'libelle': label,
    'quantite': Decimal6.format(quantity),
    'prix_unitaire': unitPrice,
    'remise': free ? gross : discount,
    'tarif': free ? 'free' : (discount > 0 ? 'manual_discount' : 'standard'),
    'statut': status.name,
    'poste_uuid': stationUuid,
    'commentaire': comment,
    'envoye': Decimal6.format(sent),
    'reglee': Decimal6.format(settled),
  };

  static RestoLine fromJson(Map m) => RestoLine(
    uuid: m['ligne_uuid'] as String,
    productUuid: m['produit_uuid'] as String,
    packagingUuid: m['conditionnement_uuid'] as String?,
    label: m['libelle'] as String,
    quantity: Decimal6.parse(m['quantite'] as String),
    unitPrice: m['prix_unitaire'] as int,
    discount: m['tarif'] == 'free' ? 0 : m['remise'] as int,
    free: m['tarif'] == 'free',
    comment: m['commentaire'] as String?,
    stationUuid: m['poste_uuid'] as String?,
    status: RestoLineStatus.values.byName(m['statut'] as String),
    sent: Decimal6.parse(m['envoye'] as String),
    settled: Decimal6.parse(m['reglee'] as String),
  );
}

class RestoOrder {
  RestoOrder({
    required this.uuid,
    required this.localNumber,
    required this.businessDay,
    required this.profile,
    this.tableUuid,
    this.covers,
    this.serverId,
    this.comment,
    this.status = 'open',
    this.version = 0,
    this.prebills = 0,
    List<RestoLine>? lines,
  }) : lines = lines ?? [];

  final String uuid;

  /// Numéro que la salle connaît : préfixe, date, `L` et 4 chiffres (contrat §4.2).
  final String localNumber;
  final String businessDay;

  /// `TABLE_SERVICE` ou `PRODUCTION`.
  final String profile;
  String? tableUuid;
  int? covers;
  String? serverId;
  String? comment;

  /// `open`, `settled` ou `cancelled`.
  String status;
  int version;
  int prebills;
  final List<RestoLine> lines;

  bool get isOpen => status == 'open';
  List<RestoLine> get activeLines => [for (final l in lines) if (l.status != RestoLineStatus.cancelled) l];
  int get payable => activeLines.fold(0, (sum, l) => sum + l.total);

  RestoLine line(String uuid) => lines.where((l) => l.uuid == uuid).firstOrNull ?? (throw const RestoRefusal('Ligne introuvable dans la commande.'));

  RestoOrder copy() => RestoOrder(
    uuid: uuid,
    localNumber: localNumber,
    businessDay: businessDay,
    profile: profile,
    tableUuid: tableUuid,
    covers: covers,
    serverId: serverId,
    comment: comment,
    status: status,
    version: version,
    prebills: prebills,
    lines: [for (final l in lines) l.copy()],
  );

  /// État complet de la commande (forme `etat_commande` proposée par A, champs connus du moteur).
  Map<String, dynamic> toJson() {
    final active = activeLines;
    final gross = active.fold<int>(0, (sum, l) => sum + l.gross);
    return {
      'uuid': uuid,
      'profil': profile,
      'numero_local': localNumber,
      'date_metier': businessDay,
      'table_uuid': tableUuid,
      'couverts': covers,
      'serveur_id': serverId,
      'commentaire': comment,
      'statut': status,
      'version': version,
      'prefactures': prebills,
      'lignes': [for (final l in lines) l.toJson()],
      'totaux': {
        'brut': gross,
        'remises': gross - payable,
        'a_payer': payable,
        'regle': active.fold<int>(0, (sum, l) => sum + _settledShare(l)),
      },
    };
  }

  static int _settledShare(RestoLine l) => l.quantity == 0 ? 0 : (l.total * l.settled) ~/ l.quantity;

  static RestoOrder fromJson(Map m) => RestoOrder(
    uuid: m['uuid'] as String,
    localNumber: m['numero_local'] as String,
    businessDay: m['date_metier'] as String,
    profile: m['profil'] as String,
    tableUuid: m['table_uuid'] as String?,
    covers: m['couverts'] as int?,
    serverId: m['serveur_id'] as String?,
    comment: m['commentaire'] as String?,
    status: m['statut'] as String,
    version: m['version'] as int,
    prebills: m['prefactures'] as int,
    lines: [for (final l in (m['lignes'] as List).cast<Map>()) RestoLine.fromJson(l)],
  );
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
}

/// Compteurs des bons, persistés par la caisse maîtresse : numéro par (commande, poste) et numéro du jour par poste.
class RestoCounters {
  RestoCounters([Map<String, int>? values]) : values = values ?? {};

  final Map<String, int> values;

  int next(String key) => values[key] = (values[key] ?? 0) + 1;
}

/// Fait d'une commande (forme `resto_commande` : version, action, fait, motif, état résultant), gardé pour la remontée.
class RestoEvent {
  const RestoEvent({required this.uuid, required this.version, required this.action, required this.fact, this.reason, required this.state, this.tickets = const []});

  final String uuid;
  final int version;
  final String action;
  final Map<String, dynamic> fact;
  final String? reason;
  final Map<String, dynamic> state;
  final List<RestoTicket> tickets;
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
  RestoEngine({required this.newUuid, required this.now, required this.stations, required this.counters, this.sendToStations = true});

  final String Function() newUuid;
  final DateTime Function() now;

  /// Postes publiés, par uuid.
  final Map<String, RestoStation> stations;
  final RestoCounters counters;

  /// Paramètre d'envoi (`restaurant.table_service_send_to_production` ou `restaurant.production_send_to_stations`) :
  /// éteint, « Envoyer » devient « Valider » : la commande est figée et aucun bon ne part.
  final bool sendToStations;

  RestoResult _record(RestoOrder order, String action, Map<String, dynamic> fact, {String? reason, List<RestoTicket> tickets = const []}) {
    order.version++;
    return RestoResult(order, RestoEvent(uuid: newUuid(), version: order.version, action: action, fact: fact, reason: reason, state: order.toJson(), tickets: tickets), tickets);
  }

  void _requireOpen(RestoOrder order) {
    if (!order.isOpen) throw const RestoRefusal('Cette commande est close : elle ne se modifie plus.');
  }

  /// Ouverture : numéro local `PREFIXE-AAAAMMJJ-L0001`, compté par jour sur la caisse maîtresse.
  RestoResult open({required String prefix, required String businessDay, required String profile, String? tableUuid, int? covers, String? serverId}) {
    final cleanPrefix = prefix.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');
    final day = businessDay.replaceAll('-', '');
    final sequence = counters.next('commande|$day');
    final order = RestoOrder(
      uuid: newUuid(),
      localNumber: '${cleanPrefix.isEmpty ? 'CMD' : cleanPrefix}-$day-L${sequence.toString().padLeft(4, '0')}',
      businessDay: businessDay,
      profile: profile,
      tableUuid: tableUuid,
      covers: covers,
      serverId: serverId,
    );
    return _record(order, 'ouverture', const {});
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
  }) {
    _requireOpen(order);
    if (quantity <= 0) throw const RestoRefusal('Quantité invalide.');
    final next = order.copy();
    final line = RestoLine(
      uuid: newUuid(),
      productUuid: productUuid,
      packagingUuid: packagingUuid,
      label: label,
      quantity: quantity,
      unitPrice: unitPrice,
      comment: comment == null || comment.trim().isEmpty ? null : comment.trim(),
      stationUuid: routing.resolve(stations, firstActiveFallback: firstActiveFallback)?.uuid,
    );
    next.lines.add(line);
    return _record(next, 'lignes', {'ajoutees': [line.uuid], 'modifiees': <String>[], 'retirees': <String>[]});
  }

  /// Changement de quantité d'une ligne pas encore envoyée. Une ligne envoyée ne baisse que par [cancelLine].
  RestoResult changeQuantity(RestoOrder order, String lineUuid, int quantity) {
    _requireOpen(order);
    final next = order.copy();
    final line = next.line(lineUuid);
    if (line.status == RestoLineStatus.cancelled) throw const RestoRefusal('Cette ligne est annulée.');
    if (quantity <= 0) return removeLine(order, lineUuid);
    if (quantity < line.sent) throw const RestoRefusal('Article déjà envoyé : annulez la quantité envoyée avec un motif.');
    line.quantity = quantity;
    if (quantity > line.sent) line.status = RestoLineStatus.pending;
    return _record(next, 'lignes', {'ajoutees': <String>[], 'modifiees': [lineUuid], 'retirees': <String>[]});
  }

  /// Retrait d'une ligne jamais envoyée.
  RestoResult removeLine(RestoOrder order, String lineUuid) {
    _requireOpen(order);
    final next = order.copy();
    final line = next.line(lineUuid);
    if (line.sent > 0) throw const RestoRefusal('Article déjà envoyé : annulez-le avec un motif.');
    line.status = RestoLineStatus.cancelled;
    return _record(next, 'lignes', {'ajoutees': <String>[], 'modifiees': <String>[], 'retirees': [lineUuid]}, reason: 'Retiré de la commande');
  }

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

  /// Envoi par différence : à envoyer = quantité active − envoyé net, un bon par poste. Les articles sans poste sont
  /// figés sans bon. Envoi éteint : « Valider » fige la commande sans aucun bon.
  RestoResult send(RestoOrder order) {
    _requireOpen(order);
    final next = order.copy();
    final waiting = [for (final l in next.lines) if (l.toSend > 0) l];
    if (waiting.isEmpty) throw const RestoRefusal('Rien de nouveau à envoyer.');
    if (!sendToStations) {
      for (final l in waiting) {
        l
          ..sent = l.quantity
          ..status = RestoLineStatus.sent;
      }
      return _record(next, 'validation', {'lignes': [for (final l in waiting) l.uuid]});
    }
    final byStation = <String, List<RestoLine>>{};
    for (final l in waiting) {
      if (l.stationUuid != null && stations.containsKey(l.stationUuid)) (byStation[l.stationUuid!] ??= []).add(l);
    }
    final tickets = [
      for (final entry in (byStation.entries.toList()..sort((a, b) => stations[a.key]!.order.compareTo(stations[b.key]!.order))))
        _ticket(next, entry.key, 'envoi', [
          for (final l in entry.value) RestoTicketLine(lineUuid: l.uuid, label: l.label, quantity: l.toSend, comment: l.comment, action: 'add'),
        ]),
    ];
    for (final l in waiting) {
      l
        ..sent = l.quantity
        ..status = RestoLineStatus.sent;
    }
    return _record(next, 'envoi', {'bons': [for (final t in tickets) t.toJson()]}, tickets: tickets);
  }

  /// Annulation d'une quantité envoyée (droit `resto_modifier_envoye` ou autorisation, vérifiés par l'appelant) ; motif
  /// d'au moins 3 caractères. Bon d'ANNULATION seulement si la ligne avait été annoncée à un poste.
  RestoResult cancelLine(RestoOrder order, String lineUuid, int quantity, String reason) {
    _requireOpen(order);
    final motive = reason.trim();
    if (motive.length < 3) throw const RestoRefusal('Indiquez le motif de l’annulation (3 caractères au moins).');
    final next = order.copy();
    final line = next.line(lineUuid);
    if (line.status == RestoLineStatus.cancelled) throw const RestoRefusal('Cette ligne est déjà annulée.');
    if (quantity <= 0 || quantity > line.quantity) throw const RestoRefusal('Quantité à annuler invalide.');
    final announced = quantity > line.sent ? line.sent : quantity;
    final tickets = <RestoTicket>[];
    if (announced > 0 && line.stationUuid != null && stations.containsKey(line.stationUuid) && sendToStations) {
      tickets.add(_ticket(next, line.stationUuid!, 'annulation', [
        RestoTicketLine(lineUuid: line.uuid, label: line.label, quantity: announced, comment: 'ANNULÉ : $motive', action: 'cancel'),
      ], reason: motive));
    }
    line
      ..quantity -= quantity
      ..sent -= announced;
    if (line.quantity == 0) line.status = RestoLineStatus.cancelled;
    return _record(next, 'annulation_ligne', {'ligne_uuid': lineUuid, 'quantite': Decimal6.format(quantity), 'bons': [for (final t in tickets) t.toJson()]},
        reason: motive, tickets: tickets);
  }

  /// Annulation de la commande : bons d'ANNULATION pour tout ce qui était annoncé, poste par poste.
  RestoResult cancelOrder(RestoOrder order, String? reason) {
    _requireOpen(order);
    final motive = reason?.trim() ?? '';
    final next = order.copy();
    final announced = <String, List<RestoLine>>{};
    for (final l in next.activeLines) {
      if (l.sent > 0 && l.stationUuid != null && stations.containsKey(l.stationUuid)) (announced[l.stationUuid!] ??= []).add(l);
    }
    if (announced.isNotEmpty && motive.length < 3) throw const RestoRefusal('Des articles sont déjà envoyés : indiquez le motif de l’annulation.');
    final tickets = [
      if (sendToStations)
        for (final entry in announced.entries)
          _ticket(next, entry.key, 'annulation', [
            for (final l in entry.value) RestoTicketLine(lineUuid: l.uuid, label: l.label, quantity: l.sent, comment: 'ANNULÉ : $motive', action: 'cancel'),
          ], reason: motive),
    ];
    for (final l in next.activeLines) {
      l
        ..sent = 0
        ..status = RestoLineStatus.cancelled;
    }
    next.status = 'cancelled';
    return _record(next, 'annulation', {'bons': [for (final t in tickets) t.toJson()]}, reason: motive.isEmpty ? null : motive, tickets: tickets);
  }

  /// Préfacture : compteur d'impressions (rien n'est imprimé par le serveur).
  RestoResult prebill(RestoOrder order) {
    _requireOpen(order);
    final next = order.copy()..prebills += 1;
    return _record(next, 'prefacture', {'numero_local': next.localNumber});
  }

  RestoResult transfer(RestoOrder order, String tableUuid) {
    _requireOpen(order);
    final next = order.copy();
    final from = next.tableUuid;
    next.tableUuid = tableUuid;
    return _record(next, 'transfert_table', {'table_uuid_source': from, 'table_uuid_cible': tableUuid});
  }

  RestoResult coversAndServer(RestoOrder order, {int? covers, String? serverId}) {
    _requireOpen(order);
    if (covers != null && (covers < 1 || covers > 500)) throw const RestoRefusal('Nombre de couverts invalide (1 à 500).');
    final next = order.copy()
      ..covers = covers
      ..serverId = serverId;
    return _record(next, 'couverts_serveur', {'couverts': covers, 'serveur_id': serverId});
  }

  /// Règlement d'une partie des lignes (après la vente v2 qui les encaisse) puis clôture quand tout est réglé.
  RestoResult settle(RestoOrder order, Map<String, int> quantities) {
    _requireOpen(order);
    final next = order.copy();
    for (final e in quantities.entries) {
      final line = next.line(e.key);
      if (e.value <= 0 || line.settled + e.value > line.quantity) throw const RestoRefusal('Quantité réglée supérieure à la quantité commandée.');
      line.settled += e.value;
    }
    final done = next.activeLines.every((l) => l.settled >= l.quantity);
    if (!done) return _record(next, 'lignes', {'ajoutees': <String>[], 'modifiees': quantities.keys.toList(), 'retirees': <String>[]});
    next.status = 'settled';
    return _record(next, 'cloture', const {});
  }
}

// ------------------------------------------------------------------ livraison sans doublon

/// Cibles d'un bon, dans l'ordre de secours : écran du poste, imprimante du poste, imprimante de la caisse.
enum RestoTarget { ecranPoste, imprimantePoste, imprimanteCaisse }

/// Issue d'une tentative : `accuse` (l'afficheur a confirmé CE bon), `transmis` (octets partis, sans preuve de papier),
/// `nonEnvoye` (échec certain avant tout octet : seul cas qui autorise le secours), `aVerifier` (issue inconnue : jamais
/// relancé automatiquement).
enum RestoOutcome { accuse, transmis, nonEnvoye, aVerifier }

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
