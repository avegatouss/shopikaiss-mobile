import '../sync_v2_engine_test.dart' show serve21;
import 'fake_v2_server.dart';

/// Lieu de restaurant (Service de table) dont ce terminal est la caisse maîtresse : cuisine avec écran et papier, bar
/// avec écran seul (remise directe), une table, un serveur de salle (Koffi, opérateur 8).
const restoPdv = 'b1000000-0000-4000-8000-000000000001';
const restoTable = 'b4000000-0000-4000-8000-000000000001';
const restoKitchen = 'b2000000-0000-4000-8000-0000000000c1';
const restoBar = 'b2000000-0000-4000-8000-0000000000b1';

void serveRestoMaster(FakeV2Server server, {bool master = true}) {
  Map<String, dynamic> operateur(String id, String nom, List<String> droits) => {
    'operateur_id': id, 'nom': nom, 'pin_empreinte': 'empreinte', 'droits': droits,
    'remise_max_pourcent': null, 'remise_max_montant': null, 'approbateur_remise': false,
  };
  serve21(server);
  server
    ..capabilities = [...server.capabilities, 'session.cloture', 'restaurant.v1']
    ..authorizationExpires = '2026-11-20T00:00:00Z'
    ..restaurant = {'point_de_vente_uuid': restoPdv, 'profil': 'TABLE_SERVICE', 'maitre': master, 'generation': '3', 'derniers_numeros': null}
    ..put('operateur', 'operateur:8', operateur('8', 'Koffi', ['caisse_service_table', 'caisse_table']), critical: true)
    ..put('restaurant.point_de_vente', restoPdv, {
      'code': 'SALLE', 'nom': 'Salle', 'profil': 'TABLE_SERVICE', 'actif': true, 'terminaux': [fakeTerminal], 'membres': null,
      'reglages_vente': {'changement_client_paiement': true, 'reference_plateforme_avant_envoi': false, 'verrouillage_minutes': null},
    }, critical: true)
    ..put('restaurant.maitre', 'maitre:$restoPdv', {
      'point_de_vente_uuid': restoPdv, 'generation': '3', 'terminal_uuid': fakeTerminal, 'appareil_uuid': fakeDevice, 'epoque': 3, 'designe_le': '2026-11-18T09:30:00Z',
    }, critical: true)
    ..put('restaurant.reglages', 'reglages:$restoPdv', {
      'point_de_vente_uuid': restoPdv, 'envoi_production': true, 'plusieurs_commandes_par_table': false, 'prefixe_commande': 'PF', 'motif_annulation_commande': false,
      'registre_obligatoire': false, 'prefacture_a_la_demande': true, 'retard_production_minutes': 15, 'sections_z': <String>[], 'fuseau': 'Africa/Abidjan',
      'impression_mode': 'register', 'repli_premier_poste_actif': false, 'annulation_envoye_responsable': false,
      'assistant': {'max_operations_par_jour': 0, 'max_montant_par_operation': 0, 'max_montant_par_jour': 0, 'max_remise_pourcent': 0},
    }, critical: true)
    ..put('restaurant.table', restoTable, {'point_de_vente_uuid': restoPdv, 'salle_uuid': null, 'nom': 'T1', 'code': 'T1', 'capacite': 4, 'ordre': 1, 'actif': true})
    ..put('restaurant.poste', restoKitchen, {'code': 'cui', 'nom': 'Cuisine', 'type': 'kitchen', 'flux': 'preparation', 'ecran': true, 'papier': true, 'ordre': 1, 'actif': true})
    ..put('restaurant.poste', restoBar, {'code': 'bar', 'nom': 'Bar', 'type': 'bar', 'flux': 'handover', 'ecran': true, 'papier': false, 'ordre': 2, 'actif': true})
    ..put('restaurant.routage', fakeSavon,
        {'routage': 'station', 'poste_uuid': restoKitchen, 'categorie_poste_uuid': null, 'poste_effectif_uuid': restoKitchen, 'visible': true, 'ordre': 0, 'favori': false})
    ..put('restaurant.routage', fakeService,
        {'routage': 'station', 'poste_uuid': restoBar, 'categorie_poste_uuid': null, 'poste_effectif_uuid': restoBar, 'visible': true, 'ordre': 1, 'favori': false});
}
