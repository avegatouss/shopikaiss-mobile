import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'lot_wholesale.dart';

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../platform/windows_platform.dart';
import '../platform/customer_display.dart';

import '../ipc/protocol.dart';
import 'register_controller.dart';
import 'sales_history.dart';
import 'brand_logo.dart';
import 'suspended_drafts.dart';
import 'screen_settings.dart';
import 'sale_options_preview.dart';
import 'quantity_step.dart';
import 'multiple_payments.dart';
import 'searchable_choice.dart';
import 'calculator.dart';
import 'discount_approval.dart';
import 'web_destinations.dart';
import 'customer_picker.dart';
import 'payment_message.dart';
import 'cash_operations.dart';
import 'product_badges.dart';
import 'pass_payment.dart';
import 'restaurant_dialog.dart';

class WindowsRegisterApp extends StatelessWidget {
  const WindowsRegisterApp({super.key, this.controller, this.onConnection});
  final VoidCallback? onConnection;
  final WindowsRegisterController? controller;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Shopikaiss · Caisse',
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: 'Segoe UI',
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff164e42)),
      scaffoldBackgroundColor: const Color(0xfff3f5f4),
      visualDensity: VisualDensity.compact,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleTextStyle: TextStyle(
          fontFamily: 'Segoe UI',
          color: Color(0xff26332e),
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: Color(0xffdbe3de)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(40, 40),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(40, 40),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(),
      ),
    ),
    home: controller == null
        ? const _NotConnected()
        : _Register(controller!, onConnection),
  );
}

class _NotConnected extends StatelessWidget {
  const _NotConnected();
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Shopikaiss · Caisse Windows')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: const Card(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ShopikaissLogo(width: 280),
                SizedBox(height: 20),
                Text(
                  'Votre caisse doit être configurée',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 16),
                Text(
                  'Le moteur de vente local n’est pas raccordé. Aucun encaissement n’est disponible sur cette installation.',
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 12),
                Text(
                  'Contactez votre responsable pour terminer la mise en service.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _Register extends StatefulWidget {
  const _Register(this.controller, this.onConnection);
  final VoidCallback? onConnection;
  final WindowsRegisterController controller;
  @override
  State<_Register> createState() => _RegisterState();
}

class _RegisterState extends State<_Register> {
  final _search = TextEditingController();
  Future<void> _searchCatalogue({
    String? category,
    String? brand,
    String? supplier,
  }) => c.command(HostCommand.search, {
    'query': _search.text,
    'category': category ?? c.view['category'] ?? '',
    'brand': brand ?? c.view['brand'] ?? '',
    'supplier': supplier ?? c.view['supplier'] ?? '',
  });

  Widget _catalogueFilter(String field, String label, String all) {
    final values = (c.view['${field}s'] as List? ?? const []).cast<String>();
    final selected = c.view[field] as String? ?? '';
    return SearchableChoice(
      label: label,
      all: all,
      values: values,
      selected: selected,
      onChanged: _canEdit
          ? (value) {
              if (field == 'brand') {
                _searchCatalogue(brand: value);
              } else {
                _searchCatalogue(supplier: value);
              }
            }
          : null,
    );
  }

  final _scan = TextEditingController();
  final _screen = ScreenSettings.load();
  late final CustomerDisplayService _display;
  ColorScheme get _palette =>
      ColorScheme.fromSeed(seedColor: _screen.accentColor);
  Widget _imageSlot({
    bool large = false,
    Map<String, dynamic>? product,
  }) => Container(
    width: large ? double.infinity : 30,
    height: large ? 60 : 30,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: _palette.primary.withValues(alpha: .06),
      borderRadius: BorderRadius.circular(4),
    ),
    child:
        product?['image'] is Map && (product!['image'] as Map)['path'] is String
        ? Image.file(
            File((product['image'] as Map)['path'] as String),
            fit: _screen.imageFit == 'cover' ? BoxFit.cover : BoxFit.contain,
            width: large ? double.infinity : 30,
            height: large ? 60 : 30,
            errorBuilder: (_, _, _) =>
                const Icon(Icons.image_not_supported_outlined),
          )
        : Icon(
            Icons.inventory_2_outlined,
            size: large ? 32 : 19,
            color: _palette.primary,
          ),
  );
  bool get _compact => _screen.compact;
  Timer? _saveSettings;
  void _screenChanged() {
    setState(() {});
    _saveSettings?.cancel();
    _saveSettings = Timer(const Duration(milliseconds: 400), () async {
      try {
        await _screen.save();
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Réglages appliqués, mais non sauvegardés sur ce poste.',
              ),
            ),
          );
        }
      }
    });
  }

  final _scanFocus = FocusNode();
  final _searchFocus = FocusNode();
  final _categoriesScroll = ScrollController();
  void _scrollCategories(int direction) {
    if (!_categoriesScroll.hasClients) return;
    final target = (_categoriesScroll.offset + direction * 280).clamp(
      0.0,
      _categoriesScroll.position.maxScrollExtent,
    );
    _categoriesScroll.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  Future<void> _session() async {
    await c.refresh();
    if (!mounted) return;
    if (c.sessionOpen != false || !_allowed('open_session')) {
      final text = c.sessionOpen == true
          ? 'Une session est déjà ouverte sur ce terminal. Elle est conservée.'
          : (c.capabilities['open_session'] as Map?)?['reason']?.toString() ??
                'État de session indisponible : actualisez avant de continuer.';
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Session de caisse'),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Fermer'),
            ),
          ],
        ),
      );
      return;
    }
    String value = '0';
    final amount = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ouvrir la session'),
        content: TextFormField(
          initialValue: value,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Fond de caisse compté (F CFA)',
          ),
          onChanged: (v) => value = v,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () {
              final amount = int.tryParse(value.trim());
              if (amount != null && amount >= 0) Navigator.pop(context, amount);
            },
            child: const Text('Ouvrir la session'),
          ),
        ],
      ),
    );
    if (!mounted || amount == null) return;
    await c.refresh();
    if (c.sessionOpen == false && _allowed('open_session')) {
      await c.command(HostCommand.openSession, {'float': amount});
    }
  }

  bool _fullscreen = false;
  Future<void> _toggleFullscreen() async {
    try {
      final enabled = await const WindowsPlatform().toggleFullscreen();
      if (mounted) setState(() => _fullscreen = enabled);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Plein écran indisponible sur cette installation.'),
          ),
        );
      }
    }
  }

  Future<void> _backOffice({bool cashRegister = false}) async {
    final uri = cashRegister
        ? caisseStartWebsite(c.webOrigin)
        : _screen.backOfficeUri ?? caisseWebsite(c.webOrigin, '/accueil');
    if (uri == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Adresse de la boutique indisponible. Reconnectez le moteur ou renseignez le back-office dans les réglages.',
          ),
        ),
      );
      return;
    }
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw StateError('launch');
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Impossible d’ouvrir le site dans le navigateur.'),
          ),
        );
      }
    }
  }

  void _shortcuts() => showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Raccourcis de la caisse'),
      content: const Text(
        'F1 : cette aide\nF2 : scanner un article\nCtrl+F : rechercher un produit\nF4 : ouvrir le paiement\nF8 : mettre le panier en attente\nF11 : entrer / sortir du plein écran\nEntrée : valider la saisie du montant\nÉchap : fermer une fenêtre lorsque permis',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Fermer'),
        ),
      ],
    ),
  );
  WindowsRegisterController get c => widget.controller;

  /// Ticket après une vente : demandé au caissier, ou imprimé d'office selon le réglage du poste.
  Future<String> _saleTicket(String operation) async {
    if (_screen.ticketMode != 'auto') {
      final print = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Imprimer le ticket ?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Non'),
            ),
            FilledButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Imprimer'),
            ),
          ],
        ),
      );
      if (print != true) return 'Ticket disponible dans Ventes récentes.';
    }
    return printOriginalTicket(c.host, operation);
  }

  @override
  void initState() {
    super.initState();
    c.saleTicket = _saleTicket;
    _display = CustomerDisplayService(c);
    unawaited(_display.start());
    unawaited(_enterWorkspace());
  }

  Future<void> _enterWorkspace() async {
    await c.refresh();
    if (!mounted || !c.ready) return;
    try {
      final room = await c.host.call(HostCommand.restaurantView);
      if (mounted &&
          (room['table_service'] == true || room['production'] == true)) {
        await showDialog<void>(
          context: context,
          builder: (_) =>
              RestaurantDialog(host: c.host, intent: c.restaurantIntent),
        );
      }
    } catch (_) {
      /* The explicit restaurant entry retains diagnostic access. */
    }
  }

  @override
  void dispose() {
    _display.dispose();
    _saveSettings?.cancel();
    _search.dispose();
    _scan.dispose();
    _scanFocus.dispose();
    _searchFocus.dispose();
    _categoriesScroll.dispose();
    super.dispose();
  }

  void _setCatalogueMode(bool value) {
    _screen.compact = value;
    _screenChanged();
  }

  Future<void> _payment() async {
    if (!c.canPay) return;
    if (_allowed('pass')) {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PassPaymentDialog(controller: c),
      );
      return;
    }
    final prepared = await c.command(HostCommand.preparePayment, {});
    if (!mounted) return;
    if (prepared == null) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Paiement indisponible'),
          content: Text(
            c.message ?? 'Le paiement ne peut pas être préparé. Réessayez après vérification du panier.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Compris'),
            ),
          ],
        ),
      );
      return;
    }
    if (!mounted || !c.canPay) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Theme(
        data: Theme.of(context).copyWith(colorScheme: _palette),
        child: _Payment(c),
      ),
    );
  }

  bool get _canEdit => c.ready && !c.busy && c.uncertainOperation == null;
  bool _allowed(String name) =>
      (c.capabilities[name] as Map?)?['allowed'] == true;

  Future<void> _discount(Map<String, dynamic> line) async {
    final entry = line['discount_entry'] as Map?;
    var percent = entry?['type'] == 'pourcentage';
    var amount = '${entry?['valeur'] ?? line['discount'] ?? 0}';
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Remise de ligne'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButton<bool>(
                value: percent,
                items: const [
                  DropdownMenuItem(
                    value: false,
                    child: Text('Montant (F CFA)'),
                  ),
                  DropdownMenuItem(value: true, child: Text('Pourcentage (%)')),
                ],
                onChanged: (v) => update(() => percent = v!),
              ),
              TextFormField(
                initialValue: amount,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: percent
                      ? 'Remise en %'
                      : 'Remise en F CFA (0 pour retirer)',
                ),
                onChanged: (value) => amount = value,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () {
                final parsed = int.tryParse(amount.trim());
                if (percent) {
                  Navigator.pop(context, <String, dynamic>{
                    'percent': amount.trim(),
                  });
                } else if (parsed != null && parsed >= 0) {
                  Navigator.pop(context, <String, dynamic>{'amount': parsed});
                }
              },
              child: const Text('Appliquer'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || result == null || !_canEdit) return;
    await c.command(HostCommand.setLineDiscount, {
      'line_id': line['id'],
      ...result,
    });
  }

  Future<void> _submitScan() async {
    if (!_canEdit || _scan.text.trim().isEmpty) return;
    await c.command(HostCommand.scan, {'code': _scan.text.trim()});
    if (!mounted) return;
    if (c.message == null) _scan.clear();
    _scanFocus.requestFocus();
  }

  Future<void> _addProduct(Map<String, dynamic> product) async {
    if (!_canEdit) return;
    final packagings = (product['packagings'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    Object? packaging;
    if (packagings.isNotEmpty) {
      final choice = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(product['name'] as String),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, <String, dynamic>{}),
              child: Text('Unité · ${product['price_label']}'),
            ),
            for (final item in packagings)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, item),
                child: Text('${item['name']} · ${item['price_label']}'),
              ),
          ],
        ),
      );
      if (!mounted || choice == null || !_canEdit) return;
      packaging = choice['id'];
    }
    await c.command(HostCommand.addProduct, {
      'product_id': product['id'],
      'packaging_id': ?packaging,
    });
  }

  Future<void> _quantity(Map<String, dynamic> line) async {
    var input = '';
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Modifier la quantité'),
        content: TextField(
          onChanged: (value) => input = value,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'Nouvelle quantité',
            helperText:
                '${line['name']} · actuellement ${line['quantity_label']}',
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(input),
            child: const Text('Appliquer'),
          ),
        ],
      ),
    );
    if (!mounted || value == null || value.trim().isEmpty) return;
    await c.command(HostCommand.changeQuantity, {
      'line_id': line['id'],
      'quantity': value.trim(),
    });
  }

  Future<void> _stepQuantity(Map<String, dynamic> line, int step) async {
    if (!_canEdit) return;
    final quantity = steppedQuantity(
      line['quantity'] ?? line['quantity_label'],
      step,
    );
    if (quantity == null) return;
    await c.command(HostCommand.changeQuantity, {
      'line_id': line['id'],
      'quantity': quantity,
    });
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Vider le panier ?'),
        content: const Text('Tous les articles de ce panier seront retirés.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Conserver'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Vider le panier'),
          ),
        ],
      ),
    );
    if (mounted && confirmed == true) await c.command(HostCommand.clear, {});
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) => Theme(
      data: Theme.of(context).copyWith(colorScheme: _palette),
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.f1): _shortcuts,
          const SingleActivator(LogicalKeyboardKey.f11): _toggleFullscreen,
          const SingleActivator(LogicalKeyboardKey.keyF, control: true):
              _searchFocus.requestFocus,
          const SingleActivator(LogicalKeyboardKey.f4): _payment,
          const SingleActivator(LogicalKeyboardKey.f2): _scanFocus.requestFocus,
          const SingleActivator(LogicalKeyboardKey.f8): () {
            if (_canEdit && _allowed('suspend') && c.lines.isNotEmpty) {
              c.command(HostCommand.suspendDraft, {});
            }
          },
        },
        child: Scaffold(
          endDrawer: ScreenSettingsPanel(
            display: _display,
            host: c.host,
            settings: _screen,
            onChanged: _screenChanged,
          ),
          appBar: AppBar(
            toolbarHeight: 40,
            title: Row(
              children: [
                const ShopikaissLogo(width: 125),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    c.view['store_name'] as String? ?? 'Caisse',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            actions: [
              PopupMenuButton<String>(
                tooltip: 'Menu du poste',
                onSelected: (value) {
                  if (value == 'full') _toggleFullscreen();
                  if (value == 'back') _backOffice();
                  if (value == 'web') _backOffice(cashRegister: true);
                  if (value == 'help') _shortcuts();
                  if (value == 'session') _session();
                  if (value == 'close' || value == 'return') {
                    showDialog<void>(
                      context: context,
                      barrierDismissible: false,
                      builder: (_) => CashOperationsDialog(
                        controller: c,
                        returns: value == 'return',
                      ),
                    );
                  }
                  if (value == 'lock' || value == 'logout') {
                    widget.onConnection?.call();
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'close',
                    enabled: _canEdit,
                    child: const Text('Clôturer ma session'),
                  ),
                  PopupMenuItem(
                    value: 'return',
                    enabled: _canEdit,
                    child: const Text('Retour en espèces'),
                  ),
                  PopupMenuItem(
                    value: 'lock',
                    enabled:
                        widget.onConnection != null &&
                        !c.busy &&
                        c.uncertainOperation == null,
                    child: const Text('Verrouiller'),
                  ),
                  PopupMenuItem(
                    value: 'logout',
                    enabled:
                        widget.onConnection != null &&
                        !c.busy &&
                        c.uncertainOperation == null,
                    child: const Text('Se déconnecter'),
                  ),
                  PopupMenuItem(
                    value: 'session',
                    enabled: !c.busy,
                    child: Text(
                      c.sessionOpen == false
                          ? 'Ouvrir la session'
                          : 'Session de caisse',
                    ),
                  ),
                  PopupMenuItem(
                    value: 'full',
                    child: Text(
                      _fullscreen
                          ? 'Quitter le plein écran · F11'
                          : 'Plein écran · F11',
                    ),
                  ),
                  PopupMenuItem(
                    value: 'back',
                    child: const Text('Retour au back-office'),
                  ),
                  const PopupMenuItem(
                    value: 'web',
                    child: Text('Ouvrir la caisse web'),
                  ),
                  const PopupMenuItem(
                    value: 'help',
                    child: Text('Raccourcis · F1'),
                  ),
                ],
              ),
              Builder(
                builder: (context) => IconButton(
                  tooltip: 'Réglages de l’écran',
                  icon: const Icon(Icons.tune),
                  onPressed: () => Scaffold.of(context).openEndDrawer(),
                ),
              ),
              IconButton(
                tooltip: 'Ventes de ce poste',
                onPressed: c.ready && !c.busy
                    ? () => showDialog<void>(
                        context: context,
                        builder: (_) => SalesHistoryDialog(host: c.host),
                      )
                    : null,
                icon: const Icon(Icons.receipt_long_outlined),
              ),
              Chip(
                avatar: Icon(
                  c.ready ? Icons.check_circle_outline : Icons.warning_amber,
                  size: 18,
                ),
                label: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.sizeOf(context).width * .32,
                  ),
                  child: Text(
                    c.ready
                        ? c.view['sync_label'] as String? ?? 'Moteur local prêt'
                        : 'Moteur local indisponible',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (widget.onConnection != null)
                IconButton(
                  tooltip: 'Connexion au moteur',
                  onPressed: c.busy ? null : widget.onConnection,
                  icon: const Icon(Icons.settings_input_component),
                ),
              const SizedBox(width: 16),
              IconButton(
                tooltip: 'Actualiser l’état local',
                onPressed: c.busy ? null : c.refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: Column(
            children: [
              Material(
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 2,
                  ),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment(
                              value: false,
                              icon: Icon(Icons.grid_view),
                              label: Text('Visuelle'),
                            ),
                            ButtonSegment(
                              value: true,
                              icon: Icon(Icons.view_list),
                              label: Text('Compacte'),
                            ),
                          ],
                          selected: {_compact},
                          onSelectionChanged: (value) =>
                              _setCatalogueMode(value.single),
                        ),
                        const SizedBox(width: 12),
                        TextButton.icon(
                          onPressed: c.ready && !c.busy
                              ? () => showDialog<void>(
                                  context: context,
                                  builder: (_) =>
                                      SalesHistoryDialog(host: c.host),
                                )
                              : null,
                          icon: const Icon(Icons.history),
                          label: const Text('Ventes récentes'),
                        ),
                        TextButton.icon(
                          onPressed: c.ready && !c.busy
                              ? () => showDialog<void>(
                                  context: context,
                                  builder: (_) =>
                                      SalesHistoryDialog(host: c.host),
                                )
                              : null,
                          icon: const Icon(Icons.receipt_long_outlined),
                          label: const Text('Reçu'),
                        ),
                        TextButton.icon(
                          onPressed: _canEdit
                              ? () => showDialog<void>(
                                  context: context,
                                  builder: (_) =>
                                      SaleOptionsPreview(controller: c),
                                )
                              : null,
                          icon: const Icon(Icons.note_alt_outlined),
                          label: const Text('Note'),
                        ),
                        TextButton.icon(
                          onPressed: !c.busy ? _session : null,
                          icon: const Icon(Icons.point_of_sale),
                          label: Text(
                            c.sessionOpen == false
                                ? 'Ouvrir la session'
                                : 'Session de caisse',
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () => showDialog<void>(
                            context: context,
                            builder: (_) => const DeskCalculator(),
                          ),
                          icon: const Icon(Icons.calculate_outlined),
                          label: const Text('Calculatrice'),
                        ),
                        TextButton.icon(
                          onPressed: c.ready && !c.busy
                              ? () => showDialog<void>(
                                  context: context,
                                  builder: (_) => RestaurantDialog(
                                    host: c.host,
                                    intent: c.restaurantIntent,
                                  ),
                                )
                              : null,
                          icon: const Icon(Icons.table_restaurant_outlined),
                          label: Text(
                            c.productionMessage == null
                                ? 'Salle et tables'
                                : 'Bons à vérifier · Salle et tables',
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _shortcuts,
                          icon: const Icon(Icons.help_outline),
                          label: const Text('Aide'),
                        ),
                        TextButton.icon(
                          onPressed: _backOffice,
                          icon: const Icon(Icons.dashboard_outlined),
                          label: const Text('Back-office web'),
                        ),
                        TextButton.icon(
                          onPressed: () => _backOffice(cashRegister: true),
                          icon: const Icon(Icons.open_in_browser),
                          label: const Text('Ouvrir la caisse web'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (c.message != null)
                MaterialBanner(
                  content: Text(c.message!),
                  actions: [
                    if (c.uncertainOperation != null)
                      TextButton(
                        onPressed: c.busy ? null : c.reconcile,
                        child: const Text('Vérifier la vente'),
                      )
                    else
                      TextButton(
                        onPressed: c.busy ? null : c.refresh,
                        child: const Text('Vérifier l’état'),
                      ),
                  ],
                ),
              if (c.receipt != null)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    'Vente enregistrée · ${c.receipt}${c.ticketMessage == null ? '' : ' · ${c.ticketMessage}'}',
                  ),
                ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) => box.maxWidth >= 900
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              flex: _screen.cataloguePercent,
                              child: _catalogue(),
                            ),
                            Expanded(
                              flex: 100 - _screen.cataloguePercent,
                              child: _cart(),
                            ),
                          ],
                        )
                      : DefaultTabController(
                          length: 2,
                          child: Column(
                            children: [
                              const TabBar(
                                tabs: [
                                  Tab(text: 'Articles'),
                                  Tab(text: 'Panier'),
                                ],
                              ),
                              Expanded(
                                child: TabBarView(
                                  children: [_catalogue(), _cart()],
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _catalogue() => Padding(
    padding: const EdgeInsets.all(8),
    child: Column(
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _scan,
                focusNode: _scanFocus,
                autofocus: true,
                enabled: c.ready && !c.busy && c.uncertainOperation == null,
                decoration: InputDecoration(
                  isDense: true,
                  labelText: 'Scanner (F2) puis Entrée',
                  prefixIcon: const Icon(Icons.barcode_reader),
                  suffixIcon: IconButton(
                    tooltip: 'Ajouter le code scanné',
                    icon: const Icon(Icons.arrow_forward),
                    onPressed: _canEdit ? _submitScan : null,
                  ),
                ),
                onSubmitted: (_) => _submitScan(),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _search,
                focusNode: _searchFocus,
                enabled: _canEdit,
                decoration: InputDecoration(
                  isDense: true,
                  labelText: 'Rechercher un produit',
                  suffixIcon: IconButton(
                    tooltip: 'Rechercher',
                    onPressed: _canEdit ? () => _searchCatalogue() : null,
                    icon: const Icon(Icons.search),
                  ),
                ),
                onSubmitted: (_) => _searchCatalogue(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if ((c.view['categories'] as List? ?? const []).isNotEmpty)
          SizedBox(
            height: 40,
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Catégories précédentes',
                  onPressed: () => _scrollCategories(-1),
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: ListView(
                    controller: _categoriesScroll,
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final category in [
                        '',
                        ...(c.view['categories'] as List).cast<String>(),
                      ])
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            label: Text(
                              category.isEmpty ? 'Voir tout' : category,
                            ),
                            selected: (c.view['category'] ?? '') == category,
                            onSelected: _canEdit
                                ? (_) => _searchCatalogue(category: category)
                                : null,
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Catégories suivantes',
                  onPressed: () => _scrollCategories(1),
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ),
        Row(
          children: [
            Expanded(
              child: _catalogueFilter(
                'supplier',
                'Fournisseur',
                'Tous les fournisseurs',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _catalogueFilter('brand', 'Marque', 'Toutes les marques'),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: Text(
                '${c.products.length} / ${c.view['products_total'] ?? c.products.length} produits',
              ),
            ),
            if (c.view['has_more'] == true)
              TextButton.icon(
                onPressed: _canEdit
                    ? () => c.command(HostCommand.moreProducts, const {})
                    : null,
                icon: const Icon(Icons.expand_more),
                label: const Text('Afficher plus'),
              ),
          ],
        ),
        Expanded(
          child: c.products.isEmpty
              ? const Center(child: Text('Aucun article à afficher.'))
              : _compact
              ? ListView.separated(
                  itemCount: c.products.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final p = c.products[index];
                    return ListTile(
                      dense: true,
                      leading: _screen.imageLayout == 'hidden'
                          ? null
                          : _imageSlot(product: p),
                      title: Text(p['name'] as String? ?? ''),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Stock : ${p['stock_label'] ?? "à vérifier"}'),
                          if (p['wholesale_price_label'] != null)
                            Text(
                              'Gros : ${p['wholesale_price_label']}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11),
                            ),
                          ProductBadges(product: p),
                        ],
                      ),
                      trailing: Text(p['price_label'] as String? ?? '—'),
                      onTap: _canEdit ? () => _addProduct(p) : null,
                    );
                  },
                )
              : GridView.builder(
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: _screen.tileWidth,
                    mainAxisExtent:
                        _screen.tileWidth * 115 / 175 +
                        42 +
                        (_screen.imageLayout == 'top' ? 68 : 0),
                    crossAxisSpacing: 4,
                    mainAxisSpacing: 4,
                  ),
                  itemCount: c.products.length,
                  itemBuilder: (context, index) {
                    final p = c.products[index];
                    return Card(
                      color: _palette.primaryContainer.withValues(alpha: .45),
                      child: InkWell(
                        onTap:
                            c.ready && !c.busy && c.uncertainOperation == null
                            ? () => _addProduct(p)
                            : null,
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (_screen.imageLayout == 'top') ...[
                                _imageSlot(large: true, product: p),
                                const SizedBox(height: 8),
                              ],
                              Expanded(
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (_screen.imageLayout == 'left')
                                      Padding(
                                        padding: EdgeInsets.only(
                                          right: 6,
                                          top: 2,
                                        ),
                                        child: _imageSlot(product: p),
                                      ),
                                    Expanded(
                                      child: Text(
                                        p['name'] as String? ?? '',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      p['price_label'] as String? ?? '—',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  CircleAvatar(
                                    radius: 12,
                                    backgroundColor: _palette.primary,
                                    child: const Icon(
                                      Icons.add,
                                      size: 16,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              if (p['wholesale_price_label'] != null)
                                Text(
                                  'Gros : ${p['wholesale_price_label']}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 11),
                                ),
                              ProductBadges(product: p),
                              Text(
                                p['stock_label'] as String? ??
                                    'Stock à vérifier',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    ),
  );

  Widget _cart() => Card(
    margin: const EdgeInsets.all(8),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.shopping_basket_outlined, size: 18),
              const SizedBox(width: 8),
              const Text(
                'Panier',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              Text(
                '${c.lines.length} ligne(s)',
                style: const TextStyle(fontSize: 12, color: Color(0xff627168)),
              ),
            ],
          ),
          const Divider(height: 18),
          Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  icon: const Icon(Icons.person_outline),
                  label: Text(
                    customerLabel(c),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onPressed: c.ready && !c.busy && c.uncertainOperation == null
                      ? () => showDialog<void>(
                          context: context,
                          barrierDismissible: false,
                          builder: (_) => CustomerPicker(controller: c),
                        )
                      : null,
                ),
              ),
              Expanded(
                child: TextButton.icon(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => SaleOptionsPreview(controller: c),
                  ),
                  icon: const Icon(Icons.tune, size: 18),
                  label: const Text('Remise et livraison', maxLines: 2),
                ),
              ),
            ],
          ),
          WholesaleButton(controller: c),
          Expanded(
            child: c.lines.isEmpty
                ? const Center(child: Text('Scannez votre premier article.'))
                : ListView.separated(
                    itemCount: c.lines.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final line = c.lines[index];
                      return ListTile(
                        dense: true,
                        minVerticalPadding: 8,
                        contentPadding: EdgeInsets.zero,
                        title: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              line['name'] as String? ?? '',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                            LineLotChoice(controller: c, line: line),
                            if (line['stock_after_label'] != null)
                              Text(
                                'Après vente : ${line['stock_after_label']}',
                                style: const TextStyle(fontSize: 11),
                              ),
                            if (line['stock_alert'] is Map)
                              Text(
                                '${(line['stock_alert'] as Map)['message'] ?? ''}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color:
                                      (line['stock_alert'] as Map)['level'] ==
                                          'short'
                                      ? Theme.of(context).colorScheme.error
                                      : Colors.brown,
                                ),
                              ),
                          ],
                        ),
                        onTap:
                            c.ready && !c.busy && c.uncertainOperation == null
                            ? () => _quantity(line)
                            : null,
                        subtitle: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Diminuer la quantité',
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.remove, size: 18),
                              onPressed:
                                  _canEdit &&
                                      steppedQuantity(
                                            line['quantity'] ??
                                                line['quantity_label'],
                                            -1,
                                          ) !=
                                          null
                                  ? () => _stepQuantity(line, -1)
                                  : null,
                            ),
                            Flexible(
                              child: Text(
                                '${line['quantity_label'] ?? ''}',
                                maxLines: 1,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Augmenter la quantité',
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.add, size: 18),
                              onPressed: _canEdit
                                  ? () => _stepQuantity(line, 1)
                                  : null,
                            ),
                          ],
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Tooltip(
                              message:
                                  (c.capabilities['discount']
                                          as Map?)?['reason']
                                      as String? ??
                                  'Remise de ligne',
                              child: IconButton(
                                icon: const Icon(Icons.percent, size: 18),
                                onPressed: _canEdit && _allowed('discount')
                                    ? () => _discount(line)
                                    : null,
                              ),
                            ),
                            SizedBox(
                              width: 85,
                              child: Text(
                                line['total_label'] as String? ?? '',
                                textAlign: TextAlign.right,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Retirer du panier',
                              icon: const Icon(Icons.delete_outline),
                              onPressed:
                                  c.ready &&
                                      !c.busy &&
                                      c.uncertainOperation == null
                                  ? () => c.command(HostCommand.removeLine, {
                                      'line_id': line['id'],
                                    })
                                  : null,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          const Divider(),
          Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  onPressed:
                      _canEdit && _allowed('suspend') && c.lines.isNotEmpty
                      ? () => c.command(HostCommand.suspendDraft, {})
                      : null,
                  icon: const Icon(Icons.pause_circle_outline),
                  label: const Text(
                    'En attente (F8)',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              Expanded(
                child: TextButton.icon(
                  onPressed: _canEdit
                      ? () => showDialog<void>(
                          context: context,
                          builder: (_) => SuspendedDraftsDialog(controller: c),
                        )
                      : null,
                  icon: const Icon(Icons.list_alt),
                  label: Text(
                    'Suspendus (${c.view['suspended_count'] ?? 0})',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
          if (!c.canPay && c.view['pay_reason'] is String && c.lines.isNotEmpty)
            Text(
              c.view['pay_reason'] as String,
              style: const TextStyle(color: Color(0xff974b0c)),
            ),
          if (c.view['totals'] is Map)
            _CompactTotals(totals: c.view['totals'] as Map),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text(
                'À payer',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              Expanded(
                child: Text(
                  c.view['total_label'] as String? ?? '—',
                  textAlign: TextAlign.end,
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              OutlinedButton(
                onPressed: _canEdit && c.lines.isNotEmpty ? _clear : null,
                child: const Text('Vider le panier'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: c.canPay ? _payment : null,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.all(12),
                  ),
                  icon: const Icon(Icons.payments_outlined),
                  label: Text(
                    _allowed('pass') ? 'Scanner le pass (F4)' : 'Payer (F4)',
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _CompactTotals extends StatelessWidget {
  const _CompactTotals({required this.totals});
  final Map totals;
  Widget cell(String label, String key) {
    final raw = totals[key]?.toString() ?? '';
    final value = raw.isEmpty ? '—' : raw;
    return Expanded(
      child: Tooltip(
        message: '$label : $value',
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '$label : ',
                  style: const TextStyle(color: Color(0xff627168)),
                ),
                TextSpan(
                  text: value,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Row(
        children: [
          cell('Remise globale', 'global_discount_label'),
          cell('Livraison', 'delivery_label'),
        ],
      ),
      Row(
        children: [cell('Base HT', 'base_ht_label'), cell('TVA', 'vat_label')],
      ),
    ],
  );
}

class _Payment extends StatefulWidget {
  const _Payment(this.c);
  final WindowsRegisterController c;
  @override
  State<_Payment> createState() => _PaymentState();
}

class _PaymentState extends State<_Payment> {
  WindowsRegisterController get c => widget.c;
  final _received = TextEditingController();
  String? _method;
  bool _cash = false;
  bool _accepted = false;
  String? _inputError;
  Timer? _validation;
  int _editRevision = 0;
  void _scheduleValidation() {
    _validation?.cancel();
    ++_editRevision;
    setState(() {
      _accepted = false;
      _inputError = null;
    });
    _validation = Timer(const Duration(milliseconds: 250), _apply);
  }

  @override
  void dispose() {
    _validation?.cancel();
    _received.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    _validation?.cancel();
    if (!mounted || _method == null) return;
    if (c.busy) {
      _validation = Timer(const Duration(milliseconds: 100), _apply);
      return;
    }
    if (!c.canPay) return;
    final revision = _editRevision;
    final text = _received.text.trim();
    final value = text.isEmpty ? null : int.tryParse(text);
    setState(() {
      _accepted = false;
      _inputError = null;
    });
    if (_cash &&
        text.isNotEmpty &&
        (value == null || value < 0 || !RegExp(r'^\d+$').hasMatch(text))) {
      setState(
        () => _inputError = 'Saisissez un montant entier positif en F CFA.',
      );
      return;
    }
    await c.command(HostCommand.setPayment, {
      'method': _method,
      if (_cash && value != null) 'received': value,
    });
    if (mounted && revision == _editRevision) {
      setState(
        () => _accepted = c.message == null && c.view['payment_valid'] == true,
      );
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) => AlertDialog(
      scrollable: true,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Paiement'),
          PaymentMessage(message: c.message),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              c.view['total_label'] as String? ?? '—',
              style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final method in c.paymentMethods)
                  OutlinedButton.icon(
                    icon: Icon(
                      method['cash'] == true
                          ? Icons.payments_outlined
                          : Icons.account_balance_wallet_outlined,
                    ),
                    onPressed: c.canPay
                        ? () {
                            setState(() {
                              _method = method['code'] as String;
                              _cash = method['cash'] == true;
                              _accepted = false;
                              _received.clear();
                            });
                            ++_editRevision;
                            _apply();
                          }
                        : null,
                    label: Text(method['name'] as String),
                  ),
              ],
            ),
            TextButton.icon(
              onPressed: c.canPay
                  ? () async {
                      _validation?.cancel();
                      ++_editRevision;
                      setState(() => _accepted = false);
                      final committed = await showDialog<bool>(
                        context: context,
                        barrierDismissible: false,
                        builder: (_) => MultiplePayments(controller: c),
                      );
                      if (mounted && context.mounted && committed == true) {
                        Navigator.pop(context);
                      }
                    }
                  : null,
              icon: const Icon(Icons.account_balance_wallet_outlined),
              label: const Text('Plusieurs paiements / référence'),
            ),
            const SizedBox(height: 12),
            if (_cash) ...[
              TextField(
                controller: _received,
                enabled: c.ready && c.uncertainOperation == null,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Montant reçu (F CFA)',
                  helperText: 'Laisser vide pour le montant exact.',
                  errorText: _inputError,
                ),
                onChanged: (_) => _scheduleValidation(),
                onSubmitted: (_) => _apply(),
              ),
              if (!_accepted && _inputError == null && _method != null)
                const Text('Validation automatique du montant…'),
              if (_accepted && c.paymentChange != null)
                Text('Monnaie à rendre : ${c.paymentChange} F CFA'),
              if (_accepted &&
                  (c.view['payment'] as Map?)?['rounding_label'] != null) ...[
                Text(
                  'Arrondi espèces : ${(c.view['payment'] as Map)['rounding_label']}',
                ),
                Text(
                  'À recevoir en espèces : ${(c.view['payment'] as Map)['cash_due_label']}',
                ),
              ],
            ],
            Text(
              c.view['payment_label'] as String? ??
                  'Choisissez un moyen autorisé dans le moteur local.',
            ),
            if (c.uncertainOperation != null)
              TextButton(
                onPressed: c.busy ? null : c.reconcile,
                child: const Text('Vérifier cette vente'),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: c.busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Retour au panier'),
        ),
        FilledButton(
          onPressed: c.canPay && _accepted && c.view['payment_valid'] == true
              ? () async {
                  if (!_accepted ||
                      !c.canPay ||
                      c.view['payment_valid'] != true) {
                    return;
                  }
                  if (!await commitWithApproval(context, c)) return;
                  if (context.mounted &&
                      c.receipt != null &&
                      c.uncertainOperation == null) {
                    Navigator.of(context).pop();
                    unawaited(c.printPendingTicket());
                  }
                }
              : null,
          child: Text(c.busy ? 'Enregistrement…' : 'Confirmer le paiement'),
        ),
      ],
    ),
  );
}
