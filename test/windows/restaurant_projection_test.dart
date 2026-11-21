import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/restaurant/resto_context.dart';
import 'package:shopikaiss_terminal/src/restaurant/resto_engine.dart';
import 'package:shopikaiss_terminal/src/windows/ipc/restaurant_projection.dart';

void main() {
  test('Absent context never grants restaurant access', () {
    expect(restaurantProjection(null, [])['available'], false);
  });
  test(
    'Two orders on one table remain distinct and preserve server wait reason',
    () {
      const ctx = RestoContext(
        pointOfSaleUuid: 'p',
        pointOfSaleName: 'Salle',
        profile: 'TABLE_SERVICE',
        master: false,
        generation: '1',
        notMasterReason: 'Caisse non maîtresse',
        tables: [
          RestoTable(uuid: 't', name: 'Table 1', order: 1),
          RestoTable(uuid: 'free', name: 'Table 2', order: 2),
        ],
      );
      final orders = [
        for (var n = 1; n <= 2; n++)
          RestoOrderView(
            order: RestoOrder(
              uuid: '$n',
              localNumber: 'S-20261118-L000$n',
              businessDay: '2026-11-18',
              profile: 'TABLE_SERVICE',
              tableUuid: 't',
            ),
            payable: n * 1500,
            waiting: true,
          ),
      ];
      final view = restaurantProjection(ctx, orders);
      expect(view['master'], false);
      expect(view['message'], 'Caisse non maîtresse');
      final tables = view['tables'] as List;
      expect(tables, hasLength(3));
      expect(tables[0]['id'], isNot(tables[1]['id']));
      expect(tables[0]['sync_message'], contains('version précédente'));
      expect(tables[2]['state'], 'free');
    },
  );
}
