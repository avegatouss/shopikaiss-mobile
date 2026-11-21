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

  Widget _button(BuildContext context, String value, {double height = 48}) =>
      Padding(
        padding: const EdgeInsets.all(2),
        child: SizedBox(
          height: height,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              padding: EdgeInsets.zero,
              backgroundColor: value == 'Entrée'
                  ? Theme.of(context).colorScheme.primary
                  : Colors.white,
              foregroundColor: value == 'Entrée' ? Colors.white : null,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: () => key(value),
            child: Text(
              upper && value.length == 1 ? value.toUpperCase() : value,
              style: TextStyle(fontSize: value.length == 1 ? 20 : 14),
            ),
          ),
        ),
      );

  Widget _row(
    BuildContext context,
    List<String> values, {
    double height = 48,
  }) => Row(
    children: [
      for (final value in values)
        Expanded(child: _button(context, value, height: height)),
    ],
  );

  @override
  Widget build(BuildContext context) {
    const keyboardHeight = 268.0;
    final visible = editor != null;
    return Stack(
      children: [
        Positioned.fill(
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              viewInsets: MediaQuery.of(context).viewInsets
                  .copyWith(bottom: visible ? keyboardHeight : 0),
            ),
            child: Listener(
              onPointerUp: (_) =>
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) changed();
                  }),
              child: widget.child,
            ),
          ),
        ),
        if (visible)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: keyboardHeight,
            child: TextFieldTapRegion(
              child: Material(
                elevation: 8,
                color: const Color(0xffedf2ef),
                child: Focus(
                  canRequestFocus: false,
                  descendantsAreFocusable: false,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final padWidth = (constraints.maxWidth * .32).clamp(
                        240.0,
                        340.0,
                      );
                      return Padding(
                        padding: const EdgeInsets.all(4),
                        child: Column(
                          children: [
                            SizedBox(
                              height: 32,
                              child: Row(
                                children: [
                                  const Expanded(
                                    child: Padding(
                                      padding: EdgeInsets.only(left: 8),
                                      child: Text(
                                        'Clavier',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const Text('Pavé numérique'),
                                  TextButton(
                                    onPressed: () => key('Fermer'),
                                    child: const Text('Fermer'),
                                  ),
                                ],
                              ),
                            ),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    children: [
                                      _row(
                                        context,
                                        'azertyuiop'.split(''),
                                        height: 40,
                                      ),
                                      _row(
                                        context,
                                        'qsdfghjklm'.split(''),
                                        height: 40,
                                      ),
                                      _row(context, [
                                        'Maj',
                                        ...'wxcvbn'.split(''),
                                        'é',
                                        'è',
                                        "'",
                                      ], height: 40),
                                      _row(context, [
                                        '@',
                                        '.',
                                        '-',
                                        '/',
                                        '(',
                                        ')',
                                        '?',
                                        '!',
                                        ':',
                                      ], height: 40),
                                      _row(context, ['Espace'], height: 40),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                SizedBox(
                                  width: padWidth,
                                  child: Column(
                                    children: [
                                      _row(context, [
                                        '7',
                                        '8',
                                        '9',
                                        '⌫',
                                      ], height: 51),
                                      _row(context, [
                                        '4',
                                        '5',
                                        '6',
                                        'Effacer',
                                      ], height: 51),
                                      Row(
                                        children: [
                                          Expanded(
                                            flex: 3,
                                            child: Column(
                                              children: [
                                                _row(context, [
                                                  '1',
                                                  '2',
                                                  '3',
                                                ], height: 51),
                                                _row(context, [
                                                  '0',
                                                  '00',
                                                  ',',
                                                ], height: 51),
                                              ],
                                            ),
                                          ),
                                          Expanded(
                                            child: _button(
                                              context,
                                              'Entrée',
                                              height: 106,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
