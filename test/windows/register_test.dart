import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:shopikaiss_terminal/src/windows/platform/sale_intent.dart';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/protocol.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/register_app.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/register_controller.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/multiple_payments.dart';
import 'package:shopikaiss_terminal/src/windows/presentation/discount_approval.dart';

class _Host implements WindowsHost {
  final changes = StreamController<Map<String, dynamic>>.broadcast();
  final calls = <HostCommand>[];
  final argumentsByCommand = <HostCommand, Map<String, dynamic>>{};
  String? committedId;
  bool loseReply = false;
  bool reconciled = false;
  bool definitive = false;
  bool failHistory = false;
  bool approvalSeen = false;
  bool refuseApproval = false;
  bool refusePreparation = false;
  String? lookupId;
  Completer<Map<String, dynamic>>? pendingView;
  final Map<String, dynamic> state = {
    'schema': 1,
    'revision': 1,
    'ready': true,
    'can_pay': true,
    'payment_valid': true,
    'draft_id': 'draft-1',
    'store_name': 'Boutique de test',
    'total_label': '2 000 F',
    'totals': {
      'global_discount_label': '100 F',
      'delivery_label': '500 F',
      'base_ht_label': '1 695 F',
      'vat_label': '305 F',
    },
    'products': [
      <String, dynamic>{
        'id': 'p1',
        'name': 'Produit de test',
        'price_label': '2 000 F',
        'wholesale_price_label': '1 800 F',
      },
    ],
    'lines': [
      {
        'id': 'l1',
        'name': 'Article en panier',
        'quantity_label': '1',
        'total_label': '2 000 F',
      },
    ],
  };
  @override
  Stream<Map<String, dynamic>> get events => changes.stream;
  @override
  Future<Map<String, dynamic>> call(
    HostCommand command, {
    Map<String, dynamic> arguments = const {},
    String? operationId,
  }) async {
    calls.add(command);
    argumentsByCommand[command] = arguments;
    if (command == HostCommand.drafts) {
      return {
        'items': [
          {
            'draft_id': 'held-1',
            'summary': 'Panier test',
            'lines_count': 2,
            'total_label': '4 000 F',
          },
        ],
      };
    }
    if (command == HostCommand.history) {
      if (failHistory) {
        throw const HostFailure('offline', 'Moteur indisponible');
      }
      return {
        'items': [
          {
            'operation_id': 'sale-1',
            'number': 'HL-1',
            'server_number': 'V-1',
            'total_label': '2 000 F',
            'server_status': 'integree',
          },
        ],
      };
    }
    if (command == HostCommand.reprint) {
      return {
        'operation_id': arguments['operation_id'],
        'lines': ['DUPLICATA', 'HL-1'],
      };
    }
    if (command == HostCommand.view && pendingView != null) {
      return pendingView!.future;
    }
    if (command == HostCommand.preparePayment) {
      if (refusePreparation) {
        throw const HostFailure('vente_refusee', 'Le tarif gros ne se cumule pas avec une remise.');
      }
      return {
        'methods': [
          {'code': 'especes', 'name': 'Espèces', 'cash': true},
        ],
      };
    }
    if (command == HostCommand.setPayment) {
      state['payment_valid'] = true;
      state['payment_label'] = 'Espèces 2 000 F';
      return {'change': 3000};
    }
    if (command == HostCommand.commitSale) {
      approvalSeen = (arguments['approval'] as Map?)?['code'] == '12345678';
      if (refuseApproval) {
        throw const HostFailure('autorisation_refusee', 'Autorisation refusée');
      }
      committedId = operationId;
      if (loseReply) {
        throw const HostFailure(
          'host_unavailable',
          'Vérifier',
          outcomeUnknown: true,
        );
      }
      return {
        'state': 'committed',
        'operation_id': operationId,
        'number': 'TEST-1',
      };
    }
    if (command == HostCommand.saleStatus) {
      return {
        'state': reconciled ? 'committed' : 'not_found',
        'operation_id': lookupId ?? arguments['operation_id'],
        'definitive': definitive,
        'number': 'TEST-1',
      };
    }
    return Map.of(state);
  }

  @override
  Future<void> close() => changes.close();
}

void main() {
  testWidgets(
    'approval cancelled or refused preserves basket and never retains the code',
    (tester) async {
      final host = _Host()..refuseApproval = true;
      host.state['discount_approval'] = {
        'required': true,
        'approvers': [
          {'id': 7, 'name': 'Responsable test'},
        ],
      };
      final c = WindowsRegisterController(host);
      addTearDown(() async {
        c.dispose();
        await host.close();
      });
      await c.refresh();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => commitWithApproval(context, c),
                child: const Text('Essai'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Essai'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Annuler'));
      await tester.pumpAndSettle();
      expect(host.calls, isNot(contains(HostCommand.commitSale)));
      await tester.tap(find.text('Essai'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<Object>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Responsable test').last);
      await tester.pumpAndSettle();
      final codeField = find.widgetWithText(
        TextField,
        'Code du responsable (8 chiffres)',
      );
      expect(tester.widget<TextField>(codeField).obscureText, isTrue);
      await tester.enterText(codeField, '12345678');
      await tester.enterText(
        find.widgetWithText(TextField, 'Motif de la remise'),
        'Geste commercial',
      );
      await tester.pump();
      await tester.tap(find.text('Autoriser et encaisser'));
      await tester.pumpAndSettle();
      expect(host.approvalSeen, isTrue);
      expect(c.message, 'Autorisation refusée');
      expect(c.lines, isNotEmpty);
      expect(c.uncertainOperation, isNull);
      expect(
        host.argumentsByCommand[HostCommand.commitSale]!['approval'],
        isEmpty,
      );
      await tester.tap(find.text('Essai'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<EditableText>(
              find.descendant(
                of: codeField,
                matching: find.byType(EditableText),
              ),
            )
            .controller
            .text,
        isEmpty,
      );
      await tester.tap(find.text('Annuler'));
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'catalogue filters preserve each other and load more through engine',
    (tester) async {
      tester.view.physicalSize = const Size(1366, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final host = _Host();
      host.state.addAll({
        'brands': ['Marque A'],
        'suppliers': ['Fournisseur A'],
        'category': 'Épicerie',
        'supplier': 'Fournisseur A',
        'products_total': 121,
        'has_more': true,
      });
      final c = WindowsRegisterController(host);
      addTearDown(() async {
        c.dispose();
        await host.close();
      });
      await tester.pumpWidget(WindowsRegisterApp(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Toutes les marques'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Rechercher : Marque'),
        'introuvable',
      );
      await tester.pumpAndSettle();
      expect(find.text('Aucun résultat'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Rechercher : Marque'),
        'marque a',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Marque A').last);
      await tester.pumpAndSettle();
      expect(host.argumentsByCommand[HostCommand.search], {
        'query': '',
        'category': 'Épicerie',
        'brand': 'Marque A',
        'supplier': 'Fournisseur A',
      });
      expect(find.text('1 / 121 produits'), findsOneWidget);
      await tester.tap(find.text('Afficher plus'));
      await tester.pumpAndSettle();
      expect(host.calls, contains(HostCommand.moreProducts));
      host.state['brand'] = 'Marque A';
      await c.refresh();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fournisseur A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tous les fournisseurs').last);
      await tester.pumpAndSettle();
      expect(host.argumentsByCommand[HostCommand.search], {
        'query': '',
        'category': 'Épicerie',
        'brand': 'Marque A',
        'supplier': '',
      });
    },
  );
  testWidgets('category discount and suspended basket use engine commands', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final host = _Host();
    host.state['categories'] = ['Épicerie'];
    host.state['capabilities'] = {
      'discount': {'allowed': true},
      'suspend': {'allowed': true},
    };
    final c = WindowsRegisterController(host);
    addTearDown(() async {
      c.dispose();
      await host.close();
    });
    await tester.pumpWidget(WindowsRegisterApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Épicerie'));
    await tester.pumpAndSettle();
    expect(host.argumentsByCommand[HostCommand.search], {
      'query': '',
      'category': 'Épicerie',
      'brand': '',
      'supplier': '',
    });
    await tester.tap(find.byTooltip('Remise de ligne'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '100');
    await tester.tap(find.text('Appliquer'));
    await tester.pumpAndSettle();
    expect(host.argumentsByCommand[HostCommand.setLineDiscount], {
      'line_id': 'l1',
      'amount': 100,
    });
    await tester.tap(find.text('En attente (F8)'));
    await tester.pumpAndSettle();
    expect(host.calls, contains(HostCommand.suspendDraft));
    await tester.tap(find.text('Suspendus (0)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Panier test'));
    await tester.pumpAndSettle();
    expect(host.argumentsByCommand[HostCommand.resumeDraft], {
      'draft_id': 'held-1',
    });
    expect(host.calls, isNot(contains(HostCommand.commitSale)));
  });
  if (Platform.environment['SHOPIKAISS_VISUAL_PREVIEW'] == '1') {
    testWidgets('render visual review with fictitious data', (tester) async {
      await tester.runAsync(() async {
        final font = FontLoader('Segoe UI');
        font.addFont(
          Future.value(
            ByteData.sublistView(
              await File('C:/Windows/Fonts/segoeui.ttf').readAsBytes(),
            ),
          ),
        );
        await font.load();
        final icons = FontLoader('MaterialIcons');
        icons.addFont(
          Future.value(
            ByteData.sublistView(
              await File(
                'C:/dev/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
              ).readAsBytes(),
            ),
          ),
        );
        await icons.load();
      });
      tester.view.physicalSize = const Size(1366, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final host = _Host();
      host.state['store_name'] = 'Boutique de démonstration';
      host.state['sync_label'] = 'À jour';
      host.state['categories'] = ['Épicerie', 'Boissons', 'Maison'];
      host.state['capabilities'] = {
        'discount': {'allowed': true},
        'suspend': {'allowed': true},
      };
      final names = [
        'Riz parfumé 5 kg',
        'Huile végétale 1 L',
        'Savon de ménage',
        'Café moulu 250 g',
        'Biscuits secs',
        'Eau minérale 1,5 L',
        'Pâtes alimentaires',
        'Lait en poudre',
        'Jus de bissap',
        'Concentré de tomate',
        'Farine de blé',
        'Sucre en poudre',
      ];
      host.state['products'] = [
        for (var i = 0; i < 24; i++)
          <String, dynamic>{
            'id': i,
            'name': names[i % names.length],
            'price_label': '1 500 F',
            'stock_label': '24 disponibles',
          },
      ];
      host.state['lines'] = [
        for (var i = 0; i < 6; i++)
          <String, dynamic>{
            'id': '$i',
            'name': names[i],
            'quantity_label': '1',
            'total_label': '1 500 F',
          },
      ];
      host.state['total_label'] = '9 000 F';
      host.state['totals'] = {
        'base_ht_label': '7 627 F',
        'vat_label': '1 373 F',
      };
      final c = WindowsRegisterController(host);
      addTearDown(() async {
        c.dispose();
        await host.close();
      });
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: WindowsRegisterApp(controller: c),
        ),
      );
      await tester.runAsync(() async {
        await precacheImage(
          const AssetImage(
            'assets/branding/shopikaiss/SHOPIKAISS_02_Or_et_noir_sur_blanc.png',
          ),
          key.currentContext!,
        );
      });
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = File('build/visual-review/caisse-windows.png');
        await output.parent.create(recursive: true);
        await output.writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
      });
    });
  }
  testWidgets('search Enter never scans and packaging choice reaches engine', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final host = _Host();
    (host.state['products'] as List).first['packagings'] = [
      {'id': 7, 'name': 'Carton', 'price_label': '12 000 F'},
    ];
    final c = WindowsRegisterController(host);
    addTearDown(() async {
      c.dispose();
      await host.close();
    });
    await tester.pumpWidget(WindowsRegisterApp(controller: c));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Rechercher un produit'),
      'riz',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(host.argumentsByCommand[HostCommand.search], {
      'query': 'riz',
      'category': '',
      'brand': '',
      'supplier': '',
    });
    expect(host.calls, isNot(contains(HostCommand.scan)));
    await tester.tap(find.text('Compacte'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Produit de test'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Carton · 12 000 F'));
    await tester.pumpAndSettle();
    expect(host.argumentsByCommand[HostCommand.addProduct], {
      'product_id': 'p1',
      'packaging_id': 7,
    });
  });

  testWidgets('sale extras require capability and send engine commands', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final host = _Host();
    final c = WindowsRegisterController(host);
    addTearDown(() async {
      c.dispose();
      await host.close();
    });
    await tester.pumpWidget(WindowsRegisterApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remise et livraison'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextButton>(
            find.widgetWithText(TextButton, 'Appliquer la remise globale'),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('Fermer'));
    await tester.pumpAndSettle();
    host.state['capabilities'] = {
      for (final key in ['global_discount', 'delivery', 'note'])
        key: {'allowed': true},
    };
    await c.refresh();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remise et livraison'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Remise globale (0 pour retirer)'),
      '100',
    );
    await tester.tap(find.text('Appliquer la remise globale'));
    await tester.pumpAndSettle();
    expect(host.argumentsByCommand[HostCommand.setGlobalDiscount], {
      'amount': 100,
    });
    await tester.enterText(
      find.widgetWithText(TextField, 'Frais de livraison (F CFA)'),
      '500',
    );
    await tester.tap(find.text('Appliquer la livraison'));
    await tester.pumpAndSettle();
    expect(host.argumentsByCommand[HostCommand.setDelivery], {'amount': 500});
    await tester.enterText(
      find.widgetWithText(TextField, 'Note sur le ticket'),
      'Merci',
    );
    await tester.tap(find.text('Enregistrer la note'));
    await tester.pumpAndSettle();
    expect(host.argumentsByCommand[HostCommand.setNote], {'text': 'Merci'});
    expect(host.calls, isNot(contains(HostCommand.commitSale)));
  });

  testWidgets(
    'declared payments send reference and editing disables confirmation',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final host = _Host();
      final c = WindowsRegisterController(host);
      addTearDown(() async {
        c.dispose();
        await host.close();
      });
      await c.refresh();
      c.paymentMethods = [
        {
          'code': 'wave',
          'name': 'Wave',
          'cash': false,
          'reference': 'obligatoire',
        },
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MultiplePayments(controller: c)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Wave').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Montant (F CFA)'),
        '2000',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Référence obligatoire'),
        'REF-DEMO',
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Confirmer ces paiements'),
            )
            .onPressed,
        isNull,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(host.argumentsByCommand[HostCommand.setPayments], {
        'payments': [
          {'method': 'wave', 'amount': 2000, 'reference': 'REF-DEMO'},
        ],
      });
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Confirmer ces paiements'),
            )
            .onPressed,
        isNotNull,
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Montant (F CFA)'),
        '1000',
      );
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Confirmer ces paiements'),
            )
            .onPressed,
        isNull,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(host.calls, isNot(contains(HostCommand.commitSale)));
    },
  );

  testWidgets('late amount validation never enables an edited payment', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final host = _Host();
    final c = WindowsRegisterController(host);
    addTearDown(() async {
      c.dispose();
      await host.close();
    });
    await tester.pumpWidget(WindowsRegisterApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Payer (F4)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Espèces'));
    await tester.pumpAndSettle();
    final pending = Completer<Map<String, dynamic>>();
    host.pendingView = pending;
    final input = find.widgetWithText(TextField, 'Montant reçu (F CFA)');
    await tester.enterText(input, '5000');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(input, '6000');
    pending.complete(Map<String, dynamic>.from(host.state));
    host.pendingView = null;
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Confirmer le paiement'),
          )
          .onPressed,
      isNull,
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(host.argumentsByCommand[HostCommand.setPayment]?['received'], 6000);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Confirmer le paiement'),
          )
          .onPressed,
      isNotNull,
    );
    expect(host.calls, isNot(contains(HostCommand.commitSale)));
  });

  testWidgets(
    'cash edits invalidate confirmation until engine validates received amount',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final host = _Host();
      final c = WindowsRegisterController(host);
      addTearDown(() async {
        c.dispose();
        await host.close();
      });
      await tester.pumpWidget(WindowsRegisterApp(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Payer (F4)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Espèces'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Montant reçu (F CFA)'),
        '5000',
      );
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Confirmer le paiement'),
            )
            .onPressed,
        isNull,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(host.argumentsByCommand[HostCommand.setPayment], {
        'method': 'especes',
        'received': 5000,
      });
      expect(find.text('Monnaie à rendre : 3000 F CFA'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Confirmer le paiement'),
            )
            .onPressed,
        isNotNull,
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Montant reçu (F CFA)'),
        '-5',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Confirmer le paiement'),
            )
            .onPressed,
        isNull,
      );
      expect(host.calls, isNot(contains(HostCommand.commitSale)));
    },
  );
  testWidgets(
    'history and duplicate never resubmit or edit the current basket',
    (tester) async {
      final host = _Host();
      final c = WindowsRegisterController(host);
      addTearDown(() async {
        c.dispose();
        await host.close();
      });
      await tester.pumpWidget(WindowsRegisterApp(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Ventes de ce poste'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Intégrée au serveur'), findsOneWidget);
      await tester.tap(find.text('V-1 · 2 000 F'));
      await tester.pumpAndSettle();
      expect(find.text('DUPLICATA\nHL-1'), findsOneWidget);
      expect(host.argumentsByCommand[HostCommand.reprint], {
        'operation_id': 'sale-1',
      });
      expect(
        host.calls.every(
          (command) => [
            HostCommand.status,
            HostCommand.view,
            HostCommand.history,
            HostCommand.reprint,
          ].contains(command),
        ),
        isTrue,
      );
      await tester.tap(find.text('Fermer'));
      await tester.pumpAndSettle();
      expect(c.lines.single['id'], 'l1');
    },
  );

  testWidgets('failed history remains closable and retry is read only', (
    tester,
  ) async {
    final host = _Host()..failHistory = true;
    final c = WindowsRegisterController(host);
    addTearDown(() async {
      c.dispose();
      await host.close();
    });
    await tester.pumpWidget(WindowsRegisterApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Ventes de ce poste'));
    await tester.pumpAndSettle();
    expect(find.text('Moteur indisponible'), findsOneWidget);
    host.failHistory = false;
    await tester.tap(find.text('Actualiser'));
    await tester.pumpAndSettle();
    expect(find.text('V-1 · 2 000 F'), findsOneWidget);
    expect(host.calls, isNot(contains(HostCommand.commitSale)));
  });
  testWidgets(
    'quantity stays an engine command and clearing requires confirmation',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final host = _Host();
      final c = WindowsRegisterController(host);
      addTearDown(() async {
        c.dispose();
        await host.close();
      });
      await tester.pumpWidget(WindowsRegisterApp(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Article en panier'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Nouvelle quantité'),
        '1,5',
      );
      await tester.tap(find.text('Appliquer'));
      await tester.pumpAndSettle();
      expect(host.argumentsByCommand[HostCommand.changeQuantity], {
        'line_id': 'l1',
        'quantity': '1,5',
      });
      await tester.tap(find.text('Vider le panier'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Conserver'));
      await tester.pumpAndSettle();
      expect(host.calls, isNot(contains(HostCommand.clear)));
      await tester.tap(find.text('Vider le panier'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Vider le panier'));
      await tester.pumpAndSettle();
      expect(host.calls.where((c) => c == HostCommand.clear), hasLength(1));
    },
  );

  testWidgets('pending sale blocks basket edits', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final host = _Host()..loseReply = true;
    final c = WindowsRegisterController(host);
    addTearDown(() async {
      c.dispose();
      await host.close();
    });
    await c.refresh();
    await c.commitSale();
    await tester.pumpWidget(WindowsRegisterApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Article en panier'));
    await tester.tap(find.text('Vider le panier'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(host.calls, isNot(contains(HostCommand.changeQuantity)));
    expect(host.calls, isNot(contains(HostCommand.clear)));
  });
  test(
    'durable intent survives UI disposal and resolves without recommit',
    () async {
      final dir = await Directory.systemTemp.createTemp('windows-intent-');
      final file = File('${dir.path}/pending.json');
      final host = _Host()..loseReply = true;
      final first = WindowsRegisterController(
        host,
        journal: SaleIntentJournal(file),
      );
      await first.refresh();
      await first.commitSale();
      final id = first.uncertainOperation;
      expect(await SaleIntentJournal(file).read(), id);
      first.dispose();
      final next = WindowsRegisterController(
        host,
        journal: SaleIntentJournal(file),
      );
      await next.refresh();
      expect(next.canPay, isFalse);
      expect(next.uncertainOperation, id);
      host.reconciled = true;
      await next.reconcile();
      expect(next.receipt, 'TEST-1');
      expect(await file.exists(), isFalse);
      expect(host.calls.where((c) => c == HostCommand.commitSale).length, 1);
      next.dispose();
      await host.close();
      await dir.delete(recursive: true);
    },
  );

  test('corrupt durable intent fails closed without sending sale', () async {
    final dir = await Directory.systemTemp.createTemp('windows-intent-');
    final file = File('${dir.path}/pending.json');
    await file.writeAsString('{');
    final host = _Host();
    final c = WindowsRegisterController(host, journal: SaleIntentJournal(file));
    await c.refresh();
    await c.commitSale();
    expect(c.canPay, isFalse);
    expect(host.calls, isNot(contains(HostCommand.commitSale)));
    expect(await file.readAsString(), '{');
    c.dispose();
    await host.close();
    await dir.delete(recursive: true);
  });

  test('failed durable write prevents sending sale', () async {
    final dir = await Directory.systemTemp.createTemp('windows-intent-');
    final host = _Host();
    final c = WindowsRegisterController(
      host,
      journal: SaleIntentJournal(File('${dir.path}/pending.json')),
    );
    await c.refresh();
    await dir.delete();
    await File(dir.path).writeAsString('blocked parent');
    await c.commitSale();
    expect(c.canPay, isFalse);
    expect(host.calls, isNot(contains(HostCommand.commitSale)));
    c.dispose();
    await host.close();
    await File(dir.path).delete();
  });

  testWidgets('payment refusal is a visible dialog and never opens payment', (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final host = _Host()..refusePreparation = true;
    final c = WindowsRegisterController(host);
    addTearDown(() async { c.dispose(); await host.close(); });
    await tester.pumpWidget(WindowsRegisterApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Payer (F4)'));
    await tester.pumpAndSettle();
    expect(find.text('Paiement indisponible'), findsOneWidget);
    expect(find.descendant(of: find.byType(AlertDialog), matching: find.text('Le tarif gros ne se cumule pas avec une remise.')), findsOneWidget);
    expect(host.calls, isNot(contains(HostCommand.commitSale)));
    await tester.tap(find.text('Compris'));
    await tester.pumpAndSettle();
    expect(find.text('Article en panier'), findsOneWidget);
  });

  testWidgets('catalogue and payment buttons use B commands', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final host = _Host();
    host.state['payment_valid'] = false;
    final c = WindowsRegisterController(host);
    addTearDown(() async {
      c.dispose();
      await host.close();
    });
    await tester.pumpWidget(WindowsRegisterApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Produit de test'));
    await tester.pumpAndSettle();
    expect(host.calls, contains(HostCommand.addProduct));
    expect(host.calls, isNot(contains(HostCommand.scan)));
    await tester.tap(find.text('Payer (F4)'));
    await tester.pumpAndSettle();
    final confirm = find.widgetWithText(FilledButton, 'Confirmer le paiement');
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    await tester.tap(find.text('Espèces'));
    await tester.pumpAndSettle();
    expect(host.calls, contains(HostCommand.setPayment));
    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(
      host.calls.where((call) => call == HostCommand.commitSale).length,
      1,
    );
  });
  test(
    'only definitive absence for the same operation unlocks the basket',
    () async {
      final host = _Host()..loseReply = true;
      final c = WindowsRegisterController(host);
      addTearDown(() async {
        c.dispose();
        await host.close();
      });
      await c.refresh();
      await c.commitSale();
      final operation = c.uncertainOperation;
      host.definitive = true;
      host.lookupId = 'another-sale';
      await c.reconcile();
      expect(c.uncertainOperation, operation);
      expect(c.canPay, false);
      host.lookupId = null;
      await c.reconcile();
      expect(c.uncertainOperation, isNull);
      expect(c.canPay, true);
      expect(
        host.calls.where((call) => call == HostCommand.commitSale).length,
        1,
      );
    },
  );

  test('restarted engine may restart its view revision at zero', () async {
    final host = _Host();
    final c = WindowsRegisterController(host);
    addTearDown(() async {
      c.dispose();
      await host.close();
    });
    host.state['revision'] = 200;
    await c.refresh();
    host.state['revision'] = 0;
    host.state['total_label'] = 'Nouveau moteur';
    host.changes.add({'name': 'disconnected'});
    host.changes.add({'name': 'connected'});
    await Future<void>.delayed(Duration.zero);
    expect(c.view['revision'], 0);
    expect(c.view['total_label'], 'Nouveau moteur');
    expect(c.ready, true);
  });
  test('late view after disconnection cannot enable payment', () async {
    final host = _Host()..pendingView = Completer<Map<String, dynamic>>();
    final c = WindowsRegisterController(host);
    addTearDown(() async {
      c.dispose();
      await host.close();
    });
    final pending = c.refresh();
    host.changes.add({'name': 'disconnected'});
    await Future<void>.delayed(Duration.zero);
    host.pendingView!.complete(Map.of(host.state));
    await pending;
    expect(c.ready, false);
    expect(c.canPay, false);
    expect(c.view, isEmpty);
    await c.commitSale();
    expect(host.calls, isNot(contains(HostCommand.commitSale)));
    host.pendingView = null;
    host.changes.add({'name': 'connected'});
    await Future<void>.delayed(Duration.zero);
    expect(c.ready, true);
    expect(c.canPay, true);
  });

  test('reconnection reloads view but preserves an uncertain sale', () async {
    final host = _Host()..loseReply = true;
    final c = WindowsRegisterController(host);
    addTearDown(() async {
      c.dispose();
      await host.close();
    });
    await c.refresh();
    await c.commitSale();
    final operation = c.uncertainOperation;
    expect(operation, isNotNull);
    host.changes.add({'name': 'disconnected'});
    host.changes.add({'name': 'connected'});
    await Future<void>.delayed(Duration.zero);
    expect(c.ready, true);
    expect(c.uncertainOperation, operation);
    expect(c.canPay, false);
    await c.commitSale();
    expect(
      host.calls.where((call) => call == HostCommand.commitSale).length,
      1,
    );
  });

  test('closed event stream disables payment', () async {
    final host = _Host();
    final c = WindowsRegisterController(host);
    addTearDown(c.dispose);
    await c.refresh();
    expect(c.canPay, true);
    await host.close();
    expect(c.ready, false);
    expect(c.canPay, false);
  });

  test(
    'unknown sale locks further edits and only reconciles the same UUID',
    () async {
      final host = _Host()..loseReply = true;
      final c = WindowsRegisterController(host);
      addTearDown(() async {
        c.dispose();
        await host.close();
      });
      await c.refresh();
      await c.commitSale();
      final original = host.committedId;
      expect(c.uncertainOperation, original);
      expect(c.canPay, false);
      await c.commitSale();
      await c.command(HostCommand.scan, {'code': '123'});
      expect(host.calls.where((c) => c == HostCommand.commitSale).length, 1);
      expect(host.calls, isNot(contains(HostCommand.scan)));
      await c.reconcile();
      expect(
        c.uncertainOperation,
        original,
        reason: 'not_found is not proof of no commit',
      );
      host.reconciled = true;
      await c.reconcile();
      expect(c.uncertainOperation, null);
      expect(c.receipt, 'TEST-1');
    },
  );

  test('stale view cannot overwrite a newer draft', () async {
    final host = _Host();
    final c = WindowsRegisterController(host);
    addTearDown(() async {
      c.dispose();
      await host.close();
    });
    host.state['revision'] = 5;
    await c.refresh();
    host.state['revision'] = 3;
    host.state['total_label'] = 'incorrect';
    await c.refresh();
    expect(c.view['revision'], 5);
    expect(c.view['total_label'], '2 000 F');
  });

  testWidgets('production entry has no fake shop or enabled sale', (
    tester,
  ) async {
    await tester.pumpWidget(const WindowsRegisterApp());
    expect(find.text('Votre caisse doit être configurée'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });

  for (final size in [const Size(1280, 800), const Size(800, 600)]) {
    testWidgets('register and payment render without overflow at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final host = _Host();
      final c = WindowsRegisterController(host);
      addTearDown(() async {
        c.dispose();
        await host.close();
      });
      await tester.pumpWidget(WindowsRegisterApp(controller: c));
      await tester.pumpAndSettle();
      if (size.width < 900) {
        expect(find.text('Gros : 1 800 F'), findsOneWidget);
        await tester.tap(find.text('Panier').first);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Payer (F4)'));
      await tester.pumpAndSettle();
      expect(find.text('Paiement'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
