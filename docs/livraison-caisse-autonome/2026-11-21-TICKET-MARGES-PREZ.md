# Reçu : marges et diagnostic pré-Z

- Ticket de vente brut : trois lignes d'avance avant le logo/texte ; deux lignes après le dernier QR avant la coupe. L'avance cachée de quatre lignes de chaque raster logo/QR est supprimée pour ces reçus. Les autres usages raster conservent leur comportement par défaut. La zone blanche de sécurité du QR reste conservée pour sa lecture.
- PDF sur rouleau : marges de trois/deux lignes de 9 points ; suppression de la marge de huit points sous le QR. Le pilote et la distance physique tête/coupe peuvent imposer une marge matérielle supplémentaire.
- Réglages : absence de logo annoncée explicitement, avec instruction Importer puis Enregistrer. Le fichier printer.json contrôlé sur le poste ne contient pas de logo_png ; aucun logo de remplacement n'a été inventé. Fichier TBC demandé à l'utilisateur.
- Pré-Z : le moteur journeyPreZModel additionne les sessions clôturées uniquement et affiche les sessions ouvertes sans leur montant. Windows précise ce périmètre et indique Pré-X détaillé pour les ventes de la session active. Le rendu détaillé du moteur possède déjà les produits, quantités et montants.
- Demande de bilan journalier incluant les ventes en cours transmise à B et A, avec localisation du traitement. Aucun changement des calculs ou de l'audit Z dans ce correctif ; le besoin journalier reste ouvert.

Essai papier non effectué. Ne pas confondre validation des octets/PDF et résultat matériel. La correction de marges ne peut pas imprimer un logo qui n'est pas enregistré.
