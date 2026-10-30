// Généré depuis test/fixtures/contrat-v2/schemas (contrat v2, révision 2.1, lot 1c) — ne pas modifier à la main.
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
            "description": "Opérateur autorisé sur ce terminal. Le PIN n'est transmis que sous forme d'empreinte lente (bcrypt), jamais en clair.",
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
                    "description": "Au moins un paiement dès que a_payer > 0 (recoupé par le serveur) ; aucun pour une vente à 0 F."
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
      "required": ["operations"],
      "additionalProperties": false,
      "properties": {
        "operations": { "type": "array", "minItems": 1, "maxItems": 50, "items": { "type": "object" } }
      }
    },
    "reponse": {
      "type": "object",
      "required": ["recu_le", "resultats"],
      "additionalProperties": false,
      "properties": {
        "recu_le": { "$ref": "commun.json#/$defs/horodatage" },
        "resultats": { "type": "array", "minItems": 1, "maxItems": 50, "items": { "$ref": "#/$defs/resultat" } }
      }
    },
    "demande_etats": {
      "type": "object",
      "required": ["uuids"],
      "additionalProperties": false,
      "properties": {
        "uuids": { "type": "array", "minItems": 1, "maxItems": 200, "uniqueItems": true, "items": { "$ref": "commun.json#/$defs/uuid" } }
      }
    },
    "reponse_etats": {
      "type": "object",
      "required": ["etats"],
      "additionalProperties": false,
      "properties": {
        "etats": { "type": "array", "minItems": 1, "maxItems": 200, "items": { "$ref": "#/$defs/resultat" } }
      }
    },
    "resultat": {
      "description": "État persistant d'une opération. /operations ne rend jamais « inconnue » ; /operations/etats la rend pour un UUID absent ou d'un autre terminal.",
      "type": "object",
      "required": ["uuid", "etat", "version_etat", "raison", "vente", "mouvements", "couverture"],
      "additionalProperties": false,
      "properties": {
        "uuid": { "$ref": "commun.json#/$defs/uuid" },
        "etat": { "enum": ["recue", "integree", "a_arbitrer", "resolue", "rejet_protocole", "inconnue"] },
        "version_etat": { "$ref": "commun.json#/$defs/version" },
        "raison": { "oneOf": [{ "type": "null" }, { "$ref": "commun.json#/$defs/raison" }] },
        "vente": {
          "oneOf": [
            { "type": "null" },
            {
              "type": "object",
              "required": ["uuid", "numero"],
              "additionalProperties": false,
              "properties": {
                "uuid": { "$ref": "commun.json#/$defs/uuid" },
                "numero": { "type": "string", "minLength": 1, "maxLength": 40 }
              }
            }
          ]
        },
        "mouvements": {
          "description": "Mouvements serveur créés pour l'opération (UUID des mouvements locaux repris quand ils correspondent).",
          "type": "array", "maxItems": 400, "items": { "$ref": "commun.json#/$defs/uuid" }
        },
        "couverture": {
          "description": "Curseur à partir duquel le changement de stock couvrant l'opération est visible ; null tant qu'il n'est pas publié. Ne retirer la consommation locale qu'après avoir appliqué ce changement.",
          "type": "object",
          "required": ["curseur"],
          "additionalProperties": false,
          "properties": {
            "curseur": { "oneOf": [{ "type": "null" }, { "$ref": "commun.json#/$defs/curseur" }] }
          }
        }
      }
    }
  }
}
''',
};
