import 'dart:io';
import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../ipc/process_host.dart';
import '../ipc/protocol.dart';
import '../ipc/supervised_host.dart';
import '../platform/sale_intent.dart';
import '../platform/site_profiles.dart';
import '../platform/production_queue.dart';
import '../platform/receipt_printing.dart';
import 'register_app.dart';
import 'brand_logo.dart';
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
  ProductionQueue? productionQueue;
  final origin = TextEditingController();
  final code = TextEditingController();
  final pin = TextEditingController();
  final openingFloat = TextEditingController(text: '0');
  Map<String, dynamic> status = {};
  int? operatorId;
  bool busy = false;
  bool entered = false;
  String? error;
  SiteProfiles? profiles;

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
      if (profiles == null) {
        final saved = SiteProfiles(p.join(local, 'ShopiKaiss'));
        await saved.load();
        profiles = saved;
      }
      final data = profiles!.dataDirectory;
      // A v1 intent must never be reconciled as "not found" by a v2-only
      // lookup. Keep it intact and require its resolution with the old host.
      if (await File(p.join(data, 'pending-sale.json')).exists()) {
        throw const HostFailure(
          'legacy_intent',
          'Un encaissement de l’ancienne caisse reste à vérifier. Reprenez l’ancienne version pour le résoudre avant le passage en v2. Ne supprimez pas son journal.',
        );
      }
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
          arguments: [
            '--dossier',
            data,
            '--version',
            'windows-integration',
            '--paper-width',
            '${await ReceiptPrinting.paperWidth()}',
          ],
          timeout: const Duration(seconds: 45),
        );
      });
      controller = WindowsRegisterController(
        host!,
        journal: SaleIntentJournal(File(p.join(data, 'pending-sale-v2.json'))),
      );
      await controller!.recoverIntent();
    }
    await host!.connect();
    productionQueue ??= ProductionQueue(
      host!,
      send: ReceiptPrinting.printProduction,
      journal: File(
        p.join(profiles!.dataDirectory, 'production-results-v1.json'),
      ),
      onStatus: controller!.productionStatus,
    )..start();
    await productionQueue!.drain();
    await _status();
  }

  Future<void> _status() async {
    status = await host!.call(HostCommand.status);
    if (status['web_origin'] is String) {
      await profiles?.labelOrigin(
        status['web_origin'] as String,
        terminal: status['terminal_name'] as String?,
      );
    }
    if (controller!.uncertainOperation != null) await controller!.reconcile();
  }

  Future<void> _chooseSite(BuildContext dialogContext) async {
    if (busy || profiles == null) return;
    final selected = await showDialog<String>(
      context: dialogContext,
      builder: (context) => SimpleDialog(
        title: const Text('Choisir une connexion'),
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Chaque connexion conserve son appairage, ses ventes et ses paniers. Aucun dossier de caisse n’est supprimé.',
            ),
          ),
          for (final entry in profiles!.names.entries)
            SimpleDialogOption(
              onPressed: entry.key == profiles!.active
                  ? null
                  : () => Navigator.pop(context, entry.key),
              child: Text(
                '${entry.value}${entry.key == profiles!.active ? ' · actuelle' : ''}',
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'new'),
            child: const Text('+ Connecter un autre site / terminal'),
          ),
        ],
      ),
    );
    if (!mounted || selected == null) return;
    await _run(() async {
      final currentStatus = await host!.call(HostCommand.status);
      final view = await host!.call(HostCommand.view);
      final blocked = siteSwitchRefusal(
        currentStatus,
        view,
        uncertain:
            controller!.uncertainOperation != null ||
            await hasUnresolvedSiteIntent(profiles!.dataDirectory),
      );
      if (blocked != null) throw HostFailure('site_switch_refused', blocked);
      // Complete normal engine shutdown before changing the active directory.
      await productionQueue?.close();
      productionQueue = null;
      await host!.close();
      controller?.dispose();
      controller = null;
      host = null;
      try {
        if (await hasUnresolvedSiteIntent(profiles!.dataDirectory)) {
          throw const HostFailure(
            'site_switch_refused',
            'Une opération reste à vérifier sur cette connexion.',
          );
        }
        await profiles!.select(selected == 'new' ? null : selected);
      } catch (_) {
        await _connect();
        rethrow;
      }
      status = {};
      operatorId = null;
      pin.clear();
      code.clear();
      origin.clear();
      await _connect();
    });
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
    unawaited(
      () async {
        await productionQueue?.close();
        await host?.close();
      }().catchError((Object _) {}),
    );
    origin.dispose();
    code.dispose();
    pin.dispose();
    openingFloat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (entered) {
      return WindowsRegisterApp(
        controller: controller,
        onConnection: () {
          pin.clear();
          operatorId = null;
          setState(() => entered = false);
          _run(() async {
            await host!.call(HostCommand.logout);
            await _status();
          });
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
                    const Center(child: ShopikaissLogo(width: 300)),
                    const SizedBox(height: 24),
                    const Text(
                      'Mise en service de la caisse',
                      style: TextStyle(fontSize: 24),
                    ),
                    const SizedBox(height: 16),
                    if (profiles != null) ...[
                      Text('Connexion : ${profiles!.names[profiles!.active]}'),
                      Builder(
                        builder: (dialogContext) => TextButton.icon(
                          onPressed: busy
                              ? null
                              : () => _chooseSite(dialogContext),
                          icon: const Icon(Icons.dns_outlined),
                          label: const Text('Changer de site / appairage'),
                        ),
                      ),
                    ],
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
                                entered = status['session_open'] == true;
                              }),
                        child: const Text('Ouvrir la caisse'),
                      ),
                      if (status['session_open'] != true &&
                          status['operator'] != null) ...[
                        TextField(
                          controller: openingFloat,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Fond de caisse compté (F CFA)',
                          ),
                        ),
                        FilledButton(
                          onPressed:
                              busy ||
                                  ((status['capabilities']
                                              as Map?)?['open_session']
                                          as Map?)?['allowed'] !=
                                      true
                              ? null
                              : () => _run(() async {
                                  final amount = int.tryParse(
                                    openingFloat.text.trim(),
                                  );
                                  if (amount == null || amount < 0) {
                                    throw const HostFailure(
                                      'amount',
                                      'Saisissez un fond de caisse entier positif ou nul.',
                                    );
                                  }
                                  await host!.call(
                                    HostCommand.openSession,
                                    arguments: {'float': amount},
                                  );
                                  await _status();
                                  await controller!.refresh();
                                  entered = status['session_open'] == true;
                                }),
                          child: const Text('Ouvrir la session locale'),
                        ),
                        if (((status['capabilities'] as Map?)?['open_session']
                                as Map?)?['reason'] !=
                            null)
                          Text(
                            '${((status['capabilities'] as Map)['open_session'] as Map)['reason']}',
                          ),
                      ],
                    ],
                    TextButton(
                      onPressed: busy ? null : () => _run(_connect),
                      child: const Text('Reconnexion / vérifier'),
                    ),
                    if (status['paired'] == true)
                      TextButton.icon(
                        onPressed: busy
                            ? null
                            : () => _run(() async {
                                await host!.call(HostCommand.synchronize);
                                await _status();
                              }),
                        icon: const Icon(Icons.sync),
                        label: Text(
                          'Synchroniser · ${status['pending'] ?? '?'} en attente',
                        ),
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
