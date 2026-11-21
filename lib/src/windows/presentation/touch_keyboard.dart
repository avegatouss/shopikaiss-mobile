import 'package:flutter/material.dart';

/// Application keyboard, including dialogs; never sends keystrokes to Windows.
class TouchKeyboard extends StatefulWidget {
  const TouchKeyboard({super.key, required this.child});
  final Widget child;
  @override
  State<TouchKeyboard> createState() => _TouchKeyboardState();
}

class _TouchKeyboardState extends State<TouchKeyboard> {
  EditableTextState? editor;
  bool upper = false;
  bool? numericOverride;
  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(changed);
  }

  void changed() {
    final focus = FocusManager.instance.primaryFocus;
    final state = focus?.context?.findAncestorStateOfType<EditableTextState>();
    final eligible =
        state != null &&
        !state.widget.readOnly &&
        state.widget.keyboardType != TextInputType.none &&
        !['barcode', 'calculator'].contains(focus?.debugLabel);
    if (mounted) {
      setState(() {
        final next = eligible ? state : null;
        if (editor != next) numericOverride = null;
        editor = next;
      });
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(changed);
    super.dispose();
  }

  void key(String key) {
    final target = editor;
    if (target == null || !target.mounted) return;
    if (key == '123' || key == 'ABC') {
      setState(() => numericOverride = key == '123');
      return;
    }
    if (key == 'Fermer') {
      setState(() => editor = null);
      return;
    }
    if (key == 'Maj') {
      setState(() => upper = !upper);
      return;
    }
    if (key == 'Entrée') {
      target.performAction(
        target.widget.textInputAction ?? TextInputAction.done,
      );
      return;
    }
    if (key == 'Effacer') {
      target.userUpdateTextEditingValue(
        const TextEditingValue(
          text: '',
          selection: TextSelection.collapsed(offset: 0),
        ),
        SelectionChangedCause.keyboard,
      );
      return;
    }
    final value = target.widget.controller.value;
    final selection = value.selection;
    var start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    var text = key == 'Espace' ? ' ' : (upper ? key.toUpperCase() : key);
    if (key == '⌫') {
      text = '';
      if (start == end && start > 0) {
        start -= value.text.substring(0, start).characters.last.length;
      }
    }
    target.userUpdateTextEditingValue(
      TextEditingValue(
        text: value.text.replaceRange(start, end, text),
        selection: TextSelection.collapsed(offset: start + text.length),
      ),
      SelectionChangedCause.keyboard,
    );
  }

  @override
  Widget build(BuildContext context) {
    final type = editor?.widget.keyboardType;
    final numeric =
        numericOverride ??
        (type == TextInputType.number ||
            type == TextInputType.phone ||
            type?.index == TextInputType.number.index);
    return Column(
      children: [
        Expanded(
          child: Listener(
            onPointerUp: (_) =>
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) changed();
                }),
            child: widget.child,
          ),
        ),
        if (editor != null)
          Align(
            alignment: Alignment.centerRight,
            child: SizedBox(
              width: numeric ? 360 : double.infinity,
              child: Material(
                elevation: 8,
                color: const Color(0xffedf2ef),
                child: SafeArea(
                  top: false,
                  child: Focus(
                    canRequestFocus: false,
                    descendantsAreFocusable: false,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (numeric)
                            Row(
                              children: [
                                const Expanded(
                                  child: Padding(
                                    padding: EdgeInsets.only(left: 8),
                                    child: Text(
                                      'Pavé numérique',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                                TextButton(
                                  onPressed: () => key('ABC'),
                                  child: const Text('ABC'),
                                ),
                                TextButton(
                                  onPressed: () => key('Fermer'),
                                  child: const Text('Fermer'),
                                ),
                              ],
                            ),
                          for (final row
                              in numeric
                                  ? [
                                      ['7', '8', '9', '⌫'],
                                      ['4', '5', '6', 'Effacer'],
                                      ['1', '2', '3', 'Entrée'],
                                      ['0', '00', ',', '.'],
                                    ]
                                  : [
                                      '1234567890'.split(''),
                                      'azertyuiop'.split(''),
                                      'qsdfghjklm'.split(''),
                                      ['Maj', ...'wxcvbn'.split(''), '⌫'],
                                      [
                                        'é',
                                        'è',
                                        "'",
                                        '@',
                                        '.',
                                        ',',
                                        '-',
                                        'Espace',
                                        '123',
                                        'Entrée',
                                        'Fermer',
                                      ],
                                    ])
                            Row(
                              children: [
                                for (final value in row)
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.all(2),
                                      child: SizedBox(
                                        height: numeric ? 48 : 42,
                                        child: OutlinedButton(
                                          style: OutlinedButton.styleFrom(
                                            padding: EdgeInsets.zero,
                                            backgroundColor:
                                                numeric && value == 'Entrée'
                                                ? Theme.of(context)
                                                      .colorScheme
                                                      .primary
                                                : Colors.white,
                                            foregroundColor:
                                                numeric && value == 'Entrée'
                                                ? Colors.white
                                                : null,
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                          ),
                                          onPressed: () => key(value),
                                          child: Text(
                                            upper && value.length == 1
                                                ? value.toUpperCase()
                                                : value,
                                            style: TextStyle(
                                              fontSize:
                                                  numeric && value.length <= 2
                                                  ? 22
                                                  : 14,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
