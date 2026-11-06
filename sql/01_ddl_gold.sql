-- =============================================================================
-- Cloud Healthcare Unit — Livrable 2
-- DDL de la couche Gold (entrepôt décisionnel PostgreSQL)
--
-- Auteur : Elyes Jaidane
-- Schéma logique de référence : Livrable 1 (constellation Kimball)
--   5 dimensions : Temps, Patient, Diagnostic, Professionnel, Établissement
--   2 faits      : Consultation (alimenté), Hospitalisation (structure prête,
--                  source absente du dump fourni)
--
-- La base source restaurée depuis le dump reste dans le schéma public.
-- Elle possède des clés primaires, mais aucune clé étrangère.
-- Ce script crée le schéma gold, avec l'intégrité référentielle.
--
-- Exécution (après restauration du dump dans la base healthcare) :
--   psql -d healthcare -v ON_ERROR_STOP=1 -f sql/01_ddl_gold.sql
--   psql -d healthcare -v ON_ERROR_STOP=1 -f sql/02_dml_chargement_gold.sql
--
-- Le partitionnement et les index secondaires (hors clés primaires) sont
-- hors de ce script : ils constituent le point suivant du livrable 2.
-- =============================================================================

SET client_encoding = 'UTF8';

DROP SCHEMA IF EXISTS gold CASCADE;
CREATE SCHEMA gold;

COMMENT ON SCHEMA gold IS
  'Couche Gold : entrepôt décisionnel en constellation, sans donnée nominative.';

-- -----------------------------------------------------------------------------
-- Dimension Temps
-- Une ligne = un jour. date_complete est la clé naturelle (AAAA-MM-JJ).
-- Le membre « Inconnu » porte la clé technique -1 et la date 'INCONNU'.
-- -----------------------------------------------------------------------------
CREATE TABLE gold.dim_temps (
    id_temps       integer      NOT NULL,
    date_complete  varchar(10)  NOT NULL,
    jour           varchar(50)  NOT NULL,
    mois           varchar(50)  NOT NULL,
    trimestre      varchar(50)  NOT NULL,
    annee          varchar(50)  NOT NULL,
    CONSTRAINT pk_dim_temps PRIMARY KEY (id_temps),
    CONSTRAINT uq_dim_temps_date UNIQUE (date_complete),
    CONSTRAINT ck_dim_temps_date CHECK (
        date_complete = 'INCONNU'
        OR date_complete ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
    )
);

COMMENT ON TABLE gold.dim_temps IS
  'Quand ? Hiérarchie jour / mois / trimestre / année. Clé -1 = membre Inconnu.';
COMMENT ON COLUMN gold.dim_temps.date_complete IS
  'Clé naturelle AAAA-MM-JJ, ou INCONNU pour le membre technique.';

-- -----------------------------------------------------------------------------
-- Dimension Patient
-- Minimisation RGPD : ni nom, ni prénom, ni date de naissance.
-- Seuls le sexe harmonisé et la tranche d'âge sont conservés.
-- La clé technique reprend public.patient.id_patient (pseudonyme déjà
-- numérique dans le dump). Le membre Inconnu a la clé -1.
-- -----------------------------------------------------------------------------
CREATE TABLE gold.dim_patient (
    id_patient   integer      NOT NULL,
    sexe         varchar(50)  NOT NULL,
    tranche_age  varchar(50)  NOT NULL,
    CONSTRAINT pk_dim_patient PRIMARY KEY (id_patient),
    CONSTRAINT ck_dim_patient_sexe CHECK (sexe IN ('F', 'M', 'Inconnu')),
    CONSTRAINT ck_dim_patient_tranche CHECK (
        tranche_age IN (
            '0-17', '18-29', '30-44', '45-59', '60-74',
            '75 ans et plus', 'Inconnu'
        )
    )
);

COMMENT ON TABLE gold.dim_patient IS
  'Qui est soigné ? Sexe et tranche d''âge uniquement. Aucune donnée nominative.';
COMMENT ON COLUMN gold.dim_patient.id_patient IS
  'Clé technique. Reprend l''identifiant source ; -1 = membre Inconnu.';
COMMENT ON COLUMN gold.dim_patient.sexe IS
  'Sexe harmonisé : F, M ou Inconnu (source : female / male).';
COMMENT ON COLUMN gold.dim_patient.tranche_age IS
  '0-17, 18-29, 30-44, 45-59, 60-74, 75 ans et plus, Inconnu.';

-- -----------------------------------------------------------------------------
-- Dimension Diagnostic
-- code_diag est la clé naturelle.
-- -----------------------------------------------------------------------------
CREATE TABLE gold.dim_diagnostic (
    id_diagnostic  integer       NOT NULL,
    code_diag      varchar(50)   NOT NULL,
    diagnostic     varchar(250)  NOT NULL,
    CONSTRAINT pk_dim_diagnostic PRIMARY KEY (id_diagnostic),
    CONSTRAINT uq_dim_diagnostic_code UNIQUE (code_diag)
);

COMMENT ON TABLE gold.dim_diagnostic IS
  'Pour quoi ? Référentiel des diagnostics. Clé -1 = membre Inconnu.';
COMMENT ON COLUMN gold.dim_diagnostic.diagnostic IS
  'Libellé. VARCHAR(250) : le dictionnaire logique indiquait VARCHAR(50), '
  'élargi pour ne pas tronquer les libellés source (jusqu''à 250 caractères).';

-- -----------------------------------------------------------------------------
-- Dimension Professionnel
-- Le dump professionnel_de_sante ne porte pas code_specialite ni fonction :
-- ces deux attributs du modèle logique sont chargés à « Non renseigné ».
-- identifiant est la clé naturelle (identifiant du professionnel).
-- -----------------------------------------------------------------------------
CREATE TABLE gold.dim_professionnel (
    id_professionnel          integer      NOT NULL,
    identifiant               varchar(50)  NOT NULL,
    categorie_professionnelle varchar(50)  NOT NULL,
    profession                varchar(50)  NOT NULL,
    code_specialite           varchar(50)  NOT NULL,
    fonction                  varchar(50)  NOT NULL,
    specialite                varchar(100) NOT NULL,
    CONSTRAINT pk_dim_professionnel PRIMARY KEY (id_professionnel),
    CONSTRAINT uq_dim_professionnel_identifiant UNIQUE (identifiant)
);

COMMENT ON TABLE gold.dim_professionnel IS
  'Par qui ? Catégorie, profession et spécialité. Clé -1 = membre Inconnu.';
COMMENT ON COLUMN gold.dim_professionnel.identifiant IS
  'Clé naturelle du professionnel dans la source. Pas un nom.';
COMMENT ON COLUMN gold.dim_professionnel.code_specialite IS
  'Absent du dump source : renseigné à « Non renseigné ».';
COMMENT ON COLUMN gold.dim_professionnel.fonction IS
  'Absente du dump source : renseignée à « Non renseigné ».';
COMMENT ON COLUMN gold.dim_professionnel.specialite IS
  'VARCHAR(100) : élargi par rapport au VARCHAR(50) du dictionnaire logique '
  '(libellés source jusqu''à 60 caractères).';

-- -----------------------------------------------------------------------------
-- Dimension Établissement
-- finess_site est la clé naturelle quand elle est connue (9 chiffres).
-- Dans le dump, la plupart des sites n'ont pas de FINESS : la colonne reste
-- NULL (plusieurs NULL sont autorisés par la contrainte d'unicité).
-- La clé technique reprend public.etablissement.id_etablissement, car les
-- consultations sont déjà rattachées par cet identifiant.
-- -----------------------------------------------------------------------------
CREATE TABLE gold.dim_etablissement (
    id_etablissement            integer      NOT NULL,
    code_postal                 varchar(20)  NOT NULL,
    commune                     varchar(50)  NOT NULL,
    finess_site                 varchar(9),
    raison_sociale_site         varchar(200) NOT NULL,
    enseigne_commerciale_site   varchar(50)  NOT NULL,
    pays                        varchar(50)  NOT NULL,
    departement                 varchar(50)  NOT NULL,
    CONSTRAINT pk_dim_etablissement PRIMARY KEY (id_etablissement),
    CONSTRAINT uq_dim_etablissement_finess UNIQUE (finess_site),
    CONSTRAINT ck_dim_etablissement_finess CHECK (
        finess_site IS NULL OR finess_site ~ '^[0-9]{9}$'
    )
);

COMMENT ON TABLE gold.dim_etablissement IS
  'Où ? Site de soins. Clé -1 = membre Inconnu. FINESS sur 9 chiffres si connu.';
COMMENT ON COLUMN gold.dim_etablissement.finess_site IS
  'FINESS de site, complété à 9 chiffres. NULL si absent ou non numérique. '
  'L''unicité autorise plusieurs NULL.';
COMMENT ON COLUMN gold.dim_etablissement.raison_sociale_site IS
  'VARCHAR(200) : élargi par rapport au VARCHAR(50) du dictionnaire logique '
  '(raisons sociales source jusqu''à 164 caractères).';
COMMENT ON COLUMN gold.dim_etablissement.code_postal IS
  'VARCHAR(20) pour accepter le libellé « Non renseigné » quand le code est vide.';
COMMENT ON COLUMN gold.dim_etablissement.departement IS
  'Département source, ou déduit du code postal (2A / 2B pour la Corse).';

-- -----------------------------------------------------------------------------
-- Fait Consultation
-- Grain : une ligne = une consultation.
-- num_consultation est la dimension dégénérée et la clé primaire :
-- on ne l'additionne pas, elle retrouve la consultation source.
-- nb_consultation vaut toujours 1 (mesure additive).
-- -----------------------------------------------------------------------------
CREATE TABLE gold.fait_consultation (
    num_consultation   varchar(50) NOT NULL,
    id_patient         integer     NOT NULL,
    id_temps           integer     NOT NULL,
    id_diagnostic      integer     NOT NULL,
    id_professionnel   integer     NOT NULL,
    id_etablissement   integer     NOT NULL,
    nb_consultation    integer     NOT NULL,
    CONSTRAINT pk_fait_consultation PRIMARY KEY (num_consultation),
    CONSTRAINT ck_fait_consultation_mesure CHECK (nb_consultation = 1),
    CONSTRAINT fk_fait_consultation_patient
        FOREIGN KEY (id_patient) REFERENCES gold.dim_patient (id_patient),
    CONSTRAINT fk_fait_consultation_temps
        FOREIGN KEY (id_temps) REFERENCES gold.dim_temps (id_temps),
    CONSTRAINT fk_fait_consultation_diagnostic
        FOREIGN KEY (id_diagnostic) REFERENCES gold.dim_diagnostic (id_diagnostic),
    CONSTRAINT fk_fait_consultation_professionnel
        FOREIGN KEY (id_professionnel) REFERENCES gold.dim_professionnel (id_professionnel),
    CONSTRAINT fk_fait_consultation_etablissement
        FOREIGN KEY (id_etablissement) REFERENCES gold.dim_etablissement (id_etablissement)
);

COMMENT ON TABLE gold.fait_consultation IS
  'Une ligne = une consultation. Mesure nb_consultation = 1. '
  'num_consultation est une dimension dégénérée.';
COMMENT ON COLUMN gold.fait_consultation.nb_consultation IS
  'Mesure additive, constante égale à 1. Le volume s''obtient par SUM.';
COMMENT ON COLUMN gold.fait_consultation.num_consultation IS
  'Numéro source. Dimension dégénérée : ne pas l''agréger.';

-- -----------------------------------------------------------------------------
-- Fait Hospitalisation
-- Une ligne = un séjour. Le séjour est relié à l'établissement.
-- La durée source s'appelle duree_sejour ; en gold elle s'appelle duree_jour.
-- num_hospitalisation sert seulement au dédoublonnage : il n'est pas chargé.
-- Un patient ou une date introuvable rejette la ligne. Un diagnostic ou un
-- établissement introuvable est rattaché au membre Inconnu (clé -1).
-- -----------------------------------------------------------------------------
CREATE TABLE gold.fait_hospitalisation (
    id_hospitalisation  bigint GENERATED ALWAYS AS IDENTITY,
    id_patient          integer NOT NULL,
    id_temps            integer NOT NULL,
    id_diagnostic       integer NOT NULL,
    id_etablissement    integer NOT NULL,
    nb_hospitalisation  integer NOT NULL,
    duree_jour          integer NOT NULL,
    CONSTRAINT pk_fait_hospitalisation PRIMARY KEY (id_hospitalisation),
    CONSTRAINT ck_fait_hospitalisation_mesure CHECK (nb_hospitalisation = 1),
    CONSTRAINT ck_fait_hospitalisation_duree CHECK (duree_jour >= 0),
    CONSTRAINT fk_fait_hospitalisation_patient
        FOREIGN KEY (id_patient) REFERENCES gold.dim_patient (id_patient),
    CONSTRAINT fk_fait_hospitalisation_temps
        FOREIGN KEY (id_temps) REFERENCES gold.dim_temps (id_temps),
    CONSTRAINT fk_fait_hospitalisation_diagnostic
        FOREIGN KEY (id_diagnostic) REFERENCES gold.dim_diagnostic (id_diagnostic),
    CONSTRAINT fk_fait_hospitalisation_etablissement
        FOREIGN KEY (id_etablissement) REFERENCES gold.dim_etablissement (id_etablissement)
);

COMMENT ON TABLE gold.fait_hospitalisation IS
  'Une ligne = une hospitalisation, reliée à un établissement. '
  'Mesures : nb_hospitalisation = 1, duree_jour (additive).';
COMMENT ON COLUMN gold.fait_hospitalisation.duree_jour IS
  'Durée du séjour en jours, reprise de public.hospitalisation.duree_sejour.';
COMMENT ON COLUMN gold.fait_hospitalisation.id_etablissement IS
  'Établissement du séjour. Clé étrangère vers dim_etablissement.';

-- -----------------------------------------------------------------------------
-- Rejets de chargement
-- Trace la règle non respectée et la clé source, sans recopier la ligne
-- (pas de nom, pas de contenu médical libre). Cf. livrable 1, section 4.4.
-- -----------------------------------------------------------------------------
CREATE TABLE gold.rejet_chargement (
    id_rejet      bigint GENERATED ALWAYS AS IDENTITY,
    job           varchar(50)  NOT NULL,
    source_table  varchar(100) NOT NULL,
    cle_source    varchar(50),
    regle         varchar(200) NOT NULL,
    horodatage    timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT pk_rejet_chargement PRIMARY KEY (id_rejet)
);

COMMENT ON TABLE gold.rejet_chargement IS
  'Lignes refusées au chargement Gold. Clé et règle uniquement, pas le contenu.';
