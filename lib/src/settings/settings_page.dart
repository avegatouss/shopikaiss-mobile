import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_settings.dart';
import '../offline/offline_settings_section.dart';
import '../ui/screen_profile.dart';
import '../printer/escpos.dart';
import '../terminal/terminal_channel.dart';
import '../terminal/terminal_session.dart';

/// Réglages : adresse de la boutique, terminal détecté, imprimante, code d'accès.
/// Affiché au premier lancement ([firstRun]) puis par 5 touchers dans le coin de la caisse.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.session, this.firstRun = false, this.onDone});

  final TerminalSession session;
  final bool firstRun;

  /// Appelé après enregistrement au premier lancement (sinon la page se referme).
  final VoidCallback? onDone;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _url = TextEditingController(text: _settings.shopUrl);
  late final TextEditingController _serialPath = TextEditingController(text: _settings.serialPath);
  late final TextEditingController _code = TextEditingController(text: _settings.adminCode);
  late final TextEditingController _displayUrl = TextEditingController(text: _settings.customerDisplayUrl);
  late String _driver = _settings.driver;
  late int _paper = _settings.paperWidth;
  late int _baud = _settings.serialBaud;
  late String _btAddress = _settings.bluetoothAddress;
  late String _usbDevice = _settings.usbDevice;
  late bool _hideKeyboard = _settings.hideSoftKeyboard;
  late String _screenLayout = _settings.screenLayout;

  List<Map<String, dynamic>> _btDevices = const [];
  List<Map<String, dynamic>> _serialPorts = const [];
  List<Map<String, dynamic>> _usbDevices = const [];
  String? _urlError;
  String? _displayUrlError;
  String? _message;
  bool _busy = false;

  TerminalSession get _session => widget.session;
  AppSettings get _settings => _session.settings;
  TerminalInfo get _info => _session.info;

  @override
  void initState() {
    super.initState();
    _loadLists();
  }

  Future<void> _loadLists() async {
    final ch = _session.channel;
    final bt = await ch.bluetoothDevices();
    final serial = await ch.serialPorts();
    final usb = await ch.usbDevices();
    if (mounted) setState(() => (_btDevices = bt, _serialPorts = serial, _usbDevices = usb));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.firstRun ? 'Configuration du terminal' : 'Réglages'),
        automaticallyImplyLeading: !widget.firstRun,
      ),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            _Section(title: 'Boutique', children: [
              TextField(
                controller: _url,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: 'Adresse de la boutique',
                  hintText: 'boutique.exemple.ci',
                  helperText: 'Sans chemin, la caisse (/caisse) est ouverte.',
                  errorText: _urlError,
                  prefixIcon: const Icon(Icons.storefront),
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(onPressed: _testUrl, icon: const Icon(Icons.wifi_find), label: const Text('Tester la connexion')),
              ),
            ]),
            _Section(title: 'Terminal', children: [
              _Info('Appareil', _info.label.isEmpty ? '—' : _info.label),
              _Info('Android', _info.android.isEmpty ? '—' : _info.android),
              _Info('Imprimante détectée', _info.detectedLabel),
              _Info('Papier détecté', _info.detectedPaper > 0 ? '${_info.detectedPaper} mm' : 'inconnu'),
              _Info('Afficheur client', _info.hasSecondaryDisplay ? 'second écran détecté' : 'aucun second écran'),
              _Info('Pilote actif', driverLabels[_session.activeDriver] ?? _session.activeDriver),
            ]),
            _Section(title: 'Imprimante', children: [
              DropdownButtonFormField<String>(
                initialValue: _driver,
                decoration: const InputDecoration(labelText: 'Pilote', prefixIcon: Icon(Icons.print)),
                items: [
                  for (final e in driverLabels.entries)
                    DropdownMenuItem(
                      value: e.key,
                      child: Text(e.key == 'auto' ? 'Automatique (${_info.detectedLabel})' : e.value, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => setState(() => _driver = v ?? 'auto'),
              ),
              if (_driver == 'usb') ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _usbDevices.any((d) => '${d['vendorId']}:${d['productId']}' == _usbDevice) ? _usbDevice : '',
                  decoration: const InputDecoration(labelText: 'Appareil USB', helperText: 'Choisir l\u2019appareil si l\u2019imprimante ne se déclare pas comme imprimante USB.'),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('Première imprimante USB (automatique)')),
                    for (final d in _usbDevices)
                      DropdownMenuItem(
                        value: '${d['vendorId']}:${d['productId']}',
                        child: Text('${d['name']} — ${(d['vendorId'] as int).toRadixString(16).padLeft(4, '0')}:${(d['productId'] as int).toRadixString(16).padLeft(4, '0')}${d['printer'] == true ? ' (imprimante)' : ''}', overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) => setState(() => _usbDevice = v ?? ''),
                ),
              ],
              if (_driver == 'bluetooth') ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _btDevices.any((d) => d['address'] == _btAddress) ? _btAddress : '',
                  decoration: const InputDecoration(labelText: 'Périphérique Bluetooth appairé'),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('InnerPrinter (automatique)')),
                    for (final d in _btDevices) DropdownMenuItem(value: d['address'] as String, child: Text('${d['name']} — ${d['address']}')),
                  ],
                  onChanged: (v) => setState(() => _btAddress = v ?? ''),
                ),
              ],
              if (_driver == 'serial') ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _serialPath,
                  decoration: InputDecoration(
                    labelText: 'Port série',
                    helperText: _serialPorts.isEmpty
                        ? 'Aucun port /dev/tty* visible'
                        : 'Ports : ${_serialPorts.map((p) => '${p['path']}${p['writable'] == true ? '' : ' (protégé)'}').join(', ')}',
                    helperMaxLines: 3,
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: _baud,
                  decoration: const InputDecoration(labelText: 'Débit (bauds)'),
                  items: const [9600, 19200, 38400, 57600, 115200]
                      .map((b) => DropdownMenuItem(value: b, child: Text('$b')))
                      .toList(),
                  onChanged: (v) => setState(() => _baud = v ?? 115200),
                ),
              ],
              const SizedBox(height: 16),
              Text('Largeur du rouleau (tickets HTML)', style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('Auto')),
                  ButtonSegment(value: 58, label: Text('58 mm')),
                  ButtonSegment(value: 80, label: Text('80 mm')),
                ],
                selected: {_paper},
                onSelectionChanged: (s) => setState(() => _paper = s.first),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(onPressed: _testPrint, icon: const Icon(Icons.receipt_long), label: const Text('Ticket de test')),
                  OutlinedButton.icon(onPressed: _openDrawer, icon: const Icon(Icons.point_of_sale), label: const Text('Ouvrir le tiroir')),
                  OutlinedButton.icon(onPressed: _status, icon: const Icon(Icons.info_outline), label: const Text('État')),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Dans ShopiKaiss, Réglages › Terminaux : choisir l’imprimante « Imprimante intégrée par l’application ShopiKaiss Bridge » '
                'pour que les tickets partent directement sur cette imprimante.',
                style: theme.textTheme.bodySmall,
              ),
            ]),
            _Section(title: 'Afficheur client', children: [
              _Info('Second écran', _info.hasSecondaryDisplay ? 'détecté : la caisse y affiche le panier d’elle-même' : 'aucun : pas d’affichage client'),
              const SizedBox(height: 8),
              TextField(
                controller: _displayUrl,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: 'Lien imposé à l’afficheur (facultatif)',
                  helperText: 'Vide = lien envoyé automatiquement par la caisse. Sinon, coller le lien « page web » copié dans '
                      'ShopiKaiss, Réglages › Afficheur client (même adresse que la boutique).',
                  helperMaxLines: 3,
                  errorText: _displayUrlError,
                  prefixIcon: const Icon(Icons.connected_tv),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(onPressed: _pasteDisplayUrl, icon: const Icon(Icons.content_paste), label: const Text('Coller')),
                  if (_session.lastDisplayUrl?.isNotEmpty == true)
                    OutlinedButton.icon(onPressed: _copyDisplayUrl, icon: const Icon(Icons.copy), label: const Text('Copier le lien reçu de la caisse')),
                  FilledButton.tonalIcon(onPressed: _testDisplay, icon: const Icon(Icons.tv), label: const Text('Afficher sur le second écran')),
                ],
              ),
            ]),
            _Section(title: 'Clavier', children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _hideKeyboard,
                onChanged: (v) => setState(() => _hideKeyboard = v),
                title: const Text('Masquer le clavier de l’écran dans la caisse'),
                subtitle: const Text('Activé par défaut : le clavier Android ne s’ouvre plus au toucher des champs de la caisse (bloqué aussi par Android). '
                    'Le clavier externe et la douchette saisissent toujours. Le bouton ⌨ en bas à gauche de la caisse l’autorise à tout moment.'),
              ),
            ]),
            _Section(title: 'Affichage', children: [
              DropdownButtonFormField<String>(
                initialValue: screenLayoutLabels.containsKey(_screenLayout) ? _screenLayout : 'auto',
                decoration: const InputDecoration(labelText: 'Disposition de l’écran', prefixIcon: Icon(Icons.smartphone)),
                items: [for (final e in screenLayoutLabels.entries) DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis))],
                onChanged: (v) => setState(() => _screenLayout = v ?? 'auto'),
              ),
              const SizedBox(height: 8),
              Builder(builder: (context) {
                final size = MediaQuery.sizeOf(context);
                final inches = displayedInches(size, _info.screenInches);
                final layout = resolveScreenLayout(setting: _screenLayout, logicalSize: size, nativeInches: _info.screenInches);
                return Text(
                  'Écran ${_info.screenInches >= 3 ? 'mesuré' : 'estimé'} : ${inches.toStringAsFixed(1).replaceAll('.', ',')} pouces '
                  '(${size.width.round()} × ${size.height.round()} points) → disposition ${layout == ScreenLayout.compact ? 'compacte' : 'standard'}. '
                  'La caisse hors ligne s’adapte aux petits téléphones ; la caisse web suit la mise en page du site.',
                  style: Theme.of(context).textTheme.bodySmall,
                );
              }),
            ]),
            OfflineSettingsSection(session: _session),
            _Section(title: 'Sécurité', children: [
              TextField(
                controller: _code,
                obscureText: true,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Code d’accès aux réglages (facultatif)',
                  helperText: 'Demandé après les 5 touchers dans le coin haut gauche de la caisse.',
                  prefixIcon: Icon(Icons.lock_outline),
                ),
              ),
            ]),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Card(
                  color: theme.colorScheme.secondaryContainer,
                  child: Padding(padding: const EdgeInsets.all(12), child: Text(_message!)),
                ),
              ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _save,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              icon: _busy ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.check),
              label: Text(widget.firstRun ? 'Enregistrer et ouvrir la caisse' : 'Enregistrer'),
            ),
          ],
        ),
      ),
    );
  }

  /// Recopie le formulaire dans les réglages et reconfigure le pilote natif.
  Future<bool> _apply({bool persist = false}) async {
    final url = normalizeShopUrl(_url.text);
    final displayUrl = _displayUrl.text.trim();
    final displayOk = displayUrl.isEmpty || originOf(displayUrl) == originOf(url ?? _settings.shopUrl);
    setState(() {
      _urlError = url == null && persist ? 'Adresse invalide' : null;
      _displayUrlError = displayOk ? null : 'Le lien doit être sur la même adresse que la boutique.';
    });
    if ((url == null && persist) || !displayOk) return false;
    _settings
      ..shopUrl = url ?? _settings.shopUrl
      ..driver = _driver
      ..paperWidth = _paper
      ..serialPath = _serialPath.text.trim()
      ..serialBaud = _baud
      ..bluetoothAddress = _btAddress
      ..usbDevice = _usbDevice
      ..hideSoftKeyboard = _hideKeyboard
      ..screenLayout = _screenLayout
      ..customerDisplayUrl = displayUrl
      ..adminCode = _code.text.trim();
    if (persist) {
      await _session.save();
    } else {
      await _session.refresh();
    }
    return true;
  }

  Future<void> _run(Future<String> Function() action) async {
    setState(() => (_busy = true, _message = null));
    try {
      final message = await action();
      if (mounted) setState(() => _message = message);
    } catch (e) {
      if (mounted) setState(() => _message = 'Erreur : $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _testUrl() => _run(() async {
        final url = normalizeShopUrl(_url.text);
        if (url == null) return 'Adresse invalide.';
        _url.text = url;
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
        try {
          final request = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 10));
          request.followRedirects = true;
          final response = await request.close().timeout(const Duration(seconds: 10));
          await response.drain<void>();
          return response.statusCode < 500
              ? 'Boutique joignable (HTTP ${response.statusCode}).'
              : 'Le serveur répond par une erreur HTTP ${response.statusCode}.';
        } on TimeoutException {
          return 'Pas de réponse en 10 s : vérifiez le réseau et l’adresse.';
        } on SocketException catch (e) {
          return 'Boutique injoignable : ${e.message}';
        } on HandshakeException {
          return 'Certificat HTTPS refusé par le terminal.';
        } finally {
          client.close(force: true);
        }
      });

  void _testPrint() => _run(() async {
        await _apply();
        final paper = _session.rollWidth > 0 ? _session.rollWidth : 58;
        final now = DateTime.now();
        final result = await _session.channel.printRaw(EscPos.testTicket(paperWidth: paper, lines: [
          'Terminal : ${_info.label}',
          'Pilote   : ${_session.activeDriver}',
          'Papier   : $paper mm',
          'Date     : ${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year} '
              '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
        ]));
        return result.ok ? 'Ticket de test envoyé à l’imprimante (${driverLabels[_session.activeDriver]}).' : _describe(result.error);
      });

  Future<void> _pasteDisplayUrl() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isNotEmpty) setState(() => (_displayUrl.text = text, _displayUrlError = null));
  }

  Future<void> _copyDisplayUrl() async {
    await Clipboard.setData(ClipboardData(text: _session.lastDisplayUrl ?? ''));
    if (mounted) {
      setState(() => _message = 'Lien de l’afficheur copié. Il expire vite (jeton de la caisse) : pour un lien durable, '
          'utiliser le lien « page web » de Réglages › Afficheur client.');
    }
  }

  void _testDisplay() => _run(() async {
        if (!await _apply()) return 'Lien de l’afficheur refusé.';
        final url = _session.displayUrlFor(_session.lastDisplayUrl ?? '');
        if (url.isEmpty) return 'Aucun lien : collez un lien, ou ouvrez d’abord la caisse pour recevoir le sien.';
        final result = await _session.channel.showCustomerDisplay(url, _settings.origin);
        return result.ok ? 'Lien ouvert sur le second écran.' : switch (result.error) {
          'no_secondary_display' => 'Aucun second écran détecté.',
          'origin_not_allowed' => 'Lien refusé : il doit être sur la même adresse que la boutique.',
          _ => _describe(result.error),
        };
      });

  void _openDrawer() => _run(() async {
        await _apply();
        final result = await _session.channel.openDrawer();
        return result.ok ? 'Impulsion d’ouverture envoyée au tiroir.' : _describe(result.error);
      });

  void _status() => _run(() async {
        await _apply();
        final r = await _session.channel.status();
        if (!r.ok && r.data['paper'] == null) return _describe(r.error);
        return 'Papier : ${r.data['paper']} · Capot : ${r.data['cover']}${r.error != null ? ' · ${_describe(r.error)}' : ''}';
      });

  Future<void> _save() async {
    setState(() => _busy = true);
    final ok = await _apply(persist: true);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) return;
    if (widget.onDone != null) {
      widget.onDone!();
    } else {
      Navigator.of(context).pop();
    }
  }

  static String _describe(String? code) => switch (code) {
        'printer_not_configured' => 'Aucune imprimante : choisissez un pilote.',
        'sdk_absent' => 'Service d’impression SUNMI absent de ce terminal.',
        'usb_printer_not_found' => 'Aucune imprimante USB branchée.',
        'usb_permission_pending' => 'Acceptez l’autorisation USB affichée par Android, puis réessayez.',
        'bluetooth_permission_pending' => 'Acceptez l’autorisation Bluetooth affichée par Android, puis réessayez.',
        'bluetooth_disabled' => 'Activez le Bluetooth du terminal.',
        'bluetooth_printer_not_found' => 'Aucune imprimante Bluetooth appairée (InnerPrinter introuvable).',
        'paper_out' => 'Plus de papier.',
        'cover_open' => 'Capot ouvert.',
        null => 'Échec sans précision.',
        _ => 'Échec : $code',
      };
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

class _Info extends StatelessWidget {
  const _Info(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 150, child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
