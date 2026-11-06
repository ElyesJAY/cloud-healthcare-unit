-- =============================================================================
-- Cloud Healthcare Unit — Livrable 2
-- DML de chargement de la couche Gold depuis le schéma public
--
-- Auteur : Elyes Jaidane
-- Prérequis : dump restauré (tables public.*), puis sql/01_ddl_gold.sql
--
--   pg_restore --no-owner --no-privileges -d healthcare dump-healthcare-202611060813
--   psql -d healthcare -v ON_ERROR_STOP=1 -f sql/01_ddl_gold.sql
--   psql -d healthcare -v ON_ERROR_STOP=1 -f sql/02_dml_chargement_gold.sql
--
-- Le script est rejouable : il vide Gold puis le recharge (remplacement,
-- pas d'ajout). Ordre imposé par les clés étrangères : dimensions, puis faits.
--
-- Règles reprises du livrable 1 :
--   * patient absent sur un fait  -> rejet de la ligne (pas de rattachement)
--   * autre dimension introuvable -> membre Inconnu (clé -1)
--   * libellé facultatif vide     -> « Non renseigné »
--   * FINESS non numérique        -> NULL (pas de faux code partagé)
--   * sexe et tranche d'âge harmonisés ; nom et prénom jamais copiés
--   * nb_consultation = 1
--
-- Hospitalisation : aucune table source dans le dump. Le fait n'est pas
-- alimenté. La structure et ses contraintes sont créées par le DDL.
-- =============================================================================

SET client_encoding = 'UTF8';

-- Échoue tout de suite si le dump n'a pas été restauré.
DO $$
BEGIN
    IF to_regclass('public.consultation') IS NULL
       OR to_regclass('public.patient') IS NULL
       OR to_regclass('public.diagnostic') IS NULL
       OR to_regclass('public.professionnel_de_sante') IS NULL
       OR to_regclass('public.etablissement') IS NULL
       OR to_regclass('public.temps') IS NULL THEN
        RAISE EXCEPTION
            'Schéma source incomplet. Restaurez le dump dans public avant ce script.';
    END IF;
END $$;

BEGIN;

-- Un seul TRUNCATE : PostgreSQL accepte les tables liées par FK
-- lorsqu'elles sont toutes citées. RESTART IDENTITY remet à zéro
-- les clés de fait_hospitalisation et de rejet_chargement.
TRUNCATE TABLE
    gold.fait_consultation,
    gold.fait_hospitalisation,
    gold.dim_temps,
    gold.dim_patient,
    gold.dim_diagnostic,
    gold.dim_professionnel,
    gold.dim_etablissement,
    gold.rejet_chargement
RESTART IDENTITY;

-- -----------------------------------------------------------------------------
-- Membres « Inconnu » (clé technique -1)
-- Créés avant les faits pour que les clés étrangères puissent s'y rattacher.
-- -----------------------------------------------------------------------------
INSERT INTO gold.dim_temps (
    id_temps, date_complete, jour, mois, trimestre, annee
) VALUES (
    -1, 'INCONNU', 'Inconnu', 'Inconnu', 'Inconnu', 'Inconnu'
);

INSERT INTO gold.dim_patient (id_patient, sexe, tranche_age)
VALUES (-1, 'Inconnu', 'Inconnu');

INSERT INTO gold.dim_diagnostic (id_diagnostic, code_diag, diagnostic)
VALUES (-1, 'INCONNU', 'Inconnu');

INSERT INTO gold.dim_professionnel (
    id_professionnel, identifiant, categorie_professionnelle, profession,
    code_specialite, fonction, specialite
) VALUES (
    -1, 'INCONNU', 'Inconnu', 'Inconnu',
    'Non renseigné', 'Non renseigné', 'Inconnu'
);

INSERT INTO gold.dim_etablissement (
    id_etablissement, code_postal, commune, finess_site,
    raison_sociale_site, enseigne_commerciale_site, pays, departement
) VALUES (
    -1, 'Non renseigné', 'Inconnu', NULL,
    'Inconnu', 'Non renseigné', 'Non renseigné', 'Inconnu'
);

-- -----------------------------------------------------------------------------
-- Dim_Temps
-- Source : public.temps (jour, mois, annee, trimestre).
-- date_complete est calculée. make_date rejette une date impossible :
-- le chargement s'arrête plutôt que d'insérer un jour invalide.
-- Le calendrier source couvre 100 000 jours à partir du 2015-01-01
-- (jusqu'en 2288). On le reprend tel quel pour conserver les id_temps
-- déjà utilisés par les consultations (fenêtre réelle : 2015-06-20
-- à 2023-03-31).
-- -----------------------------------------------------------------------------
INSERT INTO gold.dim_temps (
    id_temps, date_complete, jour, mois, trimestre, annee
)
SELECT
    t.id_temps,
    to_char(make_date(t.annee::integer, t.mois::integer, t.jour::integer), 'YYYY-MM-DD'),
    btrim(t.jour),
    btrim(t.mois),
    t.trimestre::varchar(50),
    btrim(t.annee)
FROM public.temps AS t;

-- -----------------------------------------------------------------------------
-- Dim_Patient
-- Source : public.patient. nom et prenom sont lus nulle part.
-- female/male -> F/M. 75+ -> 75 ans et plus (libellé du livrable 1).
-- -----------------------------------------------------------------------------
INSERT INTO gold.dim_patient (id_patient, sexe, tranche_age)
SELECT
    p.id_patient,
    CASE lower(btrim(p.sexe))
        WHEN 'female' THEN 'F'
        WHEN 'f'      THEN 'F'
        WHEN 'femme'  THEN 'F'
        WHEN 'male'   THEN 'M'
        WHEN 'm'      THEN 'M'
        WHEN 'homme'  THEN 'M'
        ELSE 'Inconnu'
    END,
    CASE btrim(p.tranche_age)
        WHEN '0-17'  THEN '0-17'
        WHEN '18-29' THEN '18-29'
        WHEN '30-44' THEN '30-44'
        WHEN '45-59' THEN '45-59'
        WHEN '60-74' THEN '60-74'
        WHEN '75+'   THEN '75 ans et plus'
        WHEN '75 ans et plus' THEN '75 ans et plus'
        ELSE 'Inconnu'
    END
FROM public.patient AS p;

-- -----------------------------------------------------------------------------
-- Dim_Diagnostic
-- La clé technique source est conservée : les consultations pointent déjà
-- vers id_diagnostic. L'unicité de code_diag (contrainte DDL) refuse un
-- doublon de clé naturelle au lieu de supprimer un identifiant encore cité.
-- -----------------------------------------------------------------------------
INSERT INTO gold.dim_diagnostic (id_diagnostic, code_diag, diagnostic)
SELECT
    d.id_diagnostic,
    upper(btrim(d.code_diag)),
    COALESCE(NULLIF(btrim(d.diagnostic), ''), 'Non renseigné')
FROM public.diagnostic AS d;

-- -----------------------------------------------------------------------------
-- Dim_Professionnel
-- La clé technique source est conservée (les consultations pointent vers
-- id_professionnel). code_specialite et fonction ne sont pas dans la source :
-- « Non renseigné ». L'unicité de identifiant est portée par le DDL.
-- -----------------------------------------------------------------------------
INSERT INTO gold.dim_professionnel (
    id_professionnel, identifiant, categorie_professionnelle, profession,
    code_specialite, fonction, specialite
)
SELECT
    s.id_professionnel,
    btrim(s.identifiant),
    COALESCE(NULLIF(btrim(s.categorie_professionnelle), ''), 'Non renseigné'),
    COALESCE(NULLIF(btrim(s.profession), ''), 'Non renseigné'),
    'Non renseigné',
    'Non renseigné',
    COALESCE(NULLIF(btrim(s.specialite), ''), 'Non renseigné')
FROM public.professionnel_de_sante AS s
WHERE NULLIF(btrim(s.identifiant), '') IS NOT NULL;

-- Un professionnel sans identifiant ne peut pas entrer dans la dimension
-- (clé naturelle obligatoire). Il est rejeté, sans copie de la ligne.
INSERT INTO gold.rejet_chargement (job, source_table, cle_source, regle)
SELECT
    'dimensions',
    'public.professionnel_de_sante',
    s.id_professionnel::varchar(50),
    'identifiant professionnel absent'
FROM public.professionnel_de_sante AS s
WHERE NULLIF(btrim(s.identifiant), '') IS NULL;

-- -----------------------------------------------------------------------------
-- Dim_Etablissement
-- FINESS : chiffres uniquement, complétés à 9 caractères.
-- « Cabinet individuel » et toute valeur non numérique deviennent NULL.
-- Département : valeur source, sinon déduction du code postal
-- (20000-20199 -> 2A, 20200 et au-delà en 20 -> 2B, sinon 2 premiers chiffres).
-- -----------------------------------------------------------------------------
INSERT INTO gold.dim_etablissement (
    id_etablissement, code_postal, commune, finess_site,
    raison_sociale_site, enseigne_commerciale_site, pays, departement
)
SELECT
    e.id_etablissement,
    COALESCE(NULLIF(btrim(e.code_postal), ''), 'Non renseigné'),
    COALESCE(NULLIF(btrim(e.commune), ''), 'Non renseigné'),
    CASE
        WHEN btrim(e.finess_site) ~ '^[0-9]{1,9}$'
            THEN lpad(btrim(e.finess_site), 9, '0')
        ELSE NULL
    END,
    COALESCE(NULLIF(btrim(e.raison_sociale_site), ''), 'Non renseigné'),
    COALESCE(NULLIF(btrim(e.enseigne_commerciale_site), ''), 'Non renseigné'),
    COALESCE(NULLIF(btrim(e.pays), ''), 'Non renseigné'),
    CASE
        WHEN NULLIF(btrim(e.departement), '') IS NOT NULL
            THEN btrim(e.departement)
        WHEN btrim(e.code_postal) ~ '^20(0|1)'
            THEN '2A'
        WHEN btrim(e.code_postal) ~ '^20'
            THEN '2B'
        WHEN btrim(e.code_postal) ~ '^[0-9]{5}$'
            THEN substring(btrim(e.code_postal), 1, 2)
        ELSE 'Non renseigné'
    END
FROM public.etablissement AS e;

-- -----------------------------------------------------------------------------
-- Rejets Consultation
-- Patient introuvable : la ligne ne va pas dans le fait.
-- On ne stocke que le numéro de consultation et la règle.
-- -----------------------------------------------------------------------------
INSERT INTO gold.rejet_chargement (job, source_table, cle_source, regle)
SELECT
    'consultation',
    'public.consultation',
    c.num_consultation::varchar(50),
    'patient introuvable dans dim_patient'
FROM public.consultation AS c
LEFT JOIN gold.dim_patient AS p
    ON p.id_patient = c.id_patient
WHERE p.id_patient IS NULL;

-- -----------------------------------------------------------------------------
-- Fait Consultation
-- Jointure interne sur le patient (les rejets ci-dessus sont exclus).
-- Les autres clés manquantes sont remplacées par -1.
-- DISTINCT ON protège la clé primaire si un numéro était répété.
-- Le dump actuel a une clé primaire sur num_consultation : aucun doublon.
-- -----------------------------------------------------------------------------
INSERT INTO gold.fait_consultation (
    num_consultation, id_patient, id_temps, id_diagnostic,
    id_professionnel, id_etablissement, nb_consultation
)
SELECT DISTINCT ON (c.num_consultation)
    c.num_consultation::varchar(50),
    c.id_patient,
    COALESCE(tm.id_temps, -1),
    COALESCE(d.id_diagnostic, -1),
    COALESCE(pr.id_professionnel, -1),
    COALESCE(et.id_etablissement, -1),
    1
FROM public.consultation AS c
JOIN gold.dim_patient AS p
    ON p.id_patient = c.id_patient
LEFT JOIN gold.dim_temps AS tm
    ON tm.id_temps = c.id_temps
LEFT JOIN gold.dim_diagnostic AS d
    ON d.id_diagnostic = c.id_diagnostic
LEFT JOIN gold.dim_professionnel AS pr
    ON pr.id_professionnel = c.id_professionnel
LEFT JOIN gold.dim_etablissement AS et
    ON et.id_etablissement = c.id_etablissement
ORDER BY c.num_consultation;

-- -----------------------------------------------------------------------------
-- Contrôles
-- Le script échoue si une consultation source n'est ni chargée ni rejetée,
-- ou si une clé étrangère du fait ne tombe pas sur une dimension
-- (ce second point est déjà garanti par les contraintes FK : une violation
-- annule la transaction).
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    n_source  bigint;
    n_fait    bigint;
    n_rejet   bigint;
    n_patient bigint;
BEGIN
    SELECT count(*) INTO n_source FROM public.consultation;
    SELECT count(*) INTO n_fait   FROM gold.fait_consultation;
    SELECT count(*) INTO n_rejet
    FROM gold.rejet_chargement
    WHERE job = 'consultation';
    SELECT count(*) INTO n_patient FROM gold.dim_patient;

    IF n_fait + n_rejet <> n_source THEN
        RAISE EXCEPTION
            'Intégrité du chargement rompue : consultations source=%, fait=%, rejets=%',
            n_source, n_fait, n_rejet;
    END IF;

    -- Le membre Inconnu ne doit pas être compté comme un patient source.
    IF n_patient <> (SELECT count(*) FROM public.patient) + 1 THEN
        RAISE EXCEPTION
            'dim_patient inattendue : gold=% source=% (attendu source+1 pour Inconnu)',
            n_patient, (SELECT count(*) FROM public.patient);
    END IF;

    RAISE NOTICE 'Gold chargé : % consultations, % rejets patient, % patients (dont Inconnu).',
        n_fait, n_rejet, n_patient;
END $$;

COMMIT;

-- Bilan lisible après commit. Ces SELECT ne modifient rien.
SELECT 'dim_temps' AS table_gold, count(*) AS lignes FROM gold.dim_temps
UNION ALL SELECT 'dim_patient', count(*) FROM gold.dim_patient
UNION ALL SELECT 'dim_diagnostic', count(*) FROM gold.dim_diagnostic
UNION ALL SELECT 'dim_professionnel', count(*) FROM gold.dim_professionnel
UNION ALL SELECT 'dim_etablissement', count(*) FROM gold.dim_etablissement
UNION ALL SELECT 'fait_consultation', count(*) FROM gold.fait_consultation
UNION ALL SELECT 'fait_hospitalisation', count(*) FROM gold.fait_hospitalisation
UNION ALL SELECT 'rejet_chargement', count(*) FROM gold.rejet_chargement
ORDER BY table_gold;
