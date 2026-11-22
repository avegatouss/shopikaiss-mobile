import 'dart:async';

import 'package:flutter/material.dart';

import 'caisse_engine.dart';
import 'local_sessions.dart';
import 'models.dart';

/// Indicateur de synchronisation toujours visible (2.1 lot 12) : pastille de couleur, état en mots et compte à rebours
/// avant le prochain envoi ; un appui ouvre le détail avec « Synchroniser maintenant ».
class SyncIndicator extends StatefulWidget {
  const SyncIndicator({super.key, required this.engine, required this.onSyncNow, this.compact = false});

  final CaisseEngine engine;
  final Future<void> Function() onSyncNow;
  final bool compact;

  @override
  State<SyncIndicator> createState() => _SyncIndicatorState();
}

class _SyncIndicatorState extends State<SyncIndicator> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final engine = widget.engine;
    final status = engine.syncStatus;
    final color = syncColor(status.level);
    final left = status.secondsLeft(engine.now);
    final countdown = _clock(left);
    return Tooltip(
      message: 'Synchronisation : ${status.label()}',
      child: InkWell(
        key: const ValueKey('sync-indicator'),
        borderRadius: BorderRadius.circular(16),
        onTap: () => showSyncSheet(context, engine, widget.onSyncNow),
        child: Container(
          constraints: const BoxConstraints(minHeight: 32),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: color.withValues(alpha: .10), borderRadius: BorderRadius.circular(16), border: Border.all(color: color.withValues(alpha: .35))),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 9, height: 9, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              if (!widget.compact) ...[
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Text(status.label(), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 6),
              ],
              if (status.syncing) SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: color)) else Icon(Icons.schedule, size: 14, color: color),
              const SizedBox(width: 2),
              Text(countdown, style: TextStyle(color: color, fontSize: 12, fontFeatures: const [FontFeature.tabularFigures()])),
            ],
          ),
        ),
      ),
    );
  }
}

/// Vert : à jour ; orange : en attente ; rouge : à arbitrer, refusé ou hors connexion.
Color syncColor(String level) => switch (level) {
  'ok' => const Color(0xFF2E7D32),
  'attente' => const Color(0xFFE65100),
  _ => const Color(0xFFC62828),
};

/// « 22/11/2026 » d'un jour `AAAA-MM-JJ`.
String formatDayFr(String day) => '${day.substring(8, 10)}/${day.substring(5, 7)}/${day.substring(0, 4)}';

String _clock(int seconds) => '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

String _time(DateTime? d) {
  if (d == null) return 'jamais';
  final l = d.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(l.day)}/${two(l.month)} ${two(l.hour)}:${two(l.minute)}';
}

/// Détail de la synchronisation : compteurs, dernier contact, prochain envoi, opérations non intégrées avec leur
/// raison (« attend la session précédente »), sessions locales et « Synchroniser maintenant ».
Future<void> showSyncSheet(BuildContext context, CaisseEngine engine, Future<void> Function() onSyncNow) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) => _SyncSheet(engine: engine, onSyncNow: onSyncNow),
);

class _SyncSheet extends StatefulWidget {
  const _SyncSheet({required this.engine, required this.onSyncNow});

  final CaisseEngine engine;
  final Future<void> Function() onSyncNow;

  @override
  State<_SyncSheet> createState() => _SyncSheetState();
}

class _SyncSheetState extends State<_SyncSheet> {
  List<OfflineOperation>? _waiting;
  List<LocalSession>? _sessions;
  bool _busy = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _load();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final operations = (await widget.engine.history()).reversed;
    final sessions = await widget.engine.localSessions();
    if (!mounted) return;
    setState(() {
      _waiting = [for (final o in operations) if (!OfflineOperation.isFinalServerStatus(o.serverStatus) && o.serverStatus != 'resolue') o];
      _sessions = sessions.reversed.toList();
    });
  }

  Future<void> _sync() async {
    setState(() => _busy = true);
    try {
      await widget.onSyncNow();
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final engine = widget.engine;
    final status = engine.syncStatus;
    final color = syncColor(status.level);
    final theme = Theme.of(context);
    final left = status.secondsLeft(engine.now);
    Widget counter(String label, int value, Color c) => Expanded(
      child: Column(
        children: [
          Text('$value', style: theme.textTheme.headlineSmall?.copyWith(color: value == 0 ? theme.disabledColor : c, fontWeight: FontWeight.w700)),
          Text(label, textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
        ],
      ),
    );
    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: .7,
        maxChildSize: .95,
        builder: (context, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          children: [
            Row(
              children: [
                Container(width: 12, height: 12, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                const SizedBox(width: 8),
                Expanded(child: Text(status.label(), style: theme.textTheme.titleMedium?.copyWith(color: color, fontWeight: FontWeight.w700))),
              ],
            ),
            const SizedBox(height: 4),
            Text('Dernier contact : ${_time(status.lastContact)} · prochain envoi ${left == 0 ? 'maintenant' : 'dans ${_clock(left)}'} (toutes les ${status.intervalSeconds} s)',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 16),
            Row(
              children: [
                counter('à envoyer', status.pending, const Color(0xFFE65100)),
                counter('en attente\nde session', status.waiting, const Color(0xFFE65100)),
                counter('à arbitrer', status.arbitration, const Color(0xFFC62828)),
                counter('refusées', status.refused, const Color(0xFFC62828)),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: _busy || status.syncing ? null : _sync,
              icon: _busy || status.syncing ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.sync),
              label: const Text('Synchroniser maintenant'),
            ),
            if (_waiting case final waiting? when waiting.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text('Pas encore intégrées par la boutique', style: theme.textTheme.titleSmall),
              for (final o in waiting.take(50))
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(_operationIcon(o.type), color: o.serverStatus == 'a_arbitrer' || o.serverStatus == 'rejet_protocole' ? const Color(0xFFC62828) : const Color(0xFFE65100)),
                  title: Text('${operationLabel(o)} · ${_time(o.date)}'),
                  subtitle: Text(_waitingText(o)),
                ),
            ],
            if (_sessions case final sessions? when sessions.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text('Sessions de ce poste', style: theme.textTheme.titleSmall),
              for (final s in sessions.take(30)) sessionTile(context, engine, s),
            ],
          ],
        ),
      ),
    );
  }
}

IconData _operationIcon(String type) => switch (type) {
  'vente' || 'vente_modification' => Icons.receipt_long_outlined,
  'ouverture_session' => Icons.lock_open_outlined,
  'cloture_session' => Icons.lock_outline,
  'cloture_journee' => Icons.event_available_outlined,
  'retour' => Icons.undo,
  _ => Icons.sync_alt,
};

/// Nom d'une opération pour les listes d'attente.
String operationLabel(OfflineOperation o) => switch (o.type) {
  'vente' => 'Vente ${o.number ?? ''}'.trim(),
  'vente_modification' => 'Ticket modifié ${o.number ?? ''}'.trim(),
  'ouverture_session' => 'Ouverture de session',
  'cloture_session' => 'Clôture de session',
  'cloture_journee' => 'Z de journée ${o.content['jour'] is String ? formatDayFr(o.content['jour'] as String) : ''}'.trim(),
  'retour' => 'Retour',
  'transfert_especes' => 'Mobile money → espèces',
  _ => o.type.replaceAll('_', ' '),
};

String _waitingText(OfflineOperation o) => switch (o.serverStatus) {
  null => 'À envoyer',
  'recue' => o.message == null ? 'Reçue, en cours d’intégration' : (o.message!.contains('session') || o.message!.contains('ouverture') ? 'Attend la session précédente · ${o.message}' : o.message!),
  'a_arbitrer' => 'À arbitrer par la boutique${o.message == null ? '' : ' · ${o.message}'}',
  'rejet_protocole' => 'Refusée${o.message == null ? '' : ' · ${o.message}'}',
  final s => s,
};

/// Ligne d'une session locale : caissier, ouverture et clôture, état au serveur, Z de journée qui l'a reprise.
Widget sessionTile(BuildContext context, CaisseEngine engine, LocalSession s) {
  final opener = engine.snapshot?.operatorById(s.openerId)?.name;
  final color = s.awaitingServer
      ? (s.closingState == 'a_arbitrer' || s.openingState == 'a_arbitrer' ? const Color(0xFFC62828) : const Color(0xFFE65100))
      : const Color(0xFF2E7D32);
  return ListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    leading: Icon(s.closed ? Icons.lock_outline : Icons.lock_open_outlined, color: color),
    title: Text([?opener, s.openedAt == null ? 'Ouverte en ligne' : 'Ouverte le ${_time(s.openedAt)}', if (s.closed) 'close le ${_time(s.closedAt)}' else 'en cours'].join(' · ')),
    subtitle: Text([s.serverLabel, if (s.day != null) 'Z de journée du ${formatDayFr(s.day!)}'].join(' · '), style: TextStyle(color: color)),
  );
}

/// Liste des sessions de ce poste avec leur état au serveur et le plafond avant synchronisation.
Future<void> showLocalSessions(BuildContext context, CaisseEngine engine) async {
  final sessions = (await engine.localSessions()).reversed.toList();
  if (!context.mounted) return;
  final waiting = sessions.where((s) => s.closed && s.awaitingServer).length;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: .6,
        maxChildSize: .95,
        builder: (context, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          children: [
            Text('Sessions de ce poste', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('$waiting / ${engine.localSessionsMax} sessions attendent la boutique avant la prochaine synchronisation.'),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: engine.localSessionsMax == 0 ? 0 : (waiting / engine.localSessionsMax).clamp(0, 1).toDouble(),
              color: waiting >= engine.localSessionsMax ? const Color(0xFFC62828) : const Color(0xFF2E7D32),
            ),
            const SizedBox(height: 8),
            if (sessions.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('Aucune session sur ce poste.')),
            for (final s in sessions) sessionTile(context, engine, s),
          ],
        ),
      ),
    ),
  );
}
