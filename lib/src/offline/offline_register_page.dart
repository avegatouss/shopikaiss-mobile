import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../diagnostics.dart';
import '../terminal/terminal_session.dart';
import 'engine.dart';
import 'models.dart';
import 'money.dart';
import 'pending_operations_page.dart';
import 'ticket.dart';
import 'web_rules.dart';

const _brand = Color(0xFF0F3E2E);
const _offline = Color(0xFFB45309);

/// Caisse hors ligne : vente sur le dernier catalogue reçu, ticket imprimé, file envoyée au retour de la connexion.
///
/// [onBackOnline] est appelé quand la boutique répond de nouveau et que la file est vide (retour à la caisse web).
class OfflineRegisterPage extends StatefulWidget {
  const OfflineRegisterPage({super.key, required this.engine, required this.session, required this.onBackOnline});

  final CaisseEngine engine;
  final TerminalSession session;
  final VoidCallback onBackOnline;

  @override
  State<OfflineRegisterPage> createState() => _OfflineRegisterPageState();
}

class _OfflineRegisterPageState extends State<OfflineRegisterPage> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final List<CartLine> _cart = [];

  /// Identifiant du panier en cours : consommé par la vente dans la même transaction, renouvelé après l'encaissement.
  /// Un second encaissement du même panier (double appui, écran rejoué) est refusé par la base.
  String _draftUuid = const Uuid().v4();
  Operator? _operator;
  Timer? _probe;
  Map<int, BigInt> _sold = {};
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
    final rules = _snapshot?.rules;
    _probe = Timer.periodic(Duration(seconds: rules?.probeSeconds ?? 20), (_) => _tryOnline(automatic: true));
    if (rules != null && !rules.pinRequired) _operator = _snapshot!.operatorById(_snapshot!.lastOperatorId);
    _refreshSold();
    _refreshSuspended();
  }

  @override
  void dispose() {
    _probe?.cancel();
    _engine.removeListener(_changed);
    _search.dispose();
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

  /// Sous-total du panier (après remises de ligne) : base de la remise globale.
  int get _subtotal => _cart.fold<int>(0, (sum, l) => sum + l.base - l.discount);

  /// Remises en pourcentage recalculées sur le panier courant, comme le web ; une remise globale en montant qui dépasse
  /// le nouveau sous-total est retirée. Rend les totaux affichés et encaissés.
  WebTotals _totals(Snapshot snapshot) {
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
                decoration: InputDecoration(labelText: percent ? 'Pourcentage' : 'Montant (F)', errorText: error),
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
    if (operator == null) return _toast('Identifiez le caissier.');
    if (!_engine.hasRight(operator, 'remise')) return _toast('${operator.name} n’a pas le droit d’accorder une remise.');
    if ((_snapshot?.rules.maxGlobalDiscountPercent ?? 0) <= 0) return _toast('Remise globale non autorisée hors ligne dans cette boutique.');
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
      _toast('Session clôturée. Le Z arrivera à la prochaine synchronisation.');
    }
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
        },
    ],
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
          SaleExtras(globalDiscount: totals.globalDiscount, delivery: _delivery, note: _note, customer: _customer),
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
      ));
    }
    await _engine.deleteDraft(draft.uuid);
    final global = draft.content['remise_globale_saisie'] as Map?;
    setState(() {
      _clearCart();
      _cart.addAll(lines);
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
      _cart.addAll(taken.lines);
      _globalEntry = taken.globalDiscount == 0 ? null : DiscountEntry('montant', '${taken.globalDiscount}');
      _delivery = taken.delivery;
      _note = taken.note;
      _customer = taken.customer;
      _shared = taken.ref;
    });
    await _refreshSuspended();
  }

  /// Actions du panier : remise globale, livraison et note exigent le contrat 2.1.
  Widget _cartActions() {
    final extras = _engine.saleExtrasSupported && _cart.isNotEmpty;
    return Wrap(
      spacing: 4,
      children: [
        if (extras && _engine.customersSupported) ActionChip(label: Text(_customer?.name ?? 'Client'), onPressed: _pickCustomer),
        if (extras) ActionChip(label: const Text('Remise globale'), onPressed: _editGlobalDiscount),
        if (extras) ActionChip(label: const Text('Livraison'), onPressed: _editDelivery),
        if (extras) ActionChip(label: Text(_note == null ? 'Note' : 'Note ✓'), onPressed: _editNote),
        if (_cart.isNotEmpty) ActionChip(label: const Text('Mettre en attente'), onPressed: _suspendCart),
        if (_suspendedCount > 0) ActionChip(label: Text('En attente ($_suspendedCount)'), onPressed: () => _openSuspended(_snapshot!)),
      ],
    );
  }

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
      if (!automatic || (_snapshot?.rules.automaticSwitch ?? true)) widget.onBackOnline();
    } finally {
      _probing = false;
    }
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
      child: Scaffold(
        backgroundColor: const Color(0xFFF6F7F6),
        body: SafeArea(
          child: Column(
            children: [
              _compact ? _compactBanner() : _banner(),
              Expanded(
                child: reason != null || snapshot == null
                    ? _scrollable(_Blocked(message: reason ?? 'Catalogue absent.', onRetry: () => _tryOnline()))
                    : _operator == null
                    ? _scrollable(_OperatorLogin(engine: _engine, onLogged: (o) => setState(() => _operator = o)))
                    : !_engine.sessionOpen
                    ? _scrollable(_SessionOpening(engine: _engine, operator: _operator!, onOpened: () => setState(() {})))
                    : _register(snapshot),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _banner() {
    final remaining = _engine.remaining;
    final contact = _engine.lastContact;
    String two(int v) => v.toString().padLeft(2, '0');
    final since = contact == null
        ? 'jamais'
        : '${two(contact.toLocal().day)}/${two(contact.toLocal().month)} ${two(contact.toLocal().hour)}:${two(contact.toLocal().minute)}';
    return Material(
      color: _bannerColor,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            // Emblème ShopiKaiss (or sur noir, non transparent) : pastille noire, quelle que soit la couleur du bandeau.
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.asset('assets/marque/embleme.png', width: 32, height: 32, filterQuality: FilterQuality.medium, semanticLabel: 'ShopiKaiss'),
            ),
            const SizedBox(width: 8),
            Icon(_bannerIcon, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _engine.permanentLocal
                    ? '${_localStatus()}${_lastSyncMessage != null ? ' · $_lastSyncMessage' : ''}'
                    : 'Caisse hors ligne · dernier contact $since'
                          '${remaining != null ? ' · reste ${remaining.inHours} h ${two(remaining.inMinutes % 60)}' : ''}'
                          ' · ${_engine.pendingCount} en attente'
                          '${_lastSyncMessage != null ? ' · $_lastSyncMessage' : ''}',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (_operator != null)
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                onPressed: _cart.isEmpty && (_snapshot?.rules.pinRequired ?? true) ? () => setState(() => _operator = null) : null,
                icon: const Icon(Icons.person),
                label: Text(_operator!.name),
              ),
            IconButton(tooltip: 'Opérations hors ligne', color: Colors.white, onPressed: _openJournal, icon: const Icon(Icons.receipt_long)),
            FilledButton.tonalIcon(
              onPressed: _engine.syncing ? null : () => _tryOnline(),
              icon: _engine.syncing
                  ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(_engine.permanentLocal ? Icons.public : Icons.wifi_find),
              label: Text(_engine.permanentLocal ? 'Caisse web' : 'Reconnecter'),
            ),
          ],
        ),
      ),
    );
  }

  /// Vente locale permanente et boutique joignable : bandeau vert ; sinon, bandeau orange de la vente hors ligne.
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
  Widget _compactBanner() {
    final remaining = _engine.remaining;
    return Material(
      color: _bannerColor,
      child: Padding(
        padding: const EdgeInsets.only(left: 10),
        child: Row(
          children: [
            Icon(_bannerIcon, color: Colors.white, size: 20),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _engine.permanentLocal
                    ? _localStatus(short: true)
                    : 'Hors ligne${remaining != null ? ' · reste ${remaining.inHours} h' : ''} · ${_engine.pendingCount} en attente',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              tooltip: _engine.permanentLocal ? 'Caisse web' : 'Reconnecter',
              color: Colors.white,
              onPressed: _engine.syncing ? null : () => _tryOnline(),
              icon: _engine.syncing
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Icon(_engine.permanentLocal ? Icons.public : Icons.wifi_find),
            ),
            PopupMenuButton<String>(
              iconColor: Colors.white,
              onSelected: (choice) {
                if (choice == 'journal') {
                  _openJournal();
                } else if (choice == 'caissier') {
                  setState(() => _operator = null);
                } else if (choice == 'cloture') {
                  _closeSession();
                }
              },
              itemBuilder: (context) => [
                if (_lastSyncMessage != null) PopupMenuItem<String>(enabled: false, child: Text(_lastSyncMessage!)),
                const PopupMenuItem(value: 'journal', child: Text('Opérations hors ligne')),
                if (_operator != null && _engine.canCloseSession(_operator!))
                  PopupMenuItem(value: 'cloture', enabled: _cart.isEmpty, child: const Text('Clôturer la session')),
                if (_operator != null)
                  PopupMenuItem(
                    value: 'caissier',
                    enabled: _cart.isEmpty && (_snapshot?.rules.pinRequired ?? true),
                    child: Text('Changer de caissier (${_operator!.name})'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
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
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: _brand),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: _brand, minimumSize: const Size(0, 48)),
                  onPressed: _cart.isEmpty ? null : () => _checkout(snapshot, totals.payable),
                  child: const Text('Encaisser'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _register(Snapshot snapshot) {
    if (_compact) return _compactRegister(snapshot);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 760;
        final catalogue = _catalogue(snapshot);
        final cart = _cartPanel(snapshot);
        if (wide) {
          return Row(
            children: [
              Expanded(flex: 3, child: catalogue),
              SizedBox(width: 380, child: cart),
            ],
          );
        }
        return Column(
          children: [
            Expanded(flex: 3, child: catalogue),
            SizedBox(height: constraints.maxHeight * 0.45, child: cart),
          ],
        );
      },
    );
  }

  Widget _catalogue(Snapshot snapshot) {
    final results = snapshot.search(_search.text, limit: null, category: _category, brand: _brandFilter, supplier: _supplier);
    final compact = _compact;
    final filtered = _category != null || _brandFilter != null || _supplier != null;
    return Padding(
      padding: EdgeInsets.all(compact ? 8 : 12),
      child: Column(
        children: [
          TextField(
            controller: _search,
            focusNode: _searchFocus,
            autofocus: true,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: 'Rechercher ou scanner un article',
              filled: true,
              fillColor: Colors.white,
              border: const OutlineInputBorder(),
              suffixIcon: _search.text.isEmpty ? null : IconButton(icon: const Icon(Icons.clear), onPressed: () => setState(_search.clear)),
            ),
            onChanged: (_) => setState(() => _productLimit = _productPage),
            onSubmitted: (value) => _scan(snapshot, value),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _filter('Catégorie', _category, snapshot.categories, (v) => _category = v),
                _filter('Marque', _brandFilter, snapshot.brands, (v) => _brandFilter = v),
                _filter('Fournisseur', _supplier, snapshot.suppliers, (v) => _supplier = v),
                if (filtered)
                  TextButton(
                    onPressed: () => setState(() {
                      _category = _brandFilter = _supplier = null;
                      _productLimit = _productPage;
                    }),
                    child: const Text('Effacer'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: results.isEmpty
                ? Center(child: Text(filtered ? 'Aucun produit actif ne correspond à ces filtres.' : 'Aucun article.', textAlign: TextAlign.center))
                : GridView.builder(
                    gridDelegate: compact
                        ? const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 180,
                            mainAxisExtent: 104,
                            crossAxisSpacing: 6,
                            mainAxisSpacing: 6,
                          )
                        : const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 220,
                            mainAxisExtent: 112,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                          ),
                    itemCount: results.length.clamp(0, _productLimit),
                    itemBuilder: (context, index) => _productTile(results[index]),
                  ),
          ),
          if (results.length > _productLimit)
            TextButton(
              onPressed: () => setState(() => _productLimit += _productPage),
              child: Text('Afficher plus (${results.length - _productLimit})'),
            ),
        ],
      ),
    );
  }

  /// Filtre du catalogue : masqué si la boutique n'a aucune valeur ; porte sur tout le catalogue.
  Widget _filter(String label, String? value, List<String> values, void Function(String?) select) {
    if (values.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: PopupMenuButton<String>(
        tooltip: label,
        onSelected: (choice) => setState(() {
          select(choice.isEmpty ? null : choice);
          _productLimit = _productPage;
        }),
        itemBuilder: (_) => [
          PopupMenuItem(value: '', child: Text('Toutes les valeurs ($label)')),
          for (final v in values) PopupMenuItem(value: v, child: Text(v)),
        ],
        child: Chip(
          label: Text(value ?? label),
          avatar: const Icon(Icons.arrow_drop_down, size: 18),
          backgroundColor: value == null ? Colors.white : _brand.withValues(alpha: 0.12),
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }

  /// Badges du catalogue, comme la caisse web : présentation seule, aucun prix ne change.
  List<Widget> _badges(Product product) {
    Widget badge(String text, Color color) => Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(4)),
      child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600)),
    );
    final now = DateTime.now();
    final promotion = product.promotionLabel(now.toIso8601String().substring(0, 10));
    return [
      if (product.favorite) badge('★ Favori', _offline),
      if (product.isNew(_engine.newBadgeDays, now)) badge('Nouveau', _brand),
      if (promotion != null) Flexible(child: badge(promotion, Colors.deepPurple)),
    ];
  }

  Widget _productTile(Product product) {
    final stock = product.signedStock - (_sold[product.id] ?? BigInt.zero);
    final low = !product.unlimitedStock && stock <= BigInt.zero;
    final alert = !product.unlimitedStock && !low && product.alertThreshold != null && stock <= product.alertThreshold!;
    final badges = _badges(product);
    final image = product.image == null ? null : _engine.imagePath(product.image!);
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _add(product, null),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (image != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Image.file(File(image), width: 40, height: 40, cacheWidth: 120, fit: BoxFit.cover),
                      ),
                    ),
                  Expanded(
                    child: Text(
                      product.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              if (badges.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: Row(children: badges)),
              const Spacer(),
              Row(
                children: [
                  // Prix réduit plutôt que coupé si la tuile est étroite (gros montant, petit écran).
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        formatFcfa(product.price),
                        style: const TextStyle(color: _brand, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  if (!product.unlimitedStock)
                    Flexible(
                      child: Text(
                        'stock ${formatMicros(stock.abs())}${stock.isNegative ? ' (−)' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: TextStyle(fontSize: 11, color: low ? Colors.red : (alert ? _offline : Colors.black54)),
                      ),
                    ),
                ],
              ),
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
      _search.clear();
    } else {
      final results = snapshot.search(code);
      if (results.length == 1) {
        _add(results.first, null);
        _search.clear();
      } else if (results.isEmpty) {
        _toast('Article « $code » introuvable dans le catalogue hors ligne.');
      }
    }
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
      final existing = _cart.where((l) => l.product.id == product.id && l.packaging?.id == chosen?.id).firstOrNull;
      if (existing != null) {
        existing.quantity += BigInt.from(1000000);
      } else {
        _cart.add(CartLine(product: product, packaging: chosen));
      }
    });
    _searchFocus.requestFocus();
  }

  /// [footer] : total et bouton « Encaisser » sous le panier (la disposition compacte les porte dans sa barre fixe).
  Widget _cartPanel(Snapshot snapshot, {bool footer = true}) {
    final compact = _compact;
    final totals = _totals(snapshot);
    return Material(
      color: Colors.white,
      elevation: 2,
      child: Column(
        children: [
          ListTile(
            title: Text('Panier (${_cart.length})', style: const TextStyle(fontWeight: FontWeight.bold)),
            trailing: _cart.isEmpty ? null : TextButton(onPressed: () => setState(_clearCart), child: const Text('Vider')),
          ),
          const Divider(height: 1),
          Expanded(
            child: _cart.isEmpty
                ? const Center(child: Text('Touchez ou scannez un article.'))
                : ListView.separated(
                    itemCount: _cart.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final line = _cart[index];
                      return ListTile(
                        dense: true,
                        title: Text(line.label, maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          '${formatMicros(line.quantity)} × ${formatFcfa(line.unitPrice)}${line.discount > 0 ? ' − ${formatFcfa(line.discount)}' : ''}',
                        ),
                        onTap: () => _editLine(snapshot, line),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              visualDensity: compact ? VisualDensity.compact : null,
                              icon: const Icon(Icons.remove_circle_outline),
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
                            Text(formatFcfa(line.total), style: const TextStyle(fontWeight: FontWeight.w600)),
                            IconButton(
                              visualDensity: compact ? VisualDensity.compact : null,
                              icon: const Icon(Icons.add_circle_outline),
                              onPressed: () => setState(() => line.quantity += BigInt.from(1000000)),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          if (footer) const Divider(height: 1),
          if (footer)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Align(alignment: Alignment.centerLeft, child: _cartActions()),
                  if (totals.globalDiscount > 0)
                    Row(children: [const Text('Remise globale'), const Spacer(), Text('− ${formatFcfa(totals.globalDiscount)}')]),
                  if (totals.delivery > 0) Row(children: [const Text('Livraison'), const Spacer(), Text(formatFcfa(totals.delivery))]),
                  if (snapshot.store.hasVat)
                    Row(children: [Text(snapshot.store.vatIncluded ? 'dont TVA' : 'TVA'), const Spacer(), Text(formatFcfa(totals.vat))]),
                  Row(
                    children: [
                      const Text('Total', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                      const Spacer(),
                      Text(
                        formatFcfa(totals.payable),
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: _brand),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: _brand),
                      onPressed: _cart.isEmpty ? null : () => _checkout(snapshot, totals.payable),
                      icon: const Icon(Icons.payments),
                      label: const Text('Encaisser', style: TextStyle(fontSize: 18)),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _editLine(Snapshot snapshot, CartLine line) async {
    final quantity = TextEditingController(text: formatMicros(line.quantity));
    final refusal = _discountRefusal;
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
              if (refusal == null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.percent),
                    label: Text(line.discount > 0 ? 'Remise : ${formatFcfa(line.discount)}' : 'Ajouter une remise'),
                    onPressed: () async {
                      final q = parseMicros(quantity.text);
                      if (q == null || q <= BigInt.zero) return setLocal(() => error = 'Quantité invalide (six décimales au plus).');
                      final base = lineBase(line.unitPrice, q);
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
                final base = lineBase(line.unitPrice, q);
                final entry = line.discountEntry;
                if (entry != null && !entry.isPercent && line.discount > base) return setLocal(() => error = 'La remise dépasse le montant de la ligne.');
                setState(() => line.quantity = q);
                Navigator.pop(context);
              },
              child: const Text('Valider'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _checkout(Snapshot snapshot, int payable) async {
    final globalDiscount = _totals(snapshot).globalDiscount;
    SaleApproval? approval;
    if (!_engine.withinDiscountLimits(_operator!, _cart, globalDiscount)) {
      approval = await _askApproval(globalDiscount);
      if (approval == null || !mounted) return;
    }
    final payments = _compact
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
        extras: SaleExtras(globalDiscount: totals.globalDiscount, globalEntry: _globalEntry, delivery: _delivery, note: _note, approval: approval, customer: _customer, sharedCart: _shared?.uuid),
      );
    } on OfflineRefusal catch (e) {
      _toast(e.message);
      return;
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
    setState(() {
      _clearCart();
      _draftUuid = const Uuid().v4();
    });
    unawaited(_refreshSold());
    await _print(snapshot, operation, lines, payments);
    final change = payments.fold<int>(0, (sum, p) => sum + p.change);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.check_circle, color: _brand, size: 48),
        title: Text('Vente ${operation.number}'),
        content: Text(
          change > 0 ? 'Monnaie à rendre : ${formatFcfa(change)}' : 'Vente enregistrée sur le terminal.',
          style: const TextStyle(fontSize: 20),
        ),
        actions: [
          TextButton(onPressed: () => _print(snapshot, operation, lines, payments, duplicate: true), child: const Text('Réimprimer')),
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Vente suivante')),
        ],
      ),
    );
    _searchFocus.requestFocus();
  }

  /// Retour en espèces d'une vente de ce terminal : quantités par ligne, montant calculé, motif obligatoire.
  Future<void> _startReturn(OfflineOperation sale) async {
    final operator = _operator!;
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
                  await _engine.recordReturn(operator, sale.uuid, wanted, reason.text);
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
    }
  }

  void _openJournal() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PendingOperationsPage(
          engine: _engine,
          onReprint: _reprint,
          onReturn: _operator != null && _engine.returnsOpen(_operator!) ? _startReturn : null,
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
    final text = offlineTicketLines(
      snapshot: snapshot,
      operation: operation,
      lines: lines,
      payments: payments,
      operatorName: operatorName ?? _operator?.name ?? '',
      paperWidth: width,
      duplicate: duplicate,
    );
    if (session.hasPrinter) {
      final result = await session.channel.printRaw(offlineTicketBytes(text));
      if (payments.any((p) => p.method.isCash) && !duplicate) await session.channel.openDrawer();
      if (!result.ok) _toast('Ticket non imprimé (${result.error}) : la vente est bien enregistrée.');
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
