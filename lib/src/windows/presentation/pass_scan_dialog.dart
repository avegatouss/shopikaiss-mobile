import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Display-only verdict. The shared engine owns normalization, quotas and sale
/// validation. A successful preview is not a reservation or a completed sale.
class PassScanVerdict {
  const PassScanVerdict({
    required this.allowed,
    this.passId,
    this.holder,
    this.reason,
    this.remainingToday,
    this.remainingTotal,
    required this.verifiedOnline,
  });

  final bool allowed;
  final String? passId;
  final String? holder;
  final String? reason;
  final int? remainingToday;
  final int? remainingTotal;
  final bool verifiedOnline;

  bool get selectable => allowed && passId != null && passId!.isNotEmpty;
}

/// Not connected to production until B delivers the shared engine commands.
/// Returns the selected preview only; never submits or retries a sale.
class PassScanDialog extends StatefulWidget {
  const PassScanDialog({
    super.key,
    required this.totalLabel,
    required this.manualEntryAllowed,
    required this.verify,
    this.verificationTimeout = const Duration(seconds: 20),
  });

  final String totalLabel;
  final bool manualEntryAllowed;
  final Future<PassScanVerdict> Function(String code) verify;
  final Duration verificationTimeout;

  @override
  State<PassScanDialog> createState() => _PassScanDialogState();
}

class _PassScanDialogState extends State<PassScanDialog> {
  final _input = TextEditingController();
  final _scannerFocus = FocusNode();
  String _scan = '';
  bool _discardScan = false;
  bool _busy = false;
  String? _error;
  PassScanVerdict? _verdict;

  @override
  void dispose() {
    _input.clear();
    _input.dispose();
    _scannerFocus.dispose();
    _scan = '';
    super.dispose();
  }

  void _invalidate() => setState(() {
    _verdict = null;
    _error = null;
  });

  KeyEventResult _onScannerKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (!_busy) {
        if (_discardScan) {
          _discardScan = false;
          _scan = '';
        } else {
          unawaited(_verify(_scan));
        }
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      if (!_busy) {
        _scan = '';
        _discardScan = false;
        _invalidate();
      }
      return KeyEventResult.handled;
    }
    final character = event.character;
    if (character == null ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        character.runes.any((r) => r < 32)) {
      return KeyEventResult.ignored;
    }
    if (!_busy) {
      if (_discardScan) return KeyEventResult.handled;
      if (_scan.length + character.length > 512) {
        _scan = '';
        _discardScan = true;
        setState(() {
          _verdict = null;
          _error = 'Code trop long. Scannez à nouveau le pass.';
        });
      } else {
        _scan += character;
        _invalidate();
      }
    }
    return KeyEventResult.handled;
  }

  Future<void> _verify(String code) async {
    if (_busy) return;
    if (code.trim().isEmpty || code.length > 512) {
      setState(() {
        _verdict = null;
        _error = 'Scannez un pass pour continuer.';
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _verdict = null;
    });
    _input.clear();
    _scan = '';
    try {
      final result = await widget
          .verify(code)
          .timeout(widget.verificationTimeout);
      if (!mounted) return;
      setState(() {
        if (result.allowed && !result.selectable) {
          _error = 'Réponse incomplète. Le pass ne peut pas être utilisé.';
        } else {
          _verdict = result;
        }
      });
    } on TimeoutException {
      if (mounted) {
        setState(
          () => _error =
              'Vérification sans réponse. Aucun passage enregistré. Réessayez.',
        );
      }
    } catch (_) {
      // Exceptions can contain a URL or a bearer code: never display them.
      if (mounted) {
        setState(
          () => _error =
              'Vérification indisponible. Aucun passage enregistré. Réessayez.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        if (!widget.manualEntryAllowed) _scannerFocus.requestFocus();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final verdict = _verdict;
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.qr_code_scanner),
          SizedBox(width: 12),
          Expanded(child: Text('Scanner le pass')),
        ],
      ),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Montant du panier', style: theme.textTheme.labelLarge),
              Text(widget.totalLabel, style: theme.textTheme.headlineMedium),
              const SizedBox(height: 16),
              const Text(
                'Présentez le QR code ou le code-barres à la douchette, puis validez avec Entrée.',
              ),
              const SizedBox(height: 12),
              if (widget.manualEntryAllowed)
                TextField(
                  controller: _input,
                  autofocus: true,
                  enabled: !_busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLength: 512,
                  decoration: const InputDecoration(
                    labelText: 'Code du pass',
                    hintText: 'Scannez ou saisissez le code',
                    counterText: '',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => _invalidate(),
                  onSubmitted: _verify,
                )
              else
                Focus(
                  focusNode: _scannerFocus,
                  autofocus: true,
                  onKeyEvent: _onScannerKey,
                  child: InkWell(
                    onTap: () => _scannerFocus.requestFocus(),
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: theme.colorScheme.outline),
                      ),
                      child: Text(
                        _scan.isEmpty
                            ? 'Douchette prête — cliquez ici pour reprendre le scan'
                            : 'Code reçu — validez avec Entrée',
                      ),
                    ),
                  ),
                ),
              if (_busy) ...[
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('Vérification du pass…'),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              ],
              if (verdict != null) ...[
                const SizedBox(height: 16),
                Semantics(
                  liveRegion: true,
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: verdict.allowed
                          ? theme.colorScheme.primaryContainer
                          : theme.colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          verdict.allowed ? 'Pass autorisé' : 'Pass refusé',
                          style: theme.textTheme.headlineSmall,
                        ),
                        if (verdict.holder?.isNotEmpty == true)
                          Text(
                            verdict.holder!,
                            style: theme.textTheme.titleMedium,
                          ),
                        if (!verdict.allowed)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              verdict.reason ??
                                  'Ce pass ne peut pas payer ce panier.',
                            ),
                          ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 24,
                          runSpacing: 8,
                          children: [
                            Text(
                              'Restants aujourd’hui : ${verdict.remainingToday ?? "Non indiqué"}',
                            ),
                            Text(
                              'Restants au total : ${verdict.remainingTotal ?? "Non indiqué"}',
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          verdict.verifiedOnline ? 'Vérifié en ligne' : 'Vérifié localement selon la politique de l’événement',
                        ),
                        if (verdict.allowed)
                          const Text(
                            'La vérification ne réserve pas de passage. La vente reste à confirmer.',
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        if (widget.manualEntryAllowed)
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _verify(_input.text),
            icon: const Icon(Icons.search),
            label: const Text('Vérifier le pass'),
          ),
        FilledButton.icon(
          onPressed: !_busy && verdict?.selectable == true
              ? () => Navigator.pop(context, verdict)
              : null,
          icon: const Icon(Icons.check),
          label: const Text('Utiliser ce pass'),
        ),
      ],
    );
  }
}
