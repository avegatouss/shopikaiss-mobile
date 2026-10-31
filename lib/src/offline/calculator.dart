import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'calculator_engine.dart';

class DeskCalculator extends StatefulWidget {
  const DeskCalculator({super.key});
  @override
  State<DeskCalculator> createState() => _DeskCalculatorState();
}

class _DeskCalculatorState extends State<DeskCalculator> {
  final input = TextEditingController();
  final focus = FocusNode();
  final history = <({String expression, String result})>[];
  String? error;
  String memory = '0';
  bool hasMemory = false, evaluated = false, showHistory = false;
  void key(String value) {
    setState(() {
      error = null;
      if (value == 'AC') {
        input.clear();
        evaluated = false;
        return;
      }
      if (value == '=') {
        try {
          final expression = input.text;
          final result = calculateExpression(expression);
          history.insert(0, (expression: expression, result: result));
          if (history.length > 20) history.removeLast();
          input.text = result;
          evaluated = true;
        } on FormatException catch (e) {
          error = e.message;
        }
        return;
      }
      if (value == 'MC') {
        memory = '0';
        hasMemory = false;
        return;
      }
      if (value == 'MR') {
        insert(memory);
        return;
      }
      if (value == 'M+' || value == 'M−') {
        try {
          final result = calculateExpression(input.text);
          memory = calculateExpression(
            '($memory)${value == 'M+' ? '+' : '-'}($result)',
          );
          hasMemory = true;
        } on FormatException catch (e) {
          error = e.message;
        }
        return;
      }
      if (value == '±') {
        if (input.text.isNotEmpty) input.text = '-(${input.text})';
        evaluated = false;
      } else if (value == '⌫') {
        final selection = input.selection;
        final end = selection.isValid ? selection.end : input.text.length;
        final start = selection.isValid && !selection.isCollapsed
            ? selection.start
            : end - 1;
        if (start >= 0) {
          input.text = input.text.replaceRange(start, end, '');
          input.selection = TextSelection.collapsed(offset: start);
        }
        evaluated = false;
      } else {
        insert(value);
      }
    });
    focus.requestFocus();
  }

  void insert(String text) {
    if (evaluated && !['+', '−', '×', '÷', '%'].contains(text)) input.clear();
    evaluated = false;
    final selection = input.selection;
    final start = selection.isValid ? selection.start : input.text.length;
    final end = selection.isValid ? selection.end : input.text.length;
    if (input.text.length - (end - start) + text.length > 256) return;
    input.text = input.text.replaceRange(start, end, text);
    input.selection = TextSelection.collapsed(offset: start + text.length);
  }

  @override
  void dispose() {
    input.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Row(
      children: [
        const Expanded(child: Text('Calculatrice')),
        IconButton(
          tooltip: 'Historique des calculs',
          onPressed: () => setState(() => showHistory = !showHistory),
          icon: Icon(showHistory ? Icons.calculate_outlined : Icons.history),
        ),
      ],
    ),
    scrollable: true,
    content: SizedBox(
      width: 400,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: input,
            focusNode: focus,
            autofocus: true,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 28),
            decoration: InputDecoration(
              labelText: 'Calcul',
              errorText: error,
              helperText: hasMemory
                  ? 'Mémoire : $memory'
                  : 'Priorités × ÷ · Entrée = résultat',
            ),
            keyboardType: TextInputType.text,
            maxLength: 256,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.,+\-*/()×÷−% ]')),
            ],
            onChanged: (_) => setState(() {
              evaluated = false;
              error = null;
            }),
            onSubmitted: (_) => key('='),
          ),
          if (showHistory)
            SizedBox(
              height: 180,
              child: history.isEmpty
                  ? const Center(child: Text('Aucun calcul effectué'))
                  : ListView(
                      children: [
                        for (final entry in history)
                          ListTile(
                            title: Text(entry.expression),
                            subtitle: Text('= ${entry.result}'),
                            trailing: const Icon(Icons.north_west),
                            onTap: () => setState(() {
                              input.text = entry.result;
                              evaluated = true;
                              showHistory = false;
                              error = null;
                            }),
                          ),
                      ],
                    ),
            ),
          for (final row in const [
            ['MC', 'MR', 'M+', 'M−'],
            ['AC', '⌫', '(', ')'],
            ['7', '8', '9', '÷'],
            ['4', '5', '6', '×'],
            ['1', '2', '3', '−'],
            ['±', '0', ',', '+'],
            ['%', '='],
          ])
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  for (final value in row)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: SizedBox(
                          height: 48,
                          child: value == '='
                              ? FilledButton(
                                  onPressed: () => key(value),
                                  child: const Text(
                                    '=',
                                    style: TextStyle(fontSize: 24),
                                  ),
                                )
                              : OutlinedButton(
                                  onPressed: () => key(value),
                                  child: Text(
                                    value,
                                    style: const TextStyle(fontSize: 20),
                                  ),
                                ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Clipboard.setData(ClipboardData(text: input.text)),
        child: const Text('Copier'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Fermer'),
      ),
    ],
  );
}
