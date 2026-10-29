import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../ipc/process_host.dart';
import '../ipc/protocol.dart';
import '../ipc/supervised_host.dart';
import '../platform/sale_intent.dart';
import 'register_app.dart';
import 'register_controller.dart';

/// Explicit integration build only. No path received from the server is run.
class WindowsBootstrap extends StatefulWidget {
  const WindowsBootstrap({super.key});
  @override
  State<WindowsBootstrap> createState() => _WindowsBootstrapState();
}

class _WindowsBootstrapState extends State<WindowsBootstrap> {
  SupervisedWindowsHost? host;
  WindowsRegisterController? controller;
  final origin = TextEditingController();
  final code = TextEditingController();
  final pin = TextEditingController();
  Map<String, dynamic> status = {};
  int? operatorId;
  bool busy = false;
  bool entered = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _run(_connect);
  }

  Future<void> _verify(String file, String expected) async {
    if (expected.length != 64 ||
        (await sha256.bind(File(file).openRead()).first).toString() !=
            expected.toLowerCase()) {
      throw const HostFailure(
        'bundle',
        'Moteur absent ou différent du build validé.',
      );
    }
  }

  Future<void> _connect() async {
    if (host == null) {
      final local = Platform.environment['LOCALAPPDATA'];
      if (local == null || !p.isAbsolute(local)) {
        throw StateError('LocalAppData');
      }
      // Same default as EngineHost; this directory must not be changed to
      // bypass an unresolved intent or an existing engine lock.
      final data = p.join(local, 'ShopiKaiss', 'caisse');
      final bundle = p.join(p.dirname(Platform.resolvedExecutable), 'moteur');
      final exe = p.join(bundle, 'bin', 'shopikaiss_moteur.exe');
      host = SupervisedWindowsHost(() async {
        await _verify(
          exe,
          const String.fromEnvironment('SHOPIKAISS_ENGINE_SHA256'),
        );
        await _verify(
          p.join(bundle, 'lib', 'sqlite3.dll'),
          const String.fromEnvironment('SHOPIKAISS_SQLITE_SHA256'),
        );
        return ProcessWindowsHost.start(
          exe,
          arguments: ['--dossier', data, '--version', 'windows-integration'],
          timeout: const Duration(seconds: 45),
        );
      });
      controller = WindowsRegisterController(
        host!,
        journal: SaleIntentJournal(File(p.join(data, 'pending-sale.json'))),
      );
      await controller!.recoverIntent();
    }
    await host!.connect();
    await _status();
  }

  Future<void> _status() async {
    status = await host!.call(HostCommand.status);
    if (controller!.uncertainOperation != null) await controller!.reconcile();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } on HostFailure catch (e) {
      error = e.message;
    } catch (_) {
      error =
          'Mise en service impossible. Vérifiez le moteur et le journal local.';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    controller?.dispose();
    // OS EOF on window termination also drains the host queue before closing.
    host?.close().catchError((Object _) {});
    origin.dispose();
    code.dispose();
    pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (entered) {
      return WindowsRegisterApp(
        controller: controller,
        onConnection: () {
          setState(() => entered = false);
          _run(_connect);
        },
      );
    }
    final operators = (status['operators'] as List? ?? []).whereType<Map>();
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Shopikaiss Windows · Recette')),
        body: Center(
          child: SingleChildScrollView(
            child: SizedBox(
              width: 480,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Mise en service de la caisse',
                      style: TextStyle(fontSize: 24),
                    ),
                    const SizedBox(height: 16),
                    if (error != null) Text(error!),
                    if (controller?.message != null) Text(controller!.message!),
                    if (status['block_reason'] != null)
                      Text('${status['block_reason']}'),
                    if (busy) const LinearProgressIndicator(),
                    if (status['paired'] == false) ...[
                      TextField(
                        controller: origin,
                        decoration: const InputDecoration(
                          labelText: 'Adresse du serveur HTTPS',
                        ),
                      ),
                      TextField(
                        controller: code,
                        decoration: const InputDecoration(
                          labelText: "Code d’appairage",
                        ),
                      ),
                      FilledButton(
                        onPressed: busy
                            ? null
                            : () => _run(() async {
                                final uri = Uri.tryParse(origin.text.trim());
                                if (uri == null ||
                                    uri.scheme != 'https' ||
                                    uri.host.isEmpty ||
                                    uri.userInfo.isNotEmpty) {
                                  throw const HostFailure(
                                    'origin',
                                    'Saisissez une adresse HTTPS valide.',
                                  );
                                }
                                await host!.call(
                                  HostCommand.pair,
                                  arguments: {
                                    'origin': origin.text.trim(),
                                    'code': code.text.trim(),
                                    'model': 'Windows',
                                    'app_version': 'windows-integration',
                                  },
                                );
                                code.clear();
                                await _status();
                              }),
                        child: const Text('Appairer cette caisse'),
                      ),
                    ],
                    if (status['paired'] == true) ...[
                      DropdownButton<int>(
                        value: operatorId,
                        isExpanded: true,
                        hint: const Text('Choisir le caissier'),
                        items: [
                          for (final o in operators)
                            DropdownMenuItem<int>(
                              value: o['id'] as int,
                              child: Text('${o['name']}'),
                            ),
                        ],
                        onChanged: busy
                            ? null
                            : (v) => setState(() => operatorId = v),
                      ),
                      TextField(
                        controller: pin,
                        obscureText: true,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'PIN'),
                      ),
                      FilledButton(
                        onPressed: busy || operatorId == null
                            ? null
                            : () => _run(() async {
                                try {
                                  await host!.call(
                                    HostCommand.login,
                                    arguments: {
                                      'operator_id': operatorId,
                                      'pin': pin.text,
                                    },
                                  );
                                } finally {
                                  pin.clear();
                                }
                                await _status();
                                await controller!.refresh();
                                entered = true;
                              }),
                        child: const Text('Ouvrir la caisse'),
                      ),
                      if (status['session_open'] != true)
                        const Text(
                          'Ouvrez une session de caisse depuis un terminal compatible. L’ouverture depuis Windows reste à intégrer.',
                        ),
                    ],
                    TextButton(
                      onPressed: busy ? null : () => _run(_connect),
                      child: const Text('Reconnexion / vérifier'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
