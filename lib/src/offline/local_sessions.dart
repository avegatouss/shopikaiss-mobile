/// Sessions locales séparées, journée de caisse du terminal et état de synchronisation (contrat 2.1 lot 12, capacité
/// `session.multiple`, note A `LOT-12-SESSIONS-POUR-B-ET-C.md`).
library;

/// Une session de caisse de ce terminal telle que sa file la décrit : ouverture locale (ou session ouverte en ligne
/// que le terminal a clôturée), clôture, Z de journée qui l'a reprise, et état de chaque opération au serveur.
class LocalSession {
  LocalSession({required this.uuid, this.serverUuid, this.openedAt, this.openerId, this.openingState, this.openingReason});

  /// Identifiant local : uuid de l'`ouverture_session`, ou de la session serveur si elle a été ouverte en ligne.
  final String uuid;

  /// Session serveur correspondante (`details.session_serveur`), connue une fois l'ouverture intégrée.
  String? serverUuid;
  DateTime? openedAt;
  int? openerId;

  /// État au serveur de l'ouverture (`a_envoyer`, `recue`, `integree`…) ; null : session ouverte en ligne.
  String? openingState;
  String? openingReason;

  /// Opération de clôture (`cloture_session`) : uuid, date, état au serveur et raison d'une attente.
  String? closingUuid;
  DateTime? closedAt;
  String? closingState;
  String? closingReason;

  /// `session_uuid` porté par la clôture (celui que liste la `cloture_journee`).
  String? closingSessionUuid;

  /// Z de journée du terminal qui a repris cette session (uuid de la `cloture_journee`) et son jour.
  String? dayClosureUuid;
  String? day;

  bool get closed => closingUuid != null;

  /// Désigne-t-elle [sessionUuid] (uuid local, serveur, ou celui porté par sa clôture) ?
  bool matches(String? sessionUuid) => sessionUuid != null && (sessionUuid == uuid || sessionUuid == serverUuid || sessionUuid == closingSessionUuid);

  /// Pas encore réglée avec la boutique : ouverture ou clôture non intégrée (une quarantaine ne bloque pas).
  bool get awaitingServer => _awaiting(openingState) || (closed && _awaiting(closingState));

  static bool _awaiting(String? state) => state != null && state != 'integree' && state != 'resolue' && state != 'rejet_protocole';

  /// « En attente », « Intégrée », « À arbitrer »… pour la liste des sessions.
  String get serverLabel {
    final state = closed ? closingState : openingState;
    final reason = closed ? closingReason : openingReason;
    return switch (state) {
      null => 'Ouverte en ligne',
      'a_envoyer' || 'envoi_inconnu' => 'À envoyer',
      'recue' => reason ?? 'Reçue par la boutique',
      'integree' => 'Intégrée',
      'resolue' => 'Arbitrée',
      'a_arbitrer' => 'À arbitrer par la boutique',
      'rejet_protocole' => 'Refusée (quarantaine)',
      _ => state,
    };
  }

  Map<String, dynamic> toJson() => {
    'id': uuid,
    'server_id': serverUuid,
    'opened_at': openedAt?.toUtc().toIso8601String(),
    'opener_id': openerId,
    'closed': closed,
    'closed_at': closedAt?.toUtc().toIso8601String(),
    'opening_state': openingState,
    'closing_state': closingState,
    'awaiting_server': awaitingServer,
    'server_label': serverLabel,
    'day': day,
    'day_closed': dayClosureUuid != null,
  };
}

/// État de la synchronisation montré en permanence dans la barre de la caisse.
class SyncStatus {
  const SyncStatus({
    required this.pending,
    required this.arbitration,
    required this.waiting,
    required this.refused,
    required this.intervalSeconds,
    this.reachable,
    this.lastContact,
    this.offlineSince,
    this.lastAttempt,
    this.syncing = false,
  });

  /// Opérations jamais envoyées ou à renvoyer.
  final int pending;

  /// À arbitrer par la boutique.
  final int arbitration;

  /// Reçues mais en attente d'une session précédente (`session.*`, `journee.*`) : pas un refus.
  final int waiting;
  final int refused;

  /// Délai entre deux envois (`delais.changements_secondes`).
  final int intervalSeconds;
  final bool? reachable;
  final DateTime? lastContact;
  final DateTime? offlineSince;
  final DateTime? lastAttempt;
  final bool syncing;

  /// Prochain envoi automatique : dernier essai + délai (tout de suite si aucun essai).
  DateTime nextAttempt(DateTime now) => lastAttempt == null ? now : lastAttempt!.add(Duration(seconds: intervalSeconds));

  /// Secondes avant le prochain envoi (0 : maintenant).
  int secondsLeft(DateTime now) {
    final left = nextAttempt(now).difference(now).inSeconds;
    return left < 0 ? 0 : left;
  }

  /// Vert (à jour), orange (en attente), rouge (à arbitrer, refusées ou hors connexion).
  String get level => arbitration > 0 || refused > 0 || reachable == false ? 'alerte' : (pending > 0 || waiting > 0 ? 'attente' : 'ok');

  /// « À jour », « 3 en attente », « 1 à arbitrer », « Hors connexion depuis 14:05 »…
  String label() {
    final parts = <String>[
      if (reachable == false) 'Hors connexion${offlineSince == null ? '' : ' depuis ${_time(offlineSince!)}'}',
      if (pending > 0) '$pending à envoyer',
      if (waiting > 0) '$waiting en attente de session',
      if (arbitration > 0) '$arbitration à arbitrer',
      if (refused > 0) '$refused refusée(s)',
    ];
    return parts.isEmpty ? 'À jour' : parts.join(' · ');
  }

  static String _time(DateTime d) {
    final local = d.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}';
  }

  Map<String, dynamic> toJson(DateTime now) => {
    'label': label(),
    'level': level,
    'pending': pending,
    'waiting': waiting,
    'arbitration': arbitration,
    'refused': refused,
    'reachable': reachable,
    'syncing': syncing,
    'last_contact': lastContact?.toUtc().toIso8601String(),
    'offline_since': offlineSince?.toUtc().toIso8601String(),
    'interval_seconds': intervalSeconds,
    'next_attempt': nextAttempt(now).toUtc().toIso8601String(),
    'seconds_left': secondsLeft(now),
  };
}

/// Dernière remise à zéro appliquée sur le terminal (2.1 lot 17).
class ShopResetInfo {
  const ShopResetInfo({required this.uuid, required this.at, required this.appliedAt, required this.erased, required this.unintegrated});

  factory ShopResetInfo.fromJson(Map m) => ShopResetInfo(
    uuid: m['uuid'] as String,
    at: DateTime.parse(m['le'] as String),
    appliedAt: DateTime.tryParse('${m['applique_le']}'),
    erased: (m['operations'] as List? ?? const []).cast<String>(),
    unintegrated: (m['non_integrees'] as List? ?? const []).cast<String>(),
  );

  final String uuid;
  final DateTime at;
  final DateTime? appliedAt;
  final List<String> erased;
  final List<String> unintegrated;

  /// L'opération [operationUuid] (ou une intention datée [createdAt]) appartient aux essais effacés.
  bool covers(String? operationUuid, {DateTime? createdAt}) =>
      (operationUuid != null && erased.contains(operationUuid)) || (createdAt != null && createdAt.toUtc().isBefore(at));

  Map<String, dynamic> toJson() => {
    'uuid': uuid,
    'at': at.toUtc().toIso8601String(),
    'applied_at': appliedAt?.toUtc().toIso8601String(),
    'erased_operation_ids': erased,
    'unintegrated_operation_ids': unintegrated,
  };
}

/// Message d'attente lisible pour une raison `recue` du lot 12 (jamais un refus).
String? waitingReasonLabel(String? code) => switch (code) {
  'session.cloture_precedente' => 'Attend la clôture de la session précédente',
  'session.ouverture_en_attente' => 'Attend l’ouverture de sa session au serveur',
  'journee.sessions_en_attente' => 'Attend la clôture de ses sessions au serveur',
  _ => null,
};

/// Jour suivant d'un jour `AAAA-MM-JJ`.
String nextDay(String day) {
  final d = DateTime.utc(int.parse(day.substring(0, 4)), int.parse(day.substring(5, 7)), int.parse(day.substring(8, 10))).add(const Duration(days: 1));
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}
