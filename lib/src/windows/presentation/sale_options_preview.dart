import 'package:flutter/material.dart';

/// Prepared layout only: the engine contract must own every basket mutation.
class SaleOptionsPreview extends StatelessWidget {
  const SaleOptionsPreview({super.key});
  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('Client, remise et frais — préparation'),
    content: const SizedBox(
      width: 480,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Ces fonctions attendent leur raccordement au moteur. Aucun changement ne sera appliqué au panier depuis cet aperçu.',
          ),
          SizedBox(height: 20),
          Text('Client', style: TextStyle(fontWeight: FontWeight.bold)),
          TextField(
            enabled: false,
            decoration: InputDecoration(
              labelText: 'Rechercher par nom ou téléphone',
              prefixIcon: Icon(Icons.person_search_outlined),
            ),
          ),
          Text(
            'Prévu : client de passage, sélection et création hors connexion.',
          ),
          SizedBox(height: 20),
          Text('Remise globale', style: TextStyle(fontWeight: FontWeight.bold)),
          TextField(
            enabled: false,
            decoration: InputDecoration(
              labelText: 'Montant ou pourcentage autorisé',
            ),
          ),
          Text(
            'Droits, plafond et cumul avec les remises de ligne contrôlés par le moteur.',
          ),
          SizedBox(height: 20),
          Text('Autres frais', style: TextStyle(fontWeight: FontWeight.bold)),
          TextField(
            enabled: false,
            decoration: InputDecoration(
              labelText: 'Type de frais et montant (F CFA)',
            ),
          ),
          Text(
            'Livraison et autres frais selon la boutique. Taxes et arrondis calculés par le moteur.',
          ),
          SizedBox(height: 20),
          TextField(
            enabled: false,
            maxLines: 2,
            decoration: InputDecoration(labelText: 'Note de vente'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Fermer'),
      ),
    ],
  );
}
