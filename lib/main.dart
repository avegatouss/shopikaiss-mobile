import 'package:flutter/material.dart';

import 'src/diagnostics.dart';
import 'src/settings/settings_page.dart';
import 'src/terminal/display_mode_page.dart';
import 'src/terminal/terminal_session.dart';
import 'src/web/caisse_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ErrorJournal.install();
  final session = await TerminalSession.start();
  runApp(ShopiKaissApp(session: session));
}

class ShopiKaissApp extends StatefulWidget {
  const ShopiKaissApp({super.key, required this.session});

  final TerminalSession session;

  @override
  State<ShopiKaissApp> createState() => _ShopiKaissAppState();
}

class _ShopiKaissAppState extends State<ShopiKaissApp> {
  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    return MaterialApp(
      title: 'ShopiKaiss',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF0F3E2E), useMaterial3: true),
      // Tablette afficheur (lot R-6) : la page de la caisse maîtresse du lieu, rien d'autre.
      home: session.settings.displayModeUrl.isNotEmpty
          ? DisplayModePage(session: session)
          : session.settings.configured
          ? CaissePage(session: session)
          : SettingsPage(session: session, firstRun: true, onDone: () => setState(() {})),
    );
  }
}
