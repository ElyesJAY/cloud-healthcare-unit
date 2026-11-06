# Cloud Healthcare Unit — Livrable 2

Entrepôt de données décisionnel du groupe hospitalier.  
Ce dépôt contient la partie **création des tables** et **chargement des données** (couche Gold).

Auteur : elyesjay  
Référence : livrable 1 du groupe (modèle en constellation, PostgreSQL, schéma `gold`).

## À quoi sert ce dépôt

La base envoyée par le groupe (`public`) sert à enregistrer les soins. Elle n'est pas faite pour les questions du type « combien de consultations par mois et par diagnostic ».

La couche **gold** est une deuxième organisation des mêmes informations, prévue pour ces questions :

- une ligne de dimension décrit un contexte (un jour, un patient, un diagnostic, un professionnel, un établissement) ;
- une ligne de fait compte un événement (une consultation, plus tard une hospitalisation).

Les noms et les prénoms ne sont pas copiés dans gold. Le patient n'y a que un sexe harmonisé et une tranche d'âge.

## Ce qui est dans ce dépôt

| Fichier | Rôle |
|---|---|
| `sql/01_ddl_gold.sql` | Crée le schéma `gold`, les 5 dimensions, les 2 faits, la table des rejets, les clés primaires, les clés étrangères et les contrôles. |
| `sql/02_dml_chargement_gold.sql` | Vide gold puis recharge les dimensions et les consultations depuis `public`. Le script peut être relancé. |

Le partitionnement, les index secondaires, les graphiques de temps de réponse et le tableau de bord ne sont pas dans ce dépôt. Ce sont d'autres parties du livrable 2.

## Modèle

Cinq dimensions, partagées :

| Table | Question | Clé primaire | Clé naturelle |
|---|---|---|---|
| `gold.dim_temps` | Quand ? | `id_temps` | `date_complete` (`AAAA-MM-JJ`) |
| `gold.dim_patient` | Qui ? | `id_patient` | — (sexe + tranche d'âge seulement) |
| `gold.dim_diagnostic` | Pour quoi ? | `id_diagnostic` | `code_diag` |
| `gold.dim_professionnel` | Par qui ? | `id_professionnel` | `identifiant` |
| `gold.dim_etablissement` | Où ? | `id_etablissement` | `finess_site` (9 chiffres, ou vide) |

Deux faits :

| Table | Une ligne = | Mesures | Liens |
|---|---|---|---|
| `gold.fait_consultation` | une consultation | `nb_consultation` = 1 | patient, temps, diagnostic, professionnel, établissement |
| `gold.fait_hospitalisation` | une hospitalisation | `nb_hospitalisation` = 1, `duree_jour` | patient, temps, diagnostic |

`num_consultation` est le numéro d'origine. On ne l'additionne pas : il sert à retrouver la consultation source. C'est aussi la clé primaire du fait.

Chaque dimension a une ligne technique **Inconnu**, de clé `-1`. Règles de chargement :

- patient introuvable sur une consultation : la ligne n'est pas chargée, elle est notée dans `gold.rejet_chargement` (numéro et règle seulement, pas le contenu) ;
- autre clé introuvable : rattachement à la ligne Inconnu ;
- libellé vide : `Non renseigné` ;
- FINESS non numérique : laissé vide. Plusieurs établissements peuvent ne pas avoir de FINESS.

Les clés techniques de gold reprennent les identifiants de `public`, pour que les consultations retrouvent les bonnes lignes. Le membre Inconnu est le seul identifiant ajouté (`-1`).

### Écarts assumés avec le dictionnaire du livrable 1

Le dictionnaire logique indiquait `VARCHAR(50)` partout. Quelques colonnes sont plus larges, sinon le texte source serait coupé :

- libellé de diagnostic : `varchar(250)` ;
- raison sociale : `varchar(200)` ;
- spécialité : `varchar(100)` ;
- code postal : `varchar(20)`, pour pouvoir écrire `Non renseigné`.

`code_specialite` et `fonction` sont dans le modèle. Le dump source ne les contient pas : elles sont remplies avec `Non renseigné`.

`female` / `male` deviennent `F` / `M`. `75+` devient `75 ans et plus`.

## Source utilisée

Dump PostgreSQL 18 : `dump-healthcare-202611060942`.

Tables lues dans le schéma `public` :

- `consultation`
- `patient`
- `diagnostic`
- `professionnel_de_sante`
- `etablissement`
- `temps`

Le dump du 6 novembre 2026 à 08:13 ne contient pas les hospitalisations. Le dump de 09:42 ajoute `public.hospitalisation` (2 479 séjours : numéro, patient, diagnostic, établissement, date). Cette table n'a pas la durée du séjour. `fait_hospitalisation` est donc créée, avec ses contraintes, mais elle n'est pas alimentée. La durée ne doit pas être inventée. Le lien vers l'établissement, présent dans ce dump, n'est pas dans le modèle du livrable 1 : il n'est pas ajouté tant que le groupe ne l'a pas décidé.

## Installation sur Mac

PostgreSQL 18, sans machine virtuelle :

```bash
brew install postgresql@18
brew services start postgresql@18
echo 'export PATH="/opt/homebrew/opt/postgresql@18/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

Restaurer le dump, créer les tables, charger les données :

```bash
createdb healthcare
pg_restore --no-owner --no-privileges -d healthcare "/chemin/vers/dump-healthcare-202611060942"
psql -d healthcare -v ON_ERROR_STOP=1 -f sql/01_ddl_gold.sql
psql -d healthcare -v ON_ERROR_STOP=1 -f sql/02_dml_chargement_gold.sql
```

`01_ddl_gold.sql` supprime et recrée le schéma `gold`. `02_dml_chargement_gold.sql` vide les tables puis les remplit. Relancer les deux scripts remet gold dans le même état.

## Résultat du chargement du 6 novembre 2026

Exécuté sur la base restaurée depuis `dump-healthcare-202611060942`. Le script a affiché :

`Gold chargé : 1027157 consultations, 0 rejets patient, 100001 patients (dont Inconnu).`

| Table | Lignes | Lecture |
|---|---:|---|
| `dim_temps` | 100 001 | 100 000 jours du calendrier source, plus Inconnu |
| `dim_patient` | 100 001 | 100 000 patients, plus Inconnu |
| `dim_diagnostic` | 15 491 | 15 490 codes, plus Inconnu |
| `dim_professionnel` | 1 048 576 | 1 048 575 professionnels, plus Inconnu |
| `dim_etablissement` | 416 666 | 416 665 établissements, plus Inconnu |
| `fait_consultation` | 1 027 157 | toutes les consultations source |
| `fait_hospitalisation` | 0 | table prête, source non chargée |
| `rejet_chargement` | 0 | aucune ligne refusée |

Le calendrier source va du 1er janvier 2015 jusqu'en 2288 (100 000 jours). Les consultations n'utilisent que la fenêtre du 20 juin 2015 au 31 mars 2023. Toutes les dates sont conservées pour ne pas casser les clés `id_temps`.

## Contrôles d'intégrité

Posés dans le DDL, vérifiés par le chargement (un lien faux annule toute la transaction) :

- clé primaire sur chaque table ;
- clé étrangère de chaque fait vers ses dimensions ;
- `nb_consultation = 1` et `nb_hospitalisation = 1` ;
- `duree_jour >= 0` ;
- sexe parmi `F`, `M`, `Inconnu` ;
- tranche d'âge parmi les sept valeurs du livrable 1 ;
- code diagnostic unique ;
- identifiant professionnel unique ;
- date unique ;
- FINESS unique quand il est renseigné, et uniquement 9 chiffres.

Le script de chargement vérifie aussi que chaque consultation source est soit chargée, soit rejetée, et que `dim_patient` contient exactement les patients source plus la ligne Inconnu.

## Ordre des pull requests

Les changements sont séparés pour la relecture :

1. Documentation de ce dépôt.
2. Création des tables (`01_ddl_gold.sql`).
3. Chargement des consultations (`02_dml_chargement_gold.sql`).

À merger dans cet ordre. Les relecteurs peuvent être ajoutés sur chaque pull request.
