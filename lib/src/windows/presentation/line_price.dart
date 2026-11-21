import 'package:flutter/material.dart';

import '../ipc/protocol.dart';
import 'register_controller.dart';

/// Prices and permissions come exclusively from the shared engine projection.
class LinePriceButton extends StatelessWidget {
  const LinePriceButton({
    super.key,
    required this.controller,
    required this.line,
  });
  final WindowsRegisterController controller;
  final Map<String, dynamic> line;

  @override
  Widget build(BuildContext context) {
    final editable = line['price_editable'] == true;
    final entered = line['entered_price'] != null;
    if (!editable && !entered) return const SizedBox.shrink();
    return TextButton.icon(
      style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
      icon: const Icon(Icons.edit_outlined, size: 16),
      label: Text('Prix unitaire : ${line['unit_price_label'] ?? ''}'),
      onPressed:
          controller.ready &&
              !controller.busy &&
              controller.uncertainOperation == null
          ? () => showDialog<void>(
              context: context,
              builder: (_) =>
                  _LinePriceDialog(controller: controller, line: line),
            )
          : null,
    );
  }
}

class _LinePriceDialog extends StatefulWidget {
  const _LinePriceDialog({required this.controller, required this.line});
  final WindowsRegisterController controller;
  final Map<String, dynamic> line;

  @override
  State<_LinePriceDialog> createState() => _LinePriceDialogState();
}

class _LinePriceDialogState extends State<_LinePriceDialog> {
  late final _input = TextEditingController(
    text: widget.line['entered_price']?.toString() ?? '',
  );
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _save({bool reset = false}) async {
    if (_saving) return;
    final text = reset ? '' : _input.text.trim();
    final amount = text.isEmpty ? null : int.tryParse(text);
    if (text.isNotEmpty &&
        (amount == null || amount < 0 || amount > 1000000000)) {
      setState(
        () => _error =
            'Saisissez un entier de 0 à 1 000 000 000 F CFA, ou laissez vide.',
      );
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await widget.controller.command(HostCommand.setLinePrice, {
      'line_id': widget.line['id'],
      'amount': amount,
    });
    if (!mounted) return;
    if (result != null) {
      Navigator.pop(context);
    } else {
      setState(() {
        _saving = false;
        _error =
            widget.controller.message ?? 'Le prix n’a pas pu être modifié.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final editable = widget.line['price_editable'] == true;
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        scrollable: true,
        title: const Text('Prix unitaire'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${widget.line['name'] ?? ''}'),
              const SizedBox(height: 12),
              if (editable)
                TextField(
                  controller: _input,
                  enabled: !_saving,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Prix unitaire (F CFA)',
                    helperText:
                        'Vide : prix habituel ${widget.line['usual_price_label'] ?? ''}',
                    helperMaxLines: 2,
                  ),
                  onSubmitted: (_) => _save(),
                )
              else
                Text(
                  '${widget.line['price_edit_reason'] ?? 'Modification du prix non autorisée.'} Vous pouvez retirer le prix saisi.',
                ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: _saving ? null : () => _save(reset: true),
            child: const Text('Prix habituel'),
          ),
          if (editable)
            FilledButton(
              onPressed: _saving ? null : () => _save(),
              child: Text(_saving ? 'Application…' : 'Appliquer'),
            ),
        ],
      ),
    );
  }
}
