import 'package:flutter/material.dart';

import '../terminal/terminal_session.dart';
import 'engine.dart';
import 'pending_operations_page.dart';

/// Réglages › Caisse hors ligne : appairage du terminal par le code généré dans ShopiKaiss (Paramètres › Caisse hors
/// ligne), état du catalogue et de la file, mise à jour et envoi à la demande.
class OfflineSettingsSection extends StatefulWidget {
  const OfflineSettingsSection({super.key, required this.session});

  final TerminalSession session;

  @override
  State<OfflineSettingsSection> createState() => _OfflineSettingsSectionState();
}

class _OfflineSettingsSectionState extends State<OfflineSettingsSection> {
  final _code = TextEditingController();
  String? _message;
  bool _busy = false;

  OfflineEngine get _engine => widget.session.offline;

  @override
  void initState() {
    super.initState();
    _engine.addListener(_changed);
  }

  @override
  void dispose() {
    _engine.removeListener(_changed);
    _code.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _run(Future<String?> Function() action) async {
    setState(() => (_busy = true, _message = null));
    final message = await action();
    if (mounted) setState(() => (_busy = false, _message = message));
  }

  @override
  Widget build(BuildContext context) {
    final engine = _engine;
    final snapshot = engine.snapshot;
    final configured = widget.session.settings.configured;
    String two(int v) => v.toString().padLeft(2, '0');
    String when(DateTime? d) =>
        d == null ? '—' : '${two(d.toLocal().day)}/${two(d.toLocal().month)} ${two(d.toLocal().hour)}:${two(d.toLocal().minute)}';
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Caisse hors ligne', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                'Quand la boutique ne répond plus, ce terminal continue de vendre avec le dernier catalogue reçu et envoie ses ventes au retour de la connexion. '
                'Générez un code dans ShopiKaiss (Paramètres › Caisse hors ligne, ligne de ce terminal) puis saisissez-le ici.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              if (!configured) const Text('Enregistrez d’abord l’adresse de la boutique.'),
              if (configured && !engine.paired) ...[
                if (engine.revoked)
                  const Text('Cette application a été révoquée par la boutique : appairez-la de nouveau.', style: TextStyle(color: Colors.red)),
                TextField(
                  controller: _code,
                  textCapitalization: TextCapitalization.characters,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'Code d’appairage', hintText: 'ABCD-EFGH', prefixIcon: Icon(Icons.link)),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            final error = await engine.pair(_code.text, model: widget.session.info.label, appVersion: widget.session.appVersion);
                            return error ?? 'Terminal appairé : catalogue reçu (${engine.snapshot?.products.length ?? 0} articles).';
                          }),
                    icon: const Icon(Icons.link),
                    label: const Text('Appairer'),
                  ),
                ),
              ],
              if (engine.paired) ...[
                _line('Appareil', engine.deviceName ?? '—'),
                _line('Catalogue', snapshot == null ? 'absent' : '${snapshot.products.length} articles, reçu le ${when(engine.snapshotAt)}'),
                _line('Dernier contact', when(engine.lastContact)),
                _line('En attente d’envoi', '${engine.pendingCount}${engine.refusedCount > 0 ? ' · ${engine.refusedCount} refusée(s)' : ''}'),
                if (snapshot != null) _line('Règles', 'hors ligne ${snapshot.rules.maxHours} h au plus, ${snapshot.rules.maxSales} ventes au plus'),
                if (engine.blockReason != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(engine.blockReason!, style: const TextStyle(color: Color(0xFFB45309))),
                  ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _busy ? null : () => _run(() async => await engine.refreshSnapshot() ?? 'Catalogue mis à jour.'),
                      icon: const Icon(Icons.download),
                      label: const Text('Mettre à jour le catalogue'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                              final r = await engine.sync();
                              return r.reachable
                                  ? '${r.sent} envoyée(s), ${r.integrated} intégrée(s), ${r.pending} à arbitrer.'
                                  : (r.message ?? 'Boutique injoignable.');
                            }),
                      icon: const Icon(Icons.sync),
                      label: const Text('Envoyer les ventes'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PendingOperationsPage(engine: engine))),
                      icon: const Icon(Icons.receipt_long),
                      label: const Text('Opérations hors ligne'),
                    ),
                    TextButton(
                      onPressed: _busy || engine.pendingCount > 0
                          ? null
                          : () => _run(() async {
                              await engine.unpair();
                              return 'Appairage oublié sur ce terminal.';
                            }),
                      child: const Text('Oublier l’appairage'),
                    ),
                  ],
                ),
              ],
              if (_message != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_message!)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _line(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 150,
          child: Text(label, style: const TextStyle(color: Colors.black54)),
        ),
        Expanded(child: Text(value)),
      ],
    ),
  );
}
