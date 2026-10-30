import 'package:flutter/material.dart';

/// Independent desk calculator: never modifies the sale or its amounts.
class DeskCalculator extends StatefulWidget {
  const DeskCalculator({super.key});
  @override
  State<DeskCalculator> createState() => _DeskCalculatorState();
}

class _DeskCalculatorState extends State<DeskCalculator> {
  final first = TextEditingController();
  final second = TextEditingController();
  String operation = '+';
  String get result {
    final a = double.tryParse(first.text.replaceAll(',', '.'));
    final b = double.tryParse(second.text.replaceAll(',', '.'));
    if (a == null || b == null) return 'Saisissez deux nombres';
    if (operation == '/' && b == 0) return 'Division par zéro impossible';
    final value = switch (operation) {
      '+' => a + b,
      '-' => a - b,
      '*' => a * b,
      _ => a / b,
    };
    if (!value.isFinite) return 'Résultat hors limites';
    return value
        .toStringAsFixed(8)
        .replaceFirst(RegExp(r'\.?0+$'), '')
        .replaceAll('.', ',');
  }

  @override
  void dispose() {
    first.dispose();
    second.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Calculatrice'),
    content: SizedBox(
      width: 350,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: first,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
            decoration: const InputDecoration(labelText: 'Premier nombre'),
            onChanged: (_) => setState(() {}),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: '+', label: Text('+')),
                ButtonSegment(value: '-', label: Text('−')),
                ButtonSegment(value: '*', label: Text('×')),
                ButtonSegment(value: '/', label: Text('÷')),
              ],
              selected: {operation},
              onSelectionChanged: (v) => setState(() => operation = v.single),
            ),
          ),
          TextField(
            controller: second,
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
            decoration: const InputDecoration(labelText: 'Deuxième nombre'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          SelectableText(result, style: const TextStyle(fontSize: 24)),
          const Text('Calcul libre, sans modification du panier.'),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => setState(() {
          first.clear();
          second.clear();
        }),
        child: const Text('Effacer'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Fermer'),
      ),
    ],
  );
}
