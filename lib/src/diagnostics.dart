import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'terminal/terminal_session.dart';

/// Journal des erreurs Dart de l'application (20 dernières), gardé sur le terminal et montré dans Réglages › Diagnostic.
/// Les pannes natives (manque de mémoire, exception Java) sont écrites à part par CrashLog (Kotlin).
class ErrorJournal {
  ErrorJournal._();

  static const _key = 'journalErreurs';
  static const _max = 20;

  /// Branche la collecte : erreurs du cadre Flutter et erreurs asynchrones non rattrapées.
  static void install() {
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      record(details.exceptionAsString(), details.stack);
      previous?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      record('$error', stack);
      return true;
    };
  }

  static Future<void> record(String error, [StackTrace? stack]) async {
    try {
      final p = await SharedPreferences.getInstance();
      final list = p.getStringList(_key) ?? <String>[];
      final lines = (stack?.toString() ?? '').split('\n').take(8).join('\n');
      list.insert(0, '${DateTime.now().toIso8601String().substring(0, 19)} — $error\n$lines');
      await p.setStringList(_key, list.take(_max).toList());
    } catch (_) {}
  }

  static Future<List<String>> entries() async => (await SharedPreferences.getInstance()).getStringList(_key) ?? const [];

  static Future<void> clear() async => (await SharedPreferences.getInstance()).remove(_key);
}

/// Réglages › Diagnostic : dernière panne native et erreurs récentes, à copier pour l'assistance.
class DiagnosticsSection extends StatefulWidget {
  const DiagnosticsSection({super.key, required this.session});

  final TerminalSession session;

  @override
  State<DiagnosticsSection> createState() => _DiagnosticsSectionState();
}

class _DiagnosticsSectionState extends State<DiagnosticsSection> {
  String? _crash;
  List<String> _errors = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final crash = await widget.session.channel.lastCrash();
    final errors = await ErrorJournal.entries();
    if (mounted) setState(() => (_crash = crash, _errors = errors));
  }

  @override
  Widget build(BuildContext context) {
    final report = [if (_crash != null) 'PANNE NATIVE\n$_crash', ..._errors].join('\n\n────────\n\n');
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Diagnostic', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                _crash == null && _errors.isEmpty
                    ? 'Aucune panne ni erreur enregistrée sur ce terminal.'
                    : '${_crash != null ? 'Dernière fermeture inattendue enregistrée. ' : ''}${_errors.length} erreur(s) récente(s).',
              ),
              if (report.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  constraints: const BoxConstraints(maxHeight: 220),
                  padding: const EdgeInsets.all(8),
                  color: const Color(0xFFF3F4F6),
                  child: SingleChildScrollView(child: SelectableText(report, style: const TextStyle(fontFamily: 'monospace', fontSize: 11))),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: report));
                        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Diagnostic copié.')));
                      },
                      icon: const Icon(Icons.copy),
                      label: const Text('Copier'),
                    ),
                    TextButton(
                      onPressed: () async {
                        await widget.session.channel.clearCrash();
                        await ErrorJournal.clear();
                        await _load();
                      },
                      child: const Text('Effacer'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
