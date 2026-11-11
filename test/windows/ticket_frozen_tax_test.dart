import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/offline/models.dart';
import 'package:shopikaiss_terminal/src/offline/ticket.dart';

void main() {
  for (final currentRate in ['0.000000', '10.000000']) {
    test(
      'duplicata keeps original added VAT when current rate is $currentRate',
      () {
        final snapshot = Snapshot({
          'boutique': {
            'nom': 'Boutique',
            'devise': 'FCFA',
            'tva_taux': currentRate,
            'tva_incluse': true,
          },
          'terminal': {'nom': 'Caisse'},
        });
        final product = Product({'id': 1, 'nom': 'Article', 'prix': 1000});
        final sale = OfflineOperation(
          uuid: '00000000-0000-4000-8000-000000000001',
          sequence: 1,
          type: 'vente',
          number: 'TEST-1',
          date: DateTime(2026, 11, 11),
          operatorId: 1,
          content: {
            'tva': {'taux': '18.000000', 'incluse': false},
            'totaux': {'base_ht': 1000, 'tva': 180, 'a_payer': 1180},
            'total': 1180,
          },
        );
        final lines = offlineTicketLines(
          snapshot: snapshot,
          operation: sale,
          lines: [CartLine(product: product, quantity: BigInt.from(1000000))],
          payments: [],
          operatorName: 'Caissier',
          paperWidth: 80,
          duplicate: true,
        );
        expect(
          lines.where((l) => l.startsWith('TOTAL')).single,
          endsWith('1 180 F'),
        );
        expect(
          lines.any((l) => l.startsWith('Total HT') && l.endsWith('1 000 F')),
          isTrue,
        );
        expect(
          lines.any((l) => l.startsWith('TVA 18 %') && l.endsWith('180 F')),
          isTrue,
        );
        expect(
          lines.any((l) => l.contains('dont TVA') || l.contains('TVA 10 %')),
          isFalse,
        );
      },
    );
  }
}
