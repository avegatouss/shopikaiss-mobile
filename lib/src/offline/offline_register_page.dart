import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../app_settings.dart';
import '../diagnostics.dart';
import '../restaurant/resto_context.dart';
import '../restaurant/resto_engine.dart';
import '../sync_v2/decimal6.dart';
import '../terminal/terminal_session.dart';
import '../web/shop_browser_page.dart';
import '../web/shop_browser_policy.dart';
import '../windows/presentation/brand_logo.dart';
import '../windows/presentation/calculator.dart';
import '../windows/presentation/searchable_choice.dart';
import 'engine.dart';
import 'models.dart';
import 'money.dart';
import 'pass_sheet.dart';
import 'pending_operations_page.dart';
import 'ticket.dart';
import 'web_rules.dart';
import 'x_z_report.dart';

part 'restaurant_screen.dart';
part 'restaurant_production_screen.dart';

const _offline = Color(0xFFB45309);

/// Caisse hors ligne : vente sur le dernier catalogue reçu, ticket imprimé, file envoyée au retour de la connexion.
///
/// [onBackOnline] est appelé quand la boutique répond de nouveau et que la file est vide (retour à la caisse web).
class OfflineRegisterPage extends StatefulWidget {
  const OfflineRegisterPage({super.key, required this.engine, required this.session, required this.onBackOnline, this.onOpenSettings});

  final CaisseEngine engine;
  final TerminalSession session;
  final VoidCallback onBackOnline;

  /// Réglages de l'application (code administrateur compris).
  final Future<void> Function()? onOpenSettings;

  @override
  State<OfflineRegisterPage> createState() => _OfflineRegisterPageState();
}

class _OfflineRegisterPageState extends State<OfflineRegisterPage> {
  final _search = TextEditingController();
  final _scanInput = TextEditingController();
  final _searchFocus = FocusNode();
  final List<CartLine> _cart = [];
  final CartTier _tier = CartTier();

  /// Identifiant du panier en cours : consommé par la vente dans la même transaction, renouvelé après l'encaissement.
  /// Un second encaissement du même panier (double appui, écran rejoué) est refusé par la base.
  String _draftUuid = const Uuid().v4();
  Operator? _operator;

  /// Plan de salle affiché à la place de la caisse (Service de table, capacité `restaurant.v1`).
  bool _floor = false;
  Timer? _probe;
  Map<int, BigInt> _sold = {};

  AppSettings get _look => widget.session.settings;
  Color get _brand => Color(_look.brandColor);
  ColorScheme get _palette => ColorScheme.fromSeed(seedColor: _brand);
  bool get _listView => _look.catalogList;
  final _logoTaps = <DateTime>[];

  /// Accès aux réglages : 5 touchers en 3 s sur le logo, comme sur la caisse web.
  void _onLogoTap() {
    final now = DateTime.now();
    _logoTaps
      ..add(now)
      ..removeWhere((t) => now.difference(t) > const Duration(seconds: 3));
    if (_logoTaps.length >= 5) {
      _logoTaps.clear();
      unawaited(_openSettings());
    }
  }

  Future<void> _openSettings() async {
    _keyboardBlocked = null;
    await widget.onOpenSettings?.call();
    if (mounted) setState(_syncKeyboard);
  }

  bool _webOpen = false;
  bool? _keyboardBlocked;

  /// Bloqueur de clavier : seulement sur le champ Scanner, où écrit la douchette. Le blocage vaut pour tout l'appareil :
  /// la recherche, le paiement et les autres fenêtres doivent garder leur clavier.
  void _syncKeyboard() {
    final blocked = _look.hideSoftKeyboard && !_webOpen && FocusManager.instance.primaryFocus == _searchFocus;
    if (blocked == _keyboardBlocked) return;
    _keyboardBlocked = blocked;
    unawaited(widget.session.channel.setSoftKeyboardBlocked(blocked).then<void>((_) {}, onError: (Object _) {}));
  }

  /// Site de la boutique dans le navigateur de l'application : le panier reste sur la caisse locale.
  Future<void> _openShopWeb({required bool admin}) async {
    if (_webOpen) return;
    _webOpen = true;
    try {
      final origin = await _engine.storedOrigin() ?? widget.session.settings.origin;
      final policy = ShopBrowserPolicy(origin);
      _syncKeyboard();
      if (!mounted) return;
      await Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => ShopBrowserPage(policy: policy, admin: admin, deviceCookie: _engine.webToken)));
    } on FormatException catch (error) {
      _toast(error.message);
    } catch (_) {
      _toast('Impossible d’ouvrir le site. Votre panier est conservé.');
    } finally {
      _webOpen = false;
      _syncKeyboard();
    }
  }

  bool _probing = false;
  String? _lastSyncMessage;

  /// Filtres du catalogue (catalogue complet) et nombre de produits affichés, une page de plus à chaque « Afficher plus ».
  static const _productPage = 60;
  String? _category;
  String? _brandFilter;
  String? _supplier;
  int _productLimit = _productPage;

  /// Éléments de vente hors lignes (contrat 2.1).
  DiscountEntry? _globalEntry;
  int _delivery = 0;
  String? _note;
  Customer? _customer;
  SharedCartRef? _shared;

  /// Paniers mis en attente sur ce terminal.
  int _suspendedCount = 0;

  /// Disposition compacte (téléphone de moins de 6 pouces) : onglet affiché, 0 = articles, 1 = panier.
  int _compactTab = 0;

  CaisseEngine get _engine => widget.engine;

  /// Petit téléphone : bandeau resserré, articles et panier en onglets, paiement en plein écran. Les terminaux et
  /// tablettes (6 à 8 pouces, 14 pouces) gardent la disposition standard.
  bool get _compact => widget.session.isCompact(context);
  Snapshot? get _snapshot => _engine.snapshot;

  @override
  void initState() {
    super.initState();
    _engine.addListener(_changed);
    FocusManager.instance.addListener(_syncKeyboard);
    final rules = _snapshot?.rules;
    _probe = Timer.periodic(Duration(seconds: rules?.probeSeconds ?? 20), (_) => _tryOnline(automatic: true));
    if (rules != null && !rules.pinRequired) _operator = _snapshot!.operatorById(_snapshot!.lastOperatorId);
    // TBC : un point de vente restaurant (Service de table ou Restaurant) ouvre directement son écran après la connexion.
    _floor = _engine.restaurant?.restaurantProfile ?? false;
    _refreshSold();
    _refreshSuspended();
  }

  @override
  void dispose() {
    _probe?.cancel();
    _engine.removeListener(_changed);
    FocusManager.instance.removeListener(_syncKeyboard);
    _search.dispose();
    _scanInput.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// Paniers en attente de ce terminal ; ceux vendus ou supprimés ailleurs sont retirés.
  Future<List<StoredDraft>> _suspended() async {
    final drafts = <StoredDraft>[];
    for (final d in await _engine.openDrafts()) {
      if (d.content['suspendu'] != true) continue;
      final ref = SharedCartRef.fromJson(d.content['panier']);
      if (ref != null && await _engine.sharedCartState(ref.uuid) == 'disparu') {
        await _engine.deleteDraft(d.uuid);
      } else {
        drafts.add(d);
      }
    }
    return drafts;
  }

  /// Paniers publiés par le web ou d'autres terminaux, hors ceux déjà listés sur ce terminal.
  Future<List<SharedCart>> _published(List<StoredDraft> drafts) async {
    final linked = {for (final d in drafts) SharedCartRef.fromJson(d.content['panier'])?.uuid};
    return [for (final c in await _engine.sharedCarts()) if (!linked.contains(c.uuid)) c];
  }

  Future<void> _refreshSuspended() async {
    final drafts = await _suspended();
    final count = drafts.length + (await _published(drafts)).length;
    if (mounted) setState(() => _suspendedCount = count);
  }

  void _clearCart() {
    _cart.clear();
    _tier.cart = false;
    _globalEntry = null;
    _delivery = 0;
    _note = null;
    _customer = null;
    _shared = null;
  }

  /// Panier repris vidé à la main : rendu aux autres caisses.
  void _releaseIfEmpty() {
    if (_cart.isNotEmpty || _shared == null) return;
    if (_shared!.claimed && _operator != null) unawaited(_engine.releaseSharedCart(_operator!, _shared!.uuid));
    _shared = null;
  }

  /// Bascule du panier entier ; une remise en montant qui dépasse la ligne au nouveau prix est retirée.
  void _toggleWholesale() => setState(() {
    _tier.cart = !_tier.cart;
    for (final line in _cart) {
      if (line.discountEntry case final entry? when !entry.isPercent && line.discount > line.base) {
        line.discountEntry = null;
        line.discount = 0;
      }
    }
  });

  /// Sous-total du panier (après remises de ligne) : base de la remise globale.
  int get _subtotal => _cart.fold<int>(0, (sum, l) => sum + l.base - l.discount);

  /// Remises en pourcentage recalculées sur le panier courant, comme le web ; une remise globale en montant qui dépasse
  /// le nouveau sous-total est retirée. Rend les totaux affichés et encaissés.
  WebTotals _totals(Snapshot snapshot) {
    _tier.rules = _engine.wholesaleRules;
    for (final line in _cart) {
      final entry = line.discountEntry;
      if (entry != null && entry.isPercent) line.discount = percentDiscount(line.base, parsePercent(entry.value), rounding: _engine.percentRounding);
    }
    final entry = _globalEntry;
    final subtotal = _subtotal;
    if (entry != null && !entry.isPercent && int.parse(entry.value) > subtotal) _globalEntry = null;
    final global = _globalEntry == null
        ? 0
        : enteredDiscount(type: _globalEntry!.type, value: _globalEntry!.value, base: subtotal, rounding: _engine.percentRounding);
    return webTotals(
      lineBases: [for (final l in _cart) l.base],
      lineDiscounts: [for (final l in _cart) l.discount],
      globalDiscount: global,
      vatRate: snapshot.store.vatRate,
      vatIncluded: snapshot.store.vatIncluded,
      delivery: _delivery,
    );
  }

  /// Motif qui empêche d'accorder une remise de ligne, ou null.
  String? get _discountRefusal {
    final operator = _operator;
    if (operator == null) return 'Identifiez le caissier.';
    if (!_engine.hasRight(operator, 'remise')) return '${operator.name} n’a pas le droit d’accorder une remise.';
    if ((_snapshot?.rules.maxLineDiscountPercent ?? 0) <= 0) return 'Aucune remise autorisée hors ligne par la boutique.';
    return null;
  }

  /// Saisie d'une remise (montant ou pourcentage) : rend la saisie validée, null si le caissier annule ; vide = retirer.
  Future<(DiscountEntry?,)?> _askDiscount(String title, DiscountEntry? current, String? Function(DiscountEntry entry) check) {
    final value = TextEditingController(text: current?.value.replaceFirst('.', ',') ?? '');
    var percent = current?.isPercent ?? true;
    String? error;
    return showDialog<(DiscountEntry?,)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<bool>(
                segments: const [ButtonSegment(value: true, label: Text('%')), ButtonSegment(value: false, label: Text('Montant'))],
                selected: {percent},
                onSelectionChanged: (s) => setLocal(() => percent = s.first),
              ),
              TextField(
                controller: value,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: percent ? 'Pourcentage' : 'Montant (F)', errorText: error, errorMaxLines: 3),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, (null,)), child: const Text('Retirer')),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
            FilledButton(
              onPressed: () {
                final text = value.text.trim();
                if (text.isEmpty) return Navigator.pop(context, (null,));
                try {
                  final entry = percent ? DiscountEntry('pourcentage', formatPercent(parsePercent(text))) : DiscountEntry('montant', '${int.tryParse(text) ?? 0}');
                  final refusal = check(entry);
                  if (refusal != null) return setLocal(() => error = refusal);
                  Navigator.pop(context, (entry,));
                } on WebRuleRefusal catch (e) {
                  setLocal(() => error = e.message);
                }
              },
              child: const Text('Valider'),
            ),
          ],
        ),
      ),
    );
  }

  /// Contrôles du web pour une remise de [entry] sur [base] ; [others] = remises déjà accordées sur la vente.
  String? _checkDiscount(DiscountEntry entry, int base, int max, int others, {String? label}) {
    final int amount;
    try {
      amount = enteredDiscount(type: entry.type, value: entry.value, base: base, rounding: _engine.percentRounding, label: label);
    } on WebRuleRefusal catch (e) {
      return e.message;
    }
    if (amount > max) return 'Remise au-delà du maximum autorisé (${formatFcfa(max)}).';
    final saleCap = _engine.enterableSaleDiscount(_operator!);
    if (saleCap != null && others + amount > saleCap) return 'Remises au-delà du plafond de ${_operator!.name} par vente (${formatFcfa(saleCap)}).';
    return null;
  }

  Future<void> _editGlobalDiscount() async {
    final operator = _operator;
    if (operator == null) return _refuse('Identifiez le caissier.');
    if (!_engine.hasRight(operator, 'remise')) return _refuse('${operator.name} n’a pas le droit d’accorder une remise.');
    if ((_snapshot?.rules.maxGlobalDiscountPercent ?? 0) <= 0) return _refuse('Remise globale non autorisée hors ligne dans cette boutique.');
    final subtotal = _subtotal;
    final lines = _cart.fold<int>(0, (sum, l) => sum + l.discount);
    final result = await _askDiscount(
      'Remise globale',
      _globalEntry,
      (entry) => _checkDiscount(entry, subtotal, _engine.enterableGlobalDiscount(operator, subtotal), lines),
    );
    if (result != null) setState(() => _globalEntry = result.$1);
  }

  /// Autorisation d'un responsable, panier définitif : remises au-delà du seuil du caissier. Null si elle est abandonnée.
  Future<SaleApproval?> _askApproval(int globalDiscount) async {
    final cashier = _operator!;
    final lines = List.of(_cart);
    final approvers = _engine.approversFor(cashier, lines, globalDiscount);
    if (approvers.isEmpty) {
      _toast('Remises au-delà du seuil de ${cashier.name} et de celui des responsables : corrigez-les.');
      return null;
    }
    final code = TextEditingController();
    final reason = TextEditingController();
    var approver = approvers.first;
    var busy = false;
    String? error;
    return showDialog<SaleApproval>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Autorisation d’un responsable'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Remise au-delà du seuil de ${cashier.name}.'),
                DropdownButton<Operator>(
                  value: approver,
                  isExpanded: true,
                  items: [for (final o in approvers) DropdownMenuItem(value: o, child: Text(o.name))],
                  onChanged: (o) => setLocal(() => approver = o ?? approver),
                ),
                TextField(
                  controller: code,
                  autofocus: true,
                  obscureText: true,
                  maxLength: 8,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: 'Code du responsable (8 chiffres)', errorText: error),
                ),
                TextField(controller: reason, maxLength: 500, decoration: const InputDecoration(labelText: 'Motif de la remise')),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: const Text('Annuler')),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      setLocal(() => busy = true);
                      try {
                        final approval = await _engine.authorizeDiscount(
                          cashier: cashier,
                          approver: approver,
                          code: code.text.trim(),
                          reason: reason.text,
                          lines: lines,
                          globalDiscount: globalDiscount,
                        );
                        if (context.mounted) Navigator.pop(context, approval);
                      } on OfflineRefusal catch (e) {
                        code.clear();
                        setLocal(() {
                          busy = false;
                          error = e.message;
                        });
                      }
                    },
              child: const Text('Autoriser'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editDelivery() async {
    final operator = _operator;
    if (operator == null) return _toast('Identifiez le caissier.');
    final right = _engine.deliveryRight;
    if (right != null && !_engine.hasRight(operator, right)) return _toast('${operator.name} n’a pas le droit de saisir une livraison.');
    final text = await _askText('Livraison (F)', _delivery == 0 ? '' : '$_delivery', number: true);
    if (text != null) setState(() => _delivery = int.tryParse(text) ?? 0);
  }

  /// Clôture à l'aveugle : aucun attendu affiché. Le terminal exige un commentaire s'il constate un écart, car le contenu
  /// d'une opération ne se corrige plus.
  Future<void> _closeSession() async {
    final operator = _operator!;
    final methods = _snapshot!.methods.where((m) => !m.isCash).toList();
    final cash = TextEditingController();
    final comment = TextEditingController();
    final amounts = {for (final m in methods) m.code: TextEditingController()};
    final notes = {for (final m in methods) m.code: TextEditingController()};
    String? error;
    final closed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Clôturer la session'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: cash,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: 'Espèces comptées (F)'),
                ),
                for (final m in methods) ...[
                  TextField(
                    controller: amounts[m.code],
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(labelText: '${m.name} compté (facultatif)'),
                  ),
                  TextField(controller: notes[m.code], maxLength: 500, decoration: InputDecoration(labelText: 'Justification ${m.name}')),
                ],
                TextField(
                  controller: comment,
                  maxLength: 500,
                  decoration: InputDecoration(labelText: 'Commentaire (obligatoire s’il y a un écart)', errorText: error, errorMaxLines: 3),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
            FilledButton(
              onPressed: () async {
                final counted = int.tryParse(cash.text);
                if (counted == null) return setLocal(() => error = 'Indiquez les espèces comptées.');
                final others = [
                  for (final m in methods)
                    if (int.tryParse(amounts[m.code]!.text) case final amount?)
                      SessionCount(method: m.code, amount: amount, justification: notes[m.code]!.text.trim().isEmpty ? null : notes[m.code]!.text.trim()),
                ];
                try {
                  await _engine.closeSession(operator, cash: counted, comment: comment.text, others: others);
                  if (context.mounted) Navigator.pop(context, true);
                } on OfflineRefusal catch (e) {
                  setLocal(() => error = e.message);
                }
              },
              child: const Text('Clôturer'),
            ),
          ],
        ),
      ),
    );
    if (closed == true) {
      _changed();
      _toast('Session clôturée. Le Z de la boutique arrivera à la prochaine synchronisation.');
      if (!mounted || await _engine.closureFacts() == null || !mounted) return;
      final version = await _askZVersion('Session clôturée', 'Imprimer le Z de session de ce terminal ?', later: true);
      if (version != null) await _printClosure(ZKind.session, version);
    }
  }

  /// Menu de session : pré-X (rien n'est clôturé), clôture suivie du Z détaillé ou court, pré-Z du jour pour ce
  /// terminal, duplicata du dernier Z. Documents calculés et imprimés sur le terminal, sans réseau.
  Future<void> _sessionMenu() async {
    final operator = _operator;
    if (operator == null) return;
    final canClose = _engine.canCloseSession(operator) && _cart.isEmpty;
    final choice = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.receipt_outlined),
                title: const Text('Imprimer un pré-X'),
                subtitle: const Text('Point provisoire de la session ouverte, sans clôturer'),
                enabled: _engine.sessionOpen,
                onTap: () => Navigator.pop(context, 'prex'),
              ),
              ListTile(
                leading: const Icon(Icons.lock_outline),
                title: const Text('Clôturer la session'),
                subtitle: const Text('Comptage à l’aveugle, puis Z détaillé ou court'),
                enabled: canClose,
                onTap: () => Navigator.pop(context, 'cloture'),
              ),
              ListTile(
                leading: const Icon(Icons.today_outlined),
                title: const Text('Imprimer un pré-Z du jour'),
                subtitle: const Text('Sessions de ce terminal aujourd’hui, rien n’est clôturé'),
                enabled: _engine.hasRight(operator, 'caisse_cloturer'),
                onTap: () => Navigator.pop(context, 'prez'),
              ),
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: const Text('Réimprimer le dernier Z'),
                subtitle: const Text('Duplicata du Z de la dernière session clôturée ici'),
                onTap: () => Navigator.pop(context, 'duplicata'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'cloture':
        return _closeSession();
      case 'prex':
        if (await _askZVersion('Pré-X', 'Point provisoire : rien n’est clôturé.') case final version?) await _printClosure(ZKind.preX, version);
      case 'prez':
        if (await _askZVersion('Pré-Z du jour', 'Sessions de ce terminal aujourd’hui : rien n’est clôturé.') case final version?) await _printClosure(ZKind.preZ, version);
      case 'duplicata':
        if (await _askZVersion('Duplicata du dernier Z', 'Réimpression du Z de la dernière session clôturée sur ce terminal.') case final version?) {
          await _printClosure(ZKind.session, version, duplicate: true);
        }
    }
  }

  /// Version à imprimer : Z détaillé (article par article) ou Z court (résumé) ; null : rien.
  Future<String?> _askZVersion(String title, String message, {bool later = false}) => showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(later ? 'Plus tard' : 'Annuler')),
        TextButton(onPressed: () => Navigator.pop(context, ZVersion.short), child: const Text('Z court')),
        FilledButton(onPressed: () => Navigator.pop(context, ZVersion.detailed), child: const Text('Z détaillé')),
      ],
    ),
  );

  /// Document de clôture calculé sur les opérations du terminal, imprimé en texte (§3 d'IMPRESSION-X-Z).
  Future<void> _printClosure(String kind, String version, {bool duplicate = false}) async {
    final snapshot = _snapshot;
    final facts = await _engine.closureFacts();
    if (snapshot == null || facts == null) return _toast('Documents de clôture non disponibles sur ce terminal.');
    final context = ZContext.of(snapshot);
    final now = _engine.now;
    final Map<String, dynamic> model;
    if (kind == ZKind.preZ) {
      model = dayZModel(facts, context, day: now, now: now);
    } else {
      final session = kind == ZKind.preX ? facts.openSession : facts.lastClosed;
      if (session == null) return _toast(kind == ZKind.preX ? 'Aucune session ouverte sur ce terminal.' : 'Aucune session clôturée sur ce terminal.');
      model = sessionZModel(facts, session, context, kind: kind, now: now, duplicate: duplicate);
    }
    final width = widget.session.rollWidth > 0 ? widget.session.rollWidth : 58;
    final printout = layoutClosureTicket(closureTicket(model, version), paperWidth: width);
    await _printText(printout.lines, failure: 'Document non imprimé', bytes: printout.bytes());
  }

  /// Choix du client de la vente : recherche par nom ou téléphone, création si le caissier en a le droit.
  Future<void> _pickCustomer() async {
    var results = await _engine.searchCustomers('');
    if (!mounted) return;
    final creatable = _operator != null && _engine.canCreateCustomer(_operator!);
    final result = await showDialog<(Customer?,)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Client de la vente'),
          content: SizedBox(
            width: 360,
            height: 320,
            child: Column(
              children: [
                TextField(
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Nom ou téléphone'),
                  onChanged: (text) async {
                    final found = await _engine.searchCustomers(text);
                    setLocal(() => results = found);
                  },
                ),
                Expanded(
                  child: results.isEmpty
                      ? const Center(child: Text('Aucun client.'))
                      : ListView(
                          children: [
                            for (final c in results)
                              ListTile(
                                dense: true,
                                title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                                subtitle: Text('${c.phone ?? 'Sans téléphone'}${c.pending ? ' · en attente d’envoi' : ''}'),
                                onTap: () => Navigator.pop(context, (c,)),
                              ),
                          ],
                        ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, (null,)), child: const Text('Client de passage')),
            if (creatable)
              TextButton(
                onPressed: () async {
                  final created = await _askNewCustomer();
                  if (created != null && context.mounted) Navigator.pop(context, (created,));
                },
                child: const Text('Nouveau client'),
              ),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
          ],
        ),
      ),
    );
    if (result != null) setState(() => _customer = result.$1);
  }

  Future<Customer?> _askNewCustomer() {
    final name = TextEditingController();
    final phone = TextEditingController();
    String? error;
    return showDialog<Customer>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Nouveau client'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: name, autofocus: true, maxLength: 160, decoration: const InputDecoration(labelText: 'Nom')),
                TextField(controller: phone, keyboardType: TextInputType.phone, maxLength: 40, decoration: InputDecoration(labelText: 'Téléphone', errorText: error)),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
            FilledButton(
              onPressed: () async {
                try {
                  final customer = await _engine.createCustomer(_operator!, name: name.text, phone: phone.text);
                  if (context.mounted) Navigator.pop(context, customer);
                } on OfflineRefusal catch (e) {
                  setLocal(() => error = e.message);
                }
              },
              child: const Text('Créer'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editNote() async {
    final text = await _askText('Note du ticket', _note ?? '', maxLength: 2000);
    if (text != null) setState(() => _note = text.trim().isEmpty ? null : text.trim());
  }

  Future<String?> _askText(String title, String current, {bool number = false, int? maxLength}) {
    final value = TextEditingController(text: current);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: value,
          autofocus: true,
          maxLength: maxLength,
          maxLines: number ? 1 : 3,
          keyboardType: number ? TextInputType.number : TextInputType.multiline,
          inputFormatters: number ? [FilteringTextInputFormatter.digitsOnly] : null,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, value.text), child: const Text('Valider')),
        ],
      ),
    );
  }

  /// Contenu conservé d'un panier en attente : même forme que l'adaptateur Windows.
  Map<String, dynamic> _draftContent() => {
    'lignes': [
      for (final (i, l) in _cart.indexed)
        {
          'id': '$i',
          'produit_id': l.product.id,
          'conditionnement_id': l.packaging?.id,
          'quantite': formatMicros(l.quantity),
          'remise': l.discount,
          if (l.discountEntry != null) 'remise_saisie': l.discountEntry!.toJson(),
          if (l.lot != null) 'lot_uuid': l.lot!.uuid,
        },
    ],
    if (_tier.cart) 'tarif_gros': true,
    if (_globalEntry != null) 'remise_globale_saisie': _globalEntry!.toJson(),
    if (_delivery != 0) 'livraison': _delivery,
    if (_note != null) 'note': _note,
    if (_shared != null) 'panier': _shared!.toJson(),
    if (_customer != null) 'client': {'uuid': _customer!.uuid, 'nom': _customer!.name},
    'paiements': const [],
    'suspendu': true,
  };

  Future<void> _suspendCart() async {
    if (_cart.isEmpty) return;
    if (_engine.sharedCartsSupported && _operator != null) {
      try {
        final totals = _totals(_snapshot!);
        _shared = await _engine.suspendShared(
          _operator!,
          List.of(_cart),
          SaleExtras(wholesale: _tier.cart, globalDiscount: totals.globalDiscount, delivery: _delivery, note: _note, customer: _customer),
          previous: _shared,
        );
      } on OfflineRefusal catch (e) {
        return _toast(e.message);
      }
    }
    if (!await _engine.saveDraft(_draftUuid, 1, _draftContent())) return _toast('Ce panier a déjà été enregistré.');
    setState(() {
      _clearCart();
      _draftUuid = const Uuid().v4();
    });
    await _refreshSuspended();
    _toast('Panier mis en attente.');
  }

  /// Reprise d'un panier en attente, au catalogue et aux prix courants ; un article disparu est signalé et retiré.
  Future<void> _openSuspended(Snapshot snapshot) async {
    final drafts = await _suspended();
    final published = await _published(drafts);
    if (!mounted) return;
    final chosen = await showDialog<(Object, bool)>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Paniers en attente'),
        children: [
          if (drafts.isEmpty && published.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('Aucun panier en attente.')),
          for (final d in drafts)
            ListTile(
              title: Text('${(d.content['lignes'] as List).length} article(s)'),
              subtitle: Text(d.updatedAt.toLocal().toString().substring(0, 16)),
              onTap: () => Navigator.pop(context, (d, true)),
              trailing: IconButton(tooltip: 'Supprimer', icon: const Icon(Icons.delete_outline), onPressed: () => Navigator.pop(context, (d, false))),
            ),
          for (final c in published)
            ListTile(
              enabled: !c.takenElsewhere,
              title: Text(c.label),
              subtitle: Text('${c.linesCount} article(s)${c.takenElsewhere ? ' · repris sur une autre caisse' : ' · partagé'}'),
              onTap: () => Navigator.pop(context, (c, true)),
              trailing: c.takenElsewhere
                  ? null
                  : IconButton(tooltip: 'Supprimer', icon: const Icon(Icons.delete_outline), onPressed: () => Navigator.pop(context, (c, false))),
            ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    final (target, resume) = chosen;
    if (target is SharedCart) return _openPublished(target, resume);
    final draft = target as StoredDraft;
    var ref = SharedCartRef.fromJson(draft.content['panier']);
    if (!resume) {
      if (ref != null && _operator != null) await _engine.deleteSharedCart(_operator!, ref.uuid);
      await _engine.deleteDraft(draft.uuid);
      return _refreshSuspended();
    }
    // Un panier déjà publié ne se reprend qu'avec l'accord du serveur.
    if (ref != null && await _engine.sharedCartState(ref.uuid) == 'publie') {
      if (_operator == null) return _toast('Identifiez le caissier.');
      try {
        ref = (await _engine.takeSharedCart(_operator!, ref.uuid)).ref;
      } on OfflineRefusal catch (e) {
        return _toast(e.message);
      }
    }
    if (_cart.isNotEmpty) await _suspendCart();
    final lines = <CartLine>[];
    var missing = 0;
    for (final raw in (draft.content['lignes'] as List).cast<Map>()) {
      final product = snapshot.products.where((p) => p.id == raw['produit_id']).firstOrNull;
      final packagingId = raw['conditionnement_id'] as int?;
      final packaging = packagingId == null ? null : product?.packaging(packagingId);
      if (product == null || (packagingId != null && packaging == null)) {
        missing++;
        continue;
      }
      final entry = raw['remise_saisie'] as Map?;
      lines.add(CartLine(
        product: product,
        packaging: packaging,
        quantity: parseMicros(raw['quantite'] as String),
        discount: raw['remise'] as int,
        discountEntry: entry == null ? null : DiscountEntry.fromJson(entry),
        fixedPrice: raw['prix_fige'] as int?,
        lot: product.lots.where((l) => l.uuid == raw['lot_uuid']).firstOrNull,
        tier: _tier,
      ));
    }
    await _engine.deleteDraft(draft.uuid);
    final global = draft.content['remise_globale_saisie'] as Map?;
    setState(() {
      _clearCart();
      _cart.addAll(lines);
      _tier.cart = draft.content['tarif_gros'] == true;
      _globalEntry = global == null ? null : DiscountEntry.fromJson(global);
      _delivery = draft.content['livraison'] as int? ?? 0;
      _note = draft.content['note'] as String?;
      _customer = customerFromDraft(draft.content['client']);
      _shared = ref;
    });
    await _refreshSuspended();
    if (missing > 0) _toast('$missing article(s) retiré(s) du catalogue : non repris.');
  }

  /// Panier publié par le web ou un autre terminal : reprise exclusive, prix figés par le serveur.
  Future<void> _openPublished(SharedCart cart, bool resume) async {
    final operator = _operator;
    if (operator == null) return _toast('Identifiez le caissier.');
    if (!resume) {
      await _engine.deleteSharedCart(operator, cart.uuid);
      return _refreshSuspended();
    }
    final TakenCart taken;
    try {
      taken = await _engine.takeSharedCart(operator, cart.uuid);
    } on OfflineRefusal catch (e) {
      return _toast(e.message);
    }
    if (_cart.isNotEmpty) await _suspendCart();
    setState(() {
      _clearCart();
      _cart.addAll([for (final l in taken.lines) l..tier = _tier]);
      _tier.cart = taken.wholesale;
      _globalEntry = taken.globalDiscount == 0 ? null : DiscountEntry('montant', '${taken.globalDiscount}');
      _delivery = taken.delivery;
      _note = taken.note;
      _customer = taken.customer;
      _shared = taken.ref;
    });
    await _refreshSuspended();
  }

  /// Actions du panier : remise globale, livraison et note exigent le contrat 2.1.
  Future<void> _refreshSold() async {
    final sold = await _engine.soldSinceSnapshot();
    if (mounted) setState(() => _sold = sold);
  }

  /// Retour de la connexion : envoi de la file, puis retour à la caisse web si tout est parti (ou sur demande).
  Future<void> _tryOnline({bool automatic = false}) async {
    if (_probing) return;
    _probing = true;
    try {
      if (!await _engine.probe()) {
        if (!automatic) _toast('La boutique ne répond toujours pas.');
        return;
      }
      final report = await _engine.sync();
      // Images : hors vente seulement, pour ne jamais ralentir un encaissement.
      if (_cart.isEmpty) unawaited(_engine.downloadImages(interrupted: () => _cart.isNotEmpty).then((added) => added > 0 ? _changed() : null));
      setState(
        () => _lastSyncMessage = report.sent > 0
            ? '${report.sent} opération(s) envoyée(s) : ${report.integrated} intégrée(s)${report.pending > 0 ? ', ${report.pending} à arbitrer par la boutique' : ''}${report.refused > 0 ? ', ${report.refused} refusée(s)' : ''}.'
            : report.message,
      );
      if (_engine.permanentLocal) {
        // Vente locale permanente : la synchronisation tourne en arrière-plan, la caisse reste locale. Le catalogue
        // (stock, prix) est relu à l'intervalle réglé ; seule une demande explicite ouvre la caisse web.
        if (_engine.snapshotStale) unawaited(_engine.refreshSnapshot().then((_) => _refreshSold()));
        if (!automatic) {
          if (_cart.isNotEmpty) {
            _toast('Terminez ou videz ce panier avant d’ouvrir la caisse web.');
          } else {
            widget.onBackOnline();
          }
        }
        return;
      }
      if (_engine.pendingCount > 0) return;
      unawaited(_engine.refreshSnapshot());
      if (_cart.isNotEmpty) {
        _toast('Connexion rétablie : terminez cette vente, puis revenez à la caisse en ligne.');
        return;
      }
      if (!_webOpen && (!automatic || (_snapshot?.rules.automaticSwitch ?? true))) widget.onBackOnline();
    } finally {
      _probing = false;
    }
  }

  /// Refus d'une action demandée : fenêtre à fermer, le message ne disparaît pas sans avoir été lu.
  Future<void> _refuse(String message, {String title = 'Remise impossible'}) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Compris'))],
      ),
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final reason = _engine.blockReason;
    return PopScope(
      canPop: false,
      child: Theme(
        data: Theme.of(context).copyWith(colorScheme: _palette),
        child: Scaffold(
        backgroundColor: const Color(0xFFF6F7F6),
        body: SafeArea(
          child: Column(
            children: [
              _header(),
              Expanded(
                child: reason != null || snapshot == null
                    ? _scrollable(_Blocked(message: reason ?? 'Catalogue absent.', onRetry: () => _tryOnline()))
                    : _operator == null
                    ? _scrollable(_OperatorLogin(engine: _engine, onLogged: (o) => setState(() {
                          _operator = o;
                          _floor = (_engine.restaurant?.restaurantProfile ?? false) && _cart.isEmpty;
                        })))
                    : !_engine.sessionOpen
                    ? _scrollable(_SessionOpening(engine: _engine, operator: _operator!, onOpened: () => setState(() {})))
                    : _floor && (_engine.restaurant?.tableService ?? false)
                    ? _RestaurantFloor(host: this)
                    : _floor && (_engine.restaurant?.production ?? false)
                    ? _RestaurantBoard(host: this)
                    : _register(snapshot),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }

  /// En-tête de la caisse Windows : logo, boutique, état, puis barre d'actions défilante.
  Widget _header() {
    final remaining = _engine.remaining;
    final contact = _engine.lastContact;
    String two(int v) => v.toString().padLeft(2, '0');
    final since = contact == null
        ? 'jamais'
        : '${two(contact.toLocal().day)}/${two(contact.toLocal().month)} ${two(contact.toLocal().hour)}:${two(contact.toLocal().minute)}';
    final status = _engine.permanentLocal
        ? _localStatus(short: _compact)
        : _compact
        ? 'Hors ligne${remaining != null ? ' · reste ${remaining.inHours} h' : ''} · ${_engine.pendingCount} en attente'
        : 'Caisse hors ligne · dernier contact $since${remaining != null ? ' · reste ${remaining.inHours} h ${two(remaining.inMinutes % 60)}' : ''} · ${_engine.pendingCount} en attente';
    return Material(
      color: Colors.white,
      elevation: 1,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 10),
            child: Row(
              children: [
                GestureDetector(
                  key: const ValueKey('register-logo'),
                  behavior: HitTestBehavior.opaque,
                  onTap: _onLogoTap,
                  child: ShopikaissLogo(width: _compact ? 92 : 125),
                ),
                const SizedBox(width: 10),
                if (!_compact && _snapshot != null)
                  Flexible(child: Text(_snapshot!.store.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 10),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(color: _bannerColor.withValues(alpha: .1), borderRadius: BorderRadius.circular(16)),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(_bannerIcon, color: _bannerColor, size: 16),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(status, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: _bannerColor, fontSize: 12, fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Synchroniser',
                  onPressed: _engine.syncing ? null : () => _tryOnline(),
                  icon: _engine.syncing ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh),
                ),
                _registerMenu(),
              ],
            ),
          ),
          _toolbar(),
        ],
      ),
    );
  }

  Widget _toolbar() {
    final operator = _operator;
    final canClose = operator != null && _engine.canCloseSession(operator) && _cart.isEmpty;
    final extras = _engine.saleExtrasSupported && _cart.isNotEmpty;
    final wholesale = _engine.wholesaleRules;
    Widget action(String label, IconData icon, VoidCallback? onPressed) =>
        TextButton.icon(onPressed: onPressed, icon: Icon(icon, size: 18), label: Text(label), style: TextButton.styleFrom(visualDensity: VisualDensity.compact));
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      child: Row(
        children: [
          SegmentedButton<bool>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(value: false, icon: Icon(Icons.grid_view, size: 18), label: Text('Visuelle')),
              ButtonSegment(value: true, icon: Icon(Icons.view_list, size: 18), label: Text('Compacte')),
            ],
            selected: {_listView},
            onSelectionChanged: (value) {
              setState(() => _look.catalogList = value.single);
              unawaited(widget.session.save());
            },
          ),
          const SizedBox(width: 8),
          if (_engine.restaurant?.restaurantProfile ?? false) ...[
            SegmentedButton<bool>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: [
                ButtonSegment(
                  value: true,
                  icon: const Icon(Icons.table_restaurant, size: 18),
                  label: Text((_engine.restaurant?.production ?? false) ? 'Commandes' : 'Salle'),
                ),
                ButtonSegment(value: false, icon: Icon(Icons.point_of_sale, size: 18), label: Text('Caisse')),
              ],
              selected: {_floor},
              // Le panier de la caisse reste à part : on ne passe en salle qu'avec un panier vide.
              onSelectionChanged: _cart.isEmpty ? (value) => setState(() => _floor = value.single) : null,
            ),
            const SizedBox(width: 8),
          ],
          if (operator != null)
            action(operator.name, Icons.person_outline, _cart.isEmpty && (_snapshot?.rules.pinRequired ?? true) ? () => setState(() => _operator = null) : null),
          action('Ventes récentes', Icons.history, _openJournal),
          action('Reçu', Icons.receipt_long_outlined, _openJournal),
          action(_note == null ? 'Note' : 'Note ✓', Icons.note_alt_outlined, extras ? _editNote : null),
          if (_tier.cart || (wholesale != null && wholesale.manual && operator != null && _engine.hasRight(operator, wholesale.right)))
            // Comme au web : le mode d'un panier repris est figé.
            action(_tier.cart ? 'Tarif détail' : 'Tarif gros', Icons.sell_outlined, _shared == null ? _toggleWholesale : null),
          action('Session de caisse', Icons.point_of_sale, operator != null && _cart.isEmpty && (canClose || _engine.sessionOpen) ? _sessionMenu : null),
          if (operator != null && (_engine.restaurant?.restaurantProfile ?? false)) action('Registre', Icons.event_note, () => _restoRegisterDialog(this)),
          action(_look.hideSoftKeyboard ? 'Clavier masqué' : 'Clavier affiché', _look.hideSoftKeyboard ? Icons.keyboard_hide : Icons.keyboard, () {
            setState(() => _look.hideSoftKeyboard = !_look.hideSoftKeyboard);
            unawaited(widget.session.save());
            _syncKeyboard();
          }),
          action('Calculatrice', Icons.calculate_outlined, () => showDialog<void>(context: context, builder: (_) => const DeskCalculator())),
          action('Back-office web', Icons.dashboard_outlined, () => _openShopWeb(admin: true)),
          action(_engine.permanentLocal ? 'Ouvrir la caisse web' : 'Reconnecter', _engine.permanentLocal ? Icons.open_in_browser : Icons.wifi_find, _engine.syncing ? null : () => _tryOnline()),
        ],
      ),
    );
  }

  bool get _localOnline => _engine.permanentLocal && _engine.reachable == true;
  Color get _bannerColor => _localOnline ? _brand : _offline;
  IconData get _bannerIcon => _localOnline ? (_engine.pendingCount == 0 ? Icons.cloud_done : Icons.cloud_upload) : Icons.cloud_off;

  /// État de la caisse locale permanente, en mots distincts pour des situations distinctes (doc 06 § D).
  String _localStatus({bool short = false}) {
    final parts = <String>[];
    if (_engine.reachable == true) {
      parts.add(_engine.pendingCount == 0 ? 'Caisse locale · à jour' : 'Caisse locale · ${_engine.pendingCount} à transmettre');
    } else {
      final remaining = _engine.remaining;
      parts.add(short ? 'Connexion interrompue' : 'Connexion interrompue — vente locale disponible');
      if (remaining != null) parts.add('reste ${remaining.inHours} h');
      if (_engine.pendingCount > 0) parts.add('${_engine.pendingCount} à transmettre');
    }
    if (_engine.localArbitrationCount > 0) parts.add('${_engine.localArbitrationCount} à arbitrer');
    if (!short && _engine.snapshotStale) parts.add('catalogue ancien');
    return parts.join(' · ');
  }

  /// Petit téléphone : l'écran défile (clavier ouvert, écran court) ; disposition standard inchangée.
  Widget _scrollable(Widget child) => _compact ? SingleChildScrollView(padding: const EdgeInsets.symmetric(vertical: 12), child: child) : child;

  /// Bandeau d'un petit téléphone : une ligne, reconnexion en icône, caissier et journal dans un menu.
  Widget _registerMenu() => PopupMenuButton<String>(
    onSelected: (choice) {
      if (choice == 'journal') {
        _openJournal();
      } else if (choice == 'caissier') {
        setState(() => _operator = null);
      } else if (choice == 'cloture') {
        _closeSession();
      } else if (choice == 'session') {
        _sessionMenu();
      } else if (choice == 'registre') {
        _restoRegisterDialog(this);
      } else if (choice == 'images') {
        _editImageWindow();
      } else if (choice == 'site') {
        _openShopWeb(admin: false);
      } else if (choice == 'reglages') {
        _openSettings();
      }
    },
    itemBuilder: (context) => [
      if (_lastSyncMessage != null) PopupMenuItem<String>(enabled: false, child: Text(_lastSyncMessage!)),
      const PopupMenuItem(value: 'journal', child: Text('Ventes et retours')),
      const PopupMenuItem(value: 'site', child: Text('Site de la boutique')),
      if (widget.onOpenSettings != null) const PopupMenuItem(value: 'reglages', child: Text('Réglages')),
      if (_engine.imagesSupported) const PopupMenuItem(value: 'images', child: Text('Horaires des images')),
      if (_operator != null && _engine.canCloseSession(_operator!))
        PopupMenuItem(value: 'cloture', enabled: _cart.isEmpty, child: const Text('Clôturer la session')),
      if (_operator != null && (_engine.sessionOpen || _engine.canCloseSession(_operator!)))
        PopupMenuItem(value: 'session', enabled: _cart.isEmpty, child: const Text('Pré-X, pré-Z et Z')),
      if (_operator != null && (_engine.restaurant?.restaurantProfile ?? false))
        const PopupMenuItem(value: 'registre', child: Text('Registre (journée)')),
      if (_operator != null)
        PopupMenuItem(
          value: 'caissier',
          enabled: _cart.isEmpty && (_snapshot?.rules.pinRequired ?? true),
          child: Text('Changer de caissier (${_operator!.name})'),
        ),
    ],
  );

  /// Plage de téléchargement des images de ce terminal ; une vente qui commence arrête le lot.
  Future<void> _editImageWindow() async {
    final counts = _engine.imageCounts();
    final current = _engine.imageWindow;
    final start = TextEditingController(text: current?.start ?? '22:00');
    final end = TextEditingController(text: current?.end ?? '06:00');
    var limited = current != null;
    String? error;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('Horaires des images'),
          scrollable: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${counts.cached} / ${counts.total} photos sur ce terminal'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Limiter à une plage horaire'),
                value: limited,
                onChanged: (v) => setDialog(() => limited = v),
              ),
              if (limited) ...[
                TextField(controller: start, keyboardType: TextInputType.datetime, decoration: const InputDecoration(labelText: 'Début · HH:MM')),
                TextField(controller: end, keyboardType: TextInputType.datetime, decoration: InputDecoration(labelText: 'Fin · HH:MM', errorText: error)),
                const SizedBox(height: 8),
                const Text('Heure de ce téléphone. Une plage 22:00–06:00 passe minuit.', style: TextStyle(fontSize: 12)),
              ],
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
            FilledButton(
              onPressed: () async {
                final first = start.text.trim();
                final last = end.text.trim();
                if (limited && !validTimeWindow(first, last)) {
                  setDialog(() => error = 'Indiquez deux heures différentes, au format HH:MM.');
                  return;
                }
                await _engine.setImageWindow(limited ? (start: first, end: last) : null);
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('Enregistrer'),
            ),
          ],
        ),
      ),
    );
    start.dispose();
    end.dispose();
  }

  /// Petit téléphone : articles ou panier en plein écran, barre fixe avec le total et « Encaisser ».
  Widget _compactRegister(Snapshot snapshot) {
    final totals = _totals(snapshot);
    final count = _cart.length;
    return Column(
      children: [
        Expanded(
          child: IndexedStack(index: _compactTab, children: [_catalogue(snapshot), _cartPanel(snapshot, footer: false)]),
        ),
        Material(
          key: const ValueKey('compact-checkout-bar'),
          color: Colors.white,
          elevation: 8,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                OutlinedButton.icon(
                  onPressed: () => setState(() => _compactTab = _compactTab == 0 ? 1 : 0),
                  icon: Badge(
                    isLabelVisible: count > 0 && _compactTab == 0,
                    label: Text('$count'),
                    child: Icon(_compactTab == 0 ? Icons.shopping_cart : Icons.grid_view),
                  ),
                  label: Text(_compactTab == 0 ? 'Panier' : 'Articles'),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FittedBox(
                    alignment: Alignment.centerRight,
                    fit: BoxFit.scaleDown,
                    child: Text(
                      formatFcfa(totals.payable),
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: _brand),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (_passButton(snapshot, totals.payable) case final pass?) ...[pass, const SizedBox(width: 8)],
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: _brand, minimumSize: const Size(0, 48)),
                  onPressed: _cart.isEmpty ? null : () => _checkout(snapshot, totals.payable),
                  child: const Text('Payer'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _register(Snapshot snapshot) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Deux colonnes dès que la largeur le permet ; sinon catalogue et panier à onglets, sans réduire les touches.
        if (_compact || constraints.maxWidth < 760) return _compactRegister(snapshot);
        return Row(
          children: [
            Expanded(child: _catalogue(snapshot)),
            SizedBox(width: _look.cartWidth.toDouble(), child: _cartPanel(snapshot)),
          ],
        );
      },
    );
  }

  Widget _catalogue(Snapshot snapshot) {
    final results = snapshot.search(_search.text, limit: null, category: _category, brand: _brandFilter, supplier: _supplier);
    final shown = results.length.clamp(0, _productLimit);
    final tile = _look.tileWidth.toDouble();
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _scanInput,
                  focusNode: _searchFocus,
                  autofocus: true,
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: Colors.white,
                    labelText: 'Scanner',
                    prefixIcon: const Icon(Icons.qr_code_scanner),
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(tooltip: 'Ajouter le code scanné', icon: const Icon(Icons.arrow_forward), onPressed: () => _scan(snapshot, _scanInput.text)),
                  ),
                  onSubmitted: (value) => _scan(snapshot, value),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _search,
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: Colors.white,
                    labelText: 'Rechercher un produit',
                    border: const OutlineInputBorder(),
                    suffixIcon: _search.text.isEmpty ? const Icon(Icons.search) : IconButton(icon: const Icon(Icons.clear), onPressed: () => setState(_search.clear)),
                  ),
                  onChanged: (_) => setState(() => _productLimit = _productPage),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (snapshot.categories.isNotEmpty)
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final category in [null, ...snapshot.categories])
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(category ?? 'Voir tout'),
                        selected: _category == category,
                        onSelected: (_) => setState(() {
                          _category = category;
                          _productLimit = _productPage;
                        }),
                      ),
                    ),
                ],
              ),
            ),
          if (snapshot.suppliers.isNotEmpty || snapshot.brands.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  if (snapshot.suppliers.isNotEmpty) Expanded(child: _filter('Fournisseur', 'Tous les fournisseurs', _supplier, snapshot.suppliers, (v) => _supplier = v)),
                  if (snapshot.suppliers.isNotEmpty && snapshot.brands.isNotEmpty) const SizedBox(width: 8),
                  if (snapshot.brands.isNotEmpty) Expanded(child: _filter('Marque', 'Toutes les marques', _brandFilter, snapshot.brands, (v) => _brandFilter = v)),
                ],
              ),
            ),
          Row(
            children: [
              Expanded(child: Text('$shown / ${results.length} produits', style: const TextStyle(fontSize: 12))),
              if (_category != null || _brandFilter != null || _supplier != null)
                TextButton(
                  onPressed: () => setState(() {
                    _category = _brandFilter = _supplier = null;
                    _productLimit = _productPage;
                  }),
                  child: const Text('Effacer'),
                ),
              if (results.length > _productLimit)
                TextButton.icon(
                  onPressed: () => setState(() => _productLimit += _productPage),
                  icon: const Icon(Icons.expand_more),
                  label: Text('Afficher plus (${results.length - _productLimit})'),
                ),
            ],
          ),
          Expanded(
            child: results.isEmpty
                ? const Center(child: Text('Aucun article à afficher.', textAlign: TextAlign.center))
                : _listView
                ? ListView.separated(
                    itemCount: shown,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) => _productRow(results[index]),
                  )
                : GridView.builder(
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: tile,
                      mainAxisExtent: tile * 115 / 175 + 24 + (_look.imageMode == 'top' ? 68 : 0),
                      crossAxisSpacing: 4,
                      mainAxisSpacing: 4,
                    ),
                    itemCount: shown,
                    itemBuilder: (context, index) => _productTile(results[index]),
                  ),
          ),
        ],
      ),
    );
  }

  /// Filtre du catalogue, avec recherche ; porte sur tout le catalogue.
  Widget _filter(String label, String all, String? value, List<String> values, void Function(String?) select) => SearchableChoice(
    label: label,
    all: all,
    values: values,
    selected: value ?? '',
    onChanged: (choice) => setState(() {
      select(choice.isEmpty ? null : choice);
      _productLimit = _productPage;
    }),
  );

  /// Pastilles de la caisse Windows : défilent sur une ligne au lieu de pousser la tuile.
  Widget _badges(Product product, BigInt stock) {
    final now = DateTime.now();
    final promotion = product.promotionLabel(now.toIso8601String().substring(0, 10));
    final threshold = product.alertThreshold;
    final low = !product.unlimitedStock && threshold != null && stock <= threshold;
    final labels = [
      if (low) 'Stock faible',
      ?promotion,
      if (product.isNew(_engine.newBadgeDays, now)) 'Nouveau',
      if (product.favorite) '★ Favori',
    ];
    if (labels.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 22,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final label in labels)
            Container(
              margin: const EdgeInsets.only(right: 4),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(color: label == 'Stock faible' ? const Color(0xFFFFEDC2) : const Color(0xFFE3EEE7), borderRadius: BorderRadius.circular(8)),
              child: Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF27382F))),
            ),
        ],
      ),
    );
  }

  /// Image du cache local, ou substitut : aucune requête à l'affichage.
  Widget _imageSlot(Product product, {bool large = false}) {
    final path = product.image == null ? null : _engine.imagePath(product.image!);
    final fit = _look.imageFit == 'contain' ? BoxFit.contain : BoxFit.cover;
    final height = large ? 60.0 : 44.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: large ? double.infinity : 44,
        height: height,
        color: _palette.primaryContainer.withValues(alpha: .6),
        child: path == null
            ? Icon(Icons.inventory_2_outlined, color: _palette.primary, size: large ? 30 : 22)
            : Image.file(File(path), fit: fit, cacheWidth: large ? 360 : 132, errorBuilder: (_, _, _) => Icon(Icons.inventory_2_outlined, color: _palette.primary)),
      ),
    );
  }

  /// Quantité déjà demandée par le panier pour ce produit, en unité de base.
  BigInt _inCart(Product product) => _cart
      .where((l) => l.product.id == product.id)
      .fold(BigInt.zero, (sum, l) => sum + baseQuantity(l.quantity, l.packaging?.coefficient));

  /// Stock estimé une fois le panier vendu.
  BigInt _stockAfterCart(Product product) => product.signedStock - (_sold[product.id] ?? BigInt.zero) - _inCart(product);

  String _stockText(BigInt stock) => '${stock.isNegative ? '−' : ''}${formatMicros(stock.abs())}';

  Widget _productRow(Product product) {
    final stock = _stockAfterCart(product);
    return ListTile(
      dense: true,
      leading: _look.imageMode == 'hidden' ? null : _imageSlot(product),
      title: Text(product.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!product.unlimitedStock) Text('Stock : ${_stockText(stock)}', style: TextStyle(color: stock <= BigInt.zero ? Colors.red : Colors.black54)),
          _badges(product, stock),
          ?_wholesaleHint(product),
        ],
      ),
      trailing: Text(formatFcfa(product.price), style: const TextStyle(fontWeight: FontWeight.bold)),
      onTap: () => _add(product, null),
    );
  }

  /// Prix de gros du produit, si la boutique a le tarif gros.
  Widget? _wholesaleHint(Product product) {
    final price = product.wholesalePrice;
    if (price == null || _engine.wholesaleRules == null) return null;
    return Text('Gros : ${formatFcfa(price)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.black54));
  }

  Widget _productTile(Product product) {
    final stock = _stockAfterCart(product);
    final mode = _look.imageMode;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      elevation: 0.5,
      color: Color.alphaBlend(_palette.primaryContainer.withValues(alpha: .45), Colors.white),
      child: InkWell(
        onTap: () => _add(product, null),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (mode == 'top') ...[_imageSlot(product, large: true), const SizedBox(height: 6)],
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (mode == 'left') Padding(padding: const EdgeInsets.only(right: 6), child: _imageSlot(product)),
                    Expanded(
                      child: Text(product.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                    ),
                  ],
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(formatFcfa(product.price), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    ),
                  ),
                  CircleAvatar(radius: 12, backgroundColor: _palette.primary, child: const Icon(Icons.add, size: 16, color: Colors.white)),
                ],
              ),
              _badges(product, stock),
              ?_wholesaleHint(product),
              if (!product.unlimitedStock)
                Text(_stockText(stock), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: stock <= BigInt.zero ? Colors.red : Colors.black87)),
            ],
          ),
        ),
      ),
    );
  }

  void _scan(Snapshot snapshot, String value) {
    final code = value.trim();
    if (code.isEmpty) return;
    final found = snapshot.byCode(code);
    if (found != null) {
      _add(found.$1, found.$1.packaging(found.$2));
    } else {
      final results = snapshot.search(code);
      if (results.length == 1) {
        _add(results.first, null);
      } else if (results.isEmpty) {
        _toast('Article « $code » introuvable dans le catalogue hors ligne.');
      }
    }
    _scanInput.clear();
    setState(() {});
    _searchFocus.requestFocus();
  }

  Future<void> _add(Product product, Packaging? packaging) async {
    var chosen = packaging;
    if (chosen == null && product.packagings.isNotEmpty) {
      chosen = await showDialog<Packaging?>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(product.name),
          children: [
            SimpleDialogOption(onPressed: () => Navigator.pop(context, null), child: Text('À l’unité — ${formatFcfa(product.price)}')),
            for (final p in product.packagings)
              SimpleDialogOption(onPressed: () => Navigator.pop(context, p), child: Text('${p.name} — ${formatFcfa(p.price)}')),
          ],
        ),
      );
    }
    setState(() {
      final existing = _cart.where((l) => l.product.id == product.id && l.packaging?.id == chosen?.id && l.lot == null).firstOrNull;
      if (existing != null) {
        existing.quantity += BigInt.from(1000000);
      } else {
        _cart.add(CartLine(product: product, packaging: chosen, tier: _tier));
      }
    });
    _searchFocus.requestFocus();
  }

  /// [footer] : total et bouton « Encaisser » sous le panier (la disposition compacte les porte dans sa barre fixe).
  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Vider le panier ?'),
        content: const Text('Tous les articles de ce panier seront retirés.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Conserver')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Vider le panier')),
        ],
      ),
    );
    if (confirmed == true && mounted) setState(_clearCart);
  }

  /// Remise globale, livraison et note, derrière un seul bouton comme sur Windows.
  Future<void> _saleOptions() => showModalBottomSheet<void>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (label, icon, open) in [
            ('Remise globale', Icons.percent, _editGlobalDiscount),
            ('Livraison', Icons.local_shipping_outlined, _editDelivery),
            ('Note du ticket', Icons.note_alt_outlined, _editNote),
          ])
            ListTile(
              leading: Icon(icon),
              title: Text(label),
              onTap: () {
                Navigator.pop(context);
                open();
              },
            ),
        ],
      ),
    ),
  );

  Widget _totalCell(String label, String value) => Expanded(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: '$label : ', style: const TextStyle(color: Color(0xFF627168))),
            TextSpan(text: value, style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
    ),
  );

  Widget _cartLine(Snapshot snapshot, CartLine line, int index) {
    final tracked = !line.product.unlimitedStock;
    final first = _cart.indexWhere((l) => l.product.id == line.product.id) == index;
    final alert = !tracked || !first
        ? null
        : stockAlert(line.product.signedStock - (_sold[line.product.id] ?? BigInt.zero), _inCart(line.product), line.product.alertThreshold, _engine.oversellPolicy);
    final shownLot = line.lot ?? line.product.lots.where((l) => l.remaining > BigInt.zero).firstOrNull;
    final expired = shownLot?.expiredOn(DateTime.now().toIso8601String().substring(0, 10)) ?? false;
    final step = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Diminuer la quantité',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.remove, size: 18),
          onPressed: () => setState(() {
            line.quantity -= BigInt.from(1000000);
            if (line.quantity <= BigInt.zero) _cart.remove(line);
            _releaseIfEmpty();
            if (line.discountEntry case final entry? when !entry.isPercent && line.discount > line.base) {
              line.discountEntry = null;
              line.discount = 0;
            }
          }),
        ),
        Text(formatMicros(line.quantity)),
        IconButton(
          tooltip: 'Augmenter la quantité',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.add, size: 18),
          onPressed: () => setState(() => line.quantity += BigInt.from(1000000)),
        ),
      ],
    );
    final amounts = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(tooltip: 'Remise de ligne', visualDensity: VisualDensity.compact, icon: const Icon(Icons.percent, size: 18), onPressed: () => _editDiscount(line, line.quantity)),
        Text(formatFcfa(line.total), style: const TextStyle(fontWeight: FontWeight.bold)),
        IconButton(
          tooltip: 'Retirer du panier',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.delete_outline),
          onPressed: () => setState(() {
            _cart.remove(line);
            _releaseIfEmpty();
          }),
        ),
      ],
    );
    return InkWell(
      onTap: () => _editLine(snapshot, line),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(line.label, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            if (line.discount > 0) Text('${formatFcfa(line.unitPrice)} − ${formatFcfa(line.discount)}', style: const TextStyle(fontSize: 11)),
            if (shownLot != null)
              Text(
                '${line.lot == null ? 'Automatique : ' : ''}${shownLot.label}${expired ? ' · périmé le ${shownLot.expiryLabel}' : ''}',
                style: TextStyle(fontSize: 11, color: expired ? Colors.red : null),
              ),
            if (line.wholesale && !_tier.cart) const Text('Prix de gros (seuil atteint)', style: TextStyle(fontSize: 11)),
            if (line.wholesaleRefused) const Text('Tarif gros refusé pour ce lot : vendez au détail ou par un conditionnement', style: TextStyle(fontSize: 11, color: Colors.red)),
            if (tracked) Text('Après vente : ${_stockText(_stockAfterCart(line.product))}', style: const TextStyle(fontSize: 11)),
            if (alert != null) Text(alert.message, style: TextStyle(fontSize: 11, color: alert.level == 'short' ? Colors.red : Colors.brown)),
            Row(children: [step, const Spacer(), Flexible(child: FittedBox(fit: BoxFit.scaleDown, child: amounts))]),
          ],
        ),
      ),
    );
  }

  Widget _cartPanel(Snapshot snapshot, {bool footer = true}) {
    final totals = _totals(snapshot);
    final extras = _engine.saleExtrasSupported && _cart.isNotEmpty;
    String money(int value) => value == 0 ? '—' : formatFcfa(value);
    return Card(
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.shopping_basket_outlined, size: 18),
                const SizedBox(width: 8),
                const Text('Panier', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const Spacer(),
                Text('${_cart.length} ligne(s)', style: const TextStyle(fontSize: 12, color: Color(0xFF627168))),
              ],
            ),
            const Divider(height: 14),
            Row(
              children: [
                Expanded(
                  child: TextButton.icon(
                    icon: const Icon(Icons.person_outline),
                    label: Text(_customer?.name ?? 'Client de passage', maxLines: 1, overflow: TextOverflow.ellipsis),
                    onPressed: extras && _engine.customersSupported ? _pickCustomer : null,
                  ),
                ),
                Expanded(
                  child: TextButton.icon(
                    icon: const Icon(Icons.tune, size: 18),
                    label: const Text('Remise et livraison', maxLines: 1, overflow: TextOverflow.ellipsis),
                    onPressed: extras ? _saleOptions : null,
                  ),
                ),
              ],
            ),
            Expanded(
              child: _cart.isEmpty
                  ? const Center(child: Text('Scannez votre premier article.'))
                  : ListView.separated(
                      itemCount: _cart.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) => _cartLine(snapshot, _cart[index], index),
                    ),
            ),
            const Divider(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextButton.icon(
                    onPressed: _cart.isEmpty ? null : _suspendCart,
                    icon: const Icon(Icons.pause_circle_outline),
                    label: const Text('En attente', maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ),
                Expanded(
                  child: TextButton.icon(
                    onPressed: _suspendedCount > 0 ? () => _openSuspended(snapshot) : null,
                    icon: const Icon(Icons.list_alt),
                    label: Text('Suspendus ($_suspendedCount)', maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ),
              ],
            ),
            Row(children: [_totalCell('Remise globale', money(totals.globalDiscount)), _totalCell('Livraison', money(totals.delivery))]),
            Row(children: [_totalCell('Base HT', formatFcfa(totals.baseHt)), _totalCell('TVA', formatFcfa(totals.vat))]),
            if (footer) ...[
              Row(
                children: [
                  const Text('À payer', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text(formatFcfa(totals.payable), style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  OutlinedButton(onPressed: _cart.isEmpty ? null : _confirmClear, child: const Text('Vider le panier')),
                  const SizedBox(width: 8),
                  if (_passButton(snapshot, totals.payable) case final pass?) ...[pass, const SizedBox(width: 8)],
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(padding: const EdgeInsets.all(14)),
                      onPressed: _cart.isEmpty ? null : () => _checkout(snapshot, totals.payable),
                      icon: const Icon(Icons.payments_outlined),
                      label: const Text('Payer'),
                    ),
                  ),
                ],
              ),
            ] else if (_cart.isNotEmpty)
              OutlinedButton(onPressed: _confirmClear, child: const Text('Vider le panier')),
          ],
        ),
      ),
    );
  }

  /// Remise de la ligne pour la quantité [quantity] : directe depuis l'icône %, ou depuis la fenêtre de la ligne.
  Future<void> _editDiscount(CartLine line, BigInt quantity) async {
    final refusal = _discountRefusal;
    if (refusal != null) return _refuse(refusal);
    final base = lineBase(line.unitPrice, quantity);
    final others = _cart.where((l) => l != line).fold<int>(0, (sum, l) => sum + l.discount);
    final result = await _askDiscount(
      line.label,
      line.discountEntry,
      (entry) => _checkDiscount(entry, base, _engine.enterableLineDiscount(_operator!, base), others, label: line.label),
    );
    if (result == null) return;
    final entry = result.$1;
    final amount = entry == null
        ? 0
        : enteredDiscount(type: entry.type, value: entry.value, base: base, rounding: _engine.percentRounding, label: line.label);
    setState(() => (line.discountEntry = entry, line.discount = amount));
  }

  Future<void> _editLine(Snapshot snapshot, CartLine line) async {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final quantity = TextEditingController(text: formatMicros(line.quantity));
    final refusal = _discountRefusal;
    var lot = line.lot;
    String? error;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(line.label),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: quantity,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Quantité'),
              ),
              if (line.product.managedByLots && line.fixedPrice == null)
                DropdownButtonFormField<String?>(
                  initialValue: lot?.uuid,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Lot à vendre'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('Choix automatique selon la règle de la boutique')),
                    for (final l in line.product.lots)
                      if (l.remaining > BigInt.zero)
                        DropdownMenuItem(
                          value: l.uuid,
                          child: Text(
                            '${l.label}${l.expiresOn == null ? '' : l.expiredOn(today) ? ' · périmé le ${l.expiryLabel}' : ' · péremption ${l.expiryLabel}'} · '
                            '${formatMicros(l.remaining)} disponible(s) · ${formatFcfa(l.price)}/unité',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: l.expiredOn(today) ? Colors.red : null),
                          ),
                        ),
                  ],
                  onChanged: (v) => setLocal(() => lot = line.product.lots.where((l) => l.uuid == v).firstOrNull),
                ),
              if (refusal == null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.percent),
                    label: Text(line.discount > 0 ? 'Remise : ${formatFcfa(line.discount)}' : 'Ajouter une remise'),
                    onPressed: () async {
                      final q = parseMicros(quantity.text);
                      if (q == null || q <= BigInt.zero) return setLocal(() => error = 'Quantité invalide (six décimales au plus).');
                      await _editDiscount(line, q);
                      setLocal(() {});
                    },
                  ),
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(error!, style: const TextStyle(color: Colors.red)),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                setState(() {
                  _cart.remove(line);
                  _releaseIfEmpty();
                });
                Navigator.pop(context);
              },
              child: const Text('Retirer'),
            ),
            FilledButton(
              onPressed: () {
                final q = parseMicros(quantity.text);
                if (q == null || q <= BigInt.zero) return setLocal(() => error = 'Quantité invalide (six décimales au plus).');
                final before = line.unitPrice;
                final previous = line.lot;
                line.lot = lot;
                // Le prix suit le lot : la remise saisie sur l'ancien prix ne vaut plus.
                final repriced = line.unitPrice != before;
                final base = lineBase(line.unitPrice, q);
                final entry = line.discountEntry;
                if (!repriced && entry != null && !entry.isPercent && line.discount > base) {
                  line.lot = previous;
                  return setLocal(() => error = 'La remise dépasse le montant de la ligne.');
                }
                setState(() {
                  line.quantity = q;
                  if (repriced) {
                    line.discount = 0;
                    line.discountEntry = null;
                  }
                });
                Navigator.pop(context);
              },
              child: const Text('Valider'),
            ),
          ],
        ),
      ),
    );
  }

  /// Paiement par pass événement : feuille de scan, puis encaissement sans autre moyen de paiement.
  Future<void> _payByPass(Snapshot snapshot, int payable) async {
    final settings = _engine.passSettings;
    final operator = _operator;
    if (settings == null || operator == null) return;
    try {
      allocateLots(snapshot, _cart);
    } on OfflineRefusal catch (e) {
      return _refuse(e.message, title: 'Lot à vérifier');
    }
    final totals = _totals(snapshot);
    final extras = SaleExtras(wholesale: _tier.cart, globalDiscount: totals.globalDiscount, globalEntry: _globalEntry, delivery: _delivery, note: _note, customer: _customer, sharedCart: _shared?.uuid);
    final lines = List.of(_cart);
    Widget sheet(bool fullScreen) => PassSheet(
      payable: payable,
      settings: settings,
      brand: _brand,
      fullScreen: fullScreen,
      verify: (code, already) => _engine.verifyPass(operator, code, lines, extras, already: already),
    );
    final passes = _compact
        ? await Navigator.of(context).push<List<PassCheck>>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => sheet(true)))
        : await showDialog<List<PassCheck>>(context: context, barrierDismissible: false, builder: (_) => sheet(false));
    if (passes == null || passes.isEmpty || !mounted) return;
    await _checkout(snapshot, payable, passes: passes);
  }

  Widget? _passButton(Snapshot snapshot, int payable) {
    final operator = _operator;
    if (operator == null || !_engine.canPayByPass(operator)) return null;
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48), foregroundColor: _brand),
      onPressed: _cart.isEmpty ? null : () => _payByPass(snapshot, payable),
      icon: const Icon(Icons.qr_code_scanner),
      label: const Text('Pass'),
    );
  }

  /// [passes] : vente payée par pass (vérifiés dans la feuille de scan), sans fenêtre de paiement.
  Future<void> _checkout(Snapshot snapshot, int payable, {List<PassCheck>? passes}) async {
    try {
      allocateLots(snapshot, _cart);
    } on OfflineRefusal catch (e) {
      return _refuse(e.message, title: 'Lot à vérifier');
    }
    final globalDiscount = _totals(snapshot).globalDiscount;
    try {
      _engine.checkSaleRules(_operator!, _cart, SaleExtras(wholesale: _tier.cart, globalDiscount: globalDiscount, sharedCart: _shared?.uuid));
    } on OfflineRefusal catch (e) {
      return _refuse(e.message, title: 'Encaissement refusé');
    }
    SaleApproval? approval;
    if (!_engine.withinDiscountLimits(_operator!, _cart, globalDiscount)) {
      approval = await _askApproval(globalDiscount);
      if (approval == null || !mounted) return;
    }
    final payments = passes != null
        ? const <CartPayment>[]
        : _compact
        ? await Navigator.of(context).push<List<CartPayment>>(
            MaterialPageRoute(
              fullscreenDialog: true,
              builder: (_) => _PaymentDialog(snapshot: snapshot, payable: payable, cashDue: _engine.cashDue, fullScreen: true),
            ),
          )
        : await showDialog<List<CartPayment>>(
            context: context,
            barrierDismissible: false,
            builder: (_) => _PaymentDialog(snapshot: snapshot, payable: payable, cashDue: _engine.cashDue),
          );
    if (payments == null || !mounted) return;
    final OfflineOperation operation;
    try {
      final totals = _totals(snapshot);
      operation = await _engine.recordSale(
        List.of(_cart),
        payments,
        _operator!,
        draftUuid: _draftUuid,
        extras: SaleExtras(
          wholesale: _tier.cart,
          globalDiscount: totals.globalDiscount,
          globalEntry: _globalEntry,
          delivery: _delivery,
          note: _note,
          approval: approval,
          customer: _customer,
          sharedCart: _shared?.uuid,
          passes: passes ?? const [],
        ),
      );
    } on OfflineRefusal catch (e) {
      return _refuse(e.message, title: 'Encaissement refusé');
    } catch (e, stack) {
      // Mémoire du terminal pleine, base locale illisible… : la vente n'existe pas, rien n'est imprimé, le panier reste.
      await ErrorJournal.record('Vente hors ligne non enregistrée : $e', stack);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.error, color: Colors.red, size: 48),
          title: const Text('Vente NON enregistrée'),
          content: const Text(
            'Le terminal n’a pas pu enregistrer cette vente : ne remettez pas la marchandise et ne rendez pas la monnaie '
            'avant d’avoir réessayé. Le panier est conservé. Si le problème persiste, libérez de la place sur le terminal ou reconnectez-le.',
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Compris'))],
        ),
      );
      return;
    }
    final lines = List.of(_cart);
    // Vente par pass : les paiements sont ceux que le moteur a répartis entre les passes.
    final paid = passes == null ? payments : _engine.ticketParts(operation).$2;
    setState(() {
      _clearCart();
      _draftUuid = const Uuid().v4();
    });
    unawaited(_refreshSold());
    // Le tiroir s'ouvre pour les espèces, que le ticket soit imprimé ou non.
    final session = widget.session;
    if (session.hasPrinter && paid.any((p) => p.method.isCash)) unawaited(session.channel.openDrawer());
    var printed = _look.ticketMode == 'auto';
    if (printed) await _print(snapshot, operation, lines, paid);
    final change = paid.fold<int>(0, (sum, p) => sum + p.change);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          icon: Icon(Icons.check_circle, color: _brand, size: 48),
          title: Text('Vente ${operation.number}'),
          content: Text(
            change > 0
                ? 'Monnaie à rendre : ${formatFcfa(change)}'
                : passes != null
                ? 'Payée par pass${passes.length > 1 ? ' (${passes.length} passes)' : ''}.'
                : 'Vente enregistrée sur le terminal.',
            style: const TextStyle(fontSize: 20),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await _print(snapshot, operation, lines, paid, duplicate: printed);
                setDialog(() => printed = true);
              },
              child: Text(printed ? 'Réimprimer' : 'Imprimer le ticket'),
            ),
            FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Vente suivante')),
          ],
        ),
      ),
    );
    _searchFocus.requestFocus();
  }

  /// Retour en espèces d'une vente de ce terminal : quantités par ligne, montant calculé, motif obligatoire.
  Future<void> _startReturn(OfflineOperation sale) async {
    final operator = _operator!;
    final blocker = _engine.returnBlocker(operator);
    if (blocker != null) return _refuse(blocker, title: 'Retour impossible');
    final List<ReturnableLine> lines;
    try {
      lines = await _engine.returnableLines(sale.uuid);
    } on OfflineRefusal catch (e) {
      return _toast(e.message);
    }
    if (!mounted) return;
    if (lines.isEmpty) return _toast('Tout a déjà été retourné sur cette vente.');
    final fields = {for (final l in lines) l.lineUuid: TextEditingController()};
    final reason = TextEditingController();
    int? amount;
    String? error;
    OfflineOperation? recorded;
    Map<String, int>? recordedQuantities;
    Map<String, int>? quantities() {
      final result = <String, int>{};
      for (final e in fields.entries) {
        if (e.value.text.trim().isEmpty) continue;
        final q = parseMicros(e.value.text.trim());
        if (q == null) return null;
        result[e.key] = q.toInt();
      }
      return result;
    }

    final done = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text('Retour : vente ${sale.number}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final l in lines)
                  TextField(
                    controller: fields[l.lineUuid],
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(labelText: l.label, helperText: 'Quantité, ${formatMicros(BigInt.from(l.remaining))} au plus'),
                    onChanged: (_) async {
                      final wanted = quantities();
                      try {
                        final value = wanted == null || wanted.isEmpty ? null : await _engine.returnAmount(sale.uuid, wanted);
                        setLocal(() => (amount, error) = (value, wanted == null ? 'Quantité invalide.' : null));
                      } on OfflineRefusal catch (e) {
                        setLocal(() => (amount, error) = (null, e.message));
                      }
                    },
                  ),
                TextField(controller: reason, maxLength: 500, decoration: InputDecoration(labelText: 'Motif du retour', errorText: error, errorMaxLines: 3)),
                Text('À rendre en espèces : ${amount == null ? '—' : formatFcfa(amount!)}', style: const TextStyle(fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
            FilledButton(
              onPressed: () async {
                final wanted = quantities();
                if (wanted == null) return setLocal(() => error = 'Quantité invalide.');
                try {
                  recorded = await _engine.recordReturn(operator, sale.uuid, wanted, reason.text);
                  recordedQuantities = wanted;
                  if (context.mounted) Navigator.pop(context, true);
                } on OfflineRefusal catch (e) {
                  setLocal(() => error = e.message);
                }
              },
              child: const Text('Rembourser'),
            ),
          ],
        ),
      ),
    );
    if (done == true) {
      if (widget.session.hasPrinter) await widget.session.channel.openDrawer();
      _changed();
      _toast('Retour enregistré. Rendez le montant en espèces.');
      final operation = recorded;
      if (operation != null) {
        await _returnSlip(sale, operation, [
          for (final l in lines)
            if (recordedQuantities![l.lineUuid] case final q?) ('${l.label} x ${formatMicros(BigInt.from(q))}', ''),
          ('Rendu en especes', formatFcfa((operation.content['montant'] as num).toInt())),
          ('Motif : ${reason.text.trim()}', ''),
        ]);
      }
    }
  }

  /// Bon de retour : imprimé d'office en mode automatique, sinon sur demande, comme le ticket de vente.
  Future<void> _returnSlip(OfflineOperation sale, OfflineOperation operation, List<(String, String)> rows) async {
    if (!mounted) return;
    final print = _look.ticketMode == 'auto' ||
        await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Imprimer le bon de retour ?'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Non')),
                  FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Imprimer')),
                ],
              ),
            ) ==
            true;
    if (print) await _printSlip('BON DE RETOUR ${sale.number ?? ''}', operation, rows);
  }

  /// Z d'une clôture intégrée, depuis le journal.
  Future<void> _printZ(OfflineOperation operation) async {
    final z = (operation.content['z'] as Map).cast<String, dynamic>();
    await _printSlip('RAPPORT Z', operation, [
      ('Compte', formatFcfa(z['compte'] as int)),
      ('Theorique', formatFcfa(z['theorique'] as int)),
      ('Ecart', formatFcfa(z['ecart'] as int)),
    ]);
  }

  Future<void> _printSlip(String title, OfflineOperation operation, List<(String, String)> rows) async {
    final snapshot = _snapshot;
    if (snapshot == null) return;
    final session = widget.session;
    await _printText(offlineSlipLines(
      snapshot: snapshot,
      title: title,
      date: operation.date,
      operatorName: snapshot.operatorById(operation.operatorId)?.name ?? '',
      paperWidth: session.rollWidth > 0 ? session.rollWidth : 58,
      rows: rows,
    ), failure: 'Bon non imprimé');
  }

  void _openJournal() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PendingOperationsPage(
          engine: _engine,
          onReprint: _reprint,
          onReturn: _operator != null ? _startReturn : null,
          onPrintZ: _printZ,
        ),
      ),
    );
  }

  /// Duplicata d'un ticket hors ligne depuis le journal : prix et quantités tels qu'encaissés.
  Future<void> _reprint(OfflineOperation operation) async {
    final snapshot = _snapshot;
    if (snapshot == null || !operation.isSale) return;
    final (lines, payments) = _engine.ticketParts(operation);
    final operatorName = snapshot.operatorById(operation.operatorId)?.name ?? '';
    await _print(snapshot, operation, lines, payments, duplicate: true, operatorName: operatorName);
  }

  Future<void> _print(
    Snapshot snapshot,
    OfflineOperation operation,
    List<CartLine> lines,
    List<CartPayment> payments, {
    bool duplicate = false,
    String? operatorName,
  }) async {
    final session = widget.session;
    final width = session.rollWidth > 0 ? session.rollWidth : 58;
    final model = await _engine.ticketModelOf(operation);
    final text = offlineTicketLines(
      snapshot: snapshot,
      operation: operation,
      lines: lines,
      payments: payments,
      operatorName: operatorName ?? _operator?.name ?? '',
      paperWidth: width,
      duplicate: duplicate,
      model: model,
    );
    await _printText(text, failure: 'Ticket non imprimé', saved: ' : la vente est bien enregistrée.', compact: model?.compact ?? false);
  }

  Future<void> _printText(List<String> text, {required String failure, String saved = '.', bool compact = false, Uint8List? bytes}) async {
    final session = widget.session;
    if (session.hasPrinter) {
      final result = await session.channel.printRaw(bytes ?? offlineTicketBytes(text, compact: compact));
      if (!result.ok) _toast('$failure (${result.error})$saved');
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ticket (aucune imprimante)'),
        content: SingleChildScrollView(
          child: Text(text.join('\n'), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Fermer'))],
      ),
    );
  }
}

class _Blocked extends StatelessWidget {
  const _Blocked({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.block, size: 56, color: _offline),
          const SizedBox(height: 12),
          Text('Vente hors ligne impossible', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Réessayer la connexion')),
        ],
      ),
    ),
  );
}

/// Choix du caissier : PIN de caisse vérifié sur le terminal (empreinte reçue avec le catalogue).
class _OperatorLogin extends StatefulWidget {
  const _OperatorLogin({required this.engine, required this.onLogged});

  final CaisseEngine engine;
  final ValueChanged<Operator> onLogged;

  @override
  State<_OperatorLogin> createState() => _OperatorLoginState();
}

class _OperatorLoginState extends State<_OperatorLogin> {
  Operator? _selected;
  String _pin = '';
  String? _error;
  bool _checking = false;

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.engine.snapshot!;
    final operators = snapshot.operators.where((o) => !snapshot.rules.pinRequired || (o.pinHash ?? '').isNotEmpty).toList();
    if (!snapshot.rules.pinRequired) {
      final last = snapshot.operatorById(snapshot.lastOperatorId);
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(last == null ? 'Aucun caissier connu sur ce terminal.' : 'Caissier : ${last.name}', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            if (last != null) FilledButton(onPressed: () => widget.onLogged(last), child: const Text('Continuer')),
          ],
        ),
      );
    }
    if (_selected == null) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Qui encaisse ?', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 12),
              if (operators.isEmpty) const Text('Aucun caissier avec un PIN de caisse : définissez les PIN dans ShopiKaiss (Utilisateurs).'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final o in operators)
                    ActionChip(
                      avatar: const Icon(Icons.person),
                      label: Text(o.name),
                      onPressed: () => setState(() => (_selected = o, _pin = '', _error = null)),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_selected!.name, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text('•' * _pin.length + '○' * (6 - _pin.length).clamp(0, 6), style: const TextStyle(fontSize: 28, letterSpacing: 6)),
            if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 8),
            GridView.count(
              shrinkWrap: true,
              crossAxisCount: 3,
              childAspectRatio: 1.6,
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
              children: [
                for (final key in ['1', '2', '3', '4', '5', '6', '7', '8', '9', '←', '0', 'OK'])
                  FilledButton.tonal(
                    onPressed: _checking ? null : () => _key(key),
                    child: _checking && key == 'OK' ? const CircularProgressIndicator() : Text(key, style: const TextStyle(fontSize: 20)),
                  ),
              ],
            ),
            TextButton(onPressed: () => setState(() => _selected = null), child: const Text('Changer de caissier')),
          ],
        ),
      ),
    );
  }

  Future<void> _key(String key) async {
    if (key == '←') return setState(() => _pin = _pin.isEmpty ? '' : _pin.substring(0, _pin.length - 1));
    if (key != 'OK') {
      if (_pin.length < 6) setState(() => _pin += key);
      return;
    }
    if (!widget.engine.pinDefined(_selected!)) {
      return setState(() => (_pin = '', _error = 'PIN non défini pour ce caissier : définissez-le dans ShopiKaiss.'));
    }
    // Blocage après 3 échecs, gardé par le moteur sur le terminal (un redémarrage ne l'efface pas).
    final locked = await widget.engine.pinLockedFor(_selected!);
    if (!mounted) return;
    if (locked != null) {
      return setState(() => (_pin = '', _error = 'Trop d’essais : patientez ${locked.inSeconds + 1} s.'));
    }
    setState(() => (_checking = true, _error = null));
    final ok = await widget.engine.checkPin(_selected!, _pin);
    if (!mounted) return;
    if (ok) {
      widget.onLogged(_selected!);
    } else {
      final wait = await widget.engine.pinLockedFor(_selected!);
      if (!mounted) return;
      setState(
        () => (_checking = false, _pin = '', _error = wait == null ? 'PIN incorrect.' : 'PIN incorrect. Nouvel essai dans ${wait.inSeconds + 1} s.'),
      );
    }
  }
}

class _SessionOpening extends StatefulWidget {
  const _SessionOpening({required this.engine, required this.operator, required this.onOpened});

  final CaisseEngine engine;
  final Operator operator;
  final VoidCallback onOpened;

  @override
  State<_SessionOpening> createState() => _SessionOpeningState();
}

class _SessionOpeningState extends State<_SessionOpening> {
  final _float = TextEditingController(text: '0');
  String? _error;

  @override
  Widget build(BuildContext context) {
    final allowed = widget.engine.snapshot?.rules.sessionOpening ?? false;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Aucune session de caisse ouverte', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  allowed
                      ? 'Comptez le fond de caisse : la session sera ouverte sur la boutique au retour de la connexion.'
                      : 'La boutique n’autorise pas l’ouverture de session hors ligne : la vente reprendra en ligne.',
                ),
                if (allowed) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _float,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(labelText: 'Fond de caisse (F)', errorText: _error),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _open, child: const Text('Ouvrir la session')),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _open() async {
    try {
      await widget.engine.openSession(int.tryParse(_float.text) ?? 0, widget.operator);
      widget.onOpened();
    } on OfflineRefusal catch (e) {
      setState(() => _error = e.message);
    }
  }
}

/// Encaissement : un ou plusieurs moyens autorisés hors ligne ; les espèces calculent la monnaie.
class _PaymentDialog extends StatefulWidget {
  const _PaymentDialog({required this.snapshot, required this.payable, required this.cashDue, this.fullScreen = false});

  final Snapshot snapshot;
  final int payable;

  /// Montant dû au tiroir pour une ligne d'espèces (arrondi de caisse de la boutique).
  final int Function(int amount) cashDue;

  /// Petit téléphone : page plein écran qui défile, boutons en bas (au lieu d'une boîte de dialogue).
  final bool fullScreen;

  @override
  State<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<_PaymentDialog> {
  final List<CartPayment> _payments = [];
  late PaymentMethodInfo _method = widget.snapshot.methods.first;
  final _amount = TextEditingController();
  final _received = TextEditingController();
  final _reference = TextEditingController();
  String? _error;

  int get _remaining => widget.payable - _payments.fold<int>(0, (sum, p) => sum + p.amount);

  @override
  void initState() {
    super.initState();
    _reset();
  }

  void _reset() {
    _amount.text = '$_remaining';
    _received.text = '';
    _reference.text = '';
  }

  @override
  Widget build(BuildContext context) {
    final cash = _method.isCash;
    final received = int.tryParse(_received.text);
    final amount = int.tryParse(_amount.text) ?? 0;
    final title = Text('Encaisser ${formatFcfa(widget.payable)}');
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final p in _payments)
          ListTile(
            dense: true,
            title: Text(p.method.name),
            subtitle: p.change > 0
                ? Text('reçu ${formatFcfa(p.received!)} · monnaie ${formatFcfa(p.change)}')
                : (p.reference != null ? Text('réf. ${p.reference}') : null),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(formatFcfa(p.amount)),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() {
                    _payments.remove(p);
                    _reset();
                  }),
                ),
              ],
            ),
          ),
        if (_remaining > 0) ...[
          Wrap(
            spacing: 6,
            children: [
              for (final m in widget.snapshot.methods)
                ChoiceChip(label: Text(m.name), selected: m.code == _method.code, onSelected: (_) => setState(() => _method = m)),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _amount,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(labelText: 'Montant réglé (reste ${formatFcfa(_remaining)})'),
            onChanged: (_) => setState(() {}),
          ),
          if (cash)
            TextField(
              controller: _received,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: 'Espèces reçues',
                helperText: [
                  if (widget.cashDue(amount) != amount) 'À encaisser : ${formatFcfa(widget.cashDue(amount))}',
                  if (received != null && received > widget.cashDue(amount)) 'Monnaie : ${formatFcfa(received - widget.cashDue(amount))}',
                ].join(' · '),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _addPayment(),
            ),
          if (!cash)
            TextField(
              controller: _reference,
              maxLength: 100,
              decoration: const InputDecoration(labelText: 'Référence de la transaction (facultative)', counterText: ''),
              onSubmitted: (_) => _addPayment(),
            ),
          if (cash)
            Wrap(
              spacing: 6,
              children: [
                for (final note in _quickNotes(amount))
                  ActionChip(label: Text(formatFcfa(note)), onPressed: () => setState(() => _received.text = '$note')),
              ],
            ),
          const SizedBox(height: 8),
          OutlinedButton.icon(onPressed: _addPayment, icon: const Icon(Icons.add), label: const Text('Ajouter ce paiement')),
        ],
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!, style: const TextStyle(color: Colors.red)),
          ),
      ],
    );
    final cancel = TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler'));
    final validate = FilledButton(
      onPressed: () {
        if (_remaining > 0 && !_addPayment()) return;
        if (_remaining == 0) Navigator.pop(context, _payments);
      },
      child: const Text('Valider la vente'),
    );
    if (widget.fullScreen) {
      return Scaffold(
        appBar: AppBar(title: title, automaticallyImplyLeading: false),
        body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: content),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                Expanded(child: cancel),
                const SizedBox(width: 8),
                Expanded(flex: 2, child: SizedBox(height: 52, child: validate)),
              ],
            ),
          ),
        ),
      );
    }
    return AlertDialog(
      title: title,
      content: SizedBox(width: 420, child: content),
      actions: [cancel, validate],
    );
  }

  List<int> _quickNotes(int amount) {
    final notes = <int>{amount};
    for (final step in [500, 1000, 2000, 5000, 10000]) {
      final rounded = ((amount + step - 1) ~/ step) * step;
      if (rounded > amount) notes.add(rounded);
    }
    return notes.take(5).toList();
  }

  bool _addPayment() {
    final amount = int.tryParse(_amount.text) ?? 0;
    if (amount <= 0 || amount > _remaining) {
      setState(() => _error = 'Montant entre 1 et ${formatFcfa(_remaining)}.');
      return false;
    }
    if (_method.isCash && _payments.any((p) => p.method.isCash)) {
      setState(() => _error = 'Une seule ligne d’espèces par vente : retirez la précédente pour la modifier.');
      return false;
    }
    final due = widget.cashDue(amount);
    final received = _method.isCash ? (int.tryParse(_received.text) ?? due) : null;
    if (received != null && received < due) {
      setState(() => _error = 'Espèces reçues inférieures au montant.');
      return false;
    }
    setState(() {
      final reference = _reference.text.trim();
      _payments.add(CartPayment(method: _method, amount: amount, received: received, cashDue: due, reference: _method.isCash || reference.isEmpty ? null : reference));
      _error = null;
      _reset();
    });
    return true;
  }
}
