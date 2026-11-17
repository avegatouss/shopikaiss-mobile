import 'package:flutter_test/flutter_test.dart';
import 'package:shopikaiss_terminal/src/passes/pass_rules.dart';

/// Jeux d'essai d'ECAS (`ReglesPassageTest`, `ControlePanierPassTest`), même calendrier : lundi 2026-11-09.
void main() {
  const lundi = '2026-11-09';
  const mardi = '2026-11-10';
  const mercredi = '2026-11-11';
  const jeudi = '2026-11-12';
  const dimanche = '2026-11-15';

  void allowed(PassDecision d) => expect(d.allowed, isTrue, reason: d.refusal);
  void refused(PassDecision d) => expect(d.allowed, isFalse);

  group('ReglesPassage', () {
    test('le calendrier ISO est juste', () {
      expect(PassDay.weekday(lundi), 1);
      expect(PassDay.weekday(mercredi), 3);
      expect(PassDay.weekday(dimanche), 7);
      expect(PassDay.weekday('2026-01-05'), 1);
    });

    test('3 le lundi, 2 le mardi, 5 le mercredi', () {
      const def = PassDefinition(rules: [PassDayRule(weekday: 1, max: 3), PassDayRule(weekday: 2, max: 2), PassDayRule(weekday: 3, max: 5)]);
      allowed(PassRules.decide(def, lundi, 2, 2, 1000));
      refused(PassRules.decide(def, lundi, 3, 3, 1000));
      allowed(PassRules.decide(def, mardi, 1, 4, 1000));
      refused(PassRules.decide(def, mardi, 2, 5, 1000));
      allowed(PassRules.decide(def, mercredi, 4, 9, 1000));
      refused(PassRules.decide(def, mercredi, 5, 10, 1000));
      expect(PassRules.decide(def, jeudi, 0, 0, 1000).refusal, 'Ce pass ne passe pas le jeudi 12/11/2026. Jours prévus : lundi (3), mardi (2), mercredi (5).');
      expect(PassRules.decide(def, lundi, 3, 3, 1000).refusal, "Ce pass a déjà fait ses 3 passages aujourd'hui.");
    });

    test('restant du jour et total annoncés après le passage', () {
      const def = PassDefinition(maxTotal: 4, rules: [PassDayRule(weekday: 1, max: 3)]);
      final d = PassRules.decide(def, lundi, 1, 1, 0);
      expect([d.leftToday, d.leftTotal], [1, 2]);
    });

    test('lundi uniquement sur trois semaines', () {
      const def = PassDefinition(start: lundi, end: '2026-11-29', rules: [PassDayRule(weekday: 1, max: 1)]);
      allowed(PassRules.decide(def, lundi, 0, 0, 0));
      allowed(PassRules.decide(def, '2026-11-16', 0, 1, 0));
      allowed(PassRules.decide(def, '2026-11-23', 0, 2, 0));
      expect(PassRules.decide(def, '2026-11-30', 0, 3, 0).refusal, 'Ce pass a expiré le 29/11/2026.');
      refused(PassRules.decide(def, mardi, 0, 1, 0));
      expect(PassRules.decide(def, '2026-11-02', 0, 0, 0).refusal, "Ce pass n'est valable qu'à partir du 09/11/2026.");
    });

    test('mardi, mercredi ou jeudi en une seule fois', () {
      const def = PassDefinition(maxTotal: 1, rules: [PassDayRule(weekday: 2, max: 1), PassDayRule(weekday: 3, max: 1), PassDayRule(weekday: 4, max: 1)]);
      refused(PassRules.decide(def, lundi, 0, 0, 0));
      allowed(PassRules.decide(def, mercredi, 0, 0, 0));
      expect(PassRules.decide(def, mercredi, 0, 1, 0).refusal, 'Ce pass a déjà utilisé ses 1 passage.');
      refused(PassRules.decide(def, jeudi, 0, 1, 0));
    });

    test('sans règle : tous les jours, sans limite par jour', () {
      allowed(PassRules.decide(const PassDefinition(), dimanche, 99, 500, 1000000));
      expect(PassRules.decide(const PassDefinition(), dimanche, 99, 500, 0).leftToday, isNull);
    });

    test('une date précise l’emporte sur le jour de semaine ; 0 interdit le jour', () {
      const def = PassDefinition(rules: [PassDayRule(weekday: 1, max: 3), PassDayRule(date: '2026-11-16', max: 1)]);
      allowed(PassRules.decide(def, lundi, 2, 2, 0));
      refused(PassRules.decide(def, '2026-11-16', 1, 3, 0));
      refused(PassRules.decide(const PassDefinition(rules: [PassDayRule(weekday: 1, max: 3), PassDayRule(date: lundi, max: 0)]), lundi, 0, 0, 0));
    });

    test('révocation, événement clos, plafond, fenêtre de l’événement', () {
      expect(PassRules.decide(const PassDefinition(revoked: true), lundi, 0, 0, 0).refusal, 'Ce pass a été révoqué : il ne passe plus.');
      expect(PassRules.decide(const PassDefinition(eventActive: false), lundi, 0, 0, 0).refusal, "L'événement de ce pass est clos ou désactivé.");
      expect(PassRules.decide(const PassDefinition(eventStart: mardi), lundi, 0, 0, 0).refusal, "L'événement commence le 10/11/2026.");
      expect(PassRules.decide(const PassDefinition(eventEnd: dimanche), '2026-11-16', 0, 0, 0).refusal, "L'événement s'est terminé le 15/11/2026.");
      expect(PassRules.decide(const PassDefinition(capPerPassage: 5000), lundi, 0, 0, 5001).refusal,
          'Le panier (5001 FCFA) dépasse le plafond du pass par passage (5000 FCFA).');
      allowed(PassRules.decide(const PassDefinition(capPerPassage: 5000), lundi, 0, 0, 5000));
    });

    test('ordre des refus : la révocation passe avant tout le reste', () {
      const def = PassDefinition(revoked: true, eventActive: false, maxTotal: 1, capPerPassage: 1);
      expect(PassRules.decide(def, lundi, 9, 9, 99).refusal, startsWith('Ce pass a été révoqué'));
    });
  });

  group('ControlePanierPass', () {
    test('périmètre vide : refus, sauf « tous les produits »', () {
      expect(PassRules.basketRefusal([('p4', 'Autre')], allProducts: false, eventProducts: {}), startsWith("L'événement n'a aucun produit"));
      expect(PassRules.basketRefusal([('p4', 'Autre')], allProducts: true, eventProducts: {}), isNull);
      expect(PassRules.basketRefusal([], allProducts: true, eventProducts: {}), 'Le panier est vide.');
    });

    test('un produit hors de l’événement est nommé dans le refus', () {
      final r = PassRules.basketRefusal([('p1', 'Bière'), ('p4', 'Cigarettes')], allProducts: false, eventProducts: {'p1'})!;
      expect(r, "Hors du service de l'événement : Cigarettes. Retirez-les du panier ou encaissez-les en caisse normale.");
    });

    test('un pass lié à un menu ne paie que les produits du menu', () {
      expect(PassRules.basketRefusal([('p1', 'Bière'), ('p2', 'Plat')], allProducts: true, eventProducts: {}, menuProducts: {'p1', 'p2'}), isNull);
      expect(PassRules.basketRefusal([('p1', 'Bière'), ('p4', 'Dessert')], allProducts: true, eventProducts: {}, menuProducts: {'p1', 'p2'}),
          'Hors des menus de ce pass : Dessert.');
    });

    test('répartition au franc près, sans perte', () {
      expect(PassRules.split(10000, 3), [3334, 3333, 3333]);
      expect(PassRules.split(0, 2), [0, 0]);
      for (var n = 1; n <= 7; n++) {
        for (final t in [0, 1, 999, 15001]) {
          expect(PassRules.split(t, n).fold<int>(0, (a, b) => a + b), t);
        }
      }
    });

    test('normalisation et empreinte du code', () {
      expect(PassRules.normalize(' abc-12\r\n'), 'ABC-12');
      expect(PassRules.normalize(' evt 7k3 '), 'EVT 7K3', reason: 'espaces intérieurs gardés');
      expect(PassRules.fingerprint(' evt-7k3m9qx2\n'), PassRules.fingerprint('EVT-7K3M9QX2'));
      expect(PassRules.fingerprint('EVT-7K3M9QX2'), matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('jour civil de la boutique : fuseau fixe publié, sinon heure du terminal', () {
      final late = DateTime.utc(2026, 11, 9, 23, 30);
      expect(PassDay.of(late, 'Africa/Abidjan'), '2026-11-09');
      expect(PassDay.of(late, 'Africa/Lagos'), '2026-11-10');
    });
  });
}
