// Généré depuis test/fixtures/contrat-v2/schemas (contrat v2, révision 2.1, restaurant-1 R-5, lot Z local c3610bbb, lots 9 à 11, lots 12 à 16 integration/lots-12-15 3ba28b1d) — ne pas modifier à la main.
// Régénérer après mise à jour des schémas ; test/contrat_v2_test.dart vérifie l'égalité.

/// Schémas du contrat v2 embarqués : le moteur (Android et hôte Windows, sans fichiers ni assets) valide ses
/// opérations avant de les enregistrer et les réponses du serveur avant de les appliquer.
const contractV2Schemas = <String, String>{
  'accuses.json': r'''{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "accuses.json",
  "title": "POST /accuses : dernier curseur appliqué, politiques réellement appliquées, état minimal de la file (télémétrie). Réponse 204.",
  "$defs": {
    "demande": {
      "type": "object",
      "required": ["curseur_applique", "version_politiques_appliquee", "file"],
      "additionalProperties": false,
      "properties": {
        "curseur_applique": { "oneOf": [{ "type": "null" }, { "$ref": "commun.json#/$defs/curseur" }] },
        "version_politiques_appliquee": { "$ref": "commun.json#/$defs/version" },
        "file": {
          "type": "object",
          "required": ["non_envoyees", "envoyees_non_reconciliees", "a_arbitrer", "plus_ancienne_non_envoyee_le"],
          "additionalProperties": false,
          "properties": {
            "non_envoyees": { "type": "integer", "minimum": 0 },
            "envoyees_non_reconciliees": { "type": "integer", "minimum": 0 },
            "a_arbitrer": { "type": "integer", "minimum": 0 },
            "plus_ancienne_non_envoyee_le": { "oneOf": [{ "type": "null" }, { "$ref": "commun.json#/$defs/horodatage" }] }
          }
        }
      }
    }
  }
}
''',
  'appairage.json': r'''{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "appairage.json",
  "title": "POST /appairage : code à usage unique → identité, jeton et capacités compatibles.",
  "$defs": {
    "demande": {
      "type": "object",
      "required": ["code", "installation_uuid", "plateforme", "version_application", "schema_local", "capacites"],
      "additionalProperties": false,
      "properties": {
        "code": { "type": "string", "minLength": 6, "maxLength": 20 },
        "installation_uuid": { "$ref": "commun.json#/$defs/uuid", "description": "Identité stable de l'installation ; jamais copiée d'un autre appareil." },
        "plateforme": { "enum": ["android", "windows"] },
        "modele": { "type": ["string", "null"], "maxLength": 120 },
        "version_application": { "type": "string", "minLength": 1, "maxLength": 40 },
        "schema_local": { "$ref": "commun.json#/$defs/version" },
        "capacites": { "type": "array", "uniqueItems": true, "maxItems": 100, "items": { "$ref": "commun.json#/$defs/code" } }
      }
    },
    "reponse": {
      "type": "object",
      "required": ["jeton", "appareil", "epoque", "capacites_serveur"],
      "additionalProperties": false,
      "properties": {
        "jeton": { "type": "string", "minLength": 20, "maxLength": 200, "description": "Rendu une seule fois ; à stocker dans le coffre de la plateforme." },
        "epoque": { "type": "integer", "minimum": 1, "description": "Époque d'appairage : la séquence des opérations repart dans cette époque, sans recouvrir la précédente." },
        "appareil": {
          "type": "object",
          "required": ["uuid", "nom", "terminal_uuid", "terminal_nom", "boutique_uuid", "boutique_nom", "derniere_sequence"],
          "additionalProperties": false,
          "properties": {
            "uuid": { "$ref": "commun.json#/$defs/uuid" },
            "nom": { "type": "string", "maxLength": 120 },
            "terminal_uuid": { "$ref": "commun.json#/$defs/uuid" },
            "terminal_nom": { "type": "string", "maxLength": 120 },
            "boutique_uuid": { "$ref": "commun.json#/$defs/uuid" },
            "boutique_nom": { "type": "string", "maxLength": 120 },
            "derniere_sequence": { "type": "integer", "minimum": 0 }
          }
        },
        "capacites_serveur": { "type": "array", "uniqueItems": true, "maxItems": 100, "items": { "$ref": "commun.json#/$defs/code" } },
        "cle_web": { "type": "string", "pattern": "^[A-Za-z0-9]{48}$", "description": "Révision 2.0.2 (B-REQ-006) : clé web de l'appareil, rendue une seule fois. La vue web de la caisse dans l'application la pose en cookie sk_appareil ; elle seule ouvre un terminal réservé à l'application (exclusivité « appareil »). À garder dans le coffre comme le jeton." }
      }
    }
  }
}
''',
  'changements.json': r'''{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "changements.json",
  "title": "GET /changements : page ordonnée du journal, par groupes atomiques, avec le curseur suivant.",
  "$defs": {
    "page": {
      "type": "object",
      "required": ["version", "curseur_suivant", "suite", "groupes"],
      "additionalProperties": false,
      "properties": {
        "version": { "const": 2 },
        "curseur_suivant": { "$ref": "commun.json#/$defs/curseur", "description": "À enregistrer dans la MÊME transaction locale que l'application des groupes de la page." },
        "suite": { "type": "boolean", "description": "Vrai : d'autres changements sont déjà disponibles, redemander immédiatement." },
        "groupes": { "type": "array", "minItems": 0, "maxItems": 500, "items": { "$ref": "#/$defs/groupe" } }
      }
    },
    "groupe": {
      "description": "Changements produits par une même transaction serveur : appliqués tous ou aucun. Un groupe n'est jamais coupé entre deux pages.",
      "type": "object",
      "required": ["uuid", "changements"],
      "additionalProperties": false,
      "properties": {
        "uuid": { "$ref": "commun.json#/$defs/uuid" },
        "changements": { "type": "array", "minItems": 1, "maxItems": 1000, "items": { "$ref": "#/$defs/changement" } }
      }
    },
    "changement": {
      "description": "Enveloppe commune ; donnees est validé selon type (donnees.json). Type inconnu : si critique, arrêter l'avancement sur ce groupe et demander une mise à jour ; sinon l'ignorer.",
      "type": "object",
      "required": ["type", "critique", "cle", "revision", "action", "donnees"],
      "additionalProperties": false,
      "properties": {
        "type": { "$ref": "commun.json#/$defs/code" },
        "critique": { "type": "boolean" },
        "cle": {
          "description": "Clé de l'entité : son UUID, ou une clé composée (« <produit_uuid>:<lot_uuid> » pour un stock par lot, « operateur:<id> »).",
          "type": "string", "minLength": 1, "maxLength": 120, "pattern": "^[A-Za-z0-9:._-]+$"
        },
        "revision": { "$ref": "commun.json#/$defs/version", "description": "Révision de l'entité : ignorer un changement de révision inférieure ou égale à celle appliquée." },
        "action": { "enum": ["upsert", "suppression"] },
        "donnees": { "type": ["object", "null"], "description": "null pour une suppression (tombstone)." },
        "operations_couvertes": {
          "description": "stock.projection : opérations du terminal dont TOUS les mouvements pour cette clé sont inclus dans la projection.",
          "type": "array", "maxItems": 2000, "uniqueItems": true, "items": { "$ref": "commun.json#/$defs/uuid" }
        },
        "mouvements_couverts": {
          "description": "stock.projection : mouvements individuels inclus, quand une opération n'est couverte qu'en partie pour cette clé.",
          "type": "array", "maxItems": 2000, "uniqueItems": true, "items": { "$ref": "commun.json#/$defs/uuid" }
        }
      }
    }
  }
}
''',
  'commun.json': r'''{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "commun.json",
  "title": "Définitions communes du contrat de synchronisation v2 (profil SK-SCHEMA-1)",
  "$defs": {
    "uuid": {
      "description": "UUID en minuscules, version 1 à 8.",
      "type": "string",
      "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
    },
    "identifiant_serveur": {
      "description": "Identifiant numérique d'une entité sans UUID (utilisateur), transmis en chaîne pour ne pas perdre de précision.",
      "type": "string",
      "pattern": "^[1-9][0-9]{0,18}$"
    },
    "horodatage": {
      "description": "Date et heure ISO 8601 en UTC, suffixe Z, précision à la seconde ou à la milliseconde.",
      "type": "string",
      "pattern": "^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\\.[0-9]{3})?Z$"
    },
    "montant": {
      "description": "Montant entier dans l'unité monétaire de la boutique (FCFA : pas de décimales).",
      "type": "integer",
      "minimum": 0,
      "maximum": 999999999999
    },
    "montant_signe": {
      "type": "integer",
      "minimum": -999999999999,
      "maximum": 999999999999
    },
    "quantite": {
      "description": "Quantité décimale positive en chaîne, six décimales exactement.",
      "type": "string",
      "pattern": "^(0|[1-9][0-9]{0,8})\\.[0-9]{6}$"
    },
    "quantite_signee": {
      "description": "Variation de stock décimale en chaîne, six décimales exactement ; négative pour une sortie.",
      "type": "string",
      "pattern": "^-?(0|[1-9][0-9]{0,8})\\.[0-9]{6}$"
    },
    "taux": {
      "description": "Taux en pourcentage, chaîne à six décimales (18 % : \"18.000000\").",
      "type": "string",
      "pattern": "^(0|[1-9][0-9]{0,2})\\.[0-9]{6}$"
    },
    "jour": {
      "description": "Date civile AAAA-MM-JJ, sans heure ni fuseau (jour civil de la boutique, dans son fuseau publié).",
      "type": "string",
      "pattern": "^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$"
    },
    "curseur": {
      "description": "Curseur opaque du journal de changements. Le client le conserve et le renvoie tel quel ; il ne l'interprète jamais.",
      "type": "string",
      "minLength": 1,
      "maxLength": 200,
      "pattern": "^[A-Za-z0-9._~-]+$"
    },
    "version": {
      "description": "Version ou révision monotone, en chaîne (pas de perte de précision JavaScript).",
      "type": "string",
      "pattern": "^(0|[1-9][0-9]{0,18})$"
    },
    "empreinte": {
      "description": "SHA-256 hexadécimal minuscule de la forme canonique SK-JCS-1.",
      "type": "string",
      "pattern": "^[0-9a-f]{64}$"
    },
    "code": {
      "description": "Code technique stable (snake_case ASCII).",
      "type": "string",
      "pattern": "^[a-z][a-z0-9_.]{0,63}$"
    },
    "texte": {
      "type": "string",
      "maxLength": 500
    },
    "raison": {
      "description": "Motif structuré : code stable à traduire par le client ; message lisible facultatif, sans trace ni secret.",
      "type": "object",
      "required": ["code"],
      "additionalProperties": false,
      "properties": {
        "code": { "$ref": "#/$defs/code" },
        "message": { "type": ["string", "null"], "maxLength": 500 },
        "details": { "type": ["object", "null"] }
      }
    }
  }
}
''',
  'donnees-2.1.json': r'''{
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "$id": "donnees-2.1.json",
    "title": "Données des changements, forme 2.1 (rendue aux clients qui annoncent contrat.2_1 ; REVISION-2.1 §7.1). Les autres reçoivent la forme 2.0 de donnees.json.",
    "$defs": {
        "produit": {
            "type": "object",
            "required": [
                "nom",
                "reference",
                "categorie",
                "prix",
                "stock_illimite",
                "actif",
                "vente_locale",
                "categorie_uuid",
                "marque",
                "fournisseur",
                "unite",
                "prix_gros",
                "gros_quantite_min",
                "seuil_alerte",
                "cree_le",
                "favori",
                "promotions",
                "image"
            ],
            "additionalProperties": false,
            "properties": {
                "nom": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 200
                },
                "reference": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 100
                },
                "categorie": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 120
                },
                "prix": {
                    "$ref": "commun.json#/$defs/montant"
                },
                "stock_illimite": {
                    "type": "boolean"
                },
                "actif": {
                    "type": "boolean"
                },
                "vente_locale": {
                    "type": "boolean",
                    "description": "Faux : produit vendable seulement en ligne (variantes, coffrets, lots…) ; le client l'affiche avec ce motif."
                },
                "categorie_uuid": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ]
                },
                "marque": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 120
                },
                "fournisseur": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 200
                },
                "unite": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "type": "object",
                            "required": [
                                "code",
                                "nom"
                            ],
                            "additionalProperties": false,
                            "properties": {
                                "code": {
                                    "type": [
                                        "string",
                                        "null"
                                    ],
                                    "maxLength": 20
                                },
                                "nom": {
                                    "type": "string",
                                    "maxLength": 120
                                }
                            }
                        }
                    ]
                },
                "prix_gros": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/montant"
                        }
                    ]
                },
                "gros_quantite_min": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/quantite"
                        }
                    ]
                },
                "seuil_alerte": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/quantite"
                        }
                    ]
                },
                "cree_le": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/horodatage"
                        }
                    ]
                },
                "favori": {
                    "type": "boolean"
                },
                "promotions": {
                    "type": "array",
                    "description": "Bons affichés en badge « Promotion », par priorité : le premier dont la période couvre la date locale de la boutique et hors exclusions. Présentation seule : aucune remise appliquée, aucun prix avant/après.",
                    "items": {
                        "type": "object",
                        "required": [
                            "libelle",
                            "du",
                            "au",
                            "exclusions"
                        ],
                        "additionalProperties": false,
                        "properties": {
                            "libelle": {
                                "type": "string",
                                "minLength": 1,
                                "maxLength": 300
                            },
                            "du": {
                                "oneOf": [
                                    {
                                        "type": "null"
                                    },
                                    {
                                        "type": "string",
                                        "pattern": "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"
                                    }
                                ]
                            },
                            "au": {
                                "type": "string",
                                "pattern": "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"
                            },
                            "exclusions": {
                                "type": "array",
                                "items": {
                                    "type": "object",
                                    "required": [
                                        "du",
                                        "au"
                                    ],
                                    "additionalProperties": false,
                                    "properties": {
                                        "du": {
                                            "type": "string",
                                            "pattern": "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"
                                        },
                                        "au": {
                                            "type": "string",
                                            "pattern": "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"
                                        }
                                    }
                                }
                            }
                        }
                    }
                },
                "image": {
                    "description": "Image principale ; à télécharger hors vente par GET /images/{uuid}.",
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "type": "object",
                            "required": [
                                "uuid",
                                "empreinte",
                                "octets",
                                "largeur",
                                "hauteur"
                            ],
                            "additionalProperties": false,
                            "properties": {
                                "uuid": {
                                    "$ref": "commun.json#/$defs/uuid"
                                },
                                "empreinte": {
                                    "type": "string",
                                    "pattern": "^[0-9a-f]{64}$"
                                },
                                "octets": {
                                    "type": "integer",
                                    "minimum": 1
                                },
                                "largeur": {
                                    "type": "integer",
                                    "minimum": 1
                                },
                                "hauteur": {
                                    "type": "integer",
                                    "minimum": 1
                                }
                            }
                        }
                    ]
                },
                "gere_par_lots": {
                    "type": "boolean",
                    "description": "Capacité lots.vente seulement : produit vendu par lot, avec vente_locale selon actif. Sa quantité se lit sur les stock.projection produit:lot."
                },
                "prix_modifiable": {
                    "type": "boolean",
                    "const": true,
                    "description": "Capacité prix.modifiable seulement (2.1 lot 9) : présent, et toujours true, quand le prix se saisit à la vente (case « Prix modifiable à la vente ») ; absent sinon. Le prix se saisit à l'unité de base, hors conditionnement et hors coffret, par un opérateur qui a le droit prix_vente_modifier ; il devient le prix_unitaire de la ligne."
                },
                "fournisseur_uuid": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ],
                    "description": "Capacité referentiels.creation seulement (2.1 lot 18) : fournisseur du produit (entité fournisseur). Présent seulement quand le produit a un fournisseur ; absent (ou null) : aucun."
                }
            }
        },
        "conditionnement": {
            "type": "object",
            "required": [
                "produit_uuid",
                "nom",
                "coefficient",
                "prix",
                "defaut",
                "actif",
                "prix_gros"
            ],
            "additionalProperties": false,
            "properties": {
                "produit_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "nom": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 120
                },
                "coefficient": {
                    "$ref": "commun.json#/$defs/quantite"
                },
                "prix": {
                    "$ref": "commun.json#/$defs/montant"
                },
                "defaut": {
                    "type": "boolean"
                },
                "actif": {
                    "type": "boolean"
                },
                "prix_gros": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/montant"
                        }
                    ]
                }
            }
        },
        "code_barre": {
            "type": "object",
            "required": [
                "code",
                "produit_uuid",
                "conditionnement_uuid"
            ],
            "additionalProperties": false,
            "properties": {
                "code": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 64
                },
                "produit_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "conditionnement_uuid": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ]
                }
            }
        },
        "moyen_paiement": {
            "type": "object",
            "required": [
                "code",
                "nom",
                "especes",
                "local",
                "reference"
            ],
            "additionalProperties": false,
            "properties": {
                "code": {
                    "$ref": "commun.json#/$defs/code"
                },
                "nom": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 120
                },
                "especes": {
                    "type": "boolean"
                },
                "local": {
                    "type": "boolean",
                    "description": "Admis pour une vente locale (paiements.moyens_locaux)."
                },
                "reference": {
                    "enum": [
                        "aucune",
                        "facultative",
                        "obligatoire"
                    ],
                    "description": "Référence de transaction : réglage Trésorerie du web (references_required) ; espèces, crédit, compte client, carte cadeau : aucune."
                }
            }
        },
        "operateur": {
            "description": "Opérateur autorisé sur ce terminal. Le PIN n'est transmis que sous forme d'empreinte lente (bcrypt), jamais en clair. Avec restaurant.v1 (lot R-3), un opérateur qui a `caisse_table` sans `vente` (serveur de salle) est aussi publié : il prend des commandes, n'encaisse pas.",
            "type": "object",
            "required": [
                "operateur_id",
                "nom",
                "pin_empreinte",
                "droits",
                "remise_max_pourcent",
                "remise_max_montant",
                "approbateur_remise"
            ],
            "additionalProperties": false,
            "properties": {
                "operateur_id": {
                    "$ref": "commun.json#/$defs/identifiant_serveur"
                },
                "nom": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 120
                },
                "pin_empreinte": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 100,
                    "description": "null quand la politique demande un PIN : l’opérateur n’a pas défini de PIN ; le refuser avec le motif « PIN non défini », sans compter d’échec."
                },
                "droits": {
                    "type": "array",
                    "uniqueItems": true,
                    "maxItems": 100,
                    "items": {
                        "$ref": "commun.json#/$defs/code"
                    }
                },
                "remise_max_pourcent": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/taux"
                        }
                    ]
                },
                "remise_max_montant": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/montant"
                        }
                    ]
                },
                "approbateur_remise": {
                    "type": "boolean"
                },
                "code_autorisation_empreinte": {
                    "description": "Empreinte bcrypt (coût ≥ 12) du code de 8 chiffres d’un approbateur. Clé absente : pas de code publiable, autorisation hors ligne impossible pour lui. Jamais le PIN.",
                    "type": "string",
                    "minLength": 59,
                    "maxLength": 60
                },
                "approbateur_restaurant": {
                    "description": "Restaurant.v1 seulement (RESTAURANT-1 §3.10, lot R-3) : approbateur restaurant (`manager` = RESTO_AUTORISER_SANS_LIMITE, `assistant` = RESTO_AUTORISER, plafonds de restaurant.reglages.assistant) ou null. Son `code_autorisation_empreinte` est alors publié même sans REMISE (E7). Clé absente pour les autres terminaux.",
                    "enum": [
                        "manager",
                        "assistant",
                        null
                    ]
                },
                "approbateur_modification": {
                    "const": true,
                    "description": "Capacité vente.modification (2.1 lot 11) : responsable qui peut autoriser « Modifier le ticket » (manager ou assistant manager qui détient CORRIGER_VENTE et ANNULATION). Son `code_autorisation_empreinte` est alors publié, même sans REMISE. Clé absente pour les autres opérateurs et pour les terminaux sans la capacité."
                }
            }
        },
        "stock.projection": {
            "description": "Projection absolue versionnée pour la clé (produit, ou produit:lot). Jamais un delta.",
            "type": "object",
            "required": [
                "produit_uuid",
                "lot_uuid",
                "quantite"
            ],
            "additionalProperties": false,
            "properties": {
                "produit_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "lot_uuid": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ]
                },
                "quantite": {
                    "$ref": "commun.json#/$defs/quantite_signee"
                }
            }
        },
        "politique": {
            "description": "Valeur effective calculée par le serveur (03). Le client n'applique aucune logique d'héritage. Clé inconnue critique : restriction, jamais de défaut permissif.",
            "type": "object",
            "required": [
                "cle_politique",
                "valeur",
                "source",
                "verrouillee"
            ],
            "additionalProperties": false,
            "properties": {
                "cle_politique": {
                    "type": "string",
                    "pattern": "^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)+$"
                },
                "valeur": {
                    "description": "Valeur JSON (entier, chaîne, booléen, liste ou null) ; jamais de nombre à virgule."
                },
                "source": {
                    "enum": [
                        "defaut",
                        "entreprise",
                        "boutique",
                        "terminal"
                    ]
                },
                "verrouillee": {
                    "type": "boolean"
                }
            }
        },
        "boutique": {
            "description": "Révision 2.0.1 (B-REQ-005) : paramètres de calcul de la boutique. Critique : un changement de TVA modifie le total des ventes suivantes ; une vente déjà commise garde la TVA qu'elle a figée.",
            "type": "object",
            "required": [
                "nom",
                "devise",
                "tva_taux",
                "tva_incluse",
                "regles",
                "ticket",
                "devise_secondaire"
            ],
            "additionalProperties": false,
            "properties": {
                "nom": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 200
                },
                "devise": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 10
                },
                "tva_taux": {
                    "$ref": "commun.json#/$defs/taux"
                },
                "tva_incluse": {
                    "type": "boolean"
                },
                "regles": {
                    "type": "object",
                    "additionalProperties": false,
                    "required": [
                        "remise_pourcentage_arrondi",
                        "arrondi_especes",
                        "trop_percu",
                        "moins_a_un",
                        "livraison_droit",
                        "ouverture_session",
                        "survente",
                        "gros",
                        "fuseau",
                        "nouveau_jours"
                    ],
                    "description": "Codes du web, tels quels (PARITE-CAISSE-WEB §3).",
                    "properties": {
                        "remise_pourcentage_arrondi": {
                            "enum": [
                                "down",
                                "nearest"
                            ]
                        },
                        "arrondi_especes": {
                            "oneOf": [
                                {
                                    "type": "null"
                                },
                                {
                                    "type": "object",
                                    "required": [
                                        "pas",
                                        "mode"
                                    ],
                                    "additionalProperties": false,
                                    "properties": {
                                        "pas": {
                                            "type": "integer",
                                            "minimum": 1
                                        },
                                        "mode": {
                                            "type": "string",
                                            "maxLength": 40
                                        }
                                    }
                                }
                            ]
                        },
                        "trop_percu": {
                            "enum": [
                                "refuse",
                                "customer_advance",
                                "cash_change"
                            ]
                        },
                        "moins_a_un": {
                            "enum": [
                                "refuse",
                                "remove"
                            ]
                        },
                        "livraison_droit": {
                            "oneOf": [
                                {
                                    "type": "null"
                                },
                                {
                                    "$ref": "commun.json#/$defs/code"
                                }
                            ]
                        },
                        "ouverture_session": {
                            "enum": [
                                "payment",
                                "before_sale",
                                "automatic"
                            ]
                        },
                        "survente": {
                            "type": "string",
                            "maxLength": 40
                        },
                        "gros": {
                            "type": "object",
                            "required": [
                                "actif",
                                "mode",
                                "quantite_min",
                                "droit",
                                "remises",
                                "prix_lot"
                            ],
                            "additionalProperties": false,
                            "properties": {
                                "actif": {
                                    "type": "boolean"
                                },
                                "mode": {
                                    "enum": [
                                        "cart",
                                        "quantity",
                                        "cart_and_quantity"
                                    ]
                                },
                                "quantite_min": {
                                    "oneOf": [
                                        {
                                            "type": "null"
                                        },
                                        {
                                            "$ref": "commun.json#/$defs/quantite"
                                        }
                                    ]
                                },
                                "droit": {
                                    "oneOf": [
                                        {
                                            "type": "null"
                                        },
                                        {
                                            "$ref": "commun.json#/$defs/code"
                                        }
                                    ]
                                },
                                "remises": {
                                    "enum": [
                                        "refuse",
                                        "allow"
                                    ]
                                },
                                "prix_lot": {
                                    "enum": [
                                        "refuse",
                                        "lot_price",
                                        "lowest"
                                    ]
                                }
                            }
                        },
                        "fuseau": {
                            "type": "string",
                            "maxLength": 64
                        },
                        "nouveau_jours": {
                            "description": "Badge « Nouveau » : produit créé depuis N jours au plus ; null = désactivé.",
                            "oneOf": [
                                {
                                    "type": "null"
                                },
                                {
                                    "type": "integer",
                                    "minimum": 1
                                }
                            ]
                        },
                        "retour_residuel": {
                            "description": "Règle du reste d'arrondi d'un retour partiel (référentiel §3.13). Facultative : reçue avec la capacité retour.especes.",
                            "enum": [
                                "refuse",
                                "last_line",
                                "largest_share",
                                "largest_fraction"
                            ]
                        },
                        "lots_mode": {
                            "enum": [
                                "fifo",
                                "dernier_achat",
                                "prix_bas",
                                "fefo",
                                "manuel",
                                "prix_unique"
                            ],
                            "description": "Capacité lots.vente seulement : règle d’allocation de la boutique, même sens que la caisse web."
                        },
                        "modification_ticket": {
                            "description": "Capacité vente.modification (2.1 lot 11) : option « Modifier un ticket après encaissement » de la boutique (Paramètres › Règles de gestion › Correction des ventes). Absente sans la capacité.",
                            "type": "object",
                            "required": [
                                "actif",
                                "fenetre"
                            ],
                            "additionalProperties": false,
                            "properties": {
                                "actif": {
                                    "type": "boolean",
                                    "description": "false : le bouton « Modifier le ticket » n’est pas proposé."
                                },
                                "fenetre": {
                                    "enum": [
                                        "same_day",
                                        "open_session"
                                    ],
                                    "description": "same_day : le jour même (fuseau de la boutique) ET session de la vente ouverte ; open_session : tant que la session de la vente est ouverte. Jamais une session close."
                                }
                            }
                        },
                        "sessions_locales": {
                            "description": "Capacité session.multiple (2.1 lot 12) : sessions locales séparées. Absente sans la capacité.",
                            "type": "object",
                            "required": [
                                "max"
                            ],
                            "additionalProperties": false,
                            "properties": {
                                "max": {
                                    "type": "integer",
                                    "minimum": 1,
                                    "maximum": 50,
                                    "description": "Sessions que le terminal peut ouvrir (et clôturer) tant que le serveur ne les a pas intégrées ; au-delà, il demande une connexion avant d'en ouvrir une autre (Paramètres › Caisse hors ligne, 20 par défaut)."
                                }
                            }
                        },
                        "prevente": {
                            "description": "Capacité prevente.v1 (lot 15) : option « Prévente / réservations » de la boutique (Paramètres › Règles de gestion). Présente seulement option activée ; absente sans la capacité.",
                            "type": "object",
                            "required": [
                                "actif"
                            ],
                            "additionalProperties": false,
                            "properties": {
                                "actif": {
                                    "type": "boolean",
                                    "description": "false : l’écran Prévente n’est pas proposé."
                                }
                            }
                        },
                        "remise_a_zero": {
                            "description": "Capacité remise.zero (lot 17) : dernière remise à zéro de la boutique avant la production, absente tant qu'il n'y en a pas. Un uuid nouveau pour le poste : il efface ses pièces locales (ventes, sessions, Z, file d'envoi, préventes, compteurs) et garde catalogue, réglages et opérateurs.",
                            "type": "object",
                            "required": [
                                "uuid",
                                "le"
                            ],
                            "additionalProperties": false,
                            "properties": {
                                "uuid": {
                                    "$ref": "commun.json#/$defs/uuid"
                                },
                                "le": {
                                    "$ref": "commun.json#/$defs/horodatage",
                                    "description": "Instant de la remise (UTC). Une opération dont cree_le est antérieur est refusée : rejet_protocole remise_a_zero."
                                }
                            }
                        },
                        "transfert_especes": {
                            "description": "Capacité transfert.especes (lot 16) : présente seulement si la boutique a activé le transfert de fin de journée vers les espèces (Paramètres › Trésorerie). Absente : bouton masqué.",
                            "type": "object",
                            "required": [
                                "actif",
                                "moyens"
                            ],
                            "additionalProperties": false,
                            "properties": {
                                "actif": {
                                    "const": true
                                },
                                "moyens": {
                                    "type": "array",
                                    "maxItems": 30,
                                    "uniqueItems": true,
                                    "items": {
                                        "$ref": "commun.json#/$defs/code"
                                    },
                                    "description": "Moyens dont tout le solde de la session part vers les espèces (jamais les espèces ; les cartes seulement si la boutique les a cochées)."
                                }
                            }
                        }
                    }
                },
                "ticket": {
                    "type": "object",
                    "required": [
                        "raison_sociale",
                        "adresse",
                        "telephone",
                        "ncc",
                        "entete",
                        "pied",
                        "largeur_papier"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "raison_sociale": {
                            "type": [
                                "string",
                                "null"
                            ],
                            "maxLength": 160
                        },
                        "adresse": {
                            "type": [
                                "string",
                                "null"
                            ],
                            "maxLength": 500
                        },
                        "telephone": {
                            "type": [
                                "string",
                                "null"
                            ],
                            "maxLength": 60
                        },
                        "ncc": {
                            "type": [
                                "string",
                                "null"
                            ],
                            "maxLength": 60
                        },
                        "entete": {
                            "type": [
                                "string",
                                "null"
                            ],
                            "maxLength": 1000
                        },
                        "pied": {
                            "type": [
                                "string",
                                "null"
                            ],
                            "maxLength": 1000
                        },
                        "logo": {
                            "$ref": "#/$defs/logo_boutique"
                        },
                        "logo_carre": {
                            "$ref": "#/$defs/logo_boutique"
                        },
                        "largeur_papier": {
                            "type": "integer",
                            "minimum": 30,
                            "maximum": 120
                        }
                    }
                },
                "devise_secondaire": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "type": "object",
                            "required": [
                                "libelle",
                                "taux"
                            ],
                            "additionalProperties": false,
                            "properties": {
                                "libelle": {
                                    "type": "string",
                                    "maxLength": 20
                                },
                                "taux": {
                                    "$ref": "commun.json#/$defs/quantite",
                                    "description": "Unités de la devise secondaire pour 1 unité de la devise de la boutique ou l'inverse, tel que saisi au web ; format quantité (6 décimales)."
                                }
                            }
                        }
                    ]
                }
            }
        },
        "autorisation": {
            "type": "object",
            "required": [
                "vente_locale",
                "version",
                "expire_le"
            ],
            "additionalProperties": false,
            "properties": {
                "vente_locale": {
                    "type": "boolean"
                },
                "version": {
                    "$ref": "commun.json#/$defs/version"
                },
                "expire_le": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/horodatage"
                        }
                    ]
                }
            }
        },
        "revocation": {
            "description": "Révocation de l'appareil ou de ses droits de vente : bloquer toute nouvelle vente dès application ; conserver la file.",
            "type": "object",
            "required": [
                "portee",
                "raison"
            ],
            "additionalProperties": false,
            "properties": {
                "portee": {
                    "enum": [
                        "appareil",
                        "vente_locale",
                        "operateur"
                    ]
                },
                "operateur_id": {
                    "$ref": "commun.json#/$defs/identifiant_serveur"
                },
                "raison": {
                    "$ref": "commun.json#/$defs/raison"
                }
            }
        },
        "session": {
            "type": "object",
            "required": [
                "session_uuid",
                "ouverte",
                "ouverte_le",
                "operateur_id"
            ],
            "additionalProperties": false,
            "properties": {
                "session_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "ouverte": {
                    "type": "boolean"
                },
                "ouverte_le": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/horodatage"
                        }
                    ]
                },
                "operateur_id": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/identifiant_serveur"
                        }
                    ]
                }
            }
        },
        "operation_etat": {
            "description": "Changement d'état d'une opération du terminal (intégration, arbitrage, résolution) : la résolution revient aux terminaux par le journal.",
            "type": "object",
            "required": [
                "operation_uuid",
                "etat",
                "version_etat",
                "raison"
            ],
            "additionalProperties": false,
            "properties": {
                "operation_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "etat": {
                    "enum": [
                        "recue",
                        "integree",
                        "a_arbitrer",
                        "resolue",
                        "rejet_protocole"
                    ]
                },
                "version_etat": {
                    "$ref": "commun.json#/$defs/version"
                },
                "raison": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/raison"
                        }
                    ]
                },
                "details": {
                    "type": "object",
                    "description": "Sur une creation_client intégrée (capacité client.creation) ou une cloture_session intégrée (capacité session.cloture).",
                    "additionalProperties": false,
                    "properties": {
                        "client_uuid_canonique": {
                            "$ref": "commun.json#/$defs/uuid"
                        },
                        "z": {
                            "type": "object",
                            "description": "Z de la clôture intégrée.",
                            "required": [
                                "cloture_uuid",
                                "compte",
                                "theorique",
                                "ecart",
                                "mode"
                            ],
                            "additionalProperties": false,
                            "properties": {
                                "cloture_uuid": {
                                    "$ref": "commun.json#/$defs/uuid"
                                },
                                "compte": {
                                    "$ref": "commun.json#/$defs/montant"
                                },
                                "theorique": {
                                    "type": "integer"
                                },
                                "ecart": {
                                    "type": "integer"
                                },
                                "mode": {
                                    "enum": [
                                        "V1",
                                        "COMPLETE"
                                    ]
                                }
                            }
                        },
                        "commande": {
                            "description": "Capacité restaurant.v1 : sur une resto_commande intégrée, la commande et sa version (numéro = numéro serveur).",
                            "type": "object",
                            "required": [
                                "commande_uuid",
                                "numero",
                                "version"
                            ],
                            "additionalProperties": false,
                            "properties": {
                                "commande_uuid": {
                                    "$ref": "commun.json#/$defs/uuid"
                                },
                                "numero": {
                                    "type": "string",
                                    "minLength": 1,
                                    "maxLength": 40
                                },
                                "version": {
                                    "type": "integer",
                                    "minimum": 1
                                }
                            }
                        },
                        "z_restaurant": {
                            "description": "Capacité restaurant.v1 (lot R-4) : Z restaurant figé par le serveur, à la clôture de session d'un terminal restaurant (`session`) ou à la clôture du registre (`register`).",
                            "type": "object",
                            "required": [
                                "z_uuid",
                                "type",
                                "numero"
                            ],
                            "additionalProperties": false,
                            "properties": {
                                "z_uuid": {
                                    "$ref": "commun.json#/$defs/uuid"
                                },
                                "type": {
                                    "enum": [
                                        "session",
                                        "register"
                                    ]
                                },
                                "numero": {
                                    "type": "integer",
                                    "minimum": 1
                                }
                            }
                        },
                        "produit_uuid_canonique": {
                            "$ref": "commun.json#/$defs/uuid",
                            "description": "Capacités produit.creation / produit.modification (2.1 lot 10) : produit serveur désigné par produit_uuid (lui-même, ou le produit auquel il est rattaché ; l’uuid du terminal reste alors un alias sans limite)."
                        },
                        "produit_resolution": {
                            "type": "object",
                            "description": "2.1 lot 10 : décision appliquée à une creation_produit ou une modification_produit.",
                            "required": [
                                "decision",
                                "champs_serveur",
                                "decide_par"
                            ],
                            "additionalProperties": false,
                            "properties": {
                                "decision": {
                                    "enum": [
                                        "creee",
                                        "rattachee",
                                        "creee_distincte",
                                        "appliquee",
                                        "sans_effet",
                                        "arbitree"
                                    ]
                                },
                                "champs_serveur": {
                                    "type": "array",
                                    "uniqueItems": true,
                                    "maxItems": 10,
                                    "description": "Champs de la modification où la valeur du serveur a été gardée par arbitrage.",
                                    "items": {
                                        "enum": [
                                            "nom",
                                            "reference",
                                            "categorie_uuid",
                                            "prix",
                                            "prix_gros",
                                            "gros_quantite_min",
                                            "fournisseur_uuid"
                                        ]
                                    }
                                },
                                "decide_par": {
                                    "oneOf": [
                                        {
                                            "type": "null"
                                        },
                                        {
                                            "$ref": "commun.json#/$defs/identifiant_serveur"
                                        }
                                    ],
                                    "description": "Utilisateur qui a arbitré ; null sans arbitrage."
                                }
                            }
                        },
                        "session_serveur": {
                            "description": "Capacité session.multiple (2.1 lot 12) : sur une ouverture_session intégrée, la session serveur qui lui correspond (id local ↔ id serveur). Une ouverture rattachée à une session déjà ouverte au serveur (ouverte au web) rend cette session.",
                            "type": "object",
                            "required": [
                                "session_uuid"
                            ],
                            "additionalProperties": false,
                            "properties": {
                                "session_uuid": {
                                    "$ref": "commun.json#/$defs/uuid"
                                }
                            }
                        },
                        "journee": {
                            "description": "Capacité session.multiple (2.1 lot 12) : sur une cloture_journee intégrée, le rapprochement du serveur.",
                            "type": "object",
                            "required": [
                                "jour",
                                "sessions",
                                "ecart"
                            ],
                            "additionalProperties": false,
                            "properties": {
                                "jour": {
                                    "$ref": "commun.json#/$defs/jour"
                                },
                                "sessions": {
                                    "type": "integer",
                                    "minimum": 1
                                },
                                "ecart": {
                                    "type": "integer",
                                    "description": "Somme des écarts (terminal − serveur) sur les théoriques par moyen ; 0 si le Z du terminal concorde."
                                }
                            }
                        },
                        "categorie_uuid_canonique": {
                            "$ref": "commun.json#/$defs/uuid",
                            "description": "Capacité referentiels.creation (2.1 lot 18) : catégorie du serveur désignée par l’uuid du poste (créée, ou existante du même nom). Le poste remplace partout son uuid local par celui-ci."
                        },
                        "fournisseur_uuid_canonique": {
                            "$ref": "commun.json#/$defs/uuid",
                            "description": "Capacité referentiels.creation (2.1 lot 18) : fournisseur du serveur désigné par l’uuid du poste (créé, ou existant du même nom). Le poste remplace partout son uuid local par celui-ci."
                        },
                        "referentiel_resolution": {
                            "type": "object",
                            "description": "2.1 lot 18 : décision appliquée à une creation_categorie ou creation_fournisseur.",
                            "required": [
                                "decision"
                            ],
                            "additionalProperties": false,
                            "properties": {
                                "decision": {
                                    "enum": [
                                        "creee",
                                        "rattachee"
                                    ],
                                    "description": "creee : fiche créée au serveur ; rattachee : fiche du même nom déjà présente, rien n’a été créé."
                                }
                            }
                        }
                    }
                }
            }
        },
        "categorie": {
            "description": "Révision 2.1 : catégorie du catalogue (onglets de la caisse web). Non critique.",
            "type": "object",
            "required": [
                "nom",
                "ordre",
                "actif"
            ],
            "additionalProperties": false,
            "properties": {
                "nom": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 120
                },
                "ordre": {
                    "type": "integer"
                },
                "actif": {
                    "type": "boolean"
                }
            }
        },
        "client": {
            "description": "Client actif de la boutique (capacité client.lecture). Aucun solde : crédit, points et avoirs restent en ligne.",
            "type": "object",
            "required": [
                "nom",
                "telephone",
                "type",
                "tarif",
                "actif"
            ],
            "additionalProperties": false,
            "properties": {
                "nom": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 160
                },
                "telephone": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "pattern": "^\\+[1-9][0-9]{7,14}$",
                    "description": "E.164 ; null si absent ou illisible."
                },
                "type": {
                    "enum": [
                        "particulier",
                        "professionnel",
                        "passage"
                    ]
                },
                "tarif": {
                    "enum": [
                        "detail",
                        "gros"
                    ]
                },
                "actif": {
                    "type": "boolean"
                }
            }
        },
        "contenu_panier": {
            "type": "object",
            "required": [
                "lignes",
                "client_uuid",
                "client_nom",
                "remise_globale",
                "livraison",
                "note",
                "tarif"
            ],
            "additionalProperties": false,
            "properties": {
                "lignes": {
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 100,
                    "items": {
                        "type": "object",
                        "required": [
                            "produit_uuid",
                            "conditionnement_uuid",
                            "libelle",
                            "quantite",
                            "coefficient",
                            "prix_unitaire",
                            "remise"
                        ],
                        "additionalProperties": false,
                        "properties": {
                            "produit_uuid": {
                                "$ref": "commun.json#/$defs/uuid"
                            },
                            "conditionnement_uuid": {
                                "oneOf": [
                                    {
                                        "type": "null"
                                    },
                                    {
                                        "$ref": "commun.json#/$defs/uuid"
                                    }
                                ]
                            },
                            "libelle": {
                                "type": "string",
                                "minLength": 1,
                                "maxLength": 400
                            },
                            "quantite": {
                                "type": "string"
                            },
                            "coefficient": {
                                "type": "string"
                            },
                            "prix_unitaire": {
                                "$ref": "commun.json#/$defs/montant",
                                "description": "Prix figé à la suspension."
                            },
                            "remise": {
                                "$ref": "commun.json#/$defs/montant"
                            }
                        }
                    }
                },
                "client_uuid": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ]
                },
                "client_nom": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 255
                },
                "remise_globale": {
                    "$ref": "commun.json#/$defs/montant"
                },
                "livraison": {
                    "$ref": "commun.json#/$defs/montant"
                },
                "note": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 2000
                },
                "tarif": {
                    "enum": [
                        "detail",
                        "gros"
                    ]
                }
            }
        },
        "panier": {
            "description": "Panier partagé en attente ou repris, de moins de 30 jours (capacité panier.partage). Vendu ou supprimé : suppression au journal.",
            "type": "object",
            "required": [
                "etat",
                "libelle",
                "auteur_operateur_id",
                "terminal_origine_uuid",
                "terminaux",
                "repris_par",
                "contenu",
                "cree_le",
                "modifie_le"
            ],
            "additionalProperties": false,
            "properties": {
                "etat": {
                    "enum": [
                        "en_attente",
                        "repris"
                    ]
                },
                "libelle": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 150
                },
                "auteur_operateur_id": {
                    "$ref": "commun.json#/$defs/identifiant_serveur"
                },
                "terminal_origine_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "terminaux": {
                    "description": "Terminaux de son point de vente : les seuls à pouvoir le lister et le reprendre.",
                    "type": "array",
                    "maxItems": 500,
                    "items": {
                        "$ref": "commun.json#/$defs/uuid"
                    }
                },
                "repris_par": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "type": "object",
                            "required": [
                                "terminal_uuid",
                                "operateur_id",
                                "le"
                            ],
                            "additionalProperties": false,
                            "properties": {
                                "terminal_uuid": {
                                    "oneOf": [
                                        {
                                            "type": "null"
                                        },
                                        {
                                            "$ref": "commun.json#/$defs/uuid"
                                        }
                                    ]
                                },
                                "operateur_id": {
                                    "$ref": "commun.json#/$defs/identifiant_serveur"
                                },
                                "le": {
                                    "$ref": "commun.json#/$defs/horodatage"
                                }
                            }
                        }
                    ]
                },
                "contenu": {
                    "$ref": "#/$defs/contenu_panier"
                },
                "cree_le": {
                    "$ref": "commun.json#/$defs/horodatage"
                },
                "modifie_le": {
                    "$ref": "commun.json#/$defs/horodatage"
                }
            }
        },
        "lot": {
            "description": "Capacité lots.vente : lot d’un produit. Quantité sur la stock.projection de clé produit:lot.",
            "type": "object",
            "required": [
                "produit_uuid",
                "reference",
                "entree",
                "peremption",
                "prix_vente",
                "actif"
            ],
            "additionalProperties": false,
            "properties": {
                "produit_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "reference": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 255
                },
                "entree": {
                    "type": "string",
                    "description": "Date d’entrée UTC, ordre des modes fifo et dernier_achat."
                },
                "peremption": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "type": "string",
                            "pattern": "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"
                        }
                    ]
                },
                "prix_vente": {
                    "type": "integer",
                    "minimum": 0
                },
                "actif": {
                    "type": "boolean"
                }
            }
        },
        "modele_ticket": {
            "description": "Capacité ticket.modeles : modèle de ticket de la boutique (Paramètres › Modèles de ticket et de facture). Les articles et les totaux sont fixes, entre haut et bas. Bloc inconnu du terminal : ignoré. Bloc obligatoire (document, operations, fne) absent ou masqué : imprimé à sa place d’origine. Modèle illisible : disposition d’origine ; un ticket sort toujours.",
            "type": "object",
            "required": [
                "nom",
                "haut",
                "bas",
                "masques",
                "titre",
                "compact",
                "entete",
                "pied"
            ],
            "additionalProperties": false,
            "properties": {
                "nom": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 80
                },
                "haut": {
                    "description": "Blocs avant les articles, dans l’ordre d’impression (masqués compris). Origine : logo, nom, adresse, telephone, ncc, entete, document, vendeur, client, restaurant, note.",
                    "type": "array",
                    "maxItems": 30,
                    "uniqueItems": true,
                    "items": {
                        "$ref": "commun.json#/$defs/code"
                    }
                },
                "bas": {
                    "description": "Blocs après les totaux, dans l’ordre d’impression (masqués compris). Origine : avantages, remises, paiements, operations, fne, qr, pied.",
                    "type": "array",
                    "maxItems": 30,
                    "uniqueItems": true,
                    "items": {
                        "$ref": "commun.json#/$defs/code"
                    }
                },
                "masques": {
                    "description": "Blocs à ne pas imprimer. Jamais document, lignes, totaux, operations ni fne.",
                    "type": "array",
                    "maxItems": 30,
                    "uniqueItems": true,
                    "items": {
                        "$ref": "commun.json#/$defs/code"
                    }
                },
                "titre": {
                    "description": "Titre du document (ex. « Reçu de vente »), imprimé en majuscules en ESC/POS.",
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 40
                },
                "compact": {
                    "description": "Une ligne par article (sans la ligne prix × quantité), avance réduite avant la coupe.",
                    "type": "boolean"
                },
                "entete": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "type": "string",
                            "minLength": 1,
                            "maxLength": 600
                        }
                    ],
                    "description": "Texte d’en-tête du modèle ; null : boutique.ticket.entete."
                },
                "pied": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "type": "string",
                            "minLength": 1,
                            "maxLength": 600
                        }
                    ],
                    "description": "Texte de pied du modèle ; null : boutique.ticket.pied."
                }
            }
        },
        "ticket_terminal": {
            "description": "Capacité ticket.modeles : modèle de ticket résolu pour le terminal de clé (son uuid) — terminal, puis sa caisse, puis le modèle en usage de la boutique. La révision change quand l’affectation OU le contenu du modèle change (modele_empreinte). Le terminal ne lit que la clé de son propre uuid.",
            "type": "object",
            "required": [
                "modele_uuid",
                "modele_empreinte"
            ],
            "additionalProperties": false,
            "properties": {
                "modele_uuid": {
                    "description": "Clé d’un modele_ticket, ou null : disposition d’origine.",
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ]
                },
                "modele_empreinte": {
                    "description": "SHA-256 SK-JCS-1 des données du modele_ticket résolu, ou null.",
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "type": "string",
                            "pattern": "^[0-9a-f]{64}$"
                        }
                    ]
                }
            }
        },
        "pass_reglages": {
            "description": "Capacité passes.evenement : réglages du module pour la boutique de clé (son uuid). actifs = false : aucun paiement par pass.",
            "type": "object",
            "required": [
                "actifs",
                "en_service_table",
                "plusieurs_pass_par_vente",
                "saisie_manuelle",
                "hors_ligne"
            ],
            "additionalProperties": false,
            "properties": {
                "actifs": {
                    "type": "boolean"
                },
                "en_service_table": {
                    "description": "Paiement par pass permis au Service de table.",
                    "type": "boolean"
                },
                "plusieurs_pass_par_vente": {
                    "type": "boolean"
                },
                "saisie_manuelle": {
                    "description": "false : masquer la saisie volontaire du code (douchette ou caméra seulement).",
                    "type": "boolean"
                },
                "hors_ligne": {
                    "description": "Sans réseau : refuser (« Vérification impossible sans connexion pour cet événement. ») ou autoriser (décision locale avec compteurs + passages locaux en attente).",
                    "enum": [
                        "refuser",
                        "autoriser"
                    ]
                }
            }
        },
        "pass_evenement": {
            "description": "Capacité passes.evenement : événement de clé (son uuid). Le service est résolu par le serveur en uuid de produits (catégories, fournisseurs, marques et produits marqués ; une variante entre par son parent).",
            "type": "object",
            "required": [
                "nom",
                "debut",
                "fin",
                "actif",
                "tous_produits",
                "produits",
                "hors_ligne"
            ],
            "additionalProperties": false,
            "properties": {
                "nom": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 160
                },
                "debut": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/jour"
                        }
                    ],
                    "description": "Premier jour inclus ; null = ouvert."
                },
                "fin": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/jour"
                        }
                    ],
                    "description": "Dernier jour inclus ; null = ouvert."
                },
                "actif": {
                    "description": "false : « L'événement de ce pass est clos ou désactivé. »",
                    "type": "boolean"
                },
                "tous_produits": {
                    "description": "Vrai : tout produit est du service (produits est alors vide).",
                    "type": "boolean"
                },
                "produits": {
                    "description": "Produits du service, triés. Vide et tous_produits = false : rien ne passe (« L'événement n'a aucun produit dans son service… »).",
                    "type": "array",
                    "maxItems": 20000,
                    "uniqueItems": true,
                    "items": {
                        "$ref": "commun.json#/$defs/uuid"
                    }
                },
                "hors_ligne": {
                    "description": "Sans réseau : refuser (« Vérification impossible sans connexion pour cet événement. ») ou autoriser (décision locale avec compteurs + passages locaux en attente).",
                    "enum": [
                        "refuser",
                        "autoriser"
                    ]
                }
            }
        },
        "pass": {
            "description": "Capacité passes.evenement : pass de clé (son uuid), révoqué compris (statut revoque, refusé avec le message ECAS). Le code n'est jamais publié : le terminal normalise le code lu (bords et retours retirés, majuscules), calcule son SHA-256 et le cherche parmi les code_empreinte.",
            "type": "object",
            "required": [
                "evenement_uuid",
                "code_empreinte",
                "type",
                "porteur",
                "statut",
                "debut",
                "fin",
                "max_total",
                "plafond_par_passage",
                "regles",
                "menus_produits",
                "compteurs"
            ],
            "additionalProperties": false,
            "properties": {
                "evenement_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "code_empreinte": {
                    "description": "SHA-256 hexadécimal minuscule du code normalisé (UTF-8).",
                    "type": "string",
                    "pattern": "^[0-9a-f]{64}$"
                },
                "type": {
                    "enum": [
                        "qr",
                        "code_barre"
                    ]
                },
                "porteur": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 160
                },
                "statut": {
                    "enum": [
                        "actif",
                        "revoque"
                    ]
                },
                "debut": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/jour"
                        }
                    ],
                    "description": "Validité propre du pass, premier jour inclus ; null = ouverte."
                },
                "fin": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/jour"
                        }
                    ],
                    "description": "Dernier jour inclus ; null = ouverte."
                },
                "max_total": {
                    "description": "Passages au total ; null = illimité.",
                    "type": [
                        "integer",
                        "null"
                    ],
                    "minimum": 1,
                    "maximum": 1000000
                },
                "plafond_par_passage": {
                    "description": "Montant maximal d'un passage (FCFA) ; null = libre.",
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/montant"
                        }
                    ]
                },
                "regles": {
                    "description": "Quotas par jour : une règle datée l'emporte sur le jour de semaine ; sans règle, tous les jours de la fenêtre sans limite par jour ; avec des règles, seulement les jours couverts ; 0 interdit le jour.",
                    "type": "array",
                    "maxItems": 400,
                    "items": {
                        "$ref": "#/$defs/pass_regle"
                    }
                },
                "menus_produits": {
                    "description": "Produits des menus liés au pass (produits nommés et catégories des menus), triés ; null = pas de contrainte de menu.",
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "type": "array",
                            "maxItems": 20000,
                            "uniqueItems": true,
                            "items": {
                                "$ref": "commun.json#/$defs/uuid"
                            }
                        }
                    ]
                },
                "compteurs": {
                    "$ref": "#/$defs/pass_compteurs"
                }
            }
        },
        "pass_regle": {
            "description": "Une règle porte soit un jour de semaine (1 = lundi … 7 = dimanche), soit une date.",
            "oneOf": [
                {
                    "type": "object",
                    "required": [
                        "jour_semaine",
                        "date",
                        "max_passages"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "jour_semaine": {
                            "type": "integer",
                            "minimum": 1,
                            "maximum": 7
                        },
                        "date": {
                            "type": "null"
                        },
                        "max_passages": {
                            "type": "integer",
                            "minimum": 0,
                            "maximum": 1000000
                        }
                    }
                },
                {
                    "type": "object",
                    "required": [
                        "jour_semaine",
                        "date",
                        "max_passages"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "jour_semaine": {
                            "type": "null"
                        },
                        "date": {
                            "$ref": "commun.json#/$defs/jour"
                        },
                        "max_passages": {
                            "type": "integer",
                            "minimum": 0,
                            "maximum": 1000000
                        }
                    }
                }
            ]
        },
        "pass_compteurs": {
            "description": "Passages validés au serveur, tous terminaux confondus. Le terminal ajoute SEULEMENT ses passages locaux dont l'uuid n'est pas dans passages : jamais de double compte, même si la révision arrive avant l'accusé de la vente.",
            "type": "object",
            "required": [
                "total",
                "jours",
                "passages"
            ],
            "additionalProperties": false,
            "properties": {
                "total": {
                    "type": "integer",
                    "minimum": 0,
                    "maximum": 1000000
                },
                "jours": {
                    "description": "Passages par jour civil sur les 7 derniers jours de la boutique, aujourd'hui compris, triés par jour ; jours sans passage absents. Liste plutôt que carte {AAAA-MM-JJ: n} : le profil SK-SCHEMA-1 n'a que des objets fermés.",
                    "type": "array",
                    "maxItems": 7,
                    "items": {
                        "type": "object",
                        "required": [
                            "jour",
                            "passages"
                        ],
                        "additionalProperties": false,
                        "properties": {
                            "jour": {
                                "$ref": "commun.json#/$defs/jour"
                            },
                            "passages": {
                                "type": "integer",
                                "minimum": 1,
                                "maximum": 1000000
                            }
                        }
                    }
                },
                "passages": {
                    "description": "uuid des passages comptés dans jours (même fenêtre), triés.",
                    "type": "array",
                    "maxItems": 10000,
                    "uniqueItems": true,
                    "items": {
                        "$ref": "commun.json#/$defs/uuid"
                    }
                }
            }
        },
        "interface_caisse": {
            "description": "Capacité caisse.interface (2.1 lot 13) : interface de la caisse résolue pour le terminal de clé (son uuid) — réglage propre au terminal s’il existe, sinon celui de la boutique, sinon les défauts (= écran d’avant le lot). Non critique, publiée pour chaque terminal actif de la boutique ; le terminal ne lit que la clé de son propre uuid. Il applique ce qu’il connaît et ignore les éléments dont il ne connaît pas la clé. Aucun prix, aucune taxe, aucun paiement n’en dépend.",
            "type": "object",
            "required": [
                "origine",
                "verrouille",
                "elements",
                "tuile_categorie",
                "tuile_produit",
                "police_compacte",
                "bouton_payer"
            ],
            "additionalProperties": false,
            "properties": {
                "origine": {
                    "description": "D’où vient le réglage : defaut (rien d’enregistré au web), boutique (réglage de la boutique), terminal (surcharge propre à ce terminal).",
                    "enum": [
                        "defaut",
                        "boutique",
                        "terminal"
                    ]
                },
                "verrouille": {
                    "description": "true : le poste applique ce réglage et n’offre pas de réglage local qui le remplace. false : le réglage local du poste, s’il existe, prime.",
                    "type": "boolean"
                },
                "elements": {
                    "description": "Éléments de l’écran de vente, triés par ordre croissant (1 à N, sans trou). Clés connues : scanner, recherche, favoris, categories, marques, fournisseurs ; boutons de la barre : vue, plein_ecran, ventes_recentes, retour, carte_cadeau, coffret, client_rapide, produit_rapide, calculatrice, clavier, quitter ; boutons des postes seulement : recu, note, session, retour_web, back_office, salle_tables. Une clé inconnue du terminal est ignorée.",
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 30,
                    "items": {
                        "type": "object",
                        "required": [
                            "cle",
                            "visible",
                            "ordre"
                        ],
                        "additionalProperties": false,
                        "properties": {
                            "cle": {
                                "type": "string",
                                "pattern": "^[a-z][a-z0-9_]{0,39}$"
                            },
                            "visible": {
                                "type": "boolean"
                            },
                            "ordre": {
                                "type": "integer",
                                "minimum": 1,
                                "maximum": 30
                            }
                        }
                    }
                },
                "tuile_categorie": {
                    "$ref": "#/$defs/taille_interface"
                },
                "tuile_produit": {
                    "$ref": "#/$defs/taille_interface"
                },
                "police_compacte": {
                    "description": "Taille du texte en mode compact (liste ou densité compacte) ; m = taille d’avant le lot.",
                    "$ref": "#/$defs/taille_interface"
                },
                "bouton_payer": {
                    "description": "Hauteur du bouton Payer ; m = hauteur d’avant le lot.",
                    "$ref": "#/$defs/taille_interface"
                }
            }
        },
        "taille_interface": {
            "description": "Taille relative (2.1 lot 13) : s ≈ 0,85, m = 1 (taille d’avant le lot), l ≈ 1,2, xl ≈ 1,45.",
            "enum": [
                "s",
                "m",
                "l",
                "xl"
            ]
        },
        "prevente": {
            "description": "Capacité prevente.v1 (lot 15) : prévente OUVERTE de la boutique, pour qu’un autre poste la retrouve (code, nom) et la convertisse après synchro. Convertie ou annulée : suppression au journal.",
            "type": "object",
            "required": [
                "code",
                "statut",
                "client",
                "retrait_prevu",
                "lignes",
                "total",
                "acompte",
                "acompte_moyen",
                "terminal_origine_uuid",
                "auteur_operateur_id",
                "cree_le",
                "modifie_le",
                "note"
            ],
            "additionalProperties": false,
            "properties": {
                "code": {
                    "type": "string",
                    "pattern": "^[A-Z0-9]{6}$"
                },
                "statut": {
                    "enum": [
                        "ouverte"
                    ]
                },
                "client": {
                    "$ref": "operation.json#/$defs/client_prevente"
                },
                "retrait_prevu": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/horodatage"
                        }
                    ]
                },
                "lignes": {
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 100,
                    "items": {
                        "$ref": "operation.json#/$defs/ligne_prevente"
                    }
                },
                "total": {
                    "$ref": "commun.json#/$defs/montant"
                },
                "acompte": {
                    "$ref": "commun.json#/$defs/montant"
                },
                "acompte_moyen": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/code"
                        }
                    ]
                },
                "terminal_origine_uuid": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ],
                    "description": "null : prévente créée au web."
                },
                "auteur_operateur_id": {
                    "$ref": "commun.json#/$defs/identifiant_serveur"
                },
                "cree_le": {
                    "$ref": "commun.json#/$defs/horodatage"
                },
                "modifie_le": {
                    "$ref": "commun.json#/$defs/horodatage"
                },
                "note": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 500
                }
            }
        },
        "logo_boutique": {
            "description": "Capacité boutique.logo : logo de la boutique pour les impressions du poste (en tête de chaque document, sans rien au-dessus). Fichier JPEG servi par GET /logos/{uuid}, immuable ; null : pas de logo.",
            "oneOf": [
                {
                    "type": "null"
                },
                {
                    "type": "object",
                    "required": [
                        "uuid",
                        "empreinte",
                        "octets",
                        "largeur",
                        "hauteur"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "uuid": {
                            "$ref": "commun.json#/$defs/uuid"
                        },
                        "empreinte": {
                            "$ref": "commun.json#/$defs/empreinte"
                        },
                        "octets": {
                            "type": "integer",
                            "minimum": 1
                        },
                        "largeur": {
                            "type": "integer",
                            "minimum": 1
                        },
                        "hauteur": {
                            "type": "integer",
                            "minimum": 1
                        }
                    }
                }
            ]
        },
        "fournisseur": {
            "description": "Capacité referentiels.creation (2.1 lot 18) : fournisseur de la boutique (liste des fournisseurs du web), actif ou non, pour le choix de la fiche produit. Non critique.",
            "type": "object",
            "required": [
                "nom",
                "telephone",
                "actif"
            ],
            "additionalProperties": false,
            "properties": {
                "nom": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 160
                },
                "telephone": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 40
                },
                "actif": {
                    "type": "boolean"
                }
            }
        }
    }
}
''',
  'donnees-restaurant-1.json': r'''{
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "$id": "donnees-restaurant-1.json",
    "title": "Données des changements restaurant.* (révision restaurant-1, lots R-1 à R-3 ; RESTAURANT-1 §3). Rendues aux seuls clients à qui restaurant.v1 est accordée. R-1 : critiques ; R-2 (salle, table, menu, categorie) et R-3 (poste, routage), R-4 (canal) et R-5 (promotion, remise_client) et lot Z local (interface) : non critiques.",
    "$defs": {
        "restaurant.point_de_vente": {
            "description": "Point de vente de la boutique (clé = son uuid). Le mode du terminal en dépend : Boutique, Service de table ou Restaurant.",
            "type": "object",
            "required": [
                "code",
                "nom",
                "profil",
                "actif",
                "terminaux",
                "membres",
                "reglages_vente"
            ],
            "additionalProperties": false,
            "properties": {
                "code": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 20
                },
                "nom": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 120
                },
                "profil": {
                    "enum": [
                        null,
                        "TABLE_SERVICE",
                        "PRODUCTION"
                    ]
                },
                "actif": {
                    "type": "boolean"
                },
                "terminaux": {
                    "description": "Terminaux actifs qui travaillent dans ce point de vente (rattachés, plus ceux sans rattachement pour le point de vente principal).",
                    "type": "array",
                    "maxItems": 100,
                    "uniqueItems": true,
                    "items": {
                        "$ref": "commun.json#/$defs/uuid"
                    }
                },
                "membres": {
                    "description": "null : toute affiliation de la boutique y travaille ; sinon les seuls opérateurs admis (operateur_id).",
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "type": "array",
                            "maxItems": 2000,
                            "uniqueItems": true,
                            "items": {
                                "$ref": "commun.json#/$defs/identifiant_serveur"
                            }
                        }
                    ]
                },
                "reglages_vente": {
                    "type": "object",
                    "required": [
                        "changement_client_paiement",
                        "reference_plateforme_avant_envoi",
                        "verrouillage_minutes"
                    ],
                    "additionalProperties": false,
                    "description": "Valeurs résolues : surcharge du point de vente, sinon valeur de la boutique.",
                    "properties": {
                        "changement_client_paiement": {
                            "type": "boolean"
                        },
                        "reference_plateforme_avant_envoi": {
                            "type": "boolean"
                        },
                        "verrouillage_minutes": {
                            "description": "0 = verrouillage désactivé.",
                            "oneOf": [
                                {
                                    "type": "null"
                                },
                                {
                                    "type": "integer",
                                    "minimum": 0,
                                    "maximum": 1440
                                }
                            ]
                        }
                    }
                }
            }
        },
        "restaurant.maitre": {
            "description": "Caisse maîtresse du point de vente (clé = maitre:<uuid du point de vente>). Je suis maître si appareil_uuid est mon appareil ET epoque mon époque d’appairage. terminal_uuid null : aucune caisse maîtresse, le web a la main.",
            "type": "object",
            "required": [
                "point_de_vente_uuid",
                "generation",
                "terminal_uuid",
                "appareil_uuid",
                "epoque",
                "designe_le"
            ],
            "additionalProperties": false,
            "properties": {
                "point_de_vente_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "generation": {
                    "$ref": "commun.json#/$defs/version",
                    "description": "Croît à chaque désignation, changement ou retrait ; 0 = jamais désigné."
                },
                "terminal_uuid": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ]
                },
                "appareil_uuid": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ]
                },
                "epoque": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "type": "integer",
                            "minimum": 1
                        }
                    ]
                },
                "designe_le": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/horodatage"
                        }
                    ]
                }
            }
        },
        "restaurant.reglages": {
            "description": "Réglages restaurant résolus pour le point de vente (clé = reglages:<uuid du point de vente>) : valeur de la boutique, profil du point de vente.",
            "type": "object",
            "required": [
                "point_de_vente_uuid",
                "envoi_production",
                "plusieurs_commandes_par_table",
                "prefixe_commande",
                "motif_annulation_commande",
                "registre_obligatoire",
                "prefacture_a_la_demande",
                "retard_production_minutes",
                "sections_z",
                "fuseau",
                "impression_mode",
                "repli_premier_poste_actif",
                "assistant",
                "annulation_envoye_responsable"
            ],
            "additionalProperties": false,
            "properties": {
                "point_de_vente_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "envoi_production": {
                    "type": "boolean",
                    "description": "restaurant.table_service_send_to_production (Service de table) ou restaurant.production_send_to_stations (Restaurant) ; faux sans profil. Éteint : « Envoyer » devient « Valider », aucun bon."
                },
                "plusieurs_commandes_par_table": {
                    "type": "boolean"
                },
                "prefixe_commande": {
                    "type": "string",
                    "maxLength": 30,
                    "description": "Préfixe du numéro local, à normaliser par la caisse (majuscules, caractères admis)."
                },
                "motif_annulation_commande": {
                    "type": "boolean"
                },
                "registre_obligatoire": {
                    "type": "boolean"
                },
                "prefacture_a_la_demande": {
                    "type": "boolean"
                },
                "retard_production_minutes": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 240
                },
                "sections_z": {
                    "type": "array",
                    "maxItems": 50,
                    "uniqueItems": true,
                    "items": {
                        "$ref": "commun.json#/$defs/code"
                    }
                },
                "fuseau": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 64,
                    "description": "Fuseau de la journée métier (restaurant.timezone, sinon celui de la boutique)."
                },
                "impression_mode": {
                    "enum": [
                        "register",
                        "station"
                    ],
                    "description": "Indicatif : hors ligne, chaque bon part à toutes les cibles de son poste (plan §2)."
                },
                "repli_premier_poste_actif": {
                    "type": "boolean",
                    "description": "Paramètre à créer (plan §2 bis), absent du web : toujours faux en R-1."
                },
                "assistant": {
                    "type": "object",
                    "required": [
                        "max_operations_par_jour",
                        "max_montant_par_operation",
                        "max_montant_par_jour",
                        "max_remise_pourcent"
                    ],
                    "additionalProperties": false,
                    "description": "Plafonds d’une autorisation par un assistant manager (approval.assistant.*) ; 0 = illimité, sauf la remise.",
                    "properties": {
                        "max_operations_par_jour": {
                            "type": "integer",
                            "minimum": 0,
                            "maximum": 1000
                        },
                        "max_montant_par_operation": {
                            "$ref": "commun.json#/$defs/montant"
                        },
                        "max_montant_par_jour": {
                            "$ref": "commun.json#/$defs/montant"
                        },
                        "max_remise_pourcent": {
                            "type": "integer",
                            "minimum": 0,
                            "maximum": 100
                        }
                    }
                },
                "annulation_envoye_responsable": {
                    "type": "boolean",
                    "description": "Lot R-3 (§4.3 bis, décision Q3) : vrai = annuler un article déjà envoyé exige toujours l'autorisation d'un responsable, même pour un opérateur qui a `resto_modifier_envoye` (comme ECAS). restaurant.offline_sent_change_requires_approver, éteint par défaut."
                }
            }
        },
        "restaurant.salle": {
            "description": "Salle de la boutique (clé = uuid de restaurant_spaces). Par boutique, sans point de vente.",
            "type": "object",
            "required": [
                "code",
                "nom",
                "ordre",
                "actif"
            ],
            "additionalProperties": false,
            "properties": {
                "code": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 40
                },
                "nom": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 120
                },
                "ordre": {
                    "type": "integer",
                    "minimum": 0
                },
                "actif": {
                    "type": "boolean"
                }
            }
        },
        "restaurant.table": {
            "description": "Table (clé = uuid de restaurant_tables). L'occupation n'est pas publiée : elle appartient à la caisse maîtresse.",
            "type": "object",
            "required": [
                "point_de_vente_uuid",
                "salle_uuid",
                "nom",
                "code",
                "capacite",
                "ordre",
                "actif"
            ],
            "additionalProperties": false,
            "properties": {
                "point_de_vente_uuid": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ]
                },
                "salle_uuid": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ]
                },
                "nom": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 160
                },
                "code": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 40
                },
                "capacite": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "type": "integer",
                            "minimum": 0
                        }
                    ]
                },
                "ordre": {
                    "type": "integer",
                    "minimum": 0
                },
                "actif": {
                    "type": "boolean"
                }
            }
        },
        "restaurant.canal": {
            "description": "Canal de vente du profil Restaurant (RESTAURANT-1 §3.6, lot R-4, clé = uuid du canal, non critique) : `restaurant_channels`. Une commande du Restaurant cite son `code` (`etat_commande.canal`). Table exigée si `exige_table`. Un canal à `suivi_livraison` reste vendable hors ligne ; le suivi des livraisons reste restreint (`restaurant.livraison`). Publié actif ou non.",
            "type": "object",
            "required": [
                "code",
                "nom",
                "type",
                "exige_table",
                "exige_reference",
                "suivi_livraison",
                "ordre",
                "actif"
            ],
            "additionalProperties": false,
            "properties": {
                "code": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 40
                },
                "nom": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 120
                },
                "type": {
                    "type": "string",
                    "maxLength": 20,
                    "description": "dine_in, takeaway, delivery…"
                },
                "exige_table": {
                    "type": "boolean"
                },
                "exige_reference": {
                    "type": "boolean",
                    "description": "Référence de la plateforme exigée (`reference_externe`)."
                },
                "suivi_livraison": {
                    "type": "boolean"
                },
                "ordre": {
                    "type": "integer",
                    "minimum": 0
                },
                "actif": {
                    "type": "boolean"
                }
            }
        },
        "restaurant.menu": {
            "description": "Menu du Service de table (clé = uuid de restaurant_menus) : produits et catégories qu'il propose.",
            "type": "object",
            "required": [
                "nom",
                "actif",
                "produits",
                "categories"
            ],
            "additionalProperties": false,
            "properties": {
                "nom": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 160
                },
                "actif": {
                    "type": "boolean"
                },
                "produits": {
                    "type": "array",
                    "maxItems": 5000,
                    "uniqueItems": true,
                    "items": {
                        "$ref": "commun.json#/$defs/uuid"
                    }
                },
                "categories": {
                    "type": "array",
                    "maxItems": 500,
                    "uniqueItems": true,
                    "items": {
                        "$ref": "commun.json#/$defs/uuid"
                    }
                }
            }
        },
        "restaurant.categorie": {
            "description": "Réglages restaurant d'une catégorie (clé = uuid de la catégorie ; réponse de B à Q16) : onglets de la caisse. Publié pour chaque catégorie qui a des réglages restaurant ; sans entité, la catégorie est visible, sans parent ni poste. `poste_uuid` : poste de la catégorie (`restaurant.poste`, lot R-3).",
            "type": "object",
            "required": [
                "parent_uuid",
                "poste_uuid",
                "ordre",
                "visible"
            ],
            "additionalProperties": false,
            "properties": {
                "parent_uuid": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ]
                },
                "poste_uuid": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ]
                },
                "ordre": {
                    "type": "integer",
                    "minimum": 0
                },
                "visible": {
                    "type": "boolean"
                }
            }
        },
        "restaurant.poste": {
            "description": "Poste de production de la boutique (clé = uuid du poste ; RESTAURANT-1 §3.8, lot R-3). Un poste peut avoir `ecran` ET `papier` : il reçoit alors le bon sur les deux. Ni adresse ni port d'imprimante, ni jeton d'afficheur : réglages locaux de la caisse. Un poste inactif reste publié (actif = faux).",
            "type": "object",
            "required": [
                "code",
                "nom",
                "type",
                "flux",
                "ecran",
                "papier",
                "ordre",
                "actif"
            ],
            "additionalProperties": false,
            "properties": {
                "code": {
                    "type": "string",
                    "pattern": "^[A-Za-z0-9_-]{1,40}$",
                    "description": "Code du poste ; la caisse le normalise (majuscules, caractères admis) pour former `numero_jour`."
                },
                "nom": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 120
                },
                "type": {
                    "type": "string",
                    "maxLength": 20,
                    "description": "Type du web (kitchen, bar, counter…), indicatif."
                },
                "flux": {
                    "enum": [
                        "preparation",
                        "handover"
                    ],
                    "description": "preparation : new → in_progress → ready → served ; handover : new → served. Un bon d'ANNULATION ou vidé suit le flux d'accusé (new → served)."
                },
                "ecran": {
                    "type": "boolean"
                },
                "papier": {
                    "type": "boolean"
                },
                "ordre": {
                    "type": "integer",
                    "minimum": 0
                },
                "actif": {
                    "type": "boolean"
                }
            }
        },
        "restaurant.routage": {
            "description": "Routage d'un produit vers un poste (clé = uuid du produit ; RESTAURANT-1 §3.9, lot R-3), calculé comme StationResolver : réglage du produit (`none` : rien ne part ; `station` : son poste s'il est actif), sinon poste actif de sa catégorie, sans catégorie parente ni repli sur un premier poste. La caisse utilise `poste_effectif_uuid` ; désactiver un poste republie les produits concernés.",
            "type": "object",
            "required": [
                "routage",
                "poste_uuid",
                "categorie_poste_uuid",
                "poste_effectif_uuid",
                "visible",
                "ordre",
                "favori"
            ],
            "additionalProperties": false,
            "properties": {
                "routage": {
                    "enum": [
                        "station",
                        "none",
                        "inherit"
                    ]
                },
                "poste_uuid": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ]
                },
                "categorie_poste_uuid": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ]
                },
                "poste_effectif_uuid": {
                    "description": "Résultat de StationResolver à la publication ; null = rien ne part.",
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ]
                },
                "visible": {
                    "type": "boolean"
                },
                "ordre": {
                    "type": "integer",
                    "minimum": 0
                },
                "favori": {
                    "type": "boolean"
                }
            }
        },
        "restaurant.promotion": {
            "description": "Promotion, happy hour ou tarif du personnel (RESTAURANT-1 §3.12, lot R-5, clé = uuid de la promotion, non critique) : `restaurant_promotions` ACTIVES de la boutique ; une promotion désactivée quitte le journal (suppression). Profil Restaurant seulement. Règle du web (PromotionEngine) : à la saisie d'une ligne, parmi les promotions de sa catégorie (`staff` pour une ligne au tarif du personnel, sinon `promotion` et `happy_hour`) qui valent à l'heure de la caisse dans le fuseau publié (`restaurant.reglages.fuseau`) et visent la ligne, la priorité la plus haute, puis la plus forte remise, puis la plus ancienne ; une ligne n'en a qu'une, figée à la saisie avec ses conditions (un changement de quantité les garde).",
            "type": "object",
            "required": [
                "nom",
                "categorie",
                "type",
                "pourcentage",
                "montant",
                "achetes",
                "offerts",
                "priorite",
                "jours",
                "heure_debut",
                "heure_fin",
                "du",
                "au",
                "canaux",
                "salles",
                "produits",
                "categories",
                "max_par_personnel"
            ],
            "additionalProperties": false,
            "properties": {
                "nom": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 120
                },
                "categorie": {
                    "enum": [
                        "promotion",
                        "happy_hour",
                        "staff"
                    ],
                    "description": "Tarif de la ligne (`ligne_commande.tarif`) : `promotion`, `happy_hour` ou `staff`."
                },
                "type": {
                    "enum": [
                        "pourcentage",
                        "montant",
                        "prix_special",
                        "x_achetes_y_offerts"
                    ],
                    "description": "Remise de la ligne : `pourcentage` du brut de la ligne (arrondi vers le bas) ; `montant` par article (unité de base : quantité × coefficient), au plus le brut ; `prix_special` par article (brut − prix × articles, arrondi au plus proche, jamais négatif) ; `x_achetes_y_offerts` : la ligne achetée garde sa remise à 0 et une ligne offerte liée de floor(quantité / achetes) × offerts, au même prix, entièrement remisée (aucune à 0)."
                },
                "pourcentage": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/taux"
                        }
                    ]
                },
                "montant": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/montant"
                        }
                    ],
                    "description": "Montant ou prix spécial par article."
                },
                "achetes": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "type": "integer",
                            "minimum": 0
                        }
                    ]
                },
                "offerts": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "type": "integer",
                            "minimum": 0
                        }
                    ]
                },
                "priorite": {
                    "type": "integer",
                    "minimum": -1000000,
                    "maximum": 1000000
                },
                "jours": {
                    "type": "array",
                    "maxItems": 7,
                    "uniqueItems": true,
                    "items": {
                        "type": "integer",
                        "minimum": 1,
                        "maximum": 7
                    },
                    "description": "Jours ISO (1 = lundi) ; vide = tous. Une fenêtre qui passe minuit compte pour le jour où elle a commencé."
                },
                "heure_debut": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "type": "string",
                            "pattern": "^([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$"
                        }
                    ],
                    "description": "Heure locale de la boutique (fuseau publié). Début après la fin : la fenêtre passe minuit."
                },
                "heure_fin": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "type": "string",
                            "pattern": "^([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$"
                        }
                    ]
                },
                "du": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/jour"
                        }
                    ]
                },
                "au": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/jour"
                        }
                    ]
                },
                "canaux": {
                    "type": "array",
                    "maxItems": 50,
                    "uniqueItems": true,
                    "items": {
                        "type": "string",
                        "minLength": 1,
                        "maxLength": 40
                    },
                    "description": "Codes des canaux (`restaurant.canal`) ; vide = tous."
                },
                "salles": {
                    "type": "array",
                    "maxItems": 100,
                    "uniqueItems": true,
                    "items": {
                        "$ref": "commun.json#/$defs/uuid"
                    },
                    "description": "Salles de la table de la commande ; vide = toutes (une commande sans table n’est alors pas visée)."
                },
                "produits": {
                    "type": "array",
                    "maxItems": 2000,
                    "uniqueItems": true,
                    "items": {
                        "$ref": "commun.json#/$defs/uuid"
                    },
                    "description": "Produits visés. Avec `categories` vides aussi : tous les articles."
                },
                "categories": {
                    "type": "array",
                    "maxItems": 500,
                    "uniqueItems": true,
                    "items": {
                        "$ref": "commun.json#/$defs/uuid"
                    },
                    "description": "Catégories visées : la catégorie du produit ou sa catégorie parente restaurant (`restaurant.categorie.parent_uuid`)."
                },
                "max_par_personnel": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/quantite"
                        }
                    ],
                    "description": "Tarif du personnel : articles (unité de base) par employé et par jour, toutes commandes du jour. Contrôle, pas un prix : dépassé (autre appareil), le serveur le note sans refuser."
                }
            }
        },
        "restaurant.remise_client": {
            "description": "Remise par client (RESTAURANT-1 §3.13, lot R-5, clé = uuid du client, non critique) : `restaurant_customer_discounts`, publiée seulement si le paramètre restaurant.customer_discounts est allumé (sinon aucune entité). Remise de commande `customer` = floor(montant après remises de ligne × pourcent / 100), recalculée à chaque fait tant qu’aucune remise manuelle ni aucun règlement ne l’a figée (`etat_commande.remise_globale_source`). Hors du plafond de la remise manuelle, de confiance à la vente.",
            "type": "object",
            "required": [
                "client_uuid",
                "pourcent"
            ],
            "additionalProperties": false,
            "properties": {
                "client_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "pourcent": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 100
                }
            }
        },
        "restaurant.interface": {
            "description": "Lot Z local (README §12.8), NON critique, clé « interface:<uuid du point de vente> » : réglages d’affichage de la caisse restaurant (interface simplifiée du web). Un terminal qui ne connaît pas ce type l’ignore ; type absent ou valeur inconnue : valeurs par défaut (demander_couverts vrai, libelle_envoi « send », navigation_carte « chips »).",
            "type": "object",
            "required": [
                "point_de_vente_uuid",
                "demander_couverts",
                "libelle_envoi",
                "navigation_carte"
            ],
            "additionalProperties": false,
            "properties": {
                "point_de_vente_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "demander_couverts": {
                    "type": "boolean",
                    "description": "restaurant.ask_covers : demander le nombre de couverts à l’ouverture d’une table ; faux = toucher une table libre ouvre aussitôt la commande. Défaut vrai."
                },
                "libelle_envoi": {
                    "enum": [
                        "send",
                        "hold",
                        "hold_short"
                    ],
                    "description": "restaurant.send_button_label : send = « Envoyer » (« Valider » sans envoi en production), hold = « Mettre en attente », hold_short = « Mise en attente ». Défaut send."
                },
                "navigation_carte": {
                    "enum": [
                        "chips",
                        "tiles",
                        "families"
                    ],
                    "description": "restaurant.catalog_navigation : chips = puces de catégories, tiles = tuiles de catégories, families = familles en haut, catégories en dossiers, puis articles. Défaut chips."
                }
            }
        }
    }
}
''',
  'donnees-z-local-1.json': r'''{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "donnees-z-local-1.json",
  "title": "Lot « Z local » du contrat v2 (README §12, capacité z.local) : données publiées pour imprimer hors ligne le pré-X, le Z de session et le pré-Z de la journée, et bloc de détail de clôture (DetailCloture, version 1) commun au web, aux terminaux et à cloture_session.",
  "$defs": {
    "z.session": {
      "description": "Non critique. Clé « z_session:<terminal_uuid> ». Dernière session du terminal (la même que l'entité session) : fond initial, caissier d'ouverture et retours et annulations SAISIS EN LIGNE dans la session (ceux d'une opération retour du terminal ne sont pas republiés : il les a déjà).",
      "type": "object",
      "required": ["terminal_uuid", "session_uuid", "ouverte", "ouverte_le", "operateur_id", "operateur_nom", "fond_initial", "retours", "retours_omis"],
      "additionalProperties": false,
      "properties": {
        "terminal_uuid": { "$ref": "commun.json#/$defs/uuid" },
        "session_uuid": { "$ref": "commun.json#/$defs/uuid" },
        "ouverte": { "type": "boolean" },
        "ouverte_le": { "oneOf": [{ "type": "null" }, { "$ref": "commun.json#/$defs/horodatage" }] },
        "operateur_id": { "oneOf": [{ "type": "null" }, { "$ref": "commun.json#/$defs/identifiant_serveur" }], "description": "Caissier d'ouverture." },
        "operateur_nom": { "type": ["string", "null"], "maxLength": 255 },
        "fond_initial": { "oneOf": [{ "type": "null" }, { "$ref": "commun.json#/$defs/montant" }], "description": "Fond de caisse déclaré à l'ouverture (espèces). null : inconnu du serveur ; le ticket affiche alors « — »." },
        "retours": { "type": "array", "maxItems": 100, "items": { "$ref": "#/$defs/retour_en_ligne" }, "description": "Du plus ancien au plus récent ; les 100 plus récents au plus." },
        "retours_omis": { "type": "integer", "minimum": 0, "description": "Retours en ligne de la session non publiés (au-delà de 100) : le pré-X local est alors partiel." },
        "modifications": { "type": "array", "maxItems": 100, "items": { "$ref": "#/$defs/detail_modification" }, "description": "Facultatif, capacité vente.modification (2.1 lot 11) : tickets modifiés EN LIGNE dans la session (pas ceux d’une opération vente_modification du terminal : il les a déjà), du plus ancien au plus récent, 100 au plus. Clé absente sans la capacité." }
      }
    },
    "retour_en_ligne": {
      "description": "Retour ou annulation saisi en ligne dans la session. Correspondance avec DetailCloture.returns : kind = return|cancellation selon type, sale = vente_numero, at = le, amount = montant, reason = motif, destination, lines = lignes {label = libelle, quantity = quantite, amount = montant} ; remboursements par moyen vers DetailCloture.refunds.",
      "type": "object",
      "required": ["retour_uuid", "type", "vente_numero", "le", "montant", "motif", "destination", "lignes", "remboursements"],
      "additionalProperties": false,
      "properties": {
        "retour_uuid": { "$ref": "commun.json#/$defs/uuid" },
        "type": { "enum": ["retour", "annulation"] },
        "vente_numero": { "type": ["string", "null"], "maxLength": 60 },
        "le": { "oneOf": [{ "type": "null" }, { "$ref": "commun.json#/$defs/horodatage" }] },
        "montant": { "$ref": "commun.json#/$defs/montant" },
        "motif": { "type": "string", "maxLength": 2000 },
        "destination": { "type": "string", "maxLength": 24, "description": "Destination du remboursement au web (cash, credit, original…)." },
        "lignes": {
          "type": "array",
          "maxItems": 200,
          "items": {
            "type": "object",
            "required": ["produit_uuid", "libelle", "conditionnement", "quantite", "prix_unitaire", "montant"],
            "additionalProperties": false,
            "properties": {
              "produit_uuid": { "oneOf": [{ "type": "null" }, { "$ref": "commun.json#/$defs/uuid" }] },
              "libelle": { "type": "string", "maxLength": 300, "description": "Libellé imprimé, déjà formé comme au web (annulation sans lignes propres : « nom (conditionnement) »)." },
              "conditionnement": { "type": ["string", "null"], "maxLength": 120 },
              "quantite": { "$ref": "#/$defs/quantite_texte", "description": "Retour : quantité en unité de base ; annulation sans lignes propres : quantité de la ligne de vente." },
              "prix_unitaire": { "oneOf": [{ "type": "null" }, { "$ref": "commun.json#/$defs/montant_signe" }], "description": "Prix unitaire de la ligne de vente d'origine (par conditionnement)." },
              "montant": { "$ref": "commun.json#/$defs/montant_signe" }
            }
          }
        },
        "remboursements": {
          "type": "array",
          "maxItems": 30,
          "items": {
            "type": "object",
            "required": ["moyen", "montant"],
            "additionalProperties": false,
            "properties": {
              "moyen": { "type": "string", "minLength": 1, "maxLength": 64 },
              "montant": { "$ref": "commun.json#/$defs/montant_signe" }
            }
          }
        }
      }
    },
    "z.journee": {
      "description": "Non critique. Clé « z_journee:<uuid du point de vente> » (ou de la boutique sans point de vente). Journée de caisse au grain du Z journalier du web : un point de vente, tous ses terminaux, sessions d'un registre restaurant exclues. La clôture de la journée (Z journalier officiel) reste au serveur ; le terminal en tire seulement un pré-Z (README §12.4).",
      "type": "object",
      "required": ["point_de_vente_uuid", "point_de_vente_nom", "terminaux", "fuseau", "date_exploitation", "statut", "dernier_z", "sessions_closes", "sessions_omises", "sessions_ouvertes"],
      "additionalProperties": false,
      "properties": {
        "point_de_vente_uuid": { "oneOf": [{ "type": "null" }, { "$ref": "commun.json#/$defs/uuid" }] },
        "point_de_vente_nom": { "type": ["string", "null"], "maxLength": 120 },
        "terminaux": { "type": "array", "maxItems": 100, "uniqueItems": true, "items": { "$ref": "commun.json#/$defs/uuid" }, "description": "Terminaux actifs de cette journée : un terminal lit l'entité qui le contient." },
        "fuseau": { "type": "string", "minLength": 1, "maxLength": 64 },
        "date_exploitation": { "$ref": "commun.json#/$defs/jour", "description": "Date qu'aurait le Z journalier s'il était clôturé maintenant (jour civil de la boutique)." },
        "statut": { "enum": ["ouverte", "close"], "description": "close : aucune session ouverte ni close en attente de Z journalier (le dernier Z est dans dernier_z)." },
        "dernier_z": {
          "oneOf": [
            { "type": "null" },
            {
              "type": "object",
              "required": ["numero", "date_exploitation", "cloture_le"],
              "additionalProperties": false,
              "properties": {
                "numero": { "type": "integer", "minimum": 1 },
                "date_exploitation": { "$ref": "commun.json#/$defs/jour" },
                "cloture_le": { "oneOf": [{ "type": "null" }, { "$ref": "commun.json#/$defs/horodatage" }] }
              }
            }
          ]
        },
        "sessions_closes": { "type": "array", "maxItems": 20, "items": { "$ref": "#/$defs/session_close" }, "description": "Sessions closes en attente de Z journalier, les 20 plus récentes, dans l'ordre de création." },
        "sessions_omises": { "type": "integer", "minimum": 0, "description": "Sessions closes en attente non publiées (au-delà de 20) : le pré-Z local est alors partiel." },
        "sessions_ouvertes": { "type": "array", "maxItems": 100, "items": { "$ref": "#/$defs/session_identite" }, "description": "Sessions encore ouvertes au serveur : signalées au pré-Z, sans montant." }
      }
    },
    "session_identite": {
      "type": "object",
      "required": ["session_uuid", "terminal_uuid", "terminal_nom", "caissier", "operateur_id", "ouverte_le"],
      "additionalProperties": false,
      "properties": {
        "session_uuid": { "$ref": "commun.json#/$defs/uuid" },
        "terminal_uuid": { "oneOf": [{ "type": "null" }, { "$ref": "commun.json#/$defs/uuid" }] },
        "terminal_nom": { "type": "string", "maxLength": 120 },
        "caissier": { "type": "string", "maxLength": 255 },
        "operateur_id": { "oneOf": [{ "type": "null" }, { "$ref": "commun.json#/$defs/identifiant_serveur" }] },
        "ouverte_le": { "oneOf": [{ "type": "null" }, { "$ref": "commun.json#/$defs/horodatage" }] }
      }
    },
    "session_close": {
      "description": "Session close : montants espèces de sa clôture (rectification d'arbitrage comprise, comme le Z journalier) et détail figé avec son Z.",
      "type": "object",
      "required": ["session_uuid", "terminal_uuid", "terminal_nom", "caissier", "operateur_id", "ouverte_le", "close_le", "cloture_uuid", "fond", "theorique", "compte", "ecart", "rectifiee", "detail_recalcule", "detail"],
      "additionalProperties": false,
      "properties": {
        "session_uuid": { "$ref": "commun.json#/$defs/uuid" },
        "terminal_uuid": { "oneOf": [{ "type": "null" }, { "$ref": "commun.json#/$defs/uuid" }] },
        "terminal_nom": { "type": "string", "maxLength": 120 },
        "caissier": { "type": "string", "maxLength": 255 },
        "operateur_id": { "oneOf": [{ "type": "null" }, { "$ref": "commun.json#/$defs/identifiant_serveur" }] },
        "ouverte_le": { "oneOf": [{ "type": "null" }, { "$ref": "commun.json#/$defs/horodatage" }] },
        "close_le": { "oneOf": [{ "type": "null" }, { "$ref": "commun.json#/$defs/horodatage" }] },
        "cloture_uuid": { "oneOf": [{ "type": "null" }, { "$ref": "commun.json#/$defs/uuid" }] },
        "fond": { "$ref": "commun.json#/$defs/montant_signe" },
        "theorique": { "oneOf": [{ "type": "null" }, { "$ref": "commun.json#/$defs/montant_signe" }] },
        "compte": { "oneOf": [{ "type": "null" }, { "$ref": "commun.json#/$defs/montant_signe" }] },
        "ecart": { "oneOf": [{ "type": "null" }, { "$ref": "commun.json#/$defs/montant_signe" }] },
        "rectifiee": { "type": "boolean" },
        "detail_recalcule": { "type": "boolean", "description": "Vrai si la clôture est antérieure au figement du détail (18/11) : le détail est recalculé ; le document porte « Détail par article recalculé… »." },
        "detail": { "$ref": "#/$defs/detail_cloture" }
      }
    },
    "montant_texte": {
      "description": "Montant entier FCFA en chaîne (format du bloc de détail du web, sans borne).",
      "type": "string",
      "pattern": "^-?(0|[1-9][0-9]{0,15})$"
    },
    "quantite_texte": {
      "description": "Quantité en chaîne, six décimales exactement (somme : sans borne de chiffres entiers).",
      "type": "string",
      "pattern": "^-?(0|[1-9][0-9]{0,15})\\.[0-9]{6}$"
    },
    "detail_cloture": {
      "description": "Bloc de détail d'un Z (DetailCloture, version 1 ; IMPRESSION-X-Z.md §5), clés du web. Tiré des ventes validées des sessions (annulées ensuite comprises), hors ventes hors chiffre d'affaires. Le pré-X, le Z détaillé, le Z court et le pré-Z s'en déduisent sans autre calcul.",
      "type": "object",
      "required": ["version", "summary", "payments", "articles", "top", "returns", "refunds", "vat"],
      "additionalProperties": false,
      "properties": {
        "version": { "const": 1 },
        "summary": { "$ref": "#/$defs/detail_synthese" },
        "payments": {
          "type": "array",
          "maxItems": 50,
          "items": {
            "type": "object",
            "required": ["code", "label", "count", "amount"],
            "additionalProperties": false,
            "properties": {
              "code": { "type": "string", "minLength": 1, "maxLength": 64 },
              "label": { "type": "string", "maxLength": 120 },
              "count": { "type": "integer", "minimum": 0 },
              "amount": { "$ref": "#/$defs/montant_texte" }
            }
          }
        },
        "articles": {
          "type": "object",
          "required": ["categories", "totals"],
          "additionalProperties": false,
          "properties": {
            "categories": { "type": "array", "maxItems": 500, "items": { "$ref": "#/$defs/detail_categorie" } },
            "totals": {
              "type": "object",
              "required": ["lines", "quantity", "value", "discount", "amount", "offered_count", "offered_value"],
              "additionalProperties": false,
              "properties": {
                "lines": { "type": "integer", "minimum": 0 },
                "quantity": { "$ref": "#/$defs/quantite_texte" },
                "value": { "$ref": "#/$defs/montant_texte" },
                "discount": { "$ref": "#/$defs/montant_texte" },
                "amount": { "$ref": "#/$defs/montant_texte" },
                "offered_count": { "type": "integer", "minimum": 0 },
                "offered_value": { "$ref": "#/$defs/montant_texte" }
              }
            }
          }
        },
        "top": {
          "type": "array",
          "maxItems": 5,
          "items": {
            "type": "object",
            "required": ["label", "quantity", "amount"],
            "additionalProperties": false,
            "properties": {
              "label": { "type": "string", "maxLength": 400 },
              "quantity": { "$ref": "#/$defs/quantite_texte" },
              "amount": { "$ref": "#/$defs/montant_texte" }
            }
          }
        },
        "returns": { "type": "array", "maxItems": 500, "items": { "$ref": "#/$defs/detail_retour" } },
        "refunds": {
          "type": "array",
          "maxItems": 50,
          "items": {
            "type": "object",
            "required": ["code", "label", "amount"],
            "additionalProperties": false,
            "properties": {
              "code": { "type": "string", "minLength": 1, "maxLength": 64 },
              "label": { "type": "string", "maxLength": 120 },
              "amount": { "$ref": "#/$defs/montant_texte" }
            }
          }
        },
        "vat": {
          "type": "array",
          "maxItems": 20,
          "items": {
            "type": "object",
            "required": ["rate", "base", "vat", "ttc"],
            "additionalProperties": false,
            "properties": {
              "rate": { "type": "string", "pattern": "^(0|[1-9][0-9]{0,2})(\\.[0-9]{1,2})?$", "description": "Taux en pour cent, sans zéros inutiles (« 18 », « 5.5 »)." },
              "base": { "$ref": "#/$defs/montant_texte" },
              "vat": { "$ref": "#/$defs/montant_texte" },
              "ttc": { "$ref": "#/$defs/montant_texte" }
            }
          }
        },
        "cashiers": {
          "description": "Facultatif (rapports du 19/11, absent d’un bloc plus ancien) : paiements par caissier, auteur de la vente, dans l’ordre du premier encaissement.",
          "type": "array",
          "maxItems": 200,
          "items": {
            "type": "object",
            "required": ["label", "methods", "total"],
            "additionalProperties": false,
            "properties": {
              "label": { "type": "string", "maxLength": 190 },
              "methods": {
                "type": "array",
                "maxItems": 50,
                "items": {
                  "type": "object",
                  "required": ["code", "label", "amount"],
                  "additionalProperties": false,
                  "properties": {
                    "code": { "type": "string", "minLength": 1, "maxLength": 64 },
                    "label": { "type": "string", "maxLength": 120 },
                    "amount": { "$ref": "#/$defs/montant_texte" }
                  }
                }
              },
              "total": { "$ref": "#/$defs/montant_texte" }
            }
          }
        },
        "payments_count": { "description": "Facultatif (19/11) : nombre de paiements.", "type": "integer", "minimum": 0 },
        "families": {
          "description": "Facultatif (19/11) : rubrique « Par famille », présente seulement si la boutique a défini des familles de rapport.",
          "type": "array",
          "maxItems": 200,
          "items": {
            "type": "object",
            "required": ["key", "label", "lines", "quantity", "amount"],
            "additionalProperties": false,
            "properties": {
              "key": { "type": "string", "pattern": "^(none|family:[0-9]+)$" },
              "label": { "type": "string", "maxLength": 120 },
              "lines": { "type": "integer", "minimum": 0 },
              "quantity": { "$ref": "#/$defs/quantite_texte" },
              "amount": { "$ref": "#/$defs/montant_texte" }
            }
          }
        },
        "modifications": { "$ref": "#/$defs/detail_modifications", "description": "Facultatif (2.1 lot 11) : rubrique « Tickets modifiés », présente seulement si au moins un ticket des sessions a été modifié après encaissement." },
        "prevente": { "$ref": "#/$defs/detail_prevente", "description": "Facultatif (lot 15, capacité prevente.v1) : rubrique « Prévente », présente seulement si un acompte, un remboursement ou une conversion de prévente touche les sessions." }
      }
    },
    "detail_prevente": {
      "description": "Rubrique « Prévente » du bloc de détail (lot 15) : argent des préventes, séparé des ventes. Les acomptes reçus et les acomptes remboursés passent par le tiroir (par moyen) ; l’acompte imputé à une vente de conversion est le paiement technique `acompte_prevente` de cette vente, sans entrée d’argent.",
      "type": "object",
      "required": ["deposits_count", "deposits", "refunds_count", "refunds", "net", "conversions_count", "conversions_deposits", "cancellations_count", "methods"],
      "additionalProperties": false,
      "properties": {
        "deposits_count": { "type": "integer", "minimum": 0, "description": "Acomptes reçus (préventes créées avec acompte)." },
        "deposits": { "$ref": "#/$defs/montant_texte" },
        "refunds_count": { "type": "integer", "minimum": 0 },
        "refunds": { "$ref": "#/$defs/montant_texte", "description": "Acomptes remboursés (désistements), positif." },
        "net": { "$ref": "#/$defs/montant_texte", "description": "deposits − refunds : argent de prévente resté au tiroir et aux moyens." },
        "conversions_count": { "type": "integer", "minimum": 0, "description": "Préventes converties en vente dans les sessions." },
        "conversions_deposits": { "$ref": "#/$defs/montant_texte", "description": "Acomptes imputés aux ventes de conversion (paiements acompte_prevente)." },
        "cancellations_count": { "type": "integer", "minimum": 0, "description": "Désistements (avec ou sans remboursement)." },
        "methods": {
          "type": "array",
          "maxItems": 50,
          "items": {
            "type": "object",
            "required": ["code", "label", "deposits", "refunds"],
            "additionalProperties": false,
            "properties": {
              "code": { "type": "string", "minLength": 1, "maxLength": 64 },
              "label": { "type": "string", "maxLength": 120 },
              "deposits": { "$ref": "#/$defs/montant_texte" },
              "refunds": { "$ref": "#/$defs/montant_texte" }
            }
          }
        }
      }
    },
    "detail_synthese": {
      "type": "object",
      "required": ["tickets", "revenue", "delivery_fees", "payable", "credit", "average_basket", "lines", "quantity", "gross_value", "line_discounts", "global_discounts", "discounts", "offered_count", "offered_value", "ht", "vat", "returns_count", "returns_amount", "cancellations_count", "cancellations_amount", "net_after_returns"],
      "additionalProperties": false,
      "properties": {
        "tickets": { "type": "integer", "minimum": 0 },
        "revenue": { "$ref": "#/$defs/montant_texte", "description": "CA TTC = somme des net." },
        "delivery_fees": { "$ref": "#/$defs/montant_texte" },
        "payable": { "$ref": "#/$defs/montant_texte", "description": "Montant des ventes = somme des à payer (livraison comprise)." },
        "credit": { "$ref": "#/$defs/montant_texte" },
        "average_basket": { "$ref": "#/$defs/montant_texte", "description": "revenue / tickets, arrondi au franc, demi vers le haut ; 0 sans ticket." },
        "lines": { "type": "integer", "minimum": 0 },
        "quantity": { "$ref": "#/$defs/quantite_texte" },
        "gross_value": { "$ref": "#/$defs/montant_texte" },
        "line_discounts": { "$ref": "#/$defs/montant_texte" },
        "global_discounts": { "$ref": "#/$defs/montant_texte" },
        "discounts": { "$ref": "#/$defs/montant_texte" },
        "offered_count": { "type": "integer", "minimum": 0 },
        "offered_value": { "$ref": "#/$defs/montant_texte" },
        "ht": { "$ref": "#/$defs/montant_texte" },
        "vat": { "$ref": "#/$defs/montant_texte" },
        "returns_count": { "type": "integer", "minimum": 0 },
        "returns_amount": { "$ref": "#/$defs/montant_texte" },
        "cancellations_count": { "type": "integer", "minimum": 0 },
        "cancellations_amount": { "$ref": "#/$defs/montant_texte" },
        "net_after_returns": { "$ref": "#/$defs/montant_texte" }
      }
    },
    "detail_categorie": {
      "description": "Catégorie (triées par nom, « Sans catégorie » en dernier, clé « none »), lignes par article, conditionnement, prix unitaire et offert (montant décroissant, puis quantité décroissante, puis libellé).",
      "type": "object",
      "required": ["key", "label", "rows", "lines", "quantity", "value", "discount", "amount"],
      "additionalProperties": false,
      "properties": {
        "key": { "type": "string", "minLength": 1, "maxLength": 80 },
        "label": { "type": "string", "maxLength": 255 },
        "rows": {
          "type": "array",
          "maxItems": 2000,
          "items": {
            "type": "object",
            "required": ["label", "packaging", "quantity", "unit_price", "value", "discount", "amount", "offered"],
            "additionalProperties": false,
            "properties": {
              "label": { "type": "string", "maxLength": 300 },
              "packaging": { "type": ["string", "null"], "maxLength": 120 },
              "quantity": { "$ref": "#/$defs/quantite_texte" },
              "unit_price": { "$ref": "#/$defs/montant_texte" },
              "value": { "$ref": "#/$defs/montant_texte" },
              "discount": { "$ref": "#/$defs/montant_texte" },
              "amount": { "$ref": "#/$defs/montant_texte" },
              "offered": { "type": "boolean" }
            }
          }
        },
        "lines": { "type": "integer", "minimum": 0 },
        "quantity": { "$ref": "#/$defs/quantite_texte" },
        "value": { "$ref": "#/$defs/montant_texte" },
        "discount": { "$ref": "#/$defs/montant_texte" },
        "amount": { "$ref": "#/$defs/montant_texte" }
      }
    },
    "detail_retour": {
      "type": "object",
      "required": ["kind", "sale", "at", "amount", "reason", "destination", "lines"],
      "additionalProperties": false,
      "properties": {
        "kind": { "enum": ["return", "cancellation"] },
        "sale": { "type": ["string", "null"], "maxLength": 60 },
        "at": { "type": ["string", "null"], "maxLength": 40, "description": "Date de l'opération (pas de la vente), telle qu'imprimée." },
        "amount": { "$ref": "#/$defs/montant_texte" },
        "reason": { "type": "string", "maxLength": 2000 },
        "destination": { "type": "string", "maxLength": 24 },
        "lines": {
          "type": "array",
          "maxItems": 200,
          "items": {
            "type": "object",
            "required": ["label", "quantity", "amount"],
            "additionalProperties": false,
            "properties": {
              "label": { "type": "string", "maxLength": 300 },
              "quantity": { "$ref": "#/$defs/quantite_texte" },
              "amount": { "$ref": "#/$defs/montant_texte" }
            }
          }
        }
      }
    },
    "detail_modifications": {
      "description": "Rubrique « Tickets modifiés » du bloc de détail (2.1 lot 11) : nombre, total des différences, compléments et remboursements (par moyen), et chaque ticket modifié.",
      "type": "object",
      "required": ["count", "difference", "complements", "refunds", "methods", "rows"],
      "additionalProperties": false,
      "properties": {
        "count": { "type": "integer", "minimum": 0 },
        "difference": { "$ref": "#/$defs/montant_texte", "description": "Somme des différences : compléments − remboursements." },
        "complements": { "$ref": "#/$defs/montant_texte" },
        "refunds": { "$ref": "#/$defs/montant_texte", "description": "Somme des remboursements, positive." },
        "methods": {
          "type": "array",
          "maxItems": 50,
          "items": {
            "type": "object",
            "required": ["code", "label", "complements", "refunds"],
            "additionalProperties": false,
            "properties": {
              "code": { "type": "string", "minLength": 1, "maxLength": 64 },
              "label": { "type": "string", "maxLength": 120 },
              "complements": { "$ref": "#/$defs/montant_texte" },
              "refunds": { "$ref": "#/$defs/montant_texte" }
            }
          }
        },
        "rows": { "type": "array", "maxItems": 500, "items": { "$ref": "#/$defs/detail_modification" } }
      }
    },
    "detail_modification": {
      "description": "Ticket modifié après encaissement (2.1 lot 11) : n° d’origine → n° nouveau, articles retirés et ajoutés (quantités, montants), différence et moyen, responsable, caissier, heure, motif.",
      "type": "object",
      "required": ["original", "replacement", "at", "original_amount", "replacement_amount", "difference", "method", "method_label", "approver", "cashier", "reason", "source", "removed", "added"],
      "additionalProperties": false,
      "properties": {
        "original": { "type": "string", "maxLength": 60 },
        "replacement": { "type": "string", "maxLength": 60 },
        "at": { "type": ["string", "null"], "maxLength": 40, "description": "Horodatage ISO 8601 UTC de la modification." },
        "original_amount": { "$ref": "#/$defs/montant_texte" },
        "replacement_amount": { "$ref": "#/$defs/montant_texte" },
        "difference": { "$ref": "#/$defs/montant_texte", "description": "Positive : complément encaissé ; négative : remboursement." },
        "method": { "type": ["string", "null"], "maxLength": 64, "description": "Moyen de règlement de la différence (null : différence nulle)." },
        "method_label": { "type": ["string", "null"], "maxLength": 120 },
        "approver": { "type": "string", "maxLength": 255, "description": "Responsable qui a donné son code." },
        "cashier": { "type": "string", "maxLength": 255 },
        "reason": { "type": ["string", "null"], "maxLength": 2000 },
        "source": { "enum": ["web", "terminal"] },
        "removed": { "$ref": "#/$defs/detail_modification_lignes" },
        "added": { "$ref": "#/$defs/detail_modification_lignes" }
      }
    },
    "detail_modification_lignes": {
      "type": "array",
      "maxItems": 200,
      "items": {
        "type": "object",
        "required": ["label", "packaging", "quantity", "amount"],
        "additionalProperties": false,
        "properties": {
          "label": { "type": "string", "maxLength": 300 },
          "packaging": { "type": ["string", "null"], "maxLength": 120 },
          "quantity": { "$ref": "#/$defs/quantite_texte" },
          "amount": { "$ref": "#/$defs/montant_texte" }
        }
      }
    }
  }
}
''',
  'donnees.json': r'''{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "donnees.json",
  "title": "Données des changements, par type (v2.0). Un type absent de cette liste est « inconnu » pour un client v2.0.",
  "$defs": {
    "produit": {
      "type": "object",
      "required": ["nom", "reference", "categorie", "prix", "stock_illimite", "actif", "vente_locale"],
      "additionalProperties": false,
      "properties": {
        "nom": { "type": "string", "minLength": 1, "maxLength": 200 },
        "reference": { "type": ["string", "null"], "maxLength": 100 },
        "categorie": { "type": ["string", "null"], "maxLength": 120 },
        "prix": { "$ref": "commun.json#/$defs/montant" },
        "stock_illimite": { "type": "boolean" },
        "actif": { "type": "boolean" },
        "vente_locale": { "type": "boolean", "description": "Faux : produit vendable seulement en ligne (variantes, coffrets, lots…) ; le client l'affiche avec ce motif." }
      }
    },
    "conditionnement": {
      "type": "object",
      "required": ["produit_uuid", "nom", "coefficient", "prix", "defaut", "actif"],
      "additionalProperties": false,
      "properties": {
        "produit_uuid": { "$ref": "commun.json#/$defs/uuid" },
        "nom": { "type": "string", "minLength": 1, "maxLength": 120 },
        "coefficient": { "$ref": "commun.json#/$defs/quantite" },
        "prix": { "$ref": "commun.json#/$defs/montant" },
        "defaut": { "type": "boolean" },
        "actif": { "type": "boolean" }
      }
    },
    "code_barre": {
      "type": "object",
      "required": ["code", "produit_uuid", "conditionnement_uuid"],
      "additionalProperties": false,
      "properties": {
        "code": { "type": "string", "minLength": 1, "maxLength": 64 },
        "produit_uuid": { "$ref": "commun.json#/$defs/uuid" },
        "conditionnement_uuid": { "oneOf": [{ "type": "null" }, { "$ref": "commun.json#/$defs/uuid" }] }
      }
    },
    "moyen_paiement": {
      "type": "object",
      "required": ["code", "nom", "especes", "local"],
      "additionalProperties": false,
      "properties": {
        "code": { "$ref": "commun.json#/$defs/code" },
        "nom": { "type": "string", "minLength": 1, "maxLength": 120 },
        "especes": { "type": "boolean" },
        "local": { "type": "boolean", "description": "Admis pour une vente locale (paiements.moyens_locaux)." }
      }
    },
    "operateur": {
      "description": "Opérateur autorisé sur ce terminal. Le PIN n'est transmis que sous forme d'empreinte lente (bcrypt), jamais en clair.",
      "type": "object",
      "required": ["operateur_id", "nom", "pin_empreinte", "droits"],
      "additionalProperties": false,
      "properties": {
        "operateur_id": { "$ref": "commun.json#/$defs/identifiant_serveur" },
        "nom": { "type": "string", "minLength": 1, "maxLength": 120 },
        "pin_empreinte": { "type": ["string", "null"], "maxLength": 100, "description": "null quand la politique demande un PIN : l’opérateur n’a pas défini de PIN ; le refuser avec le motif « PIN non défini », sans compter d’échec." },
        "droits": { "type": "array", "uniqueItems": true, "maxItems": 100, "items": { "$ref": "commun.json#/$defs/code" } }
      }
    },
    "stock.projection": {
      "description": "Projection absolue versionnée pour la clé (produit, ou produit:lot). Jamais un delta.",
      "type": "object",
      "required": ["produit_uuid", "lot_uuid", "quantite"],
      "additionalProperties": false,
      "properties": {
        "produit_uuid": { "$ref": "commun.json#/$defs/uuid" },
        "lot_uuid": { "oneOf": [{ "type": "null" }, { "$ref": "commun.json#/$defs/uuid" }] },
        "quantite": { "$ref": "commun.json#/$defs/quantite_signee" }
      }
    },
    "politique": {
      "description": "Valeur effective calculée par le serveur (03). Le client n'applique aucune logique d'héritage. Clé inconnue critique : restriction, jamais de défaut permissif.",
      "type": "object",
      "required": ["cle_politique", "valeur", "source", "verrouillee"],
      "additionalProperties": false,
      "properties": {
        "cle_politique": { "type": "string", "pattern": "^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)+$" },
        "valeur": { "description": "Valeur JSON (entier, chaîne, booléen, liste ou null) ; jamais de nombre à virgule." },
        "source": { "enum": ["defaut", "entreprise", "boutique", "terminal"] },
        "verrouillee": { "type": "boolean" }
      }
    },
    "boutique": {
      "description": "Révision 2.0.1 (B-REQ-005) : paramètres de calcul de la boutique. Critique : un changement de TVA modifie le total des ventes suivantes ; une vente déjà commise garde la TVA qu'elle a figée.",
      "type": "object",
      "required": ["nom", "devise", "tva_taux", "tva_incluse"],
      "additionalProperties": false,
      "properties": {
        "nom": { "type": "string", "minLength": 1, "maxLength": 200 },
        "devise": { "type": "string", "minLength": 1, "maxLength": 10 },
        "tva_taux": { "$ref": "commun.json#/$defs/taux" },
        "tva_incluse": { "type": "boolean" }
      }
    },
    "autorisation": {
      "type": "object",
      "required": ["vente_locale", "version", "expire_le"],
      "additionalProperties": false,
      "properties": {
        "vente_locale": { "type": "boolean" },
        "version": { "$ref": "commun.json#/$defs/version" },
        "expire_le": { "oneOf": [{ "type": "null" }, { "$ref": "commun.json#/$defs/horodatage" }] }
      }
    },
    "revocation": {
      "description": "Révocation de l'appareil ou de ses droits de vente : bloquer toute nouvelle vente dès application ; conserver la file.",
      "type": "object",
      "required": ["portee", "raison"],
      "additionalProperties": false,
      "properties": {
        "portee": { "enum": ["appareil", "vente_locale", "operateur"] },
        "operateur_id": { "$ref": "commun.json#/$defs/identifiant_serveur" },
        "raison": { "$ref": "commun.json#/$defs/raison" }
      }
    },
    "session": {
      "type": "object",
      "required": ["session_uuid", "ouverte", "ouverte_le", "operateur_id"],
      "additionalProperties": false,
      "properties": {
        "session_uuid": { "$ref": "commun.json#/$defs/uuid" },
        "ouverte": { "type": "boolean" },
        "ouverte_le": { "oneOf": [{ "type": "null" }, { "$ref": "commun.json#/$defs/horodatage" }] },
        "operateur_id": { "oneOf": [{ "type": "null" }, { "$ref": "commun.json#/$defs/identifiant_serveur" }] }
      }
    },
    "operation_etat": {
      "description": "Changement d'état d'une opération du terminal (intégration, arbitrage, résolution) : la résolution revient aux terminaux par le journal.",
      "type": "object",
      "required": ["operation_uuid", "etat", "version_etat", "raison"],
      "additionalProperties": false,
      "properties": {
        "operation_uuid": { "$ref": "commun.json#/$defs/uuid" },
        "etat": { "enum": ["recue", "integree", "a_arbitrer", "resolue", "rejet_protocole"] },
        "version_etat": { "$ref": "commun.json#/$defs/version" },
        "raison": { "oneOf": [{ "type": "null" }, { "$ref": "commun.json#/$defs/raison" }] }
      }
    }
  }
}
''',
  'erreur.json': r'''{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "erreur.json",
  "title": "Erreur de requête entière (v2). Les refus d'une opération isolée passent par son résultat, pas par cette erreur.",
  "type": "object",
  "required": ["erreur"],
  "additionalProperties": false,
  "properties": {
    "erreur": {
      "type": "object",
      "required": ["code", "message"],
      "additionalProperties": false,
      "properties": {
        "code": {
          "enum": [
            "appareil_non_reconnu",
            "appareil_revoque",
            "protocole_non_supporte",
            "politique_refusee",
            "curseur_expire",
            "instantane_expire",
            "requete_invalide",
            "corps_trop_grand",
            "trop_de_requetes",
            "panier_deja_repris",
            "indisponible"
          ]
        },
        "message": { "$ref": "commun.json#/$defs/texte" },
        "reessayer_apres_secondes": { "type": ["integer", "null"], "minimum": 1, "maximum": 86400 },
        "details": { "type": ["object", "null"] }
      }
    }
  }
}
''',
  'etat.json': r'''{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "etat.json",
  "title": "GET /etat : heure serveur, protocole, capacités, autorisation de l'appareil, délais conseillés. Ne vaut pas synchronisation des données.",
  "type": "object",
  "required": ["heure_serveur", "protocole", "capacites_serveur", "fonctions_restreintes", "autorisation", "versions", "delais", "notifications"],
  "additionalProperties": false,
  "properties": {
    "heure_serveur": { "$ref": "commun.json#/$defs/horodatage" },
    "protocole": {
      "type": "object",
      "required": ["courant", "minimum", "maximum"],
      "additionalProperties": false,
      "properties": {
        "courant": { "type": "integer", "minimum": 2, "maximum": 99 },
        "minimum": { "type": "integer", "minimum": 2, "maximum": 99 },
        "maximum": { "type": "integer", "minimum": 2, "maximum": 99 }
      }
    },
    "capacites_serveur": {
      "description": "Capacités que le serveur sait traiter pour cet appareil (intersection avec celles annoncées par le client).",
      "type": "array",
      "uniqueItems": true,
      "maxItems": 100,
      "items": { "$ref": "commun.json#/$defs/code" }
    },
    "fonctions_restreintes": {
      "description": "Fonctions métier que le client ne doit PAS proposer localement, avec motif (capacité absente, politique, version).",
      "type": "array",
      "maxItems": 100,
      "items": {
        "type": "object",
        "required": ["fonction", "raison"],
        "additionalProperties": false,
        "properties": {
          "fonction": { "$ref": "commun.json#/$defs/code" },
          "raison": { "$ref": "commun.json#/$defs/raison" }
        }
      }
    },
    "autorisation": {
      "description": "Autorisation bornée de vente locale. Expirée ou révoquée : aucune nouvelle vente locale ; la file existante reste transmissible.",
      "type": "object",
      "required": ["vente_locale", "version", "expire_le"],
      "additionalProperties": false,
      "properties": {
        "vente_locale": { "type": "boolean" },
        "version": { "$ref": "commun.json#/$defs/version" },
        "expire_le": { "oneOf": [{ "type": "null" }, { "$ref": "commun.json#/$defs/horodatage" }] },
        "raison": { "oneOf": [{ "type": "null" }, { "$ref": "commun.json#/$defs/raison" }] }
      }
    },
    "versions": {
      "type": "object",
      "required": ["politiques", "calcul", "schema_instantane"],
      "additionalProperties": false,
      "properties": {
        "politiques": { "$ref": "commun.json#/$defs/version", "description": "Numéro du journal où les politiques effectives actuelles sont publiées (0 avant la première publication). Ne change qu’à la publication d’une politique, pas à chaque vente ; à renvoyer dans version_politiques_appliquee une fois appliquées." },
        "calcul": { "$ref": "commun.json#/$defs/version" },
        "schema_instantane": { "$ref": "commun.json#/$defs/version" }
      }
    },
    "delais": {
      "type": "object",
      "required": ["changements_secondes", "reprise_max_secondes"],
      "additionalProperties": false,
      "properties": {
        "changements_secondes": { "type": "integer", "minimum": 5, "maximum": 300 },
        "reprise_max_secondes": { "type": "integer", "minimum": 10, "maximum": 300 }
      }
    },
    "notifications": {
      "description": "Canal d'indication « des changements existent ». Sans canal, sondage de /changements selon delais.changements_secondes.",
      "type": "object",
      "required": ["mode"],
      "additionalProperties": false,
      "properties": {
        "mode": { "enum": ["sondage", "sse"] },
        "url": { "type": ["string", "null"], "maxLength": 300 }
      }
    },
    "restaurant": { "$ref": "#/$defs/restaurant" }
  },
  "$defs": {
    "restaurant": {
      "description": "Révision restaurant-1 (RESTAURANT-1 §2.3) : rendu SEULEMENT aux terminaux à qui restaurant.v1 est accordée. Double l’entité restaurant.maitre pour un refus rapide ; en cas de désaccord, la caisse retient le plus restrictif (non maîtresse).",
      "type": "object",
      "required": ["point_de_vente_uuid", "profil", "maitre", "generation", "derniers_numeros"],
      "additionalProperties": false,
      "properties": {
        "point_de_vente_uuid": { "oneOf": [{ "type": "null" }, { "$ref": "commun.json#/$defs/uuid" }] },
        "profil": { "enum": [null, "TABLE_SERVICE", "PRODUCTION"] },
        "maitre": { "type": "boolean", "description": "Vrai si cet appareil ET cette époque sont la caisse maîtresse désignée de son point de vente." },
        "generation": { "$ref": "commun.json#/$defs/version" },
        "derniers_numeros": {
          "description": "Rendu seulement à l’appareil maître : derniers numéros reçus de lui (relecture B, Q1). Toujours null avant le lot R-2.",
          "oneOf": [
            { "type": "null" },
            {
              "type": "object",
              "required": ["commande", "bons"],
              "additionalProperties": false,
              "properties": {
                "commande": { "oneOf": [{ "type": "null" }, { "type": "string", "maxLength": 40 }] },
                "bons": {
                  "description": "Dernier numero_jour reçu par poste. Liste et non carte : le profil SK-SCHEMA-1 n’a que des objets fermés.",
                  "type": "array",
                  "maxItems": 50,
                  "items": {
                    "type": "object",
                    "required": ["poste_uuid", "numero_jour"],
                    "additionalProperties": false,
                    "properties": {
                      "poste_uuid": { "$ref": "commun.json#/$defs/uuid" },
                      "numero_jour": { "type": "string", "maxLength": 30 }
                    }
                  }
                }
              }
            }
          ]
        }
      }
    },
    "reprise": {
      "description": "Déclaration de reprise d’une caisse restaurée (RESTAURANT-1 §2.3) : en-tête X-Caisse-Reprise de GET /etat, en JSON compact ou en base64url de ce JSON. Appareil et époque d’origine de la sauvegarde, dernière séquence qu’elle contient.",
      "type": "object",
      "required": ["appareil_uuid", "epoque", "derniere_sequence"],
      "additionalProperties": false,
      "properties": {
        "appareil_uuid": { "$ref": "commun.json#/$defs/uuid" },
        "epoque": { "type": "integer", "minimum": 1 },
        "derniere_sequence": { "type": "integer", "minimum": 0 }
      }
    }
  }
}
''',
  'instantanes.json': r'''{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "instantanes.json",
  "title": "Bootstrap cohérent : POST /instantanes (manifeste) puis GET /instantanes/{uuid}/pages/{page}.",
  "$defs": {
    "demande": {
      "type": "object",
      "required": ["raison"],
      "additionalProperties": false,
      "properties": {
        "raison": { "enum": ["premier_demarrage", "curseur_expire", "restauration", "reparation"] }
      }
    },
    "manifeste": {
      "description": "Vue du référentiel et des projections à la borne curseur_base. Télécharger toutes les pages en zone temporaire, vérifier les empreintes, puis remplacer la projection centrale ET le curseur dans une seule transaction locale. Ne jamais toucher ventes, paiements en cours, brouillons ni journal local.",
      "type": "object",
      "required": ["uuid", "schema", "curseur_base", "cree_le", "expire_le", "devise", "versions", "pages", "couverture"],
      "additionalProperties": false,
      "properties": {
        "uuid": { "$ref": "commun.json#/$defs/uuid" },
        "schema": { "$ref": "commun.json#/$defs/version" },
        "curseur_base": { "$ref": "commun.json#/$defs/curseur", "description": "Reprendre /changements strictement après ce curseur." },
        "cree_le": { "$ref": "commun.json#/$defs/horodatage" },
        "expire_le": { "$ref": "commun.json#/$defs/horodatage" },
        "devise": { "type": "string", "minLength": 1, "maxLength": 10 },
        "versions": {
          "type": "object",
          "required": ["politiques", "calcul"],
          "additionalProperties": false,
          "properties": {
            "politiques": { "$ref": "commun.json#/$defs/version" },
            "calcul": { "$ref": "commun.json#/$defs/version" }
          }
        },
        "pages": {
          "type": "object",
          "required": ["nombre", "empreintes"],
          "additionalProperties": false,
          "properties": {
            "nombre": { "type": "integer", "minimum": 1, "maximum": 10000 },
            "empreintes": { "type": "array", "minItems": 1, "maxItems": 10000, "items": { "$ref": "commun.json#/$defs/empreinte" } }
          }
        },
        "couverture": {
          "description": "Réconciliation des opérations du terminal, lue dans la MÊME vue que les stocks : integrees = reflétées dans les projections ; recues_non_integrees = preuve reçue, consommation locale à garder.",
          "type": "object",
          "required": ["epoque", "depuis_sequence", "integrees", "recues_non_integrees", "tronque"],
          "additionalProperties": false,
          "properties": {
            "epoque": { "type": "integer", "minimum": 1 },
            "depuis_sequence": { "type": "integer", "minimum": 1 },
            "integrees": { "type": "array", "maxItems": 2000, "uniqueItems": true, "items": { "$ref": "commun.json#/$defs/uuid" } },
            "recues_non_integrees": { "type": "array", "maxItems": 2000, "uniqueItems": true, "items": { "$ref": "commun.json#/$defs/uuid" } },
            "tronque": { "type": "boolean" }
          }
        }
      }
    },
    "page": {
      "description": "Page immuable : la même requête rend exactement les mêmes octets jusqu'à expiration. empreinte = SHA-256 SK-JCS-1 du tableau entites.",
      "type": "object",
      "required": ["instantane_uuid", "page", "entites", "empreinte"],
      "additionalProperties": false,
      "properties": {
        "instantane_uuid": { "$ref": "commun.json#/$defs/uuid" },
        "page": { "type": "integer", "minimum": 1, "maximum": 10000 },
        "entites": { "type": "array", "minItems": 0, "maxItems": 1000, "items": { "$ref": "changements.json#/$defs/changement" } },
        "empreinte": { "$ref": "commun.json#/$defs/empreinte" }
      }
    }
  }
}
''',
  'livre-caisse.json': r'''{
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "$id": "livre-caisse.json",
    "title": "Capacité livre_caisse.v1 (2.1 lot 14) : livre de caisse de la boutique de l'appareil lu en ligne par un opérateur qui a le droit livre_caisse_voir (GET /livre-caisse?du&au&operateur_id[&suite]). Lecture seule : mêmes lignes que le « Livre de caisse journalier » des rapports web, totaux par moyen du « Livre de caisse » du poste web.",
    "$defs": {
        "reponse": {
            "type": "object",
            "required": [
                "boutique_uuid",
                "fuseau",
                "du",
                "au",
                "genere_le",
                "page",
                "sessions",
                "mouvements",
                "totaux_page",
                "totaux_par_moyen"
            ],
            "additionalProperties": false,
            "properties": {
                "boutique_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "fuseau": {
                    "description": "Fuseau de la boutique qui découpe les journées (identique à boutique.regles.fuseau).",
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 64
                },
                "du": {
                    "$ref": "commun.json#/$defs/jour"
                },
                "au": {
                    "$ref": "commun.json#/$defs/jour"
                },
                "genere_le": {
                    "$ref": "commun.json#/$defs/horodatage",
                    "description": "Heure serveur de la lecture : date de la copie gardée sur le poste (effacée 30 jours plus tard)."
                },
                "page": {
                    "$ref": "#/$defs/page"
                },
                "sessions": {
                    "description": "Sessions ouvertes pendant les journées de la page, toutes caisses de la boutique, dans l'ordre d'ouverture.",
                    "type": "array",
                    "maxItems": 5000,
                    "items": {
                        "$ref": "#/$defs/session"
                    }
                },
                "mouvements": {
                    "description": "Lignes du livre de caisse web des journées de la page, dans son ordre : par session, ouverture, flux espèces, autres moyens, clôture.",
                    "type": "array",
                    "maxItems": 20000,
                    "items": {
                        "$ref": "#/$defs/mouvement"
                    }
                },
                "totaux_page": {
                    "$ref": "#/$defs/totaux_mouvements"
                },
                "totaux_par_moyen": {
                    "$ref": "#/$defs/totaux_par_moyen"
                }
            }
        },
        "page": {
            "description": "Journées entières : une page s'arrête après la journée qui porte le total à 1000 mouvements ou plus. suite = jour à redemander (paramètre suite), null à la dernière page.",
            "type": "object",
            "required": [
                "du",
                "au",
                "suite"
            ],
            "additionalProperties": false,
            "properties": {
                "du": {
                    "$ref": "commun.json#/$defs/jour"
                },
                "au": {
                    "$ref": "commun.json#/$defs/jour"
                },
                "suite": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/jour"
                        }
                    ]
                }
            }
        },
        "session": {
            "type": "object",
            "required": [
                "session_uuid",
                "jour",
                "terminal_uuid",
                "terminal_nom",
                "operateur_id",
                "operateur_nom",
                "ouverte_le",
                "close_le",
                "statut",
                "fond_initial"
            ],
            "additionalProperties": false,
            "properties": {
                "session_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "jour": {
                    "$ref": "commun.json#/$defs/jour",
                    "description": "Journée d'ouverture au calendrier de la boutique."
                },
                "terminal_uuid": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ]
                },
                "terminal_nom": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 120
                },
                "operateur_id": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/identifiant_serveur"
                        }
                    ]
                },
                "operateur_nom": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 120
                },
                "ouverte_le": {
                    "$ref": "commun.json#/$defs/horodatage"
                },
                "close_le": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/horodatage"
                        }
                    ]
                },
                "statut": {
                    "enum": [
                        "ouverte",
                        "close"
                    ]
                },
                "fond_initial": {
                    "$ref": "commun.json#/$defs/montant"
                }
            }
        },
        "mouvement": {
            "description": "Une ligne du livre de caisse web (colonnes Date, Session, Caisse, Opération, Moyen, Entrée espèces, Sortie espèces, Autres moyens (signé, hors tiroir), Attendu appliqué, Compté, Écart). Entrées moins sorties d'une session = attendu complet ; attendu, compté et écart ne figurent que sur la ligne de clôture.",
            "type": "object",
            "required": [
                "jour",
                "date",
                "session_uuid",
                "terminal",
                "nature",
                "moyen",
                "entree_especes",
                "sortie_especes",
                "autres",
                "attendu",
                "compte",
                "ecart"
            ],
            "additionalProperties": false,
            "properties": {
                "jour": {
                    "$ref": "commun.json#/$defs/jour",
                    "description": "Journée du livre web qui porte la ligne (journée d'ouverture de la session)."
                },
                "date": {
                    "$ref": "commun.json#/$defs/horodatage",
                    "description": "Ouverture de la session, ou heure de la clôture pour la ligne de clôture."
                },
                "session_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "terminal": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 120
                },
                "nature": {
                    "description": "Libellé du web, tel quel (Ouverture de session (fond de caisse), Ventes encaissées, Remboursements de retours et annulations, Apports de caisse, Retraits de caisse, Dépenses payées, Restitutions de dépenses, Règlements clients, Dépôts sur compte client, Retraits de compte client, Paiements fournisseurs, Remboursements fournisseurs reçus, Clôture (mode …), Session ouverte : aucune clôture archivée ; mention « — rectifiée » possible).",
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 300
                },
                "moyen": {
                    "description": "Nom du moyen (Espèces, Mobile money…), ou « — » pour une session sans clôture.",
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 120
                },
                "entree_especes": {
                    "$ref": "commun.json#/$defs/montant_signe"
                },
                "sortie_especes": {
                    "$ref": "commun.json#/$defs/montant_signe"
                },
                "autres": {
                    "$ref": "commun.json#/$defs/montant_signe",
                    "description": "Autres moyens, informatif : positif encaissé, négatif remboursé ; n'entre pas dans le tiroir."
                },
                "attendu": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/montant_signe"
                        }
                    ]
                },
                "compte": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/montant_signe"
                        }
                    ]
                },
                "ecart": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/montant_signe"
                        }
                    ]
                }
            }
        },
        "totaux_mouvements": {
            "description": "Sommes des colonnes additionnées par le web (entrées, sorties, autres) sur les mouvements de la page. La somme des pages = totaux du livre web de la période.",
            "type": "object",
            "required": [
                "entree_especes",
                "sortie_especes",
                "autres"
            ],
            "additionalProperties": false,
            "properties": {
                "entree_especes": {
                    "$ref": "commun.json#/$defs/montant_signe"
                },
                "sortie_especes": {
                    "$ref": "commun.json#/$defs/montant_signe"
                },
                "autres": {
                    "$ref": "commun.json#/$defs/montant_signe"
                }
            }
        },
        "totaux_par_moyen": {
            "description": "Livre de caisse du poste web sur toute la période (du..au), tous caissiers, identique à chaque page : ventes au chiffre d'affaires datées de la vente, remboursements et annulations à leur propre date.",
            "type": "object",
            "required": [
                "ventes_nombre",
                "ventes_montant",
                "credit",
                "annulations_nombre",
                "annulations_montant",
                "moyens",
                "encaisse",
                "rembourse",
                "net"
            ],
            "additionalProperties": false,
            "properties": {
                "ventes_nombre": {
                    "type": "integer",
                    "minimum": 0
                },
                "ventes_montant": {
                    "$ref": "commun.json#/$defs/montant_signe"
                },
                "credit": {
                    "$ref": "commun.json#/$defs/montant_signe",
                    "description": "Part à crédit des ventes (reste à payer)."
                },
                "annulations_nombre": {
                    "type": "integer",
                    "minimum": 0
                },
                "annulations_montant": {
                    "$ref": "commun.json#/$defs/montant_signe"
                },
                "moyens": {
                    "type": "array",
                    "maxItems": 100,
                    "items": {
                        "$ref": "#/$defs/moyen"
                    }
                },
                "encaisse": {
                    "$ref": "commun.json#/$defs/montant_signe"
                },
                "rembourse": {
                    "$ref": "commun.json#/$defs/montant_signe"
                },
                "net": {
                    "$ref": "commun.json#/$defs/montant_signe"
                }
            }
        },
        "moyen": {
            "type": "object",
            "required": [
                "moyen",
                "encaisse",
                "rembourse",
                "net"
            ],
            "additionalProperties": false,
            "properties": {
                "moyen": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 120
                },
                "encaisse": {
                    "$ref": "commun.json#/$defs/montant_signe"
                },
                "rembourse": {
                    "$ref": "commun.json#/$defs/montant_signe"
                },
                "net": {
                    "$ref": "commun.json#/$defs/montant_signe"
                }
            }
        }
    }
}
''',
  'operation.json': r'''{
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "$id": "operation.json",
    "title": "Opération v2 émise par un terminal. Chaque opération est validée seule : une opération invalide n'empêche pas les autres du lot.",
    "description": "L'empreinte couvre l'opération entière sauf le champ empreinte (SK-JCS-1). Même UUID et même empreinte : renvoi identique. Même UUID, autre empreinte : conflit, l'original reste intact.",
    "oneOf": [
        {
            "$ref": "#/$defs/vente"
        },
        {
            "$ref": "#/$defs/ouverture_session"
        },
        {
            "$ref": "#/$defs/creation_client"
        },
        {
            "$ref": "#/$defs/cloture_session"
        },
        {
            "$ref": "#/$defs/panier_suspendre"
        },
        {
            "$ref": "#/$defs/panier_supprimer"
        },
        {
            "$ref": "#/$defs/retour"
        },
        {
            "$ref": "#/$defs/resto_commande"
        },
        {
            "$ref": "#/$defs/resto_bons_etats"
        },
        {
            "$ref": "#/$defs/resto_registre_ouvre"
        },
        {
            "$ref": "#/$defs/resto_registre_clos"
        },
        {
            "$ref": "#/$defs/resto_remboursement"
        },
        {
            "$ref": "#/$defs/edition_pre_x"
        },
        {
            "$ref": "#/$defs/edition_pre_z"
        },
        {
            "$ref": "#/$defs/creation_produit"
        },
        {
            "$ref": "#/$defs/modification_produit"
        },
        {
            "$ref": "#/$defs/vente_modification"
        },
        {
            "$ref": "#/$defs/cloture_journee"
        },
        {
            "$ref": "#/$defs/prevente_creer"
        },
        {
            "$ref": "#/$defs/prevente_modifier"
        },
        {
            "$ref": "#/$defs/prevente_convertir"
        },
        {
            "$ref": "#/$defs/prevente_annuler"
        },
        {
            "$ref": "#/$defs/transfert_especes"
        },
        {
            "$ref": "#/$defs/creation_categorie"
        },
        {
            "$ref": "#/$defs/creation_fournisseur"
        }
    ],
    "$defs": {
        "appareil": {
            "type": "object",
            "required": [
                "uuid",
                "epoque"
            ],
            "additionalProperties": false,
            "properties": {
                "uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "epoque": {
                    "type": "integer",
                    "minimum": 1
                }
            }
        },
        "versions": {
            "description": "Versions des règles réellement appliquées au calcul de l'opération.",
            "type": "object",
            "required": [
                "politiques",
                "calcul",
                "curseur_catalogue"
            ],
            "additionalProperties": false,
            "properties": {
                "politiques": {
                    "$ref": "commun.json#/$defs/version"
                },
                "calcul": {
                    "$ref": "commun.json#/$defs/version"
                },
                "curseur_catalogue": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/curseur"
                        }
                    ]
                }
            }
        },
        "sequence": {
            "type": "integer",
            "minimum": 1,
            "maximum": 2147483647
        },
        "vente": {
            "type": "object",
            "required": [
                "uuid",
                "type",
                "appareil",
                "sequence",
                "cree_le",
                "operateur_id",
                "versions",
                "empreinte",
                "contenu"
            ],
            "additionalProperties": false,
            "properties": {
                "uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "type": {
                    "const": "vente"
                },
                "appareil": {
                    "$ref": "#/$defs/appareil"
                },
                "sequence": {
                    "$ref": "#/$defs/sequence"
                },
                "cree_le": {
                    "$ref": "commun.json#/$defs/horodatage",
                    "description": "Heure du terminal, informative ; l'heure de réception serveur est tenue à part."
                },
                "operateur_id": {
                    "$ref": "commun.json#/$defs/identifiant_serveur"
                },
                "versions": {
                    "$ref": "#/$defs/versions"
                },
                "empreinte": {
                    "$ref": "commun.json#/$defs/empreinte"
                },
                "contenu": {
                    "$ref": "#/$defs/contenu_vente"
                }
            }
        },
        "contenu_vente": {
            "type": "object",
            "required": [
                "numero_local",
                "brouillon_uuid",
                "session_uuid",
                "client_uuid",
                "tva",
                "lignes",
                "remise_globale",
                "livraison",
                "totaux",
                "paiements",
                "mouvements",
                "autorisations"
            ],
            "additionalProperties": false,
            "properties": {
                "numero_local": {
                    "type": "string",
                    "pattern": "^[A-Z0-9][A-Z0-9-]{0,29}$"
                },
                "brouillon_uuid": {
                    "$ref": "commun.json#/$defs/uuid",
                    "description": "Brouillon consommé : une seule vente par brouillon."
                },
                "session_uuid": {
                    "$ref": "commun.json#/$defs/uuid",
                    "description": "Session serveur connue, ou UUID de l'opération ouverture_session locale dont la vente dépend."
                },
                "client_uuid": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ]
                },
                "tva": {
                    "type": "object",
                    "required": [
                        "taux",
                        "incluse"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "taux": {
                            "$ref": "commun.json#/$defs/taux"
                        },
                        "incluse": {
                            "type": "boolean"
                        }
                    }
                },
                "lignes": {
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 200,
                    "items": {
                        "$ref": "#/$defs/ligne"
                    }
                },
                "remise_globale": {
                    "$ref": "commun.json#/$defs/montant"
                },
                "livraison": {
                    "$ref": "commun.json#/$defs/montant"
                },
                "totaux": {
                    "type": "object",
                    "required": [
                        "brut",
                        "remises",
                        "base_ht",
                        "tva",
                        "a_payer"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "brut": {
                            "$ref": "commun.json#/$defs/montant"
                        },
                        "remises": {
                            "$ref": "commun.json#/$defs/montant"
                        },
                        "base_ht": {
                            "$ref": "commun.json#/$defs/montant"
                        },
                        "tva": {
                            "$ref": "commun.json#/$defs/montant"
                        },
                        "a_payer": {
                            "$ref": "commun.json#/$defs/montant"
                        }
                    }
                },
                "paiements": {
                    "type": "array",
                    "minItems": 0,
                    "maxItems": 20,
                    "items": {
                        "$ref": "#/$defs/paiement"
                    },
                    "description": "Au moins un paiement dès que a_payer > 0 (recoupé par le serveur) ; aucun pour une vente à 0 F. Le serveur l’applique au règlement d’une commande de la caisse maîtresse (`commande`, lot R-5 : commande entièrement offerte) ; les autres ventes gardent au moins un paiement."
                },
                "mouvements": {
                    "type": "array",
                    "minItems": 0,
                    "maxItems": 400,
                    "items": {
                        "$ref": "#/$defs/mouvement"
                    }
                },
                "autorisations": {
                    "type": "array",
                    "minItems": 0,
                    "maxItems": 10,
                    "items": {
                        "$ref": "#/$defs/autorisation"
                    }
                },
                "remise_globale_saisie": {
                    "description": "Révision 2.1 : remise telle que saisie ; le montant (remise) en découle selon boutique.regles.remise_pourcentage_arrondi (pourcentage) ou lui est égal (montant).",
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "type": "object",
                            "required": [
                                "type",
                                "valeur"
                            ],
                            "additionalProperties": false,
                            "properties": {
                                "type": {
                                    "enum": [
                                        "montant",
                                        "pourcentage"
                                    ]
                                },
                                "valeur": {
                                    "type": "string",
                                    "pattern": "^[0-9]{1,19}(\\.[0-9]{1,2})?$"
                                }
                            }
                        }
                    ]
                },
                "note": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 2000,
                    "description": "Révision 2.1 : note du ticket (commentaire de la vente)."
                },
                "tarif": {
                    "enum": [
                        "detail",
                        "gros",
                        "gros_quantite"
                    ],
                    "description": "Révision 2.1 : gros = bascule manuelle du panier (droit boutique.regles.gros.droit) ; gros_quantite = seuil atteint sur au moins une ligne."
                },
                "client_nom": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 200
                },
                "panier_uuid": {
                    "description": "Panier consommé par la vente. Inconnu du serveur (jamais publié) : accepté sans arbitrage.",
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ]
                },
                "passages": {
                    "description": "Capacité passes.evenement (2.1 lot 8) : un passage par pass, obligatoire dès qu'un paiement est de moyen pass_evenement (aucun autre moyen dans la même vente) ; Σ montant = totaux.a_payer. hors_chiffre_affaires n'est pas envoyé : le serveur l'applique selon pass_reglages. Pass inconnu, produit hors du service ou des menus, paiement pass sans passages : a_arbitrer. Règle non conforme au serveur (quota pris par un autre terminal, révoqué entre-temps, hors fenêtre) : vente intégrée, passage en écart.",
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 20,
                    "items": {
                        "$ref": "#/$defs/passage"
                    }
                },
                "commande": {
                    "$ref": "#/$defs/commande_vente"
                },
                "prevente_uuid": {
                    "$ref": "commun.json#/$defs/uuid",
                    "description": "Lot 15 (capacité prevente.v1) : vente qui convertit cette prévente. Elle porte alors un paiement `acompte_prevente` égal à l’acompte (aucun si acompte = 0) ; le reste par les moyens ordinaires. Moyen technique : aucune entrée d’argent au tiroir (l’acompte a été compté à sa réception)."
                }
            }
        },
        "ligne": {
            "description": "Ligne figée au moment de la vente : libellé, conversion et prix ne sont jamais relus d'un catalogue modifié depuis.",
            "type": "object",
            "required": [
                "ligne_uuid",
                "produit_uuid",
                "conditionnement_uuid",
                "libelle",
                "quantite",
                "coefficient",
                "quantite_base",
                "prix_unitaire",
                "remise",
                "total",
                "revision_prix"
            ],
            "additionalProperties": false,
            "properties": {
                "ligne_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "produit_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "conditionnement_uuid": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ]
                },
                "libelle": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 200
                },
                "quantite": {
                    "$ref": "commun.json#/$defs/quantite"
                },
                "coefficient": {
                    "$ref": "commun.json#/$defs/quantite",
                    "description": "Unités de base par unité vendue (1.000000 sans conditionnement)."
                },
                "quantite_base": {
                    "$ref": "commun.json#/$defs/quantite"
                },
                "prix_unitaire": {
                    "$ref": "commun.json#/$defs/montant"
                },
                "remise": {
                    "$ref": "commun.json#/$defs/montant"
                },
                "total": {
                    "$ref": "commun.json#/$defs/montant"
                },
                "revision_prix": {
                    "$ref": "commun.json#/$defs/version"
                },
                "remise_saisie": {
                    "description": "Révision 2.1 : remise telle que saisie ; le montant (remise) en découle selon boutique.regles.remise_pourcentage_arrondi (pourcentage) ou lui est égal (montant).",
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "type": "object",
                            "required": [
                                "type",
                                "valeur"
                            ],
                            "additionalProperties": false,
                            "properties": {
                                "type": {
                                    "enum": [
                                        "montant",
                                        "pourcentage"
                                    ]
                                },
                                "valeur": {
                                    "type": "string",
                                    "pattern": "^[0-9]{1,19}(\\.[0-9]{1,2})?$"
                                }
                            }
                        }
                    ]
                },
                "tarif": {
                    "enum": [
                        "detail",
                        "gros"
                    ],
                    "description": "Révision 2.1 : prix appliqué (gros = prix_gros du produit ou du conditionnement)."
                },
                "lot_uuid": {
                    "$ref": "commun.json#/$defs/uuid",
                    "description": "Capacité lots.vente : lot vendu, obligatoire pour un produit à lots. Une ligne par lot."
                }
            }
        },
        "paiement": {
            "type": "object",
            "required": [
                "tentative_uuid",
                "moyen",
                "montant",
                "recu",
                "reference"
            ],
            "additionalProperties": false,
            "properties": {
                "tentative_uuid": {
                    "$ref": "commun.json#/$defs/uuid",
                    "description": "Tentative de paiement ; stable entre renvois, distincte des tentatives réseau."
                },
                "moyen": {
                    "$ref": "commun.json#/$defs/code"
                },
                "montant": {
                    "$ref": "commun.json#/$defs/montant"
                },
                "recu": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/montant"
                        }
                    ],
                    "description": "Espèces seulement : somme remise par le client."
                },
                "reference": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 120
                },
                "monnaie": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/montant"
                        }
                    ],
                    "description": "Révision 2.1 (versions.calcul = \"2\") : monnaie rendue sur cette ligne d'espèces."
                },
                "ecart_arrondi": {
                    "type": [
                        "integer",
                        "null"
                    ],
                    "minimum": -1000000,
                    "maximum": 1000000,
                    "description": "Révision 2.1 : arrondi de caisse des espèces = montant encaissé au tiroir − montant (exact). montant reste la part exacte de la vente ; écart = arrondi_especes appliqué au montant − montant."
                }
            }
        },
        "passage": {
            "description": "Passage débité sur un pass (capacité passes.evenement). Idempotent par uuid : l'uuid du terminal devient celui du passage au serveur.",
            "type": "object",
            "required": [
                "uuid",
                "pass_uuid",
                "jour",
                "montant",
                "point_passage",
                "point_consommation",
                "table_uuid",
                "verifie_en_ligne"
            ],
            "additionalProperties": false,
            "properties": {
                "uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "pass_uuid": {
                    "$ref": "commun.json#/$defs/uuid",
                    "description": "Clé de l'entité pass publiée. Jamais le code en clair."
                },
                "jour": {
                    "$ref": "commun.json#/$defs/jour",
                    "description": "Jour civil du passage dans le fuseau publié de la boutique (même règle que date_metier)."
                },
                "montant": {
                    "$ref": "commun.json#/$defs/montant"
                },
                "point_passage": {
                    "description": "Poste de scan ; vide : réglage de la boutique, sinon « Caisse ».",
                    "type": "string",
                    "maxLength": 60
                },
                "point_consommation": {
                    "description": "Nom de la table, sinon le point de passage ; null : le serveur reprend la table ou le point de passage.",
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 160
                },
                "table_uuid": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ]
                },
                "verifie_en_ligne": {
                    "description": "Vrai si POST /passes/verifier a autorisé ce passage juste avant (information, sans effet sur l'autorité du serveur).",
                    "type": "boolean"
                }
            }
        },
        "mouvement": {
            "description": "Mouvement de stock local identifié : la couverture par le serveur se suit mouvement par mouvement.",
            "type": "object",
            "required": [
                "mouvement_uuid",
                "produit_uuid",
                "lot_uuid",
                "variation"
            ],
            "additionalProperties": false,
            "properties": {
                "mouvement_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "produit_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "lot_uuid": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ]
                },
                "variation": {
                    "$ref": "commun.json#/$defs/quantite_signee"
                }
            }
        },
        "autorisation": {
            "type": "object",
            "required": [
                "type",
                "approbateur_id",
                "motif",
                "preuve"
            ],
            "additionalProperties": false,
            "properties": {
                "type": {
                    "enum": [
                        "remise",
                        "survente",
                        "prix_manuel"
                    ]
                },
                "approbateur_id": {
                    "$ref": "commun.json#/$defs/identifiant_serveur"
                },
                "motif": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 500
                },
                "preuve": {
                    "type": "string",
                    "maxLength": 500,
                    "description": "Preuve locale de l'autorisation (jamais un PIN ni son empreinte)."
                }
            }
        },
        "ouverture_session": {
            "type": "object",
            "required": [
                "uuid",
                "type",
                "appareil",
                "sequence",
                "cree_le",
                "operateur_id",
                "versions",
                "empreinte",
                "contenu"
            ],
            "additionalProperties": false,
            "properties": {
                "uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "type": {
                    "const": "ouverture_session"
                },
                "appareil": {
                    "$ref": "#/$defs/appareil"
                },
                "sequence": {
                    "$ref": "#/$defs/sequence"
                },
                "cree_le": {
                    "$ref": "commun.json#/$defs/horodatage"
                },
                "operateur_id": {
                    "$ref": "commun.json#/$defs/identifiant_serveur"
                },
                "versions": {
                    "$ref": "#/$defs/versions"
                },
                "empreinte": {
                    "$ref": "commun.json#/$defs/empreinte"
                },
                "contenu": {
                    "type": "object",
                    "required": [
                        "fond"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "fond": {
                            "$ref": "commun.json#/$defs/montant"
                        }
                    }
                }
            }
        },
        "creation_client": {
            "type": "object",
            "required": [
                "uuid",
                "type",
                "appareil",
                "sequence",
                "cree_le",
                "operateur_id",
                "versions",
                "empreinte",
                "contenu"
            ],
            "additionalProperties": false,
            "properties": {
                "uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "type": {
                    "const": "creation_client"
                },
                "appareil": {
                    "$ref": "#/$defs/appareil"
                },
                "sequence": {
                    "$ref": "#/$defs/sequence"
                },
                "cree_le": {
                    "$ref": "commun.json#/$defs/horodatage"
                },
                "operateur_id": {
                    "$ref": "commun.json#/$defs/identifiant_serveur"
                },
                "versions": {
                    "$ref": "#/$defs/versions"
                },
                "empreinte": {
                    "$ref": "commun.json#/$defs/empreinte"
                },
                "contenu": {
                    "type": "object",
                    "required": [
                        "client_uuid",
                        "nom",
                        "telephone",
                        "type"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "client_uuid": {
                            "$ref": "commun.json#/$defs/uuid",
                            "description": "UUID v4 choisi par le terminal."
                        },
                        "nom": {
                            "type": "string",
                            "minLength": 1,
                            "maxLength": 160
                        },
                        "telephone": {
                            "type": [
                                "string",
                                "null"
                            ],
                            "maxLength": 40,
                            "description": "Tel que saisi ; normalisé par le serveur."
                        },
                        "type": {
                            "enum": [
                                "particulier",
                                "professionnel"
                            ]
                        }
                    }
                }
            },
            "description": "Client créé sur le terminal (REVISION-2.1 §3.2, capacité client.creation). À émettre AVANT toute vente qui cite ce client_uuid."
        },
        "cloture_session": {
            "type": "object",
            "required": [
                "uuid",
                "type",
                "appareil",
                "sequence",
                "cree_le",
                "operateur_id",
                "versions",
                "empreinte",
                "contenu"
            ],
            "additionalProperties": false,
            "properties": {
                "uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "type": {
                    "const": "cloture_session"
                },
                "appareil": {
                    "$ref": "#/$defs/appareil"
                },
                "sequence": {
                    "$ref": "#/$defs/sequence"
                },
                "cree_le": {
                    "$ref": "commun.json#/$defs/horodatage"
                },
                "operateur_id": {
                    "$ref": "commun.json#/$defs/identifiant_serveur"
                },
                "versions": {
                    "$ref": "#/$defs/versions"
                },
                "empreinte": {
                    "$ref": "commun.json#/$defs/empreinte"
                },
                "contenu": {
                    "type": "object",
                    "required": [
                        "session_uuid",
                        "compte",
                        "comptage",
                        "commentaire"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "session_uuid": {
                            "$ref": "commun.json#/$defs/uuid",
                            "description": "Session serveur, ou UUID de l'ouverture_session locale."
                        },
                        "compte": {
                            "$ref": "commun.json#/$defs/montant",
                            "description": "Espèces comptées."
                        },
                        "comptage": {
                            "description": "Moyens autres que les espèces, facultatif.",
                            "oneOf": [
                                {
                                    "type": "null"
                                },
                                {
                                    "type": "array",
                                    "maxItems": 30,
                                    "items": {
                                        "type": "object",
                                        "required": [
                                            "moyen",
                                            "montant",
                                            "justification"
                                        ],
                                        "additionalProperties": false,
                                        "properties": {
                                            "moyen": {
                                                "$ref": "commun.json#/$defs/code"
                                            },
                                            "montant": {
                                                "$ref": "commun.json#/$defs/montant"
                                            },
                                            "justification": {
                                                "type": [
                                                    "string",
                                                    "null"
                                                ],
                                                "maxLength": 500
                                            }
                                        }
                                    }
                                }
                            ]
                        },
                        "commentaire": {
                            "type": [
                                "string",
                                "null"
                            ],
                            "maxLength": 500,
                            "description": "Obligatoire si le compté diffère de l'attendu : sinon a_arbitrer."
                        },
                        "detail": {
                            "description": "Lot Z local (README §12), facultatif : bloc de détail que le terminal a imprimé sur son Z de session (DetailCloture, version 1). Absent ou null : le serveur calcule le sien. Conservé tel quel pour le duplicata ; comparé au calcul du serveur, écart noté, jamais refusé.",
                            "oneOf": [
                                {
                                    "type": "null"
                                },
                                {
                                    "$ref": "donnees-z-local-1.json#/$defs/detail_cloture"
                                }
                            ]
                        }
                    }
                }
            },
            "description": "Clôture de la session du terminal, comptée à l'aveugle (REVISION-2.1 §3.3, capacité session.cloture). L'opérateur doit détenir caisse_cloturer. Lot Z local : champ facultatif contenu.detail."
        },
        "panier_suspendre": {
            "type": "object",
            "required": [
                "uuid",
                "type",
                "appareil",
                "sequence",
                "cree_le",
                "operateur_id",
                "versions",
                "empreinte",
                "contenu"
            ],
            "additionalProperties": false,
            "properties": {
                "uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "type": {
                    "const": "panier_suspendre"
                },
                "appareil": {
                    "$ref": "#/$defs/appareil"
                },
                "sequence": {
                    "$ref": "#/$defs/sequence"
                },
                "cree_le": {
                    "$ref": "commun.json#/$defs/horodatage"
                },
                "operateur_id": {
                    "$ref": "commun.json#/$defs/identifiant_serveur"
                },
                "versions": {
                    "$ref": "#/$defs/versions"
                },
                "empreinte": {
                    "$ref": "commun.json#/$defs/empreinte"
                },
                "contenu": {
                    "type": "object",
                    "required": [
                        "panier_uuid",
                        "libelle",
                        "remplace_uuid",
                        "contenu"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "panier_uuid": {
                            "$ref": "commun.json#/$defs/uuid"
                        },
                        "libelle": {
                            "type": "string",
                            "minLength": 1,
                            "maxLength": 150
                        },
                        "remplace_uuid": {
                            "oneOf": [
                                {
                                    "type": "null"
                                },
                                {
                                    "$ref": "commun.json#/$defs/uuid"
                                }
                            ]
                        },
                        "contenu": {
                            "type": "object",
                            "required": [
                                "lignes",
                                "client_uuid",
                                "remise_globale",
                                "livraison",
                                "note",
                                "tarif"
                            ],
                            "additionalProperties": false,
                            "properties": {
                                "lignes": {
                                    "type": "array",
                                    "minItems": 1,
                                    "maxItems": 100,
                                    "items": {
                                        "type": "object",
                                        "required": [
                                            "produit_uuid",
                                            "conditionnement_uuid",
                                            "quantite",
                                            "remise"
                                        ],
                                        "additionalProperties": false,
                                        "properties": {
                                            "produit_uuid": {
                                                "$ref": "commun.json#/$defs/uuid"
                                            },
                                            "conditionnement_uuid": {
                                                "oneOf": [
                                                    {
                                                        "type": "null"
                                                    },
                                                    {
                                                        "$ref": "commun.json#/$defs/uuid"
                                                    }
                                                ]
                                            },
                                            "quantite": {
                                                "type": "string"
                                            },
                                            "remise": {
                                                "$ref": "commun.json#/$defs/montant"
                                            }
                                        }
                                    }
                                },
                                "client_uuid": {
                                    "oneOf": [
                                        {
                                            "type": "null"
                                        },
                                        {
                                            "$ref": "commun.json#/$defs/uuid"
                                        }
                                    ]
                                },
                                "remise_globale": {
                                    "$ref": "commun.json#/$defs/montant"
                                },
                                "livraison": {
                                    "$ref": "commun.json#/$defs/montant"
                                },
                                "note": {
                                    "type": [
                                        "string",
                                        "null"
                                    ],
                                    "maxLength": 2000
                                },
                                "tarif": {
                                    "enum": [
                                        "detail",
                                        "gros"
                                    ]
                                }
                            }
                        }
                    }
                }
            },
            "description": "Panier mis en attente, admis hors ligne (capacité panier.partage). Un panier publié est immuable : suspendre de nouveau un panier repris émet un NOUVEAU panier_uuid avec remplace_uuid."
        },
        "panier_supprimer": {
            "type": "object",
            "required": [
                "uuid",
                "type",
                "appareil",
                "sequence",
                "cree_le",
                "operateur_id",
                "versions",
                "empreinte",
                "contenu"
            ],
            "additionalProperties": false,
            "properties": {
                "uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "type": {
                    "const": "panier_supprimer"
                },
                "appareil": {
                    "$ref": "#/$defs/appareil"
                },
                "sequence": {
                    "$ref": "#/$defs/sequence"
                },
                "cree_le": {
                    "$ref": "commun.json#/$defs/horodatage"
                },
                "operateur_id": {
                    "$ref": "commun.json#/$defs/identifiant_serveur"
                },
                "versions": {
                    "$ref": "#/$defs/versions"
                },
                "empreinte": {
                    "$ref": "commun.json#/$defs/empreinte"
                },
                "contenu": {
                    "type": "object",
                    "required": [
                        "panier_uuid",
                        "motif"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "panier_uuid": {
                            "$ref": "commun.json#/$defs/uuid"
                        },
                        "motif": {
                            "type": "string",
                            "minLength": 1,
                            "maxLength": 500
                        }
                    }
                }
            },
            "description": "Suppression d'un panier en attente ou repris par ce terminal (capacité panier.partage)."
        },
        "retour": {
            "type": "object",
            "required": [
                "uuid",
                "type",
                "appareil",
                "sequence",
                "cree_le",
                "operateur_id",
                "versions",
                "empreinte",
                "contenu"
            ],
            "additionalProperties": false,
            "properties": {
                "uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "type": {
                    "const": "retour"
                },
                "appareil": {
                    "$ref": "#/$defs/appareil"
                },
                "sequence": {
                    "$ref": "#/$defs/sequence"
                },
                "cree_le": {
                    "$ref": "commun.json#/$defs/horodatage"
                },
                "operateur_id": {
                    "$ref": "commun.json#/$defs/identifiant_serveur"
                },
                "versions": {
                    "$ref": "#/$defs/versions"
                },
                "empreinte": {
                    "$ref": "commun.json#/$defs/empreinte"
                },
                "contenu": {
                    "type": "object",
                    "required": [
                        "vente_ref",
                        "lignes",
                        "montant",
                        "remboursement",
                        "motif",
                        "mouvements"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "vente_ref": {
                            "type": "object",
                            "required": [
                                "operation_uuid"
                            ],
                            "additionalProperties": false,
                            "properties": {
                                "operation_uuid": {
                                    "$ref": "commun.json#/$defs/uuid"
                                }
                            }
                        },
                        "lignes": {
                            "type": "array",
                            "minItems": 1,
                            "maxItems": 100,
                            "items": {
                                "type": "object",
                                "required": [
                                    "ligne_uuid",
                                    "quantite"
                                ],
                                "additionalProperties": false,
                                "properties": {
                                    "ligne_uuid": {
                                        "$ref": "commun.json#/$defs/uuid",
                                        "description": "ligne_uuid de la vente."
                                    },
                                    "quantite": {
                                        "type": "string",
                                        "description": "En unité de base (quantite_base de la vente)."
                                    }
                                }
                            }
                        },
                        "montant": {
                            "$ref": "commun.json#/$defs/montant",
                            "description": "Par parts archivées (référentiel §3.13) ; différent du calcul serveur : a_arbitrer."
                        },
                        "remboursement": {
                            "const": "especes"
                        },
                        "motif": {
                            "type": "string",
                            "minLength": 1,
                            "maxLength": 500
                        },
                        "mouvements": {
                            "type": "array",
                            "maxItems": 400,
                            "items": {
                                "$ref": "#/$defs/mouvement"
                            },
                            "description": "Variations positives."
                        }
                    }
                }
            },
            "description": "Retour hors ligne limité (REVISION-2.1 §3.4, capacité retour.especes, politique retours.mode = especes) : espèces, vente émise par ce terminal."
        },
        "commande_vente": {
            "description": "Capacité restaurant.v1 (RESTAURANT-1 §4.6) : la vente règle une commande de la caisse maîtresse. Sans la capacité : rejet_protocole capacite_absente. La vente est intégrée dans tous les cas où elle l'aurait été sans ce champ ; un lien impossible part en arbitrage sur la commande (`restaurant.reglement_incoherent`), jamais la vente. Service de table : un seul règlement `full`. Restaurant (lot R-4) : `full` (tout le reste d'une commande sans règlement), `items` (une partie ; pas sur une commande à remise globale tant qu'elle ne couvre pas tout), `shares` (tout le reste, `parts` obligatoire : montants additionnant celui de la vente, chaque paiement dans une part et une seule). Offerts et remises de la commande sont de confiance pour la vente (ni droit REMISE ni plafond hors ligne).",
            "type": "object",
            "required": [
                "commande_uuid",
                "reglement_uuid",
                "type",
                "lignes",
                "parts",
                "libelle"
            ],
            "additionalProperties": false,
            "properties": {
                "commande_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "reglement_uuid": {
                    "$ref": "commun.json#/$defs/uuid",
                    "description": "Règlement créé par la caisse : restaurant_order_settlements.uuid."
                },
                "type": {
                    "enum": [
                        "full",
                        "items",
                        "shares"
                    ]
                },
                "lignes": {
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 200,
                    "items": {
                        "type": "object",
                        "required": [
                            "ligne_commande_uuid",
                            "ligne_vente_uuid",
                            "quantite"
                        ],
                        "additionalProperties": false,
                        "properties": {
                            "ligne_commande_uuid": {
                                "$ref": "commun.json#/$defs/uuid"
                            },
                            "ligne_vente_uuid": {
                                "$ref": "commun.json#/$defs/uuid"
                            },
                            "quantite": {
                                "$ref": "commun.json#/$defs/quantite"
                            }
                        }
                    }
                },
                "parts": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "type": "array",
                            "minItems": 2,
                            "maxItems": 50,
                            "items": {
                                "type": "object",
                                "required": [
                                    "libelle",
                                    "montant",
                                    "paiements"
                                ],
                                "additionalProperties": false,
                                "properties": {
                                    "libelle": {
                                        "type": "string",
                                        "minLength": 1,
                                        "maxLength": 120
                                    },
                                    "montant": {
                                        "$ref": "commun.json#/$defs/montant"
                                    },
                                    "paiements": {
                                        "description": "Index des paiements de la vente qui composent la part.",
                                        "type": "array",
                                        "minItems": 1,
                                        "maxItems": 20,
                                        "items": {
                                            "type": "integer",
                                            "minimum": 0
                                        }
                                    }
                                }
                            }
                        }
                    ],
                    "description": "Obligatoire (2 parts au moins) pour `shares`, null sinon."
                },
                "libelle": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 120
                }
            }
        },
        "ligne_commande": {
            "description": "Ligne de commande dans l'état résultant. `lignes` contient TOUTES les lignes de la commande, retirées comprises (statut cancelled) : une ligne n'en disparaît jamais. Libellé et prix figés à l'ajout. Lot R-5 : `promotion_uuid` et `personnel_id`, facultatifs au schéma, sont TOUJOURS envoyés par un client R-5 ; leur absence signifie un client R-4 (aucune promotion attendue).",
            "type": "object",
            "required": [
                "ligne_uuid",
                "produit_uuid",
                "conditionnement_uuid",
                "lot_uuid",
                "libelle",
                "quantite",
                "coefficient",
                "prix_unitaire",
                "remise",
                "tarif",
                "statut",
                "poste_uuid",
                "commentaire",
                "parent_ligne_uuid",
                "envoye",
                "reglee"
            ],
            "additionalProperties": false,
            "properties": {
                "ligne_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "produit_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "conditionnement_uuid": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ]
                },
                "lot_uuid": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ]
                },
                "libelle": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 160
                },
                "quantite": {
                    "$ref": "commun.json#/$defs/quantite"
                },
                "coefficient": {
                    "$ref": "commun.json#/$defs/quantite"
                },
                "prix_unitaire": {
                    "$ref": "commun.json#/$defs/montant"
                },
                "remise": {
                    "$ref": "commun.json#/$defs/montant"
                },
                "tarif": {
                    "description": "`free` (offert) et `manual_discount` (remise de ligne) seulement par les faits `offert` et `remise_ligne` (lot R-4). Lot R-5 (profil Restaurant seulement, comme au web) : `promotion` ou `happy_hour` = remise d'une promotion publiée (`restaurant.promotion`, catégorie du même nom) ; `staff` = tarif du personnel (catégorie `staff`, `personnel_id` obligatoire) ; un article acheté d'un « X achetés, Y offerts » reste `standard` avec `promotion_uuid`, son offert lié est `free` avec `parent_ligne_uuid` et le même `promotion_uuid`.",
                    "enum": [
                        "standard",
                        "free",
                        "manual_discount",
                        "promotion",
                        "happy_hour",
                        "staff"
                    ]
                },
                "statut": {
                    "enum": [
                        "pending",
                        "sent",
                        "cancelled"
                    ]
                },
                "poste_uuid": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ]
                },
                "commentaire": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 500
                },
                "parent_ligne_uuid": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ],
                    "description": "Offert lié d'une promotion « X achetés, Y offerts » (lot R-5) : la ligne achetée, dans la même commande. null sinon."
                },
                "envoye": {
                    "$ref": "commun.json#/$defs/quantite",
                    "description": "Quantité nette annoncée aux postes (Σ ajouts − Σ annulations des bons reçus)."
                },
                "reglee": {
                    "$ref": "commun.json#/$defs/quantite",
                    "description": "Quantité réglée. Un réglé supérieur à ce que le serveur connaît est accepté : il attend les ventes."
                },
                "promotion_uuid": {
                    "description": "Lot R-5 : promotion appliquée à la saisie (une promotion par ligne : priorité la plus haute, puis la plus forte remise, à l’heure de la caisse dans le fuseau publié), null sinon. Un offert ou une remise manuelle la retirent. Le serveur recontrôle avec le moteur du web ; un écart de prix suit `price_gap_policy` (`restaurant.prix_ecart` ou noté).",
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ]
                },
                "personnel_id": {
                    "description": "Lot R-5 : employé servi au tarif du personnel (`tarif` = `staff`), membre actif de la boutique ; null sinon. Droit `remise` de l’opérateur ou autorisation `remise`, motif obligatoire.",
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/identifiant_serveur"
                        }
                    ]
                }
            }
        },
        "etat_commande": {
            "description": "État complet de la commande APRÈS le fait (une version par validation de l'opérateur, réponse de B à Q2).",
            "type": "object",
            "required": [
                "profil",
                "numero_local",
                "date_metier",
                "canal",
                "table_uuid",
                "menu_uuid",
                "couverts",
                "serveur_id",
                "client_uuid",
                "client_nom",
                "reference_externe",
                "commentaire",
                "statut",
                "etape",
                "prefactures",
                "remise_globale",
                "lignes",
                "totaux"
            ],
            "additionalProperties": false,
            "properties": {
                "profil": {
                    "enum": [
                        "TABLE_SERVICE",
                        "PRODUCTION"
                    ]
                },
                "numero_local": {
                    "description": "Forme de B (Q1) : préfixe publié normalisé (majuscules, A-Z et 0-9 seulement, 23 caractères au plus), date métier AAAAMMJJ, puis L et 4 à 6 chiffres : PF-20261117-L0012.",
                    "type": "string",
                    "pattern": "^[A-Z0-9]{1,23}-[0-9]{8}-L[0-9]{4,6}$"
                },
                "date_metier": {
                    "$ref": "commun.json#/$defs/jour"
                },
                "canal": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "type": "string",
                            "maxLength": 40
                        }
                    ],
                    "description": "Profil Restaurant (lot R-4) : code d'un canal publié (`restaurant.canal`), obligatoire ; table exigée si le canal `exige_table`, absente sinon. Service de table : null."
                },
                "table_uuid": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ]
                },
                "menu_uuid": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ]
                },
                "couverts": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "type": "integer",
                            "minimum": 1,
                            "maximum": 500
                        }
                    ]
                },
                "serveur_id": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/identifiant_serveur"
                        }
                    ]
                },
                "client_uuid": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ]
                },
                "client_nom": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 160
                },
                "reference_externe": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 80
                },
                "commentaire": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 2000
                },
                "statut": {
                    "enum": [
                        "open",
                        "settled",
                        "cancelled"
                    ]
                },
                "etape": {
                    "enum": [
                        null,
                        "waiting",
                        "bill_printed",
                        "customer_validated",
                        "amended"
                    ],
                    "description": "Règle ServiceStage::next du web sur le type du journal du profil. Ouverture : `waiting` au Service de table, null au Restaurant (la préaddition la passe `bill_printed`)."
                },
                "prefactures": {
                    "type": "integer",
                    "minimum": 0,
                    "maximum": 10000
                },
                "remise_globale": {
                    "$ref": "commun.json#/$defs/montant"
                },
                "lignes": {
                    "type": "array",
                    "maxItems": 200,
                    "items": {
                        "$ref": "#/$defs/ligne_commande"
                    }
                },
                "totaux": {
                    "type": "object",
                    "required": [
                        "brut",
                        "remises",
                        "a_payer",
                        "regle"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "brut": {
                            "$ref": "commun.json#/$defs/montant"
                        },
                        "remises": {
                            "$ref": "commun.json#/$defs/montant"
                        },
                        "a_payer": {
                            "$ref": "commun.json#/$defs/montant"
                        },
                        "regle": {
                            "$ref": "commun.json#/$defs/montant"
                        }
                    }
                },
                "remise_globale_source": {
                    "description": "Lot R-5, facultatif au schéma mais TOUJOURS envoyé par un client R-5 (absent : client R-4, aucune remise client attendue). `customer` : remise du client de la commande (`restaurant.remise_client`), recalculée à chaque fait sur le montant après remises de ligne (arrondi vers le bas) tant qu'aucune remise manuelle ni aucun règlement ne l'a figée ; `manual` : posée par le fait `remise` (y compris son retrait d'une remise client, comme au web) ; null : aucune.",
                    "enum": [
                        null,
                        "manual",
                        "customer"
                    ]
                }
            }
        },
        "bon": {
            "description": "Bon de production (RESTAURANT-1 §4.4), créé une fois par la caisse maîtresse, immuable : uuid, clé (commande, poste, numero) et contenu. Intégré à partir du lot R-3 : `numero` = plus grand numéro de (commande, poste) + 1, `premier_envoi` ⇔ numero = 1, un bon par poste et par envoi, quantités = ce qui reste à annoncer (envoi) ou ce qui part de l'envoyé net (annulation), `empreinte_contenu` recalculée par le serveur. Sinon `restaurant.bon_incoherent` ; même uuid, autre empreinte : `restaurant.bon_modifie`.",
            "type": "object",
            "required": [
                "bon_uuid",
                "poste_uuid",
                "numero",
                "numero_jour",
                "type",
                "premier_envoi",
                "cree_le",
                "empreinte_contenu",
                "lignes"
            ],
            "additionalProperties": false,
            "properties": {
                "bon_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "poste_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "numero": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 100000,
                    "description": "Numéro du bon dans (commande, poste) : 1, 2, 3…"
                },
                "numero_jour": {
                    "type": "string",
                    "pattern": "^[A-Z0-9]{1,10}-[0-9]{8}-[0-9]{4,6}$",
                    "description": "Compteur du poste et du jour de la caisse, d'après ECAS : CODE-AAAAMMJJ-nnnn (code du poste normalisé : majuscules, caractères admis, 10 au plus). Gardé tel quel ; un doublon est noté, jamais refusé."
                },
                "type": {
                    "enum": [
                        "envoi",
                        "annulation"
                    ]
                },
                "premier_envoi": {
                    "type": "boolean"
                },
                "cree_le": {
                    "$ref": "commun.json#/$defs/horodatage"
                },
                "empreinte_contenu": {
                    "$ref": "commun.json#/$defs/empreinte",
                    "description": "SHA-256 SK-JCS-1 du bon sans ce champ."
                },
                "lignes": {
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 100,
                    "items": {
                        "type": "object",
                        "required": [
                            "ligne_uuid",
                            "libelle",
                            "quantite",
                            "commentaire",
                            "action"
                        ],
                        "additionalProperties": false,
                        "properties": {
                            "ligne_uuid": {
                                "$ref": "commun.json#/$defs/uuid"
                            },
                            "libelle": {
                                "type": "string",
                                "minLength": 1,
                                "maxLength": 240
                            },
                            "quantite": {
                                "$ref": "commun.json#/$defs/quantite"
                            },
                            "commentaire": {
                                "type": [
                                    "string",
                                    "null"
                                ],
                                "maxLength": 500
                            },
                            "action": {
                                "enum": [
                                    "add",
                                    "cancel"
                                ]
                            }
                        }
                    }
                }
            }
        },
        "resto_commande_ouverture": {
            "description": "Version 1 seulement : ouvre la commande (lignes vides).",
            "type": "object",
            "required": [
                "maitre_generation",
                "point_de_vente_uuid",
                "commande_uuid",
                "version",
                "action",
                "fait",
                "motif",
                "autorisations",
                "etat"
            ],
            "additionalProperties": false,
            "properties": {
                "maitre_generation": {
                    "$ref": "commun.json#/$defs/version",
                    "description": "Génération de la désignation sous laquelle le fait a été créé."
                },
                "point_de_vente_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "commande_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "version": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 100000,
                    "description": "Version de la commande : 1, 2, 3… sans trou."
                },
                "action": {
                    "const": "ouverture"
                },
                "fait": {
                    "type": "object",
                    "required": [],
                    "additionalProperties": false,
                    "properties": {}
                },
                "motif": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 500
                },
                "autorisations": {
                    "type": "array",
                    "maxItems": 5,
                    "items": {
                        "$ref": "#/$defs/autorisation_restaurant"
                    }
                },
                "etat": {
                    "$ref": "#/$defs/etat_commande"
                }
            }
        },
        "resto_commande_lignes": {
            "description": "Lignes en attente ajoutées, modifiées ou retirées (statut cancelled).",
            "type": "object",
            "required": [
                "maitre_generation",
                "point_de_vente_uuid",
                "commande_uuid",
                "version",
                "action",
                "fait",
                "motif",
                "autorisations",
                "etat"
            ],
            "additionalProperties": false,
            "properties": {
                "maitre_generation": {
                    "$ref": "commun.json#/$defs/version",
                    "description": "Génération de la désignation sous laquelle le fait a été créé."
                },
                "point_de_vente_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "commande_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "version": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 100000,
                    "description": "Version de la commande : 1, 2, 3… sans trou."
                },
                "action": {
                    "const": "lignes"
                },
                "fait": {
                    "type": "object",
                    "required": [
                        "ajoutees",
                        "modifiees",
                        "retirees"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "ajoutees": {
                            "type": "array",
                            "maxItems": 200,
                            "uniqueItems": true,
                            "items": {
                                "$ref": "commun.json#/$defs/uuid"
                            }
                        },
                        "modifiees": {
                            "type": "array",
                            "maxItems": 200,
                            "uniqueItems": true,
                            "items": {
                                "$ref": "commun.json#/$defs/uuid"
                            }
                        },
                        "retirees": {
                            "type": "array",
                            "maxItems": 200,
                            "uniqueItems": true,
                            "items": {
                                "$ref": "commun.json#/$defs/uuid"
                            }
                        }
                    }
                },
                "motif": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 500
                },
                "autorisations": {
                    "type": "array",
                    "maxItems": 5,
                    "items": {
                        "$ref": "#/$defs/autorisation_restaurant"
                    }
                },
                "etat": {
                    "$ref": "#/$defs/etat_commande"
                }
            }
        },
        "resto_commande_prefacture": {
            "description": "Préfacture imprimée par la caisse ; rien n'est imprimé côté serveur.",
            "type": "object",
            "required": [
                "maitre_generation",
                "point_de_vente_uuid",
                "commande_uuid",
                "version",
                "action",
                "fait",
                "motif",
                "autorisations",
                "etat"
            ],
            "additionalProperties": false,
            "properties": {
                "maitre_generation": {
                    "$ref": "commun.json#/$defs/version",
                    "description": "Génération de la désignation sous laquelle le fait a été créé."
                },
                "point_de_vente_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "commande_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "version": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 100000,
                    "description": "Version de la commande : 1, 2, 3… sans trou."
                },
                "action": {
                    "const": "prefacture"
                },
                "fait": {
                    "type": "object",
                    "required": [
                        "numero_local"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "numero_local": {
                            "type": "string",
                            "pattern": "^[A-Z0-9]{1,23}-[0-9]{8}-L[0-9]{4,6}$"
                        }
                    }
                },
                "motif": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 500
                },
                "autorisations": {
                    "type": "array",
                    "maxItems": 5,
                    "items": {
                        "$ref": "#/$defs/autorisation_restaurant"
                    }
                },
                "etat": {
                    "$ref": "#/$defs/etat_commande"
                }
            }
        },
        "resto_commande_transfert_table": {
            "description": "Transfert de la commande vers une autre table.",
            "type": "object",
            "required": [
                "maitre_generation",
                "point_de_vente_uuid",
                "commande_uuid",
                "version",
                "action",
                "fait",
                "motif",
                "autorisations",
                "etat"
            ],
            "additionalProperties": false,
            "properties": {
                "maitre_generation": {
                    "$ref": "commun.json#/$defs/version",
                    "description": "Génération de la désignation sous laquelle le fait a été créé."
                },
                "point_de_vente_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "commande_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "version": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 100000,
                    "description": "Version de la commande : 1, 2, 3… sans trou."
                },
                "action": {
                    "const": "transfert_table"
                },
                "fait": {
                    "type": "object",
                    "required": [
                        "table_uuid_source",
                        "table_uuid_cible"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "table_uuid_source": {
                            "$ref": "commun.json#/$defs/uuid"
                        },
                        "table_uuid_cible": {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    }
                },
                "motif": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 500
                },
                "autorisations": {
                    "type": "array",
                    "maxItems": 5,
                    "items": {
                        "$ref": "#/$defs/autorisation_restaurant"
                    }
                },
                "etat": {
                    "$ref": "#/$defs/etat_commande"
                }
            }
        },
        "resto_commande_annulation": {
            "description": "Annulation de la commande. Avec des articles annoncés aux postes : droit `resto_modifier_envoye` ou autorisation `resto_annuler_commande` (ou `resto_modifier_envoye`), motif de 3 caractères au moins, et un bon d'ANNULATION couvrant l'envoyé net de chaque article annoncé (lot R-3).",
            "type": "object",
            "required": [
                "maitre_generation",
                "point_de_vente_uuid",
                "commande_uuid",
                "version",
                "action",
                "fait",
                "motif",
                "autorisations",
                "etat"
            ],
            "additionalProperties": false,
            "properties": {
                "maitre_generation": {
                    "$ref": "commun.json#/$defs/version",
                    "description": "Génération de la désignation sous laquelle le fait a été créé."
                },
                "point_de_vente_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "commande_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "version": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 100000,
                    "description": "Version de la commande : 1, 2, 3… sans trou."
                },
                "action": {
                    "const": "annulation"
                },
                "fait": {
                    "type": "object",
                    "required": [
                        "bons"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "bons": {
                            "type": "array",
                            "maxItems": 50,
                            "items": {
                                "$ref": "#/$defs/bon"
                            }
                        }
                    }
                },
                "motif": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 500
                },
                "autorisations": {
                    "type": "array",
                    "maxItems": 5,
                    "items": {
                        "$ref": "#/$defs/autorisation_restaurant"
                    }
                },
                "etat": {
                    "$ref": "#/$defs/etat_commande"
                }
            }
        },
        "resto_commande_cloture": {
            "description": "Constat que la commande est soldée : refusé si Σ réglé < Σ quantités actives.",
            "type": "object",
            "required": [
                "maitre_generation",
                "point_de_vente_uuid",
                "commande_uuid",
                "version",
                "action",
                "fait",
                "motif",
                "autorisations",
                "etat"
            ],
            "additionalProperties": false,
            "properties": {
                "maitre_generation": {
                    "$ref": "commun.json#/$defs/version",
                    "description": "Génération de la désignation sous laquelle le fait a été créé."
                },
                "point_de_vente_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "commande_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "version": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 100000,
                    "description": "Version de la commande : 1, 2, 3… sans trou."
                },
                "action": {
                    "const": "cloture"
                },
                "fait": {
                    "type": "object",
                    "required": [],
                    "additionalProperties": false,
                    "properties": {}
                },
                "motif": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 500
                },
                "autorisations": {
                    "type": "array",
                    "maxItems": 5,
                    "items": {
                        "$ref": "#/$defs/autorisation_restaurant"
                    }
                },
                "etat": {
                    "$ref": "#/$defs/etat_commande"
                }
            }
        },
        "resto_commande_envoi": {
            "description": "Lot R-3 : chaque bon annonce à son poste la part non encore envoyée de ses lignes ; les lignes annoncées passent `sent` sur le poste du bon. Une ligne en attente dite `sent` sans bon est figée sans bon (article sans poste, ou envoi en production éteint). `bons` vide si `envoi_production` est éteint.",
            "type": "object",
            "required": [
                "maitre_generation",
                "point_de_vente_uuid",
                "commande_uuid",
                "version",
                "action",
                "fait",
                "motif",
                "autorisations",
                "etat"
            ],
            "additionalProperties": false,
            "properties": {
                "maitre_generation": {
                    "$ref": "commun.json#/$defs/version",
                    "description": "Génération de la désignation sous laquelle le fait a été créé."
                },
                "point_de_vente_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "commande_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "version": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 100000,
                    "description": "Version de la commande : 1, 2, 3… sans trou."
                },
                "action": {
                    "const": "envoi"
                },
                "fait": {
                    "type": "object",
                    "required": [
                        "bons"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "bons": {
                            "type": "array",
                            "maxItems": 50,
                            "items": {
                                "$ref": "#/$defs/bon"
                            }
                        }
                    }
                },
                "motif": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 500
                },
                "autorisations": {
                    "type": "array",
                    "maxItems": 5,
                    "items": {
                        "$ref": "#/$defs/autorisation_restaurant"
                    }
                },
                "etat": {
                    "$ref": "#/$defs/etat_commande"
                }
            }
        },
        "resto_commande_annulation_ligne": {
            "description": "Lot R-3 : réduire ou annuler un article envoyé (statut `sent`). Droit `resto_modifier_envoye`, ou autorisation `resto_modifier_envoye` d'un approbateur (toujours exigée si `restaurant.reglages.annulation_envoye_responsable`) ; `motif` de 3 caractères au moins. Un bon d'ANNULATION pour ce qui part de l'envoyé net (envoyé − quantité restante), aucun si la ligne n'a jamais été annoncée.",
            "type": "object",
            "required": [
                "maitre_generation",
                "point_de_vente_uuid",
                "commande_uuid",
                "version",
                "action",
                "fait",
                "motif",
                "autorisations",
                "etat"
            ],
            "additionalProperties": false,
            "properties": {
                "maitre_generation": {
                    "$ref": "commun.json#/$defs/version",
                    "description": "Génération de la désignation sous laquelle le fait a été créé."
                },
                "point_de_vente_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "commande_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "version": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 100000,
                    "description": "Version de la commande : 1, 2, 3… sans trou."
                },
                "action": {
                    "const": "annulation_ligne"
                },
                "fait": {
                    "type": "object",
                    "required": [
                        "ligne_uuid",
                        "quantite",
                        "bons"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "ligne_uuid": {
                            "$ref": "commun.json#/$defs/uuid"
                        },
                        "quantite": {
                            "$ref": "commun.json#/$defs/quantite"
                        },
                        "bons": {
                            "type": "array",
                            "maxItems": 50,
                            "items": {
                                "$ref": "#/$defs/bon"
                            }
                        }
                    }
                },
                "motif": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 500
                },
                "autorisations": {
                    "type": "array",
                    "maxItems": 5,
                    "items": {
                        "$ref": "#/$defs/autorisation_restaurant"
                    }
                },
                "etat": {
                    "$ref": "#/$defs/etat_commande"
                }
            }
        },
        "resto_commande_validation": {
            "description": "Lot R-4 : quand l'envoi en production est éteint (`restaurant.reglages.envoi_production`), « Valider » fige les lignes en attente citées (`sent`) sans aucun bon, comme OrderService::send. Envoi rallumé depuis la publication : accepté et noté (`envoi_production_actif`).",
            "type": "object",
            "required": [
                "maitre_generation",
                "point_de_vente_uuid",
                "commande_uuid",
                "version",
                "action",
                "fait",
                "motif",
                "autorisations",
                "etat"
            ],
            "additionalProperties": false,
            "properties": {
                "maitre_generation": {
                    "$ref": "commun.json#/$defs/version",
                    "description": "Génération de la désignation sous laquelle le fait a été créé."
                },
                "point_de_vente_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "commande_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "version": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 100000,
                    "description": "Version de la commande : 1, 2, 3… sans trou."
                },
                "action": {
                    "const": "validation"
                },
                "fait": {
                    "type": "object",
                    "required": [
                        "lignes"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "lignes": {
                            "type": "array",
                            "minItems": 1,
                            "maxItems": 100,
                            "uniqueItems": true,
                            "items": {
                                "$ref": "commun.json#/$defs/uuid"
                            }
                        }
                    }
                },
                "motif": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 500
                },
                "autorisations": {
                    "type": "array",
                    "maxItems": 5,
                    "items": {
                        "$ref": "#/$defs/autorisation_restaurant"
                    }
                },
                "etat": {
                    "$ref": "#/$defs/etat_commande"
                }
            }
        },
        "resto_commande_offert": {
            "description": "Lot R-4 : offrir un article non annulé, non réglé, pas déjà offert : `tarif` = `free`, `remise` = montant brut de la ligne (prix × quantité, arrondi au franc). Droit `resto_offrir`, ou autorisation `resto_offrir` d'un approbateur qui détient RESTO_OFFRIR ; `motif` de 3 caractères au moins. Audit `line.offer`. Un article offert garde sa quantité (retirez-le pour la changer).",
            "type": "object",
            "required": [
                "maitre_generation",
                "point_de_vente_uuid",
                "commande_uuid",
                "version",
                "action",
                "fait",
                "motif",
                "autorisations",
                "etat"
            ],
            "additionalProperties": false,
            "properties": {
                "maitre_generation": {
                    "$ref": "commun.json#/$defs/version",
                    "description": "Génération de la désignation sous laquelle le fait a été créé."
                },
                "point_de_vente_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "commande_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "version": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 100000,
                    "description": "Version de la commande : 1, 2, 3… sans trou."
                },
                "action": {
                    "const": "offert"
                },
                "fait": {
                    "type": "object",
                    "required": [
                        "ligne_uuid"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "ligne_uuid": {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    }
                },
                "motif": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 500
                },
                "autorisations": {
                    "type": "array",
                    "maxItems": 5,
                    "items": {
                        "$ref": "#/$defs/autorisation_restaurant"
                    }
                },
                "etat": {
                    "$ref": "#/$defs/etat_commande"
                }
            }
        },
        "resto_commande_remise_ligne": {
            "description": "Lot R-4 : remise manuelle d'un article non annulé, non réglé, non offert : `tarif` = `manual_discount`, `remise` = `valeur` (montant) ou `valeur` % du brut de la ligne arrondi vers le bas (pourcentage), de 1 F au brut. Droit `remise` (REMISE), ou autorisation `remise` d'un approbateur qui détient REMISE (assistant : plafond `restaurant.reglages.assistant.max_remise_pourcent`) ; `motif` de 3 caractères au moins. Audit `line.discount`. Un article remisé garde sa quantité.",
            "type": "object",
            "required": [
                "maitre_generation",
                "point_de_vente_uuid",
                "commande_uuid",
                "version",
                "action",
                "fait",
                "motif",
                "autorisations",
                "etat"
            ],
            "additionalProperties": false,
            "properties": {
                "maitre_generation": {
                    "$ref": "commun.json#/$defs/version",
                    "description": "Génération de la désignation sous laquelle le fait a été créé."
                },
                "point_de_vente_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "commande_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "version": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 100000,
                    "description": "Version de la commande : 1, 2, 3… sans trou."
                },
                "action": {
                    "const": "remise_ligne"
                },
                "fait": {
                    "type": "object",
                    "required": [
                        "ligne_uuid",
                        "saisie"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "ligne_uuid": {
                            "$ref": "commun.json#/$defs/uuid"
                        },
                        "saisie": {
                            "type": "object",
                            "required": [
                                "type",
                                "valeur"
                            ],
                            "additionalProperties": false,
                            "properties": {
                                "type": {
                                    "enum": [
                                        "montant",
                                        "pourcentage"
                                    ]
                                },
                                "valeur": {
                                    "type": "integer",
                                    "minimum": 1,
                                    "maximum": 100000000,
                                    "description": "Francs (montant) ou 1 à 100 (pourcentage)."
                                }
                            }
                        }
                    }
                },
                "motif": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 500
                },
                "autorisations": {
                    "type": "array",
                    "maxItems": 5,
                    "items": {
                        "$ref": "#/$defs/autorisation_restaurant"
                    }
                },
                "etat": {
                    "$ref": "#/$defs/etat_commande"
                }
            }
        },
        "resto_commande_remise": {
            "description": "Lot R-4 : remise de la commande (`remise_globale`), en francs, comme ECAS. 0 la retire. Plafond : `restaurant.order_discount_max_percent` (Restaurant) ou `restaurant.table_service_discount_max_percent` (Service de table) du montant après remises de ligne ; impossible une fois un règlement gardé. Droit `remise`, ou autorisation `remise` ; `motif` de 3 caractères au moins si `montant` > 0. Audit `order.discount`. Une commande à remise globale ne se règle pas par articles (`items`) avant d'être réglée en entier.",
            "type": "object",
            "required": [
                "maitre_generation",
                "point_de_vente_uuid",
                "commande_uuid",
                "version",
                "action",
                "fait",
                "motif",
                "autorisations",
                "etat"
            ],
            "additionalProperties": false,
            "properties": {
                "maitre_generation": {
                    "$ref": "commun.json#/$defs/version",
                    "description": "Génération de la désignation sous laquelle le fait a été créé."
                },
                "point_de_vente_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "commande_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "version": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 100000,
                    "description": "Version de la commande : 1, 2, 3… sans trou."
                },
                "action": {
                    "const": "remise"
                },
                "fait": {
                    "type": "object",
                    "required": [
                        "montant"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "montant": {
                            "$ref": "commun.json#/$defs/montant"
                        }
                    }
                },
                "motif": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 500
                },
                "autorisations": {
                    "type": "array",
                    "maxItems": 5,
                    "items": {
                        "$ref": "#/$defs/autorisation_restaurant"
                    }
                },
                "etat": {
                    "$ref": "#/$defs/etat_commande"
                }
            }
        },
        "resto_commande_validation_client": {
            "description": "Lot R-4, Service de table seulement : le client a validé la préfacture, `etape` = `customer_validated`. Au Restaurant : `restaurant.etat_incoherent` (`action_profil`).",
            "type": "object",
            "required": [
                "maitre_generation",
                "point_de_vente_uuid",
                "commande_uuid",
                "version",
                "action",
                "fait",
                "motif",
                "autorisations",
                "etat"
            ],
            "additionalProperties": false,
            "properties": {
                "maitre_generation": {
                    "$ref": "commun.json#/$defs/version",
                    "description": "Génération de la désignation sous laquelle le fait a été créé."
                },
                "point_de_vente_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "commande_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "version": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 100000,
                    "description": "Version de la commande : 1, 2, 3… sans trou."
                },
                "action": {
                    "const": "validation_client"
                },
                "fait": {
                    "type": "object",
                    "required": [],
                    "additionalProperties": false,
                    "properties": {}
                },
                "motif": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 500
                },
                "autorisations": {
                    "type": "array",
                    "maxItems": 5,
                    "items": {
                        "$ref": "#/$defs/autorisation_restaurant"
                    }
                },
                "etat": {
                    "$ref": "#/$defs/etat_commande"
                }
            }
        },
        "resto_commande_deplacement_lignes": {
            "description": "Lot R-4 (Q9) : une seule opération, sur la commande SOURCE ; les lignes citées passent à la commande `vers_commande_uuid` (même point de vente, même profil, même canal au Restaurant, ouverte). `version_cible` = version de la cible au moment du geste : la cible ne change pas de version, sa version suivante porte les lignes reçues (et attend ce fait s'il arrive après). Cible pas encore à `version_cible` : `recue` (`restaurant.attente_version`) ; au-delà : `restaurant.etat_incoherent` (`version_cible`). Un article annulé, réglé, ou offert lié sans son article acheté ne se déplace pas. L'état de la source ne porte plus les lignes déplacées.",
            "type": "object",
            "required": [
                "maitre_generation",
                "point_de_vente_uuid",
                "commande_uuid",
                "version",
                "action",
                "fait",
                "motif",
                "autorisations",
                "etat"
            ],
            "additionalProperties": false,
            "properties": {
                "maitre_generation": {
                    "$ref": "commun.json#/$defs/version",
                    "description": "Génération de la désignation sous laquelle le fait a été créé."
                },
                "point_de_vente_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "commande_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "version": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 100000,
                    "description": "Version de la commande : 1, 2, 3… sans trou."
                },
                "action": {
                    "const": "deplacement_lignes"
                },
                "fait": {
                    "type": "object",
                    "required": [
                        "vers_commande_uuid",
                        "version_cible",
                        "lignes"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "vers_commande_uuid": {
                            "$ref": "commun.json#/$defs/uuid"
                        },
                        "version_cible": {
                            "type": "integer",
                            "minimum": 1,
                            "maximum": 100000
                        },
                        "lignes": {
                            "type": "array",
                            "minItems": 1,
                            "maxItems": 100,
                            "uniqueItems": true,
                            "items": {
                                "$ref": "commun.json#/$defs/uuid"
                            }
                        }
                    }
                },
                "motif": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 500
                },
                "autorisations": {
                    "type": "array",
                    "maxItems": 5,
                    "items": {
                        "$ref": "#/$defs/autorisation_restaurant"
                    }
                },
                "etat": {
                    "$ref": "#/$defs/etat_commande"
                }
            }
        },
        "resto_commande_fusion": {
            "description": "Lot R-4 (Q9) : comme `deplacement_lignes`, pour toutes les lignes actives de la source (OrderTransferService::merge). La source est annulée (`statut` = `cancelled`, motif « Fusionnée dans la commande … ») ; la cible additionne couverts (500 au plus) et remises de commande, et reprend client, nom du client et commentaire de la source quand elle n'en a pas. Refusée si la source a un règlement, ou si sa remise irait sur une cible déjà en partie réglée.",
            "type": "object",
            "required": [
                "maitre_generation",
                "point_de_vente_uuid",
                "commande_uuid",
                "version",
                "action",
                "fait",
                "motif",
                "autorisations",
                "etat"
            ],
            "additionalProperties": false,
            "properties": {
                "maitre_generation": {
                    "$ref": "commun.json#/$defs/version",
                    "description": "Génération de la désignation sous laquelle le fait a été créé."
                },
                "point_de_vente_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "commande_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "version": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 100000,
                    "description": "Version de la commande : 1, 2, 3… sans trou."
                },
                "action": {
                    "const": "fusion"
                },
                "fait": {
                    "type": "object",
                    "required": [
                        "vers_commande_uuid",
                        "version_cible"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "vers_commande_uuid": {
                            "$ref": "commun.json#/$defs/uuid"
                        },
                        "version_cible": {
                            "type": "integer",
                            "minimum": 1,
                            "maximum": 100000
                        }
                    }
                },
                "motif": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 500
                },
                "autorisations": {
                    "type": "array",
                    "maxItems": 5,
                    "items": {
                        "$ref": "#/$defs/autorisation_restaurant"
                    }
                },
                "etat": {
                    "$ref": "#/$defs/etat_commande"
                }
            }
        },
        "resto_commande_couverts_serveur": {
            "description": "Lot R-4 : couverts et serveur de la commande, puis de sa table (TableService::setCovers, assignServer). L'état reçu porte les mêmes valeurs.",
            "type": "object",
            "required": [
                "maitre_generation",
                "point_de_vente_uuid",
                "commande_uuid",
                "version",
                "action",
                "fait",
                "motif",
                "autorisations",
                "etat"
            ],
            "additionalProperties": false,
            "properties": {
                "maitre_generation": {
                    "$ref": "commun.json#/$defs/version",
                    "description": "Génération de la désignation sous laquelle le fait a été créé."
                },
                "point_de_vente_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "commande_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "version": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 100000,
                    "description": "Version de la commande : 1, 2, 3… sans trou."
                },
                "action": {
                    "const": "couverts_serveur"
                },
                "fait": {
                    "type": "object",
                    "required": [
                        "couverts",
                        "serveur_id"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "couverts": {
                            "oneOf": [
                                {
                                    "type": "null"
                                },
                                {
                                    "type": "integer",
                                    "minimum": 1,
                                    "maximum": 500
                                }
                            ]
                        },
                        "serveur_id": {
                            "oneOf": [
                                {
                                    "type": "null"
                                },
                                {
                                    "$ref": "commun.json#/$defs/identifiant_serveur"
                                }
                            ]
                        }
                    }
                },
                "motif": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 500
                },
                "autorisations": {
                    "type": "array",
                    "maxItems": 5,
                    "items": {
                        "$ref": "#/$defs/autorisation_restaurant"
                    }
                },
                "etat": {
                    "$ref": "#/$defs/etat_commande"
                }
            }
        },
        "contenu_resto_commande": {
            "description": "Un fait sur une commande et son état résultant (RESTAURANT-1 §4.3). Révisions R-2 (ouverture, lignes, prefacture, transfert_table, annulation, cloture), R-3 (envoi, annulation_ligne) et R-4 (validation, offert, remise_ligne, remise, validation_client, deplacement_lignes, fusion, couverts_serveur ; profil Restaurant) : toutes les actions du contrat. Lot R-5 : promotions, happy hour et tarif du personnel dans `lignes` (profil Restaurant), remise client (`etat.remise_globale_source`).",
            "oneOf": [
                {
                    "$ref": "#/$defs/resto_commande_ouverture"
                },
                {
                    "$ref": "#/$defs/resto_commande_lignes"
                },
                {
                    "$ref": "#/$defs/resto_commande_prefacture"
                },
                {
                    "$ref": "#/$defs/resto_commande_transfert_table"
                },
                {
                    "$ref": "#/$defs/resto_commande_annulation"
                },
                {
                    "$ref": "#/$defs/resto_commande_cloture"
                },
                {
                    "$ref": "#/$defs/resto_commande_envoi"
                },
                {
                    "$ref": "#/$defs/resto_commande_annulation_ligne"
                },
                {
                    "$ref": "#/$defs/resto_commande_validation"
                },
                {
                    "$ref": "#/$defs/resto_commande_offert"
                },
                {
                    "$ref": "#/$defs/resto_commande_remise_ligne"
                },
                {
                    "$ref": "#/$defs/resto_commande_remise"
                },
                {
                    "$ref": "#/$defs/resto_commande_validation_client"
                },
                {
                    "$ref": "#/$defs/resto_commande_deplacement_lignes"
                },
                {
                    "$ref": "#/$defs/resto_commande_fusion"
                },
                {
                    "$ref": "#/$defs/resto_commande_couverts_serveur"
                }
            ]
        },
        "resto_commande": {
            "description": "Capacité restaurant.v1 (RESTAURANT-1 §4.1, §4.3) : seule la caisse maîtresse émet ce type. Sans la capacité : rejet_protocole capacite_absente.",
            "type": "object",
            "required": [
                "uuid",
                "type",
                "appareil",
                "sequence",
                "cree_le",
                "operateur_id",
                "versions",
                "empreinte",
                "contenu"
            ],
            "additionalProperties": false,
            "properties": {
                "uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "type": {
                    "const": "resto_commande"
                },
                "appareil": {
                    "$ref": "#/$defs/appareil"
                },
                "sequence": {
                    "$ref": "#/$defs/sequence"
                },
                "cree_le": {
                    "$ref": "commun.json#/$defs/horodatage"
                },
                "operateur_id": {
                    "$ref": "commun.json#/$defs/identifiant_serveur"
                },
                "versions": {
                    "$ref": "#/$defs/versions"
                },
                "empreinte": {
                    "$ref": "commun.json#/$defs/empreinte"
                },
                "contenu": {
                    "$ref": "#/$defs/contenu_resto_commande"
                }
            }
        },
        "autorisation_restaurant": {
            "description": "Autorisation hors ligne d'une opération restaurant (RESTAURANT-1 §4.3 bis, décision Q3 ; lot R-3) : celle de la 2.1, plus les types restaurant, admis seulement avec restaurant.v1. La caisse a vérifié localement le code de 8 chiffres de l'approbateur (preuve `code_local|<horodatage>`) ; le serveur revérifie à l'intégration son rôle (manager ou assistant manager), sa propre permission et les plafonds de l'assistant. Lot R-5 : `remboursement` (approbateur détenteur des permissions qui manquent à l’opérateur, plafond de remboursement de l’assistant).",
            "type": "object",
            "required": [
                "type",
                "approbateur_id",
                "motif",
                "preuve"
            ],
            "additionalProperties": false,
            "properties": {
                "type": {
                    "enum": [
                        "remise",
                        "survente",
                        "prix_manuel",
                        "resto_modifier_envoye",
                        "resto_offrir",
                        "resto_annuler_commande",
                        "remboursement"
                    ]
                },
                "approbateur_id": {
                    "$ref": "commun.json#/$defs/identifiant_serveur"
                },
                "motif": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 500
                },
                "preuve": {
                    "type": "string",
                    "maxLength": 500,
                    "description": "Preuve locale de l'autorisation (jamais un code ni son empreinte)."
                }
            }
        },
        "evenement_bon": {
            "description": "Un fait sur un bon déjà envoyé (RESTAURANT-1 §4.5).",
            "oneOf": [
                {
                    "type": "object",
                    "required": [
                        "evenement_uuid",
                        "type",
                        "bon_uuid",
                        "de",
                        "vers",
                        "le",
                        "source"
                    ],
                    "additionalProperties": false,
                    "description": "Statut du bon (afficheur ou caisse). Le statut ne recule jamais : un `vers` déjà atteint est noté sans effet ; un saut hors flux est appliqué et noté.",
                    "properties": {
                        "evenement_uuid": {
                            "$ref": "commun.json#/$defs/uuid"
                        },
                        "type": {
                            "const": "statut"
                        },
                        "bon_uuid": {
                            "$ref": "commun.json#/$defs/uuid"
                        },
                        "de": {
                            "enum": [
                                "new",
                                "in_progress",
                                "ready"
                            ]
                        },
                        "vers": {
                            "enum": [
                                "in_progress",
                                "ready",
                                "served"
                            ]
                        },
                        "le": {
                            "$ref": "commun.json#/$defs/horodatage"
                        },
                        "source": {
                            "enum": [
                                "afficheur",
                                "caisse"
                            ]
                        }
                    }
                },
                {
                    "type": "object",
                    "required": [
                        "evenement_uuid",
                        "type",
                        "bon_uuid",
                        "tentative_uuid",
                        "cible",
                        "resultat",
                        "secours",
                        "le"
                    ],
                    "additionalProperties": false,
                    "description": "Résultat d'une tentative de livraison : `accuse` (l'afficheur a confirmé ce bon), `transmis` (octets partis, sans preuve de papier), `non_envoye` (échec certain avant tout octet : seul cas qui permet le secours), `a_verifier` (issue inconnue : alerte, jamais de relance automatique).",
                    "properties": {
                        "evenement_uuid": {
                            "$ref": "commun.json#/$defs/uuid"
                        },
                        "type": {
                            "const": "livraison"
                        },
                        "bon_uuid": {
                            "$ref": "commun.json#/$defs/uuid"
                        },
                        "tentative_uuid": {
                            "$ref": "commun.json#/$defs/uuid"
                        },
                        "cible": {
                            "enum": [
                                "ecran_poste",
                                "imprimante_poste",
                                "imprimante_caisse"
                            ]
                        },
                        "resultat": {
                            "enum": [
                                "accuse",
                                "transmis",
                                "non_envoye",
                                "a_verifier"
                            ]
                        },
                        "secours": {
                            "type": "boolean"
                        },
                        "le": {
                            "$ref": "commun.json#/$defs/horodatage"
                        }
                    }
                },
                {
                    "type": "object",
                    "required": [
                        "evenement_uuid",
                        "type",
                        "bon_uuid",
                        "duplicata_uuid",
                        "cible",
                        "motif",
                        "operateur_id",
                        "le"
                    ],
                    "additionalProperties": false,
                    "description": "Réimpression demandée par un opérateur (DUPLICATA).",
                    "properties": {
                        "evenement_uuid": {
                            "$ref": "commun.json#/$defs/uuid"
                        },
                        "type": {
                            "const": "duplicata"
                        },
                        "bon_uuid": {
                            "$ref": "commun.json#/$defs/uuid"
                        },
                        "duplicata_uuid": {
                            "$ref": "commun.json#/$defs/uuid"
                        },
                        "cible": {
                            "enum": [
                                "ecran_poste",
                                "imprimante_poste",
                                "imprimante_caisse"
                            ]
                        },
                        "motif": {
                            "type": "string",
                            "minLength": 3,
                            "maxLength": 500
                        },
                        "operateur_id": {
                            "$ref": "commun.json#/$defs/identifiant_serveur"
                        },
                        "le": {
                            "$ref": "commun.json#/$defs/horodatage"
                        }
                    }
                },
                {
                    "type": "object",
                    "required": [
                        "evenement_uuid",
                        "type",
                        "bon_uuid",
                        "tentative_uuid",
                        "constat",
                        "operateur_id",
                        "le"
                    ],
                    "additionalProperties": false,
                    "description": "Vérification sur place d'une tentative `a_verifier`.",
                    "properties": {
                        "evenement_uuid": {
                            "$ref": "commun.json#/$defs/uuid"
                        },
                        "type": {
                            "const": "verification"
                        },
                        "bon_uuid": {
                            "$ref": "commun.json#/$defs/uuid"
                        },
                        "tentative_uuid": {
                            "$ref": "commun.json#/$defs/uuid"
                        },
                        "constat": {
                            "enum": [
                                "sorti",
                                "non_sorti"
                            ]
                        },
                        "operateur_id": {
                            "$ref": "commun.json#/$defs/identifiant_serveur"
                        },
                        "le": {
                            "$ref": "commun.json#/$defs/horodatage"
                        }
                    }
                }
            ]
        },
        "contenu_resto_bons_etats": {
            "description": "États des bons remontés par lot (RESTAURANT-1 §4.5, lot R-3) : pour la vue distante et l'audit, jamais pour piloter la livraison locale. Un `evenement_uuid` déjà vu est ignoré ; un bon pas encore reçu laisse l'opération `recue` (`restaurant.attente_bon`), rejouée à l'intégration de sa commande.",
            "type": "object",
            "required": [
                "maitre_generation",
                "point_de_vente_uuid",
                "evenements"
            ],
            "additionalProperties": false,
            "properties": {
                "maitre_generation": {
                    "$ref": "commun.json#/$defs/version",
                    "description": "Génération de la désignation sous laquelle les faits ont été créés."
                },
                "point_de_vente_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "evenements": {
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 200,
                    "items": {
                        "$ref": "#/$defs/evenement_bon"
                    }
                }
            }
        },
        "resto_bons_etats": {
            "description": "Capacité restaurant.v1 (RESTAURANT-1 §4.5, lot R-3) : seule la caisse maîtresse émet ce type, au plus un lot toutes les 10 s, vidé à la clôture. Sans la capacité : rejet_protocole capacite_absente.",
            "type": "object",
            "required": [
                "uuid",
                "type",
                "appareil",
                "sequence",
                "cree_le",
                "operateur_id",
                "versions",
                "empreinte",
                "contenu"
            ],
            "additionalProperties": false,
            "properties": {
                "uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "type": {
                    "const": "resto_bons_etats"
                },
                "appareil": {
                    "$ref": "#/$defs/appareil"
                },
                "sequence": {
                    "$ref": "#/$defs/sequence"
                },
                "cree_le": {
                    "$ref": "commun.json#/$defs/horodatage"
                },
                "operateur_id": {
                    "$ref": "commun.json#/$defs/identifiant_serveur"
                },
                "versions": {
                    "$ref": "#/$defs/versions"
                },
                "empreinte": {
                    "$ref": "commun.json#/$defs/empreinte"
                },
                "contenu": {
                    "$ref": "#/$defs/contenu_resto_bons_etats"
                }
            }
        },
        "contenu_resto_registre_ouvre": {
            "type": "object",
            "required": [
                "maitre_generation",
                "point_de_vente_uuid",
                "registre_uuid",
                "date_metier",
                "note"
            ],
            "additionalProperties": false,
            "properties": {
                "maitre_generation": {
                    "$ref": "commun.json#/$defs/version",
                    "description": "Génération de la désignation sous laquelle le fait a été créé."
                },
                "point_de_vente_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "registre_uuid": {
                    "$ref": "commun.json#/$defs/uuid",
                    "description": "Journée du registre créée par la caisse : restaurant_register_days.uuid."
                },
                "date_metier": {
                    "$ref": "commun.json#/$defs/jour"
                },
                "note": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 2000
                }
            },
            "description": "Ouverture de la journée du registre du terminal (RESTAURANT-1 §4.7, lot R-4). Droit `resto_registre` ; un seul registre ouvert par terminal (`restaurant.registre_deja_ouvert`) ; `date_metier` à plus d'un jour de la date de la caisse dans le fuseau publié : `restaurant.date_metier_invraisemblable`. La session ouverte du terminal y est rattachée."
        },
        "resto_registre_ouvre": {
            "description": "Capacité restaurant.v1 (RESTAURANT-1 §4.7, lot R-4) : seule la caisse maîtresse émet ce type. Sans la capacité : rejet_protocole capacite_absente.",
            "type": "object",
            "required": [
                "uuid",
                "type",
                "appareil",
                "sequence",
                "cree_le",
                "operateur_id",
                "versions",
                "empreinte",
                "contenu"
            ],
            "additionalProperties": false,
            "properties": {
                "uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "type": {
                    "const": "resto_registre_ouvre"
                },
                "appareil": {
                    "$ref": "#/$defs/appareil"
                },
                "sequence": {
                    "$ref": "#/$defs/sequence"
                },
                "cree_le": {
                    "$ref": "commun.json#/$defs/horodatage"
                },
                "operateur_id": {
                    "$ref": "commun.json#/$defs/identifiant_serveur"
                },
                "versions": {
                    "$ref": "#/$defs/versions"
                },
                "empreinte": {
                    "$ref": "commun.json#/$defs/empreinte"
                },
                "contenu": {
                    "$ref": "#/$defs/contenu_resto_registre_ouvre"
                }
            }
        },
        "contenu_resto_registre_clos": {
            "type": "object",
            "required": [
                "maitre_generation",
                "point_de_vente_uuid",
                "registre_uuid",
                "note",
                "z_local"
            ],
            "additionalProperties": false,
            "properties": {
                "maitre_generation": {
                    "$ref": "commun.json#/$defs/version",
                    "description": "Génération de la désignation sous laquelle le fait a été créé."
                },
                "point_de_vente_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "registre_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "note": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 2000
                },
                "z_local": {
                    "type": "object",
                    "required": [
                        "numero",
                        "total_ventes"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "numero": {
                            "type": "integer",
                            "minimum": 1,
                            "maximum": 100000000
                        },
                        "total_ventes": {
                            "$ref": "commun.json#/$defs/montant"
                        }
                    }
                }
            },
            "description": "Clôture du registre et Z registre (RESTAURANT-1 §4.7, lot R-4). Droit `resto_registre`. Refus : registre inconnu (`restaurant.reference_inconnue`), session ouverte (`restaurant.registre_session_ouverte`), commandes du jour non soldées (`restaurant.registre_commandes_non_soldees`) ; tant qu'une vente ou une version de commande du terminal attend son intégration : `recue` (`restaurant.attente_reglement`). Résultat : `details.z_restaurant` {z_uuid, type `register`, numero} ; `z_local` est gardé pour rapprochement."
        },
        "resto_registre_clos": {
            "description": "Capacité restaurant.v1 (RESTAURANT-1 §4.7, lot R-4) : seule la caisse maîtresse émet ce type. Sans la capacité : rejet_protocole capacite_absente.",
            "type": "object",
            "required": [
                "uuid",
                "type",
                "appareil",
                "sequence",
                "cree_le",
                "operateur_id",
                "versions",
                "empreinte",
                "contenu"
            ],
            "additionalProperties": false,
            "properties": {
                "uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "type": {
                    "const": "resto_registre_clos"
                },
                "appareil": {
                    "$ref": "#/$defs/appareil"
                },
                "sequence": {
                    "$ref": "#/$defs/sequence"
                },
                "cree_le": {
                    "$ref": "commun.json#/$defs/horodatage"
                },
                "operateur_id": {
                    "$ref": "commun.json#/$defs/identifiant_serveur"
                },
                "versions": {
                    "$ref": "#/$defs/versions"
                },
                "empreinte": {
                    "$ref": "commun.json#/$defs/empreinte"
                },
                "contenu": {
                    "$ref": "#/$defs/contenu_resto_registre_clos"
                }
            }
        },
        "contenu_resto_remboursement": {
            "type": "object",
            "required": [
                "maitre_generation",
                "point_de_vente_uuid",
                "vente_ref",
                "commande_uuid",
                "type",
                "lignes",
                "montant",
                "motif",
                "autorisations"
            ],
            "additionalProperties": false,
            "properties": {
                "maitre_generation": {
                    "$ref": "commun.json#/$defs/version",
                    "description": "Génération de la désignation sous laquelle le fait a été créé."
                },
                "point_de_vente_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "vente_ref": {
                    "type": "object",
                    "required": [
                        "operation_uuid"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "operation_uuid": {
                            "$ref": "commun.json#/$defs/uuid",
                            "description": "Opération `vente` de ce terminal qui a réglé la commande."
                        }
                    }
                },
                "commande_uuid": {
                    "$ref": "commun.json#/$defs/uuid",
                    "description": "Commande que la vente a réglée (son `commande.commande_uuid`)."
                },
                "type": {
                    "enum": [
                        "retour",
                        "annulation"
                    ],
                    "description": "`retour` : des lignes de la vente, rendues en espèces. `annulation` : toute la vente, rendue sur ses moyens de paiement d’origine ; les quantités réglées reviennent à la commande et une commande soldée est rouverte."
                },
                "lignes": {
                    "type": "array",
                    "maxItems": 100,
                    "description": "Au moins une pour `retour`, aucune pour `annulation`.",
                    "items": {
                        "type": "object",
                        "required": [
                            "ligne_uuid",
                            "quantite"
                        ],
                        "additionalProperties": false,
                        "properties": {
                            "ligne_uuid": {
                                "$ref": "commun.json#/$defs/uuid",
                                "description": "ligne_uuid de la vente."
                            },
                            "quantite": {
                                "$ref": "commun.json#/$defs/quantite",
                                "description": "En unité de base (quantite_base de la vente)."
                            }
                        }
                    }
                },
                "montant": {
                    "$ref": "commun.json#/$defs/montant",
                    "description": "Montant rendu, calculé par parts archivées comme ReturnService ; différent du calcul serveur : `restaurant.remboursement_incoherent`, rien n’est remboursé."
                },
                "motif": {
                    "type": "string",
                    "minLength": 3,
                    "maxLength": 500
                },
                "autorisations": {
                    "type": "array",
                    "maxItems": 5,
                    "items": {
                        "$ref": "#/$defs/autorisation_restaurant"
                    }
                }
            },
            "description": "Remboursement restaurant de la caisse maîtresse (RESTAURANT-1 §4.10, lot R-5), règles de RefundService : vente de ce terminal intégrée et liée à une commande du Restaurant (profil PRODUCTION) de ce point de vente. Droits `ANNULATION` (annulation) ou `RETOUR_CREER` et `RETOUR_REMBOURSER_ESPECES` (retour), sinon autorisation `remboursement` ; motif obligatoire. Vente pas encore intégrée ou règlement pas encore rapproché : `recue` `restaurant.attente_reglement`. Effet sur le Z restaurant : retours de la session, vente annulée retirée du chiffre."
        },
        "resto_remboursement": {
            "description": "Capacité restaurant.v1 (RESTAURANT-1 §4.10, lot R-5) : seule la caisse maîtresse émet ce type. Sans la capacité : rejet_protocole capacite_absente.",
            "type": "object",
            "required": [
                "uuid",
                "type",
                "appareil",
                "sequence",
                "cree_le",
                "operateur_id",
                "versions",
                "empreinte",
                "contenu"
            ],
            "additionalProperties": false,
            "properties": {
                "uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "type": {
                    "const": "resto_remboursement"
                },
                "appareil": {
                    "$ref": "#/$defs/appareil"
                },
                "sequence": {
                    "$ref": "#/$defs/sequence"
                },
                "cree_le": {
                    "$ref": "commun.json#/$defs/horodatage"
                },
                "operateur_id": {
                    "$ref": "commun.json#/$defs/identifiant_serveur"
                },
                "versions": {
                    "$ref": "#/$defs/versions"
                },
                "empreinte": {
                    "$ref": "commun.json#/$defs/empreinte"
                },
                "contenu": {
                    "$ref": "#/$defs/contenu_resto_remboursement"
                }
            }
        },
        "contenu_edition_pre_x": {
            "type": "object",
            "required": [
                "session_uuid",
                "version",
                "aveugle",
                "resume"
            ],
            "additionalProperties": false,
            "properties": {
                "session_uuid": {
                    "$ref": "commun.json#/$defs/uuid",
                    "description": "Session serveur, ou UUID de l’ouverture_session locale."
                },
                "version": {
                    "enum": [
                        "detailed",
                        "short"
                    ]
                },
                "aveugle": {
                    "type": "boolean",
                    "description": "Pré-X à l’aveugle (sans VOIR_RAPPORTS) : ni théorique, ni contrôle par moyen, ni écart."
                },
                "resume": {
                    "description": "Résumé de ce qui a été imprimé, pour l’audit.",
                    "type": "object",
                    "required": [
                        "tickets",
                        "chiffre_affaires"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "tickets": {
                            "type": "integer",
                            "minimum": 0
                        },
                        "chiffre_affaires": {
                            "$ref": "commun.json#/$defs/montant_signe"
                        }
                    }
                }
            }
        },
        "edition_pre_x": {
            "description": "Lot Z local (README §12), capacité z.local : audit d’un pré-X imprimé hors ligne (même nom que l’audit du web). Non critique : ni argent ni stock, jamais refusé, ne bloque pas la clôture. Idempotent par uuid.",
            "type": "object",
            "required": [
                "uuid",
                "type",
                "appareil",
                "sequence",
                "cree_le",
                "operateur_id",
                "versions",
                "empreinte",
                "contenu"
            ],
            "additionalProperties": false,
            "properties": {
                "uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "type": {
                    "const": "edition_pre_x"
                },
                "appareil": {
                    "$ref": "#/$defs/appareil"
                },
                "sequence": {
                    "$ref": "#/$defs/sequence"
                },
                "cree_le": {
                    "$ref": "commun.json#/$defs/horodatage"
                },
                "operateur_id": {
                    "$ref": "commun.json#/$defs/identifiant_serveur"
                },
                "versions": {
                    "$ref": "#/$defs/versions"
                },
                "empreinte": {
                    "$ref": "commun.json#/$defs/empreinte"
                },
                "contenu": {
                    "$ref": "#/$defs/contenu_edition_pre_x"
                }
            }
        },
        "contenu_edition_pre_z": {
            "type": "object",
            "required": [
                "point_de_vente_uuid",
                "date_exploitation",
                "version",
                "sessions",
                "sessions_locales",
                "partielle",
                "resume"
            ],
            "additionalProperties": false,
            "properties": {
                "point_de_vente_uuid": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ],
                    "description": "z.journee.point_de_vente_uuid de la journée imprimée."
                },
                "date_exploitation": {
                    "$ref": "commun.json#/$defs/jour"
                },
                "version": {
                    "enum": [
                        "detailed",
                        "short"
                    ]
                },
                "sessions": {
                    "type": "array",
                    "maxItems": 100,
                    "uniqueItems": true,
                    "items": {
                        "$ref": "commun.json#/$defs/uuid"
                    },
                    "description": "Sessions closes publiées reprises dans le pré-Z."
                },
                "sessions_locales": {
                    "type": "array",
                    "maxItems": 10,
                    "uniqueItems": true,
                    "items": {
                        "$ref": "commun.json#/$defs/uuid"
                    },
                    "description": "Sessions du terminal ajoutées par lui (non encore synchronisées ou ouvertes)."
                },
                "partielle": {
                    "type": "boolean",
                    "description": "Vrai si le pré-Z portait la mention « journée partielle »."
                },
                "resume": {
                    "description": "Résumé de ce qui a été imprimé, pour l’audit.",
                    "type": "object",
                    "required": [
                        "tickets",
                        "chiffre_affaires"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "tickets": {
                            "type": "integer",
                            "minimum": 0
                        },
                        "chiffre_affaires": {
                            "$ref": "commun.json#/$defs/montant_signe"
                        }
                    }
                }
            }
        },
        "edition_pre_z": {
            "description": "Lot Z local (README §12), capacité z.local : audit d’un pré-Z de la journée imprimé hors ligne (même nom que l’audit du web). Non critique : ni argent ni stock, jamais refusé. Idempotent par uuid. La clôture de la journée reste au serveur.",
            "type": "object",
            "required": [
                "uuid",
                "type",
                "appareil",
                "sequence",
                "cree_le",
                "operateur_id",
                "versions",
                "empreinte",
                "contenu"
            ],
            "additionalProperties": false,
            "properties": {
                "uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "type": {
                    "const": "edition_pre_z"
                },
                "appareil": {
                    "$ref": "#/$defs/appareil"
                },
                "sequence": {
                    "$ref": "#/$defs/sequence"
                },
                "cree_le": {
                    "$ref": "commun.json#/$defs/horodatage"
                },
                "operateur_id": {
                    "$ref": "commun.json#/$defs/identifiant_serveur"
                },
                "versions": {
                    "$ref": "#/$defs/versions"
                },
                "empreinte": {
                    "$ref": "commun.json#/$defs/empreinte"
                },
                "contenu": {
                    "$ref": "#/$defs/contenu_edition_pre_z"
                }
            }
        },
        "creation_produit": {
            "description": "Révision 2.1 lot 10 (capacité produit.creation) : fiche produit créée hors connexion, à émettre avant toute vente qui cite produit_uuid.",
            "type": "object",
            "required": [
                "uuid",
                "type",
                "appareil",
                "sequence",
                "cree_le",
                "operateur_id",
                "versions",
                "empreinte",
                "contenu"
            ],
            "additionalProperties": false,
            "properties": {
                "uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "type": {
                    "const": "creation_produit"
                },
                "appareil": {
                    "$ref": "#/$defs/appareil"
                },
                "sequence": {
                    "$ref": "#/$defs/sequence"
                },
                "cree_le": {
                    "$ref": "commun.json#/$defs/horodatage"
                },
                "operateur_id": {
                    "$ref": "commun.json#/$defs/identifiant_serveur"
                },
                "versions": {
                    "$ref": "#/$defs/versions"
                },
                "empreinte": {
                    "$ref": "commun.json#/$defs/empreinte"
                },
                "contenu": {
                    "type": "object",
                    "required": [
                        "produit_uuid",
                        "nom",
                        "reference",
                        "codes_barres",
                        "categorie_uuid",
                        "prix",
                        "prix_achat",
                        "prix_gros",
                        "gros_quantite_min",
                        "stock_illimite"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "produit_uuid": {
                            "$ref": "commun.json#/$defs/uuid",
                            "description": "UUID v4 choisi par le terminal : le produit est créé avec cet UUID, ou il devient un alias du produit auquel il est rattaché."
                        },
                        "nom": {
                            "type": "string",
                            "minLength": 1,
                            "maxLength": 160
                        },
                        "reference": {
                            "type": [
                                "string",
                                "null"
                            ],
                            "minLength": 1,
                            "maxLength": 80,
                            "description": "null : aucune, ou référence attribuée par la boutique si elle les numérote automatiquement."
                        },
                        "codes_barres": {
                            "type": "array",
                            "maxItems": 5,
                            "uniqueItems": true,
                            "description": "Le premier est le code principal. Vide : le serveur attribue un code interne, comme le formulaire du web.",
                            "items": {
                                "type": "string",
                                "pattern": "^[!-~]{1,80}$"
                            }
                        },
                        "categorie_uuid": {
                            "oneOf": [
                                {
                                    "type": "null"
                                },
                                {
                                    "$ref": "commun.json#/$defs/uuid"
                                }
                            ],
                            "description": "Uuid serveur, ou (capacité referentiels.creation) uuid d’une creation_categorie du poste émise AVANT : résolu par alias."
                        },
                        "prix": {
                            "$ref": "commun.json#/$defs/montant"
                        },
                        "prix_achat": {
                            "oneOf": [
                                {
                                    "type": "null"
                                },
                                {
                                    "$ref": "commun.json#/$defs/montant"
                                }
                            ],
                            "description": "null : coût non saisi, enregistré à 0 (note de l’opération)."
                        },
                        "prix_gros": {
                            "oneOf": [
                                {
                                    "type": "null"
                                },
                                {
                                    "$ref": "commun.json#/$defs/montant"
                                }
                            ]
                        },
                        "gros_quantite_min": {
                            "oneOf": [
                                {
                                    "type": "null"
                                },
                                {
                                    "$ref": "commun.json#/$defs/quantite"
                                }
                            ]
                        },
                        "stock_illimite": {
                            "type": "boolean",
                            "description": "Faux : stock suivi, à 0 à la création (aucun stock initial ; un ajustement reste une opération distincte)."
                        },
                        "fournisseur_uuid": {
                            "oneOf": [
                                {
                                    "type": "null"
                                },
                                {
                                    "$ref": "commun.json#/$defs/uuid"
                                }
                            ],
                            "description": "Capacité referentiels.creation seulement (2.1 lot 18) : fournisseur du produit, uuid serveur ou uuid d’une creation_fournisseur du poste émise AVANT (alias). Facultatif ; présent sans la capacité : rejet_protocole capacite_absente."
                        }
                    }
                }
            }
        },
        "modification_produit": {
            "description": "Révision 2.1 lot 10 (capacité produit.modification) : champs modifiés hors connexion avec leur valeur de base ; un seul champ en conflit met toute l’opération à arbitrer.",
            "type": "object",
            "required": [
                "uuid",
                "type",
                "appareil",
                "sequence",
                "cree_le",
                "operateur_id",
                "versions",
                "empreinte",
                "contenu"
            ],
            "additionalProperties": false,
            "properties": {
                "uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "type": {
                    "const": "modification_produit"
                },
                "appareil": {
                    "$ref": "#/$defs/appareil"
                },
                "sequence": {
                    "$ref": "#/$defs/sequence"
                },
                "cree_le": {
                    "$ref": "commun.json#/$defs/horodatage"
                },
                "operateur_id": {
                    "$ref": "commun.json#/$defs/identifiant_serveur"
                },
                "versions": {
                    "$ref": "#/$defs/versions"
                },
                "empreinte": {
                    "$ref": "commun.json#/$defs/empreinte"
                },
                "contenu": {
                    "type": "object",
                    "required": [
                        "produit_uuid",
                        "revision_base",
                        "champs"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "produit_uuid": {
                            "$ref": "commun.json#/$defs/uuid"
                        },
                        "revision_base": {
                            "oneOf": [
                                {
                                    "type": "null"
                                },
                                {
                                    "$ref": "commun.json#/$defs/version"
                                }
                            ],
                            "description": "Révision de l’entité produit reçue par /changements ; null pour un produit créé sur ce terminal et pas encore reçu. Informative : le contrôle se fait champ par champ sur « avant »."
                        },
                        "champs": {
                            "type": "object",
                            "additionalProperties": false,
                            "description": "Seulement les champs modifiés (au moins un), chacun avec la valeur connue du terminal (avant) et la nouvelle (apres).",
                            "properties": {
                                "nom": {
                                    "type": "object",
                                    "required": [
                                        "avant",
                                        "apres"
                                    ],
                                    "additionalProperties": false,
                                    "properties": {
                                        "avant": {
                                            "type": "string",
                                            "minLength": 1,
                                            "maxLength": 160
                                        },
                                        "apres": {
                                            "type": "string",
                                            "minLength": 1,
                                            "maxLength": 160
                                        }
                                    }
                                },
                                "reference": {
                                    "type": "object",
                                    "required": [
                                        "avant",
                                        "apres"
                                    ],
                                    "additionalProperties": false,
                                    "properties": {
                                        "avant": {
                                            "type": [
                                                "string",
                                                "null"
                                            ],
                                            "minLength": 1,
                                            "maxLength": 80
                                        },
                                        "apres": {
                                            "type": [
                                                "string",
                                                "null"
                                            ],
                                            "minLength": 1,
                                            "maxLength": 80
                                        }
                                    }
                                },
                                "categorie_uuid": {
                                    "type": "object",
                                    "required": [
                                        "avant",
                                        "apres"
                                    ],
                                    "additionalProperties": false,
                                    "properties": {
                                        "avant": {
                                            "oneOf": [
                                                {
                                                    "type": "null"
                                                },
                                                {
                                                    "$ref": "commun.json#/$defs/uuid"
                                                }
                                            ]
                                        },
                                        "apres": {
                                            "oneOf": [
                                                {
                                                    "type": "null"
                                                },
                                                {
                                                    "$ref": "commun.json#/$defs/uuid"
                                                }
                                            ]
                                        }
                                    }
                                },
                                "prix": {
                                    "type": "object",
                                    "required": [
                                        "avant",
                                        "apres"
                                    ],
                                    "additionalProperties": false,
                                    "properties": {
                                        "avant": {
                                            "$ref": "commun.json#/$defs/montant"
                                        },
                                        "apres": {
                                            "$ref": "commun.json#/$defs/montant"
                                        }
                                    }
                                },
                                "prix_gros": {
                                    "type": "object",
                                    "required": [
                                        "avant",
                                        "apres"
                                    ],
                                    "additionalProperties": false,
                                    "properties": {
                                        "avant": {
                                            "oneOf": [
                                                {
                                                    "type": "null"
                                                },
                                                {
                                                    "$ref": "commun.json#/$defs/montant"
                                                }
                                            ]
                                        },
                                        "apres": {
                                            "oneOf": [
                                                {
                                                    "type": "null"
                                                },
                                                {
                                                    "$ref": "commun.json#/$defs/montant"
                                                }
                                            ]
                                        }
                                    }
                                },
                                "gros_quantite_min": {
                                    "type": "object",
                                    "required": [
                                        "avant",
                                        "apres"
                                    ],
                                    "additionalProperties": false,
                                    "properties": {
                                        "avant": {
                                            "oneOf": [
                                                {
                                                    "type": "null"
                                                },
                                                {
                                                    "$ref": "commun.json#/$defs/quantite"
                                                }
                                            ]
                                        },
                                        "apres": {
                                            "oneOf": [
                                                {
                                                    "type": "null"
                                                },
                                                {
                                                    "$ref": "commun.json#/$defs/quantite"
                                                }
                                            ]
                                        }
                                    }
                                },
                                "fournisseur_uuid": {
                                    "type": "object",
                                    "required": [
                                        "avant",
                                        "apres"
                                    ],
                                    "additionalProperties": false,
                                    "description": "Capacité referentiels.creation seulement (2.1 lot 18). Uuid serveur ou alias d’une creation_fournisseur du poste ; présent sans la capacité : rejet_protocole capacite_absente.",
                                    "properties": {
                                        "avant": {
                                            "oneOf": [
                                                {
                                                    "type": "null"
                                                },
                                                {
                                                    "$ref": "commun.json#/$defs/uuid"
                                                }
                                            ]
                                        },
                                        "apres": {
                                            "oneOf": [
                                                {
                                                    "type": "null"
                                                },
                                                {
                                                    "$ref": "commun.json#/$defs/uuid"
                                                }
                                            ]
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        },
        "contenu_vente_modification": {
            "description": "Révision 2.1 lot 11 (capacité vente.modification) : ticket déjà encaissé modifié après coup. Le contenu de remplacement est complet (toutes les lignes gardées, changées ou ajoutées, comme une vente) ; la différence se règle sur UN moyen de la vente d’origine ; un responsable l’autorise par son code (vérifié localement, identifié par le code seul). Au serveur : annulation de la vente d’origine et vente de remplacement liée, dans la même transaction (correction du jour, ADR-182).",
            "type": "object",
            "required": [
                "vente_ref",
                "numero_local",
                "session_uuid",
                "tva",
                "lignes",
                "remise_globale",
                "livraison",
                "totaux",
                "a_payer_origine",
                "difference",
                "reglement",
                "motif",
                "autorisation",
                "mouvements"
            ],
            "additionalProperties": false,
            "properties": {
                "vente_ref": {
                    "type": "object",
                    "required": [
                        "operation_uuid",
                        "vente_uuid",
                        "numero"
                    ],
                    "additionalProperties": false,
                    "description": "Vente modifiée : `operation_uuid` = uuid de l’opération vente de CE terminal (vente faite hors ligne, intégrée ou non : en attente tant qu’elle ne l’est pas), sinon `vente_uuid` = uuid serveur d’une vente publiée ou encaissée en ligne. Au moins l’un des deux. `numero` : numéro imprimé sur le ticket d’origine (local ou définitif), informatif.",
                    "properties": {
                        "operation_uuid": {
                            "oneOf": [
                                {
                                    "type": "null"
                                },
                                {
                                    "$ref": "commun.json#/$defs/uuid"
                                }
                            ]
                        },
                        "vente_uuid": {
                            "oneOf": [
                                {
                                    "type": "null"
                                },
                                {
                                    "$ref": "commun.json#/$defs/uuid"
                                }
                            ]
                        },
                        "numero": {
                            "type": [
                                "string",
                                "null"
                            ],
                            "maxLength": 60
                        }
                    }
                },
                "numero_local": {
                    "type": "string",
                    "pattern": "^[A-Z0-9][A-Z0-9-]{0,29}$"
                },
                "session_uuid": {
                    "$ref": "commun.json#/$defs/uuid",
                    "description": "Session de la vente de remplacement : celle de la vente d’origine (règle du web : jamais une session close)."
                },
                "tva": {
                    "type": "object",
                    "required": [
                        "taux",
                        "incluse"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "taux": {
                            "$ref": "commun.json#/$defs/taux"
                        },
                        "incluse": {
                            "type": "boolean"
                        }
                    }
                },
                "lignes": {
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 200,
                    "items": {
                        "$ref": "#/$defs/ligne"
                    },
                    "description": "Contenu COMPLET du ticket de remplacement, prix figés comme une vente (catalogue publié). Une ligne retirée n’y figure plus ; un produit nouveau y est ajouté."
                },
                "remise_globale": {
                    "$ref": "commun.json#/$defs/montant"
                },
                "livraison": {
                    "$ref": "commun.json#/$defs/montant",
                    "description": "Celle de la vente d’origine (inchangée)."
                },
                "totaux": {
                    "type": "object",
                    "required": [
                        "brut",
                        "remises",
                        "base_ht",
                        "tva",
                        "a_payer"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "brut": {
                            "$ref": "commun.json#/$defs/montant"
                        },
                        "remises": {
                            "$ref": "commun.json#/$defs/montant"
                        },
                        "base_ht": {
                            "$ref": "commun.json#/$defs/montant"
                        },
                        "tva": {
                            "$ref": "commun.json#/$defs/montant"
                        },
                        "a_payer": {
                            "$ref": "commun.json#/$defs/montant"
                        }
                    }
                },
                "a_payer_origine": {
                    "$ref": "commun.json#/$defs/montant",
                    "description": "Montant à payer de la vente d’origine."
                },
                "difference": {
                    "$ref": "commun.json#/$defs/montant_signe",
                    "description": "totaux.a_payer − a_payer_origine : positive = complément encaissé, négative = remboursement."
                },
                "reglement": {
                    "type": "object",
                    "required": [
                        "moyen",
                        "sens",
                        "montant",
                        "reference"
                    ],
                    "additionalProperties": false,
                    "description": "Règlement de la différence, sur un moyen de la vente d’origine (choisi par la caissière si la vente en avait plusieurs). sens = aucun ⇔ difference = 0 (moyen null).",
                    "properties": {
                        "moyen": {
                            "oneOf": [
                                {
                                    "type": "null"
                                },
                                {
                                    "$ref": "commun.json#/$defs/code"
                                }
                            ]
                        },
                        "sens": {
                            "enum": [
                                "encaissement",
                                "remboursement",
                                "aucun"
                            ]
                        },
                        "montant": {
                            "$ref": "commun.json#/$defs/montant",
                            "description": "|difference|."
                        },
                        "reference": {
                            "type": [
                                "string",
                                "null"
                            ],
                            "maxLength": 120
                        }
                    }
                },
                "motif": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 500
                },
                "autorisation": {
                    "type": "object",
                    "required": [
                        "approbateur_id",
                        "preuve"
                    ],
                    "additionalProperties": false,
                    "description": "Responsable reconnu par son code seul : le terminal compare le code saisi aux empreintes publiées des opérateurs `approbateur_modification` ; exactement un doit correspondre (zéro : code inconnu ; plusieurs : code en double, refusé).",
                    "properties": {
                        "approbateur_id": {
                            "$ref": "commun.json#/$defs/identifiant_serveur"
                        },
                        "preuve": {
                            "type": "string",
                            "maxLength": 500,
                            "description": "`code_local|<horodatage>` ; jamais le code ni son empreinte."
                        }
                    }
                },
                "mouvements": {
                    "type": "array",
                    "maxItems": 400,
                    "items": {
                        "$ref": "#/$defs/mouvement"
                    },
                    "description": "Variations locales nettes : positives pour un article retiré, négatives pour un article ajouté."
                }
            }
        },
        "vente_modification": {
            "type": "object",
            "required": [
                "uuid",
                "type",
                "appareil",
                "sequence",
                "cree_le",
                "operateur_id",
                "versions",
                "empreinte",
                "contenu"
            ],
            "additionalProperties": false,
            "description": "Opération CRITIQUE (2.1 lot 11, capacité vente.modification) : modification d’un ticket déjà encaissé. Sans la capacité : rejet_protocole capacite_absente.",
            "properties": {
                "uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "type": {
                    "const": "vente_modification"
                },
                "appareil": {
                    "$ref": "#/$defs/appareil"
                },
                "sequence": {
                    "$ref": "#/$defs/sequence"
                },
                "cree_le": {
                    "$ref": "commun.json#/$defs/horodatage"
                },
                "operateur_id": {
                    "$ref": "commun.json#/$defs/identifiant_serveur"
                },
                "versions": {
                    "$ref": "#/$defs/versions"
                },
                "empreinte": {
                    "$ref": "commun.json#/$defs/empreinte"
                },
                "contenu": {
                    "$ref": "#/$defs/contenu_vente_modification"
                }
            }
        },
        "contenu_cloture_journee": {
            "type": "object",
            "required": [
                "jour",
                "sessions",
                "totaux",
                "tickets",
                "chiffre_affaires"
            ],
            "additionalProperties": false,
            "properties": {
                "jour": {
                    "$ref": "commun.json#/$defs/jour",
                    "description": "Jour d'exploitation clos (fuseau de la boutique, boutique.regles.fuseau)."
                },
                "sessions": {
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 50,
                    "uniqueItems": true,
                    "items": {
                        "$ref": "commun.json#/$defs/uuid"
                    },
                    "description": "Sessions du terminal réunies sur ce Z de journée : uuid de l'ouverture_session locale ou de la session serveur, chacune clôturée par une cloture_session de ce terminal émise avant cette opération."
                },
                "totaux": {
                    "type": "array",
                    "maxItems": 30,
                    "description": "Totaux par moyen imprimés sur le Z de journée du terminal (somme de ses Z de session).",
                    "items": {
                        "type": "object",
                        "required": [
                            "moyen",
                            "theorique",
                            "compte"
                        ],
                        "additionalProperties": false,
                        "properties": {
                            "moyen": {
                                "$ref": "commun.json#/$defs/code"
                            },
                            "theorique": {
                                "$ref": "commun.json#/$defs/montant_signe"
                            },
                            "compte": {
                                "oneOf": [
                                    {
                                        "type": "null"
                                    },
                                    {
                                        "$ref": "commun.json#/$defs/montant"
                                    }
                                ],
                                "description": "null : moyen non compté."
                            }
                        }
                    }
                },
                "tickets": {
                    "type": "integer",
                    "minimum": 0
                },
                "chiffre_affaires": {
                    "$ref": "commun.json#/$defs/montant_signe"
                },
                "detail": {
                    "description": "Facultatif : bloc de détail imprimé (DetailCloture, version 1), conservé pour le duplicata.",
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "donnees-z-local-1.json#/$defs/detail_cloture"
                        }
                    ]
                }
            }
        },
        "cloture_journee": {
            "description": "Capacité session.multiple (2.1 lot 12) : clôture de la journée de caisse du terminal, hors connexion. Le terminal imprime son Z de journée, qui réunit ses sessions clôturées du jour, puis émet cette opération. Intégrée quand toutes les sessions listées sont clôturées au serveur (sinon recue, raison journee.sessions_en_attente) ; totaux rapprochés du calcul du serveur, écart noté, jamais refusé. Idempotente par uuid.",
            "type": "object",
            "required": [
                "uuid",
                "type",
                "appareil",
                "sequence",
                "cree_le",
                "operateur_id",
                "versions",
                "empreinte",
                "contenu"
            ],
            "additionalProperties": false,
            "properties": {
                "uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "type": {
                    "const": "cloture_journee"
                },
                "appareil": {
                    "$ref": "#/$defs/appareil"
                },
                "sequence": {
                    "$ref": "#/$defs/sequence"
                },
                "cree_le": {
                    "$ref": "commun.json#/$defs/horodatage"
                },
                "operateur_id": {
                    "$ref": "commun.json#/$defs/identifiant_serveur"
                },
                "versions": {
                    "$ref": "#/$defs/versions"
                },
                "empreinte": {
                    "$ref": "commun.json#/$defs/empreinte"
                },
                "contenu": {
                    "$ref": "#/$defs/contenu_cloture_journee"
                }
            }
        },
        "ligne_prevente": {
            "description": "Lot 15 (capacité prevente.v1) : ligne réservée, figée comme une ligne de vente (libellé et prix au moment de la prévente). Indicative jusqu’à la conversion : la vente de conversion porte ses propres lignes.",
            "type": "object",
            "required": [
                "ligne_uuid",
                "produit_uuid",
                "conditionnement_uuid",
                "libelle",
                "quantite",
                "prix_unitaire",
                "remise",
                "total"
            ],
            "additionalProperties": false,
            "properties": {
                "ligne_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "produit_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "conditionnement_uuid": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ]
                },
                "libelle": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 200
                },
                "quantite": {
                    "$ref": "commun.json#/$defs/quantite"
                },
                "prix_unitaire": {
                    "$ref": "commun.json#/$defs/montant"
                },
                "remise": {
                    "$ref": "commun.json#/$defs/montant"
                },
                "total": {
                    "$ref": "commun.json#/$defs/montant",
                    "description": "quantite × prix_unitaire − remise, arrondi au franc."
                }
            }
        },
        "client_prevente": {
            "description": "Lot 15 : client de la prévente. Le nom suffit ; client_uuid relie une fiche client connue (publiée ou créée sur le terminal).",
            "type": "object",
            "required": [
                "nom",
                "telephone",
                "client_uuid"
            ],
            "additionalProperties": false,
            "properties": {
                "nom": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 160
                },
                "telephone": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 40
                },
                "client_uuid": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ]
                }
            }
        },
        "contenu_prevente_creer": {
            "description": "Lot 15 : prévente (réservation) créée sur le terminal. L’acompte (0 permis) est de l’argent reçu, compté au tiroir de la session, jamais du chiffre d’affaires avant conversion.",
            "type": "object",
            "required": [
                "prevente_uuid",
                "code",
                "client",
                "retrait_prevu",
                "lignes",
                "total",
                "acompte",
                "acompte_moyen",
                "acompte_recu",
                "acompte_reference",
                "session_uuid",
                "note"
            ],
            "additionalProperties": false,
            "properties": {
                "prevente_uuid": {
                    "$ref": "commun.json#/$defs/uuid",
                    "description": "UUID v4 choisi par le terminal : identité de la prévente partout."
                },
                "code": {
                    "type": "string",
                    "pattern": "^[A-Z0-9]{6}$",
                    "description": "Code imprimé sur la facture de prévente : 6 caractères, préfixe de 2 caractères propre au terminal (jamais « W », réservé au web) puis 4 caractères (alphabet sans 0, O, 1, I). Unique dans la boutique : un code déjà pris est gardé, noté, et la recherche par code rend les deux."
                },
                "client": {
                    "$ref": "#/$defs/client_prevente"
                },
                "retrait_prevu": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/horodatage"
                        }
                    ]
                },
                "lignes": {
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 100,
                    "items": {
                        "$ref": "#/$defs/ligne_prevente"
                    }
                },
                "total": {
                    "$ref": "commun.json#/$defs/montant",
                    "description": "Σ lignes.total."
                },
                "acompte": {
                    "$ref": "commun.json#/$defs/montant",
                    "description": "Argent laissé par le client, 0 permis, au plus total."
                },
                "acompte_moyen": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/code"
                        }
                    ],
                    "description": "Moyen de l’acompte (moyen publié de la boutique) ; null ⇔ acompte = 0."
                },
                "acompte_recu": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/montant"
                        }
                    ],
                    "description": "Espèces seulement : somme remise par le client (monnaie = recu − acompte)."
                },
                "acompte_reference": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 120
                },
                "session_uuid": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ],
                    "description": "Session où l’acompte est encaissé (même règle que la vente) ; null si acompte = 0."
                },
                "note": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 500
                }
            }
        },
        "prevente_creer": {
            "type": "object",
            "required": [
                "uuid",
                "type",
                "appareil",
                "sequence",
                "cree_le",
                "operateur_id",
                "versions",
                "empreinte",
                "contenu"
            ],
            "additionalProperties": false,
            "description": "Lot 15 (capacité prevente.v1) : créer une prévente. Sans la capacité : rejet_protocole capacite_absente.",
            "properties": {
                "uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "type": {
                    "const": "prevente_creer"
                },
                "appareil": {
                    "$ref": "#/$defs/appareil"
                },
                "sequence": {
                    "$ref": "#/$defs/sequence"
                },
                "cree_le": {
                    "$ref": "commun.json#/$defs/horodatage"
                },
                "operateur_id": {
                    "$ref": "commun.json#/$defs/identifiant_serveur"
                },
                "versions": {
                    "$ref": "#/$defs/versions"
                },
                "empreinte": {
                    "$ref": "commun.json#/$defs/empreinte"
                },
                "contenu": {
                    "$ref": "#/$defs/contenu_prevente_creer"
                }
            }
        },
        "contenu_prevente_modifier": {
            "description": "Lot 15 : prévente ouverte modifiée avant conversion (client, date, lignes, total). L’acompte ne change pas.",
            "type": "object",
            "required": [
                "prevente_uuid",
                "client",
                "retrait_prevu",
                "lignes",
                "total",
                "note"
            ],
            "additionalProperties": false,
            "properties": {
                "prevente_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "client": {
                    "$ref": "#/$defs/client_prevente"
                },
                "retrait_prevu": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/horodatage"
                        }
                    ]
                },
                "lignes": {
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 100,
                    "items": {
                        "$ref": "#/$defs/ligne_prevente"
                    }
                },
                "total": {
                    "$ref": "commun.json#/$defs/montant",
                    "description": "Σ lignes.total, au moins l’acompte."
                },
                "note": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 500
                }
            }
        },
        "prevente_modifier": {
            "type": "object",
            "required": [
                "uuid",
                "type",
                "appareil",
                "sequence",
                "cree_le",
                "operateur_id",
                "versions",
                "empreinte",
                "contenu"
            ],
            "additionalProperties": false,
            "description": "Lot 15 (capacité prevente.v1) : modifier une prévente ouverte.",
            "properties": {
                "uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "type": {
                    "const": "prevente_modifier"
                },
                "appareil": {
                    "$ref": "#/$defs/appareil"
                },
                "sequence": {
                    "$ref": "#/$defs/sequence"
                },
                "cree_le": {
                    "$ref": "commun.json#/$defs/horodatage"
                },
                "operateur_id": {
                    "$ref": "commun.json#/$defs/identifiant_serveur"
                },
                "versions": {
                    "$ref": "#/$defs/versions"
                },
                "empreinte": {
                    "$ref": "commun.json#/$defs/empreinte"
                },
                "contenu": {
                    "$ref": "#/$defs/contenu_prevente_modifier"
                }
            }
        },
        "contenu_prevente_convertir": {
            "description": "Lot 15 : marque de conversion. La conversion elle-même est faite par la vente `vente_operation_uuid`, qui porte `prevente_uuid` et le paiement `acompte_prevente` (= acompte) ; émise juste après cette vente.",
            "type": "object",
            "required": [
                "prevente_uuid",
                "vente_operation_uuid",
                "acompte_impute"
            ],
            "additionalProperties": false,
            "properties": {
                "prevente_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "vente_operation_uuid": {
                    "$ref": "commun.json#/$defs/uuid",
                    "description": "Opération vente de CE terminal qui convertit la prévente."
                },
                "acompte_impute": {
                    "$ref": "commun.json#/$defs/montant",
                    "description": "Acompte déduit sur la vente (montant du paiement acompte_prevente, 0 sans acompte)."
                }
            }
        },
        "prevente_convertir": {
            "type": "object",
            "required": [
                "uuid",
                "type",
                "appareil",
                "sequence",
                "cree_le",
                "operateur_id",
                "versions",
                "empreinte",
                "contenu"
            ],
            "additionalProperties": false,
            "description": "Lot 15 (capacité prevente.v1) : prévente convertie en vente.",
            "properties": {
                "uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "type": {
                    "const": "prevente_convertir"
                },
                "appareil": {
                    "$ref": "#/$defs/appareil"
                },
                "sequence": {
                    "$ref": "#/$defs/sequence"
                },
                "cree_le": {
                    "$ref": "commun.json#/$defs/horodatage"
                },
                "operateur_id": {
                    "$ref": "commun.json#/$defs/identifiant_serveur"
                },
                "versions": {
                    "$ref": "#/$defs/versions"
                },
                "empreinte": {
                    "$ref": "commun.json#/$defs/empreinte"
                },
                "contenu": {
                    "$ref": "#/$defs/contenu_prevente_convertir"
                }
            }
        },
        "contenu_prevente_annuler": {
            "description": "Lot 15 : désistement du client. Remboursement facultatif de tout ou partie de l’acompte, sur un moyen de la boutique, compté au tiroir de la session.",
            "type": "object",
            "required": [
                "prevente_uuid",
                "motif",
                "remboursement",
                "session_uuid"
            ],
            "additionalProperties": false,
            "properties": {
                "prevente_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "motif": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 500
                },
                "remboursement": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "type": "object",
                            "required": [
                                "moyen",
                                "montant",
                                "reference"
                            ],
                            "additionalProperties": false,
                            "properties": {
                                "moyen": {
                                    "$ref": "commun.json#/$defs/code"
                                },
                                "montant": {
                                    "type": "integer",
                                    "minimum": 1,
                                    "maximum": 999999999999,
                                    "description": "Au plus l’acompte."
                                },
                                "reference": {
                                    "type": [
                                        "string",
                                        "null"
                                    ],
                                    "maxLength": 120
                                }
                            }
                        }
                    ],
                    "description": "null : acompte gardé (ou pas d’acompte)."
                },
                "session_uuid": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ],
                    "description": "Session du remboursement ; null sans remboursement."
                }
            }
        },
        "prevente_annuler": {
            "type": "object",
            "required": [
                "uuid",
                "type",
                "appareil",
                "sequence",
                "cree_le",
                "operateur_id",
                "versions",
                "empreinte",
                "contenu"
            ],
            "additionalProperties": false,
            "description": "Lot 15 (capacité prevente.v1) : désistement, remboursement facultatif.",
            "properties": {
                "uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "type": {
                    "const": "prevente_annuler"
                },
                "appareil": {
                    "$ref": "#/$defs/appareil"
                },
                "sequence": {
                    "$ref": "#/$defs/sequence"
                },
                "cree_le": {
                    "$ref": "commun.json#/$defs/horodatage"
                },
                "operateur_id": {
                    "$ref": "commun.json#/$defs/identifiant_serveur"
                },
                "versions": {
                    "$ref": "#/$defs/versions"
                },
                "empreinte": {
                    "$ref": "commun.json#/$defs/empreinte"
                },
                "contenu": {
                    "$ref": "#/$defs/contenu_prevente_annuler"
                }
            }
        },
        "transfert_especes": {
            "description": "Capacité transfert.especes (lot 16, demande TBC) : transfert de fin de journée des mobile money vers les espèces, hors connexion. Un transfert par ligne (ADR-207, ni recette ni dépense) dans la session `session_uuid`. Montants tels que le poste les voit pour SA session (le serveur les applique tels quels). Moyen non réglé (boutique.regles.transfert_especes.moyens) ou droit absent : a_arbitrer. Idempotente par uuid.",
            "type": "object",
            "required": [
                "uuid",
                "type",
                "appareil",
                "sequence",
                "cree_le",
                "operateur_id",
                "versions",
                "empreinte",
                "contenu"
            ],
            "additionalProperties": false,
            "properties": {
                "uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "type": {
                    "const": "transfert_especes"
                },
                "appareil": {
                    "$ref": "#/$defs/appareil"
                },
                "sequence": {
                    "$ref": "#/$defs/sequence"
                },
                "cree_le": {
                    "$ref": "commun.json#/$defs/horodatage"
                },
                "operateur_id": {
                    "$ref": "commun.json#/$defs/identifiant_serveur"
                },
                "versions": {
                    "$ref": "#/$defs/versions"
                },
                "empreinte": {
                    "$ref": "commun.json#/$defs/empreinte"
                },
                "contenu": {
                    "type": "object",
                    "required": [
                        "session_uuid",
                        "lignes",
                        "motif"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "session_uuid": {
                            "$ref": "commun.json#/$defs/uuid",
                            "description": "Session serveur, ou UUID de l'ouverture_session locale."
                        },
                        "lignes": {
                            "type": "array",
                            "minItems": 1,
                            "maxItems": 30,
                            "items": {
                                "type": "object",
                                "required": [
                                    "moyen",
                                    "montant"
                                ],
                                "additionalProperties": false,
                                "properties": {
                                    "moyen": {
                                        "$ref": "commun.json#/$defs/code"
                                    },
                                    "montant": {
                                        "$ref": "commun.json#/$defs/montant"
                                    }
                                }
                            }
                        },
                        "motif": {
                            "type": [
                                "string",
                                "null"
                            ],
                            "maxLength": 500
                        }
                    }
                }
            }
        },
        "creation_categorie": {
            "description": "Capacité referentiels.creation (2.1 lot 18) : catégorie créée depuis la fiche produit du poste, à émettre AVANT toute opération produit qui cite categorie_uuid. Le serveur garde son uuid (details.categorie_uuid_canonique) ; celui du poste devient un alias. Droit CATEGORIES_CREER absent : a_arbitrer referentiel.droit_absent.",
            "type": "object",
            "required": [
                "uuid",
                "type",
                "appareil",
                "sequence",
                "cree_le",
                "operateur_id",
                "versions",
                "empreinte",
                "contenu"
            ],
            "additionalProperties": false,
            "properties": {
                "uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "type": {
                    "const": "creation_categorie"
                },
                "appareil": {
                    "$ref": "#/$defs/appareil"
                },
                "sequence": {
                    "$ref": "#/$defs/sequence"
                },
                "cree_le": {
                    "$ref": "commun.json#/$defs/horodatage"
                },
                "operateur_id": {
                    "$ref": "commun.json#/$defs/identifiant_serveur"
                },
                "versions": {
                    "$ref": "#/$defs/versions"
                },
                "empreinte": {
                    "$ref": "commun.json#/$defs/empreinte"
                },
                "contenu": {
                    "type": "object",
                    "required": [
                        "categorie_uuid",
                        "nom"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "categorie_uuid": {
                            "$ref": "commun.json#/$defs/uuid",
                            "description": "UUID v4 choisi par le poste ; devient un alias de la catégorie du serveur."
                        },
                        "nom": {
                            "type": "string",
                            "minLength": 1,
                            "maxLength": 160,
                            "description": "Nom saisi. Même nom (sans casse) déjà présent au serveur : rattachement automatique, rien n’est créé."
                        }
                    }
                }
            }
        },
        "creation_fournisseur": {
            "description": "Capacité referentiels.creation (2.1 lot 18) : fournisseur créé depuis la fiche produit du poste, à émettre AVANT toute opération produit qui cite fournisseur_uuid. Le serveur garde son uuid (details.fournisseur_uuid_canonique) ; celui du poste devient un alias. Droit FOURNISSEURS_CREER absent : a_arbitrer referentiel.droit_absent.",
            "type": "object",
            "required": [
                "uuid",
                "type",
                "appareil",
                "sequence",
                "cree_le",
                "operateur_id",
                "versions",
                "empreinte",
                "contenu"
            ],
            "additionalProperties": false,
            "properties": {
                "uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "type": {
                    "const": "creation_fournisseur"
                },
                "appareil": {
                    "$ref": "#/$defs/appareil"
                },
                "sequence": {
                    "$ref": "#/$defs/sequence"
                },
                "cree_le": {
                    "$ref": "commun.json#/$defs/horodatage"
                },
                "operateur_id": {
                    "$ref": "commun.json#/$defs/identifiant_serveur"
                },
                "versions": {
                    "$ref": "#/$defs/versions"
                },
                "empreinte": {
                    "$ref": "commun.json#/$defs/empreinte"
                },
                "contenu": {
                    "type": "object",
                    "required": [
                        "fournisseur_uuid",
                        "nom",
                        "telephone"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "fournisseur_uuid": {
                            "$ref": "commun.json#/$defs/uuid",
                            "description": "UUID v4 choisi par le poste ; devient un alias du fournisseur du serveur."
                        },
                        "nom": {
                            "type": "string",
                            "minLength": 1,
                            "maxLength": 160,
                            "description": "Nom saisi. Même nom (sans casse) déjà présent au serveur : rattachement automatique, rien n’est créé."
                        },
                        "telephone": {
                            "type": [
                                "string",
                                "null"
                            ],
                            "minLength": 1,
                            "maxLength": 40
                        }
                    }
                }
            }
        }
    }
}
''',
  'operations.json': r'''{
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "$id": "operations.json",
    "title": "POST /operations et POST /operations/etats : lots bornés, résultat individuel, aucun acquittement implicite du lot.",
    "$defs": {
        "demande": {
            "description": "Le lot n'est validé que dans sa forme ; chaque élément est ensuite validé seul contre operation.json.",
            "type": "object",
            "required": [
                "operations"
            ],
            "additionalProperties": false,
            "properties": {
                "operations": {
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 50,
                    "items": {
                        "type": "object"
                    }
                }
            }
        },
        "reponse": {
            "type": "object",
            "required": [
                "recu_le",
                "resultats"
            ],
            "additionalProperties": false,
            "properties": {
                "recu_le": {
                    "$ref": "commun.json#/$defs/horodatage"
                },
                "resultats": {
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 50,
                    "items": {
                        "$ref": "#/$defs/resultat"
                    }
                }
            }
        },
        "demande_etats": {
            "type": "object",
            "required": [
                "uuids"
            ],
            "additionalProperties": false,
            "properties": {
                "uuids": {
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 200,
                    "uniqueItems": true,
                    "items": {
                        "$ref": "commun.json#/$defs/uuid"
                    }
                }
            }
        },
        "reponse_etats": {
            "type": "object",
            "required": [
                "etats"
            ],
            "additionalProperties": false,
            "properties": {
                "etats": {
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 200,
                    "items": {
                        "$ref": "#/$defs/resultat"
                    }
                }
            }
        },
        "resultat": {
            "description": "État persistant d'une opération. /operations ne rend jamais « inconnue » ; /operations/etats la rend pour un UUID absent ou d'un autre terminal.",
            "type": "object",
            "required": [
                "uuid",
                "etat",
                "version_etat",
                "raison",
                "vente",
                "mouvements",
                "couverture"
            ],
            "additionalProperties": false,
            "properties": {
                "uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "etat": {
                    "enum": [
                        "recue",
                        "integree",
                        "a_arbitrer",
                        "resolue",
                        "rejet_protocole",
                        "inconnue"
                    ]
                },
                "version_etat": {
                    "$ref": "commun.json#/$defs/version"
                },
                "raison": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/raison"
                        }
                    ]
                },
                "vente": {
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "type": "object",
                            "required": [
                                "uuid",
                                "numero"
                            ],
                            "additionalProperties": false,
                            "properties": {
                                "uuid": {
                                    "$ref": "commun.json#/$defs/uuid"
                                },
                                "numero": {
                                    "type": "string",
                                    "minLength": 1,
                                    "maxLength": 40
                                }
                            }
                        }
                    ]
                },
                "details": {
                    "description": "Sur une creation_client intégrée : uuid à utiliser, l'ancien reste accepté sans limite. Sur une cloture_session intégrée : le Z.",
                    "type": "object",
                    "additionalProperties": false,
                    "properties": {
                        "client_uuid_canonique": {
                            "$ref": "commun.json#/$defs/uuid"
                        },
                        "z": {
                            "type": "object",
                            "description": "Z de la clôture intégrée.",
                            "required": [
                                "cloture_uuid",
                                "compte",
                                "theorique",
                                "ecart",
                                "mode"
                            ],
                            "additionalProperties": false,
                            "properties": {
                                "cloture_uuid": {
                                    "$ref": "commun.json#/$defs/uuid"
                                },
                                "compte": {
                                    "$ref": "commun.json#/$defs/montant"
                                },
                                "theorique": {
                                    "type": "integer"
                                },
                                "ecart": {
                                    "type": "integer"
                                },
                                "mode": {
                                    "enum": [
                                        "V1",
                                        "COMPLETE"
                                    ]
                                }
                            }
                        },
                        "commande": {
                            "description": "Capacité restaurant.v1 : sur une resto_commande intégrée, la commande et sa version (numéro = numéro serveur).",
                            "type": "object",
                            "required": [
                                "commande_uuid",
                                "numero",
                                "version"
                            ],
                            "additionalProperties": false,
                            "properties": {
                                "commande_uuid": {
                                    "$ref": "commun.json#/$defs/uuid"
                                },
                                "numero": {
                                    "type": "string",
                                    "minLength": 1,
                                    "maxLength": 40
                                },
                                "version": {
                                    "type": "integer",
                                    "minimum": 1
                                }
                            }
                        },
                        "z_restaurant": {
                            "description": "Capacité restaurant.v1 (lot R-4) : Z restaurant figé par le serveur, à la clôture de session d'un terminal restaurant (`session`) ou à la clôture du registre (`register`).",
                            "type": "object",
                            "required": [
                                "z_uuid",
                                "type",
                                "numero"
                            ],
                            "additionalProperties": false,
                            "properties": {
                                "z_uuid": {
                                    "$ref": "commun.json#/$defs/uuid"
                                },
                                "type": {
                                    "enum": [
                                        "session",
                                        "register"
                                    ]
                                },
                                "numero": {
                                    "type": "integer",
                                    "minimum": 1
                                }
                            }
                        },
                        "produit_uuid_canonique": {
                            "$ref": "commun.json#/$defs/uuid",
                            "description": "Capacités produit.creation / produit.modification (2.1 lot 10) : produit serveur désigné par produit_uuid (lui-même, ou le produit auquel il est rattaché ; l’uuid du terminal reste alors un alias sans limite)."
                        },
                        "produit_resolution": {
                            "type": "object",
                            "description": "2.1 lot 10 : décision appliquée à une creation_produit ou une modification_produit.",
                            "required": [
                                "decision",
                                "champs_serveur",
                                "decide_par"
                            ],
                            "additionalProperties": false,
                            "properties": {
                                "decision": {
                                    "enum": [
                                        "creee",
                                        "rattachee",
                                        "creee_distincte",
                                        "appliquee",
                                        "sans_effet",
                                        "arbitree"
                                    ]
                                },
                                "champs_serveur": {
                                    "type": "array",
                                    "uniqueItems": true,
                                    "maxItems": 10,
                                    "description": "Champs de la modification où la valeur du serveur a été gardée par arbitrage.",
                                    "items": {
                                        "enum": [
                                            "nom",
                                            "reference",
                                            "categorie_uuid",
                                            "prix",
                                            "prix_gros",
                                            "gros_quantite_min",
                                            "fournisseur_uuid"
                                        ]
                                    }
                                },
                                "decide_par": {
                                    "oneOf": [
                                        {
                                            "type": "null"
                                        },
                                        {
                                            "$ref": "commun.json#/$defs/identifiant_serveur"
                                        }
                                    ],
                                    "description": "Utilisateur qui a arbitré ; null sans arbitrage."
                                }
                            }
                        },
                        "session_serveur": {
                            "description": "Capacité session.multiple (2.1 lot 12) : session serveur d'une ouverture_session intégrée (id local ↔ id serveur).",
                            "type": "object",
                            "required": [
                                "session_uuid"
                            ],
                            "additionalProperties": false,
                            "properties": {
                                "session_uuid": {
                                    "$ref": "commun.json#/$defs/uuid"
                                }
                            }
                        },
                        "journee": {
                            "description": "Capacité session.multiple (2.1 lot 12) : rapprochement d'une cloture_journee intégrée.",
                            "type": "object",
                            "required": [
                                "jour",
                                "sessions",
                                "ecart"
                            ],
                            "additionalProperties": false,
                            "properties": {
                                "jour": {
                                    "$ref": "commun.json#/$defs/jour"
                                },
                                "sessions": {
                                    "type": "integer",
                                    "minimum": 1
                                },
                                "ecart": {
                                    "type": "integer"
                                }
                            }
                        },
                        "categorie_uuid_canonique": {
                            "$ref": "commun.json#/$defs/uuid",
                            "description": "Capacité referentiels.creation (2.1 lot 18) : catégorie du serveur désignée par l’uuid du poste (créée, ou existante du même nom). Le poste remplace partout son uuid local par celui-ci."
                        },
                        "fournisseur_uuid_canonique": {
                            "$ref": "commun.json#/$defs/uuid",
                            "description": "Capacité referentiels.creation (2.1 lot 18) : fournisseur du serveur désigné par l’uuid du poste (créé, ou existant du même nom). Le poste remplace partout son uuid local par celui-ci."
                        },
                        "referentiel_resolution": {
                            "type": "object",
                            "description": "2.1 lot 18 : décision appliquée à une creation_categorie ou creation_fournisseur.",
                            "required": [
                                "decision"
                            ],
                            "additionalProperties": false,
                            "properties": {
                                "decision": {
                                    "enum": [
                                        "creee",
                                        "rattachee"
                                    ],
                                    "description": "creee : fiche créée au serveur ; rattachee : fiche du même nom déjà présente, rien n’a été créé."
                                }
                            }
                        }
                    }
                },
                "mouvements": {
                    "description": "Mouvements serveur créés pour l'opération (UUID des mouvements locaux repris quand ils correspondent).",
                    "type": "array",
                    "maxItems": 400,
                    "items": {
                        "$ref": "commun.json#/$defs/uuid"
                    }
                },
                "couverture": {
                    "description": "Curseur à partir duquel le changement de stock couvrant l'opération est visible ; null tant qu'il n'est pas publié. Ne retirer la consommation locale qu'après avoir appliqué ce changement.",
                    "type": "object",
                    "required": [
                        "curseur"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "curseur": {
                            "oneOf": [
                                {
                                    "type": "null"
                                },
                                {
                                    "$ref": "commun.json#/$defs/curseur"
                                }
                            ]
                        }
                    }
                }
            }
        }
    }
}
''',
  'paniers.json': r'''{
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "$id": "paniers.json",
    "title": "Reprise et libération des paniers partagés (réseau requis).",
    "$defs": {
        "demande": {
            "type": "object",
            "required": [
                "operateur_id"
            ],
            "additionalProperties": false,
            "properties": {
                "operateur_id": {
                    "$ref": "commun.json#/$defs/identifiant_serveur"
                }
            }
        },
        "reprise": {
            "type": "object",
            "required": [
                "panier_uuid",
                "libelle",
                "expire_le",
                "contenu"
            ],
            "additionalProperties": false,
            "properties": {
                "panier_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "libelle": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 150
                },
                "expire_le": {
                    "$ref": "commun.json#/$defs/horodatage",
                    "description": "Reprise à renouveler par le même appel avant cette heure."
                },
                "contenu": {
                    "$ref": "donnees-2.1.json#/$defs/contenu_panier"
                }
            }
        }
    }
}
''',
  'passes.json': r'''{
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "$id": "passes.json",
    "title": "Capacité passes.evenement (2.1 lot 8) : vérification en ligne d'un pass avant passage (POST /passes/verifier). C'est le seul endroit où le code en clair transite ; il n'est ni journalisé ni renvoyé dans une erreur.",
    "$defs": {
        "demande": {
            "type": "object",
            "required": [
                "code",
                "jour",
                "lignes",
                "montant",
                "point_passage",
                "table_uuid"
            ],
            "additionalProperties": false,
            "properties": {
                "code": {
                    "description": "Code scanné ou saisi, tel que lu ; le serveur le normalise (bords et retours retirés, majuscules).",
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 120
                },
                "jour": {
                    "$ref": "commun.json#/$defs/jour",
                    "description": "Jour civil du passage dans le fuseau publié de la boutique (boutique.regles.fuseau), pas l'horloge brute du terminal."
                },
                "lignes": {
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 200,
                    "items": {
                        "$ref": "#/$defs/ligne"
                    }
                },
                "montant": {
                    "$ref": "commun.json#/$defs/montant",
                    "description": "Part de ce pass dans le total à payer (répartition au franc près, reste au premier)."
                },
                "point_passage": {
                    "description": "Nom du poste de scan ; null ou vide : réglage de la boutique, sinon « Caisse ».",
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 60
                },
                "table_uuid": {
                    "description": "Table du Service de table, ou null.",
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ]
                }
            }
        },
        "ligne": {
            "type": "object",
            "required": [
                "produit_uuid",
                "quantite",
                "montant"
            ],
            "additionalProperties": false,
            "properties": {
                "produit_uuid": {
                    "$ref": "commun.json#/$defs/uuid"
                },
                "quantite": {
                    "$ref": "commun.json#/$defs/quantite"
                },
                "montant": {
                    "$ref": "commun.json#/$defs/montant"
                }
            }
        },
        "reponse": {
            "description": "Verdict sans réservation : l'autorité finale est l'intégration de la vente (un second terminal peut être vu en écart). Motifs : textes d'ECAS (ReglesPassage.kt), mot pour mot.",
            "type": "object",
            "required": [
                "verdict",
                "motif",
                "pass_uuid",
                "porteur",
                "restant_jour",
                "restant_total"
            ],
            "additionalProperties": false,
            "properties": {
                "verdict": {
                    "enum": [
                        "autorise",
                        "refuse"
                    ]
                },
                "motif": {
                    "description": "null si autorisé ; sinon le refus lisible par le caissier.",
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 500
                },
                "pass_uuid": {
                    "description": "Clé de l'entité pass reconnue (y compris refusée), null si le code est inconnu.",
                    "oneOf": [
                        {
                            "type": "null"
                        },
                        {
                            "$ref": "commun.json#/$defs/uuid"
                        }
                    ]
                },
                "porteur": {
                    "type": [
                        "string",
                        "null"
                    ],
                    "maxLength": 160
                },
                "restant_jour": {
                    "description": "Passages restants aujourd'hui APRÈS ce passage ; null = sans limite du jour, ou refus.",
                    "type": [
                        "integer",
                        "null"
                    ],
                    "minimum": 0,
                    "maximum": 1000000
                },
                "restant_total": {
                    "description": "Passages restants au total APRÈS ce passage ; null = illimité, ou refus.",
                    "type": [
                        "integer",
                        "null"
                    ],
                    "minimum": 0,
                    "maximum": 1000000
                }
            }
        }
    }
}
''',
};
