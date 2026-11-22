import 'package:flutter/material.dart';

import 'engine.dart';
import 'local_sessions_ui.dart' show formatDayFr;
import 'models.dart';
import 'money.dart';

/// Livre de caisse (2.1 lot 14) : livre local du poste, sans réseau, et livre en ligne de la boutique pour les gérants
/// (copie gardée 30 jours). Libellés du « Livre de caisse journalier » du web ; les deux livres ne s'additionnent pas.
class CashBookPage extends StatefulWidget {
  const CashBookPage({super.key, required this.engine, required this.operator});

  final CaisseEngine engine;
  final Operator operator;

  @override
  State<CashBookPage> createState() => _CashBookPageState();
}

enum _Range { today, yesterday, week, month, custom }

class _CashBookPageState extends State<CashBookPage> {
  bool _online = false;
  _Range _range = _Range.today;
  late String _from;
  late String _to;
  CashBook? _book;
  String? _error;

  /// Livre en ligne : copie gardée montrée pendant le chargement ou hors connexion.
  bool _fromCache = false;
  bool _loading = false;

  CaisseEngine get _engine => widget.engine;
  bool get _canOnline => _engine.canReadOnlineCashBook(widget.operator);

  @override
  void initState() {
    super.initState();
    _from = _to = _engine.today;
    _load();
  }

  void _setRange(_Range range) {
    final today = _engine.today;
    setState(() {
      _range = range;
      final (from, to) = switch (range) {
        _Range.today => (today, today),
        _Range.yesterday => (shiftDay(today, -1), shiftDay(today, -1)),
        _Range.week => (shiftDay(today, -6), today),
        _Range.month => (shiftDay(today, -29), today),
        _Range.custom => (_from, _to),
      };
      _from = from;
      _to = to;
    });
    _load();
  }

  Future<void> _pickRange() async {
    DateTime d(String s) => DateTime(int.parse(s.substring(0, 4)), int.parse(s.substring(5, 7)), int.parse(s.substring(8, 10)));
    String iso(DateTime x) => '${x.year}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
    final today = d(_engine.today);
    final picked = await showDateRangePicker(
      context: context,
      firstDate: _online ? today.subtract(const Duration(days: 30)) : DateTime(2024),
      lastDate: today,
      initialDateRange: DateTimeRange(start: d(_from), end: d(_to)),
      helpText: _online ? 'Période (30 jours au plus)' : 'Période du livre',
      saveText: 'Afficher',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _range = _Range.custom;
      _from = iso(picked.start);
      _to = iso(picked.end);
    });
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_online) {
        final cached = await _engine.cachedCashBook(widget.operator);
        if (mounted && cached != null && cached.from == _from && cached.to == _to) setState(() => (_book = cached, _fromCache = true));
        final book = await _engine.fetchCashBook(widget.operator, from: _from, to: _to);
        if (mounted) setState(() => (_book = book, _fromCache = false));
      } else {
        final book = await _engine.localCashBook(widget.operator, from: _from, to: _to);
        if (mounted) setState(() => (_book = book, _fromCache = false));
      }
    } on OfflineRefusal catch (e) {
      if (!mounted) return;
      // Hors connexion : la dernière copie en ligne reste lisible, avec sa date.
      final cached = _online ? await _engine.cachedCashBook(widget.operator) : null;
      if (!mounted) return;
      setState(() {
        _error = e.message;
        if (cached != null) {
          _book = cached;
          _fromCache = true;
        } else if (_online) {
          _book = null;
        }
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final book = _book;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Livre de caisse'),
        actions: [IconButton(tooltip: 'Actualiser', onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh))],
        bottom: _loading ? const PreferredSize(preferredSize: Size.fromHeight(3), child: LinearProgressIndicator(minHeight: 3)) : null,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          if (_engine.onlineCashBookSupported)
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: [
                const ButtonSegment(value: false, icon: Icon(Icons.point_of_sale), label: Text('Ce poste')),
                ButtonSegment(value: true, enabled: _canOnline, icon: const Icon(Icons.cloud_outlined), label: const Text('Boutique (en ligne)')),
              ],
              selected: {_online},
              onSelectionChanged: (v) {
                setState(() {
                  _online = v.single;
                  _book = null;
                  if (_online && _range == _Range.custom) {
                    _from = _to = _engine.today;
                    _range = _Range.today;
                  }
                });
                _load();
              },
            ),
          if (_engine.onlineCashBookSupported && !_canOnline)
            Padding(padding: const EdgeInsets.only(top: 6), child: Text('Le livre de toute la boutique est réservé aux gérants.', style: theme.textTheme.bodySmall)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (range, label) in const [(_Range.today, 'Aujourd’hui'), (_Range.yesterday, 'Hier'), (_Range.week, '7 jours'), (_Range.month, '30 jours')])
                ChoiceChip(label: Text(label), selected: _range == range, onSelected: (_) => _setRange(range)),
              ActionChip(
                avatar: const Icon(Icons.date_range, size: 18),
                label: Text(_range == _Range.custom ? '${formatDayFr(_from)} → ${formatDayFr(_to)}' : 'Période…'),
                onPressed: _pickRange,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _scope(theme, book),
          if (_error != null) ...[
            const SizedBox(height: 8),
            _banner(Icons.info_outline, _error!, const Color(0xFFC62828)),
          ],
          if (book != null) ...[
            const SizedBox(height: 12),
            _summary(theme, book),
            const SizedBox(height: 16),
            _methods(theme, book),
            const SizedBox(height: 16),
            ..._movements(theme, book),
          ] else if (!_loading && _error == null)
            const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('Aucun mouvement sur cette période.'))),
        ],
      ),
    );
  }

  Widget _scope(ThemeData theme, CashBook? book) {
    final period = _from == _to ? 'Journée du ${formatDayFr(_from)}' : 'Du ${formatDayFr(_from)} au ${formatDayFr(_to)}';
    if (!_online) {
      return _banner(Icons.point_of_sale, '$period · ce poste seulement, depuis sa file (opérations pas encore envoyées comprises).', const Color(0xFF1565C0));
    }
    final at = book?.generatedAt?.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    final when = at == null ? '' : ' au ${two(at.day)}/${two(at.month)}/${at.year} ${two(at.hour)}:${two(at.minute)}';
    return _banner(
      _fromCache ? Icons.cloud_off : Icons.cloud_done_outlined,
      '$period · livre en ligne$when${_fromCache ? ' (copie gardée sur le poste)' : ''}. Toute la boutique, opérations intégrées seulement : ne pas l’additionner au livre du poste.',
      _fromCache ? const Color(0xFFE65100) : const Color(0xFF2E7D32),
    );
  }

  Widget _banner(IconData icon, String text, Color color) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(color: color.withValues(alpha: .07), borderRadius: BorderRadius.circular(8), border: Border.all(color: color.withValues(alpha: .25))),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [Icon(icon, size: 18, color: color), const SizedBox(width: 8), Expanded(child: Text(text, style: TextStyle(color: color)))],
    ),
  );

  Widget _summary(ThemeData theme, CashBook book) {
    Widget tile(String label, int amount, Color color, {String? sub}) => Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(formatFcfa(amount), style: theme.textTheme.titleMedium?.copyWith(color: color, fontWeight: FontWeight.w700))),
            if (sub != null) Text(sub, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
    final tiles = [
      tile('Entrées espèces', book.cashIn, const Color(0xFF2E7D32)),
      tile('Sorties espèces', book.cashOut, const Color(0xFFC62828)),
      tile('Autres moyens', book.others, theme.colorScheme.primary),
      tile('Ventes', book.salesAmount, theme.colorScheme.onSurface, sub: '${book.salesCount} ticket(s)'),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        final columns = c.maxWidth >= 600 ? 4 : 2;
        final width = (c.maxWidth - (columns - 1) * 8) / columns;
        return Wrap(spacing: 8, runSpacing: 8, children: [for (final t in tiles) SizedBox(width: width, child: t)]);
      },
    );
  }

  Widget _methods(ThemeData theme, CashBook book) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Par moyen de paiement', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          if (book.methods.isEmpty) Text('Aucun encaissement.', style: theme.textTheme.bodySmall),
          for (final m in book.methods)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Expanded(child: Text(m.method)),
                  _amount('+${formatFcfa(m.collected)}', const Color(0xFF2E7D32)),
                  const SizedBox(width: 12),
                  _amount(m.refunded == 0 ? '—' : '-${formatFcfa(m.refunded)}', const Color(0xFFC62828)),
                  const SizedBox(width: 12),
                  SizedBox(width: 96, child: Text(formatFcfa(m.net), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700))),
                ],
              ),
            ),
          if (book.cancellationsCount > 0)
            Text('${book.cancellationsCount} annulation(s) : ${formatFcfa(book.cancellationsAmount)}', style: theme.textTheme.bodySmall),
        ],
      ),
    ),
  );

  Widget _amount(String text, Color color) =>
      SizedBox(width: 90, child: Text(text, textAlign: TextAlign.right, style: TextStyle(color: color, fontFeatures: const [FontFeature.tabularFigures()])));

  List<Widget> _movements(ThemeData theme, CashBook book) {
    if (book.rows.isEmpty) return [const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('Aucun mouvement sur cette période.')))];
    final out = <Widget>[];
    for (final day in book.days) {
      final rows = [for (final r in book.rows) if (r.day == day) r];
      out.add(Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
        child: Text(formatDayFr(day), style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
      ));
      out.add(Card(
        margin: EdgeInsets.zero,
        child: Column(children: [for (final (i, r) in rows.indexed) ...[if (i > 0) const Divider(height: 1), _row(theme, r, book.storeWide)]]),
      ));
    }
    return out;
  }

  Widget _row(ThemeData theme, CashBookRow r, bool storeWide) {
    final local = r.date.toLocal();
    final time = '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    final amount = r.cashIn != 0
        ? ('+${formatFcfa(r.cashIn)}', const Color(0xFF2E7D32))
        : r.cashOut != 0
        ? ('-${formatFcfa(r.cashOut)}', const Color(0xFFC62828))
        : r.others != 0
        ? ('${r.others > 0 ? '+' : ''}${formatFcfa(r.others)}', theme.colorScheme.primary)
        : ('', theme.colorScheme.onSurface);
    return ListTile(
      dense: true,
      leading: Icon(
        r.isClosure ? Icons.lock_outline : (r.nature.startsWith('Ouverture') ? Icons.lock_open_outlined : (r.cashOut != 0 || r.others < 0 ? Icons.call_made : Icons.call_received)),
        color: amount.$2,
      ),
      title: Text(r.nature),
      subtitle: Text([time, r.method, if (storeWide && r.terminal.isNotEmpty) r.terminal].join(' · ')),
      trailing: r.isClosure
          ? Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('Attendu ${r.expected == null ? '—' : formatFcfa(r.expected!)}', style: theme.textTheme.bodySmall),
                Text('Compté ${r.counted == null ? '—' : formatFcfa(r.counted!)}', style: theme.textTheme.bodySmall),
                if (r.difference != null)
                  Text('Écart ${r.difference! > 0 ? '+' : ''}${formatFcfa(r.difference!)}',
                      style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700, color: r.difference == 0 ? const Color(0xFF2E7D32) : const Color(0xFFC62828))),
              ],
            )
          : Text(amount.$1, style: TextStyle(color: amount.$2, fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()])),
    );
  }
}
