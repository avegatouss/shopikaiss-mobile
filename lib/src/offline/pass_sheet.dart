import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'caisse_engine.dart';
import 'models.dart';
import 'money.dart';

/// Feuille « Scanner le pass » (Android) : douchette, caméra, et saisie quand la boutique l'autorise. Le verdict est
/// affiché en grand avec le porteur et les passages restants ; « Encaisser par pass » rend les passes retenus.
///
/// Le code scanné n'est jamais conservé ni réaffiché : il part au moteur, qui ne garde que la clé du pass.
class PassSheet extends StatefulWidget {
  const PassSheet({super.key, required this.payable, required this.settings, required this.verify, required this.brand, this.fullScreen = false});

  final int payable;
  final PassSettings settings;
  final Future<PassCheck> Function(String code, List<PassCheck> already) verify;
  final Color brand;
  final bool fullScreen;

  @override
  State<PassSheet> createState() => _PassSheetState();
}

class _PassSheetState extends State<PassSheet> {
  final _code = TextEditingController();
  final _focus = FocusNode();
  final _passes = <PassCheck>[];
  bool _busy = false;
  String? _refusal;
  PassCheck? _accepted;

  @override
  void dispose() {
    _code.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _full => !widget.settings.severalPerSale && _passes.isNotEmpty;

  Future<void> _verify(String code) async {
    _code.clear();
    if (_busy || code.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _refusal = null;
      _accepted = null;
    });
    try {
      final check = await widget.verify(code, List.of(_passes));
      if (!mounted) return;
      setState(() {
        _passes.add(check);
        _accepted = check;
      });
    } on OfflineRefusal catch (e) {
      if (mounted) setState(() => _refusal = e.message);
    } catch (_) {
      // Une exception peut porter une adresse ou le code : jamais affichée.
      if (mounted) setState(() => _refusal = 'Vérification indisponible. Aucun passage enregistré. Réessayez.');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _focus.requestFocus();
      }
    }
  }

  Future<void> _camera() async {
    final code = await Navigator.of(context).push<String>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const _PassCamera()));
    if (code != null && mounted) await _verify(code);
  }

  String _left(int? n) => n == null ? 'sans limite' : '$n';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shares = _passes.isEmpty ? const <int>[] : _split(widget.payable, _passes.length);
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('À débiter sur le pass', style: theme.textTheme.labelLarge)),
            Text(formatFcfa(widget.payable), style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold, color: widget.brand)),
          ],
        ),
        const SizedBox(height: 16),
        if (!_full) ...[
          TextField(
            controller: _code,
            focusNode: _focus,
            autofocus: true,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            // Sans saisie manuelle : aucun clavier à l'écran, seule la douchette (clavier matériel) écrit ici.
            keyboardType: widget.settings.manualEntry ? TextInputType.visiblePassword : TextInputType.none,
            showCursor: widget.settings.manualEntry,
            obscureText: !widget.settings.manualEntry,
            enableInteractiveSelection: widget.settings.manualEntry,
            textCapitalization: TextCapitalization.characters,
            maxLength: 120,
            decoration: InputDecoration(
              labelText: widget.settings.manualEntry ? 'Code du pass' : 'Douchette prête',
              hintText: widget.settings.manualEntry ? 'Scannez ou saisissez le code' : 'Présentez le pass à la douchette',
              prefixIcon: const Icon(Icons.qr_code_2),
              counterText: '',
              border: const OutlineInputBorder(),
            ),
            onSubmitted: _verify,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _camera,
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: const Text('Caméra'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                ),
              ),
              if (widget.settings.manualEntry) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _busy ? null : () => _verify(_code.text),
                    icon: const Icon(Icons.search),
                    label: const Text('Vérifier'),
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                  ),
                ),
              ],
            ],
          ),
        ],
        if (_busy) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
          const Padding(padding: EdgeInsets.only(top: 8), child: Text('Vérification du pass…')),
        ],
        if (_refusal != null) _Verdict(ok: false, title: 'Pass refusé', lines: [_refusal!]),
        if (_accepted != null)
          _Verdict(
            ok: true,
            title: 'Pass accepté',
            subtitle: _accepted!.holder,
            lines: [
              'Restants aujourd’hui : ${_left(_accepted!.leftToday)} · au total : ${_left(_accepted!.leftTotal)}',
              _accepted!.online ? 'Vérifié en ligne' : 'Vérifié sans connexion, selon les règles de l’événement',
            ],
          ),
        if (_passes.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(_passes.length > 1 ? 'Passes de la vente' : 'Pass de la vente', style: theme.textTheme.titleSmall),
          for (var i = 0; i < _passes.length; i++)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(_passes[i].online ? Icons.verified : Icons.offline_pin, color: widget.brand),
              title: Text(_passes[i].holder ?? 'Pass sans porteur'),
              subtitle: Text(_passes[i].online ? 'Vérifié en ligne' : 'Vérifié sans connexion'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(formatFcfa(shares[i]), style: const TextStyle(fontWeight: FontWeight.w600)),
                  IconButton(
                    tooltip: 'Retirer ce pass',
                    icon: const Icon(Icons.close),
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _passes.removeAt(i);
                            _accepted = null;
                          }),
                  ),
                ],
              ),
            ),
        ],
        const SizedBox(height: 8),
        Text(
          'La vérification ne réserve rien : le passage est enregistré à l’encaissement.',
          style: theme.textTheme.bodySmall?.copyWith(color: Colors.black54),
        ),
      ],
    );
    final pay = FilledButton.icon(
      style: FilledButton.styleFrom(backgroundColor: widget.brand, minimumSize: const Size(0, 52)),
      onPressed: _busy || _passes.isEmpty ? null : () => Navigator.pop(context, List.of(_passes)),
      icon: const Icon(Icons.confirmation_number_outlined),
      label: const Text('Encaisser par pass'),
    );
    if (widget.fullScreen) {
      return Scaffold(
        appBar: AppBar(title: const Text('Scanner le pass')),
        body: SafeArea(child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: body)),
        bottomNavigationBar: SafeArea(child: Padding(padding: const EdgeInsets.all(16), child: pay)),
      );
    }
    return AlertDialog(
      title: const Row(children: [Icon(Icons.qr_code_scanner), SizedBox(width: 12), Expanded(child: Text('Scanner le pass'))]),
      content: SizedBox(width: 480, child: SingleChildScrollView(child: body)),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')), pay],
    );
  }

  /// Même répartition que le moteur : le reste au premier pass.
  static List<int> _split(int total, int n) => [for (var i = 0; i < n; i++) total ~/ n + (i == 0 ? total - (total ~/ n) * n : 0)];
}

class _Verdict extends StatelessWidget {
  const _Verdict({required this.ok, required this.title, this.subtitle, required this.lines});

  final bool ok;
  final String title;
  final String? subtitle;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final color = ok ? Colors.green.shade700 : Colors.red.shade700;
    return Semantics(
      liveRegion: true,
      child: Container(
        margin: const EdgeInsets.only(top: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: (ok ? Colors.green : Colors.red).shade50,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(ok ? Icons.check_circle : Icons.cancel, color: color, size: 40),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color)),
                  if (subtitle != null && subtitle!.isNotEmpty) Text(subtitle!, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  for (final line in lines) Padding(padding: const EdgeInsets.only(top: 4), child: Text(line)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Lecture d'un QR code ou d'un code-barres à la caméra : rend le premier code lu.
class _PassCamera extends StatefulWidget {
  const _PassCamera();

  @override
  State<_PassCamera> createState() => _PassCameraState();
}

class _PassCameraState extends State<_PassCamera> {
  final _controller = MobileScannerController(detectionSpeed: DetectionSpeed.noDuplicates);
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: const Text('Caméra'), backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: Stack(
        alignment: Alignment.center,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: (capture) {
              final code = capture.barcodes.map((b) => b.rawValue).whereType<String>().where((v) => v.trim().isNotEmpty).firstOrNull;
              if (code == null || _done) return;
              _done = true;
              Navigator.pop(context, code);
            },
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  error.errorCode == MobileScannerErrorCode.permissionDenied
                      ? 'Autorisez la caméra dans les réglages du téléphone pour scanner les passes.'
                      : 'Caméra indisponible : utilisez la douchette ou la saisie.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
          IgnorePointer(
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(border: Border.all(color: Colors.white, width: 3), borderRadius: BorderRadius.circular(20)),
            ),
          ),
          const Positioned(
            bottom: 32,
            child: Text('Placez le QR code ou le code-barres dans le cadre', style: TextStyle(color: Colors.white, fontSize: 16)),
          ),
        ],
      ),
    );
  }
}
