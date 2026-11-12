# CRM AO — Suivi des appels d'offres · Veolia Nouvelle-Aquitaine

Document de cadrage pour la construction de l'outil avec Claude Code.
À lire en premier avant d'écrire du code.

---

## 1. Objectif

Construire un outil interne léger de suivi des appels d'offres (AO), partagé
entre deux personnes (Mathis + un collègue) de l'agence Nouvelle-Aquitaine.

L'outil remplace un workflow Notion existant (bases « Pipeline » et « Todo ») en
l'enrichissant : pipeline plus riche, système de rappels, gestion de contacts,
et reporting sur les AO.

**Ce que l'outil doit apporter, par ordre de priorité :**
1. Rappels / relances (échéances de remise, tâches, relances manuelles).
2. Reporting / statistiques sur les AO (taux de réussite, montants, répartition).
3. Vue pipeline plus riche que le Notion actuel.

---

## 2. Contraintes fortes (à respecter absolument)

- **Postes de travail = Chromebook (ChromeOS).** Pas de Python ni d'installation
  locale possible sur les postes pro. L'outil DOIT être une application web qui
  tourne entièrement dans le navigateur.
- **Doit aussi tourner sur Windows** (travail depuis la maison). Une app web pure
  répond nativement à ce besoin.
- **Gratuit.** Aucune dépendance à un service payant.
- **Partagé à deux.** Mathis fait les évolutions ; les deux tiennent les données
  à jour.
- **Pas d'email.** Les comptes Veolia bloquent l'envoi de mails automatiques.
  Les rappels passent donc par l'affichage dans l'app, pas par mail.
- **Données = AO publics.** Aucune donnée personnelle ni confidentielle.

---

## 3. Architecture cible

Application web **full-navigateur**, en un seul fichier HTML autonome
(`crm.html`) contenant la structure, le style et la logique.

**Principe clé : la couche de stockage est ISOLÉE du reste de l'application.**

L'app ne parle jamais directement au stockage. Elle passe par une interface
unique (un « adaptateur de stockage ») avec quatre opérations :

```
  load()        -> renvoie toutes les données
  save(data)    -> enregistre toutes les données
  subscribe(cb) -> notifie quand les données changent (pour le temps réel)
  meta()        -> infos de version / dernière modif (anti-conflit)
```

Derrière cette interface, on peut brancher plusieurs implémentations SANS
toucher au reste de l'app :

- **`LocalStorageAdapter`** : données dans le navigateur + export / import
  JSON manuel. Utilisé pour démarrer le projet ; reste dans le fichier comme
  secours / dev hors ligne, mais n'est plus l'adaptateur actif.
- **`SupabaseAdapter`** (actif depuis le 2026-09-09) : base PostgreSQL en
  ligne (projet Supabase perso, gratuit), Auth + Realtime natifs, RLS pour
  l'accès différencié par service (voir §4.1 et §9). Schéma versionné dans
  `supabase/schema.sql`.
- **`GoogleDriveAdapter`** : abandonné — le RDV DSI Veolia du 2026-09 a
  confirmé que l'accès à l'API Google Drive via compte pro n'est pas jouable
  en l'état. On part sur l'hébergement externe (Supabase) à la place.

> L'adaptateur actif se bascule à un seul endroit dans `crm.html`
> (`const storageAdapter = ...`), sans toucher au reste de l'app — c'est tout
> l'intérêt de cette interface.

---

## 4. Schéma de données (FIGÉ)

Trois entités : **AO**, **Tâches**, **Contacts**. Les rappels sont toujours
rattachés à l'une de ces entités (pas d'entité rappel autonome).

### 4.1 AO (appel d'offres)

Repris du Pipeline Notion existant, enrichi.

| Champ | Type | Notes |
|---|---|---|
| `id` | identifiant unique | généré automatiquement |
| `nom_projet` | texte | titre de l'AO |
| `type_client` | liste | Habitat, Collectivité, Santé, Enseignement, Tertiaire, Autre |
| `assigne_a` | multi-personnes | ajouté à l'étape 5 (affichage et filtre par personne sur les cartes Kanban, §5.2). Modifié le 2026-11-11 : tableau comme pour les tâches (`supabase/migrate_ao_assignes.sql`), soi-même coché par défaut à la création |
| `phase` | liste | voir valeurs ci-dessous |
| `type` | liste | Appel d'offres, Renouvellement, Avenant, Sollicitation directe, Proposition travaux |
| `priorite` | liste | ajouté le 2026-11-11 (`supabase/migrate_ao_priorite.sql`) : Haute, Moyenne, Basse ou vide. Colore les cartes du pipeline (liseré + pastille), et sert de filtre (volontairement aucun tri par priorité) |
| `type_marche` | multi-liste | P1, P2, P3, CPE, R1, R2, GTR, Gaz |
| `service` | multi-liste | ajouté le 2026-09-09 : Commerce, Travaux — pilote la visibilité par service (§9). Vide = visible par tout le monde (migration douce des AO existants) |
| `valeur_estimee_keur` | nombre | en k€ |
| `amo` | texte | assistance à maîtrise d'ouvrage |
| `concurrence` | texte | concurrents identifiés |
| `date_remise` | date | date limite de remise de l'offre |
| `date_visite` | date | visite éventuelle |
| `date_prise_effet` | date | prise d'effet du contrat |
| `duree_contrat_mois` | nombre | ajouté le 2026-11-12 (`supabase/migrate_ao_contrat.sql`) : durée du futur contrat, reprise comme durée du contrat créé quand l'AO est gagné |
| `date_entree_etude` | date | ajouté le 2026-10-07 : posée automatiquement à la première sortie de la phase "A venir", reste modifiable à la main. Alimente le plan de charge (§10) |
| `lieu` | texte | localisation |
| `notes` | texte long | |
| `fichiers` | liste de liens | liens vers livrables (résumé de lecture, mémoire technique…) |
| `resultat` | liste | En cours, Gagné, Perdu, Abandonné |
| `motif_categorie` | liste | ajouté ultérieurement : Prix, Technique, Mauvais environnement, Autre — saisie obligatoire via pop-up quand l'AO passe en Perdu (Kanban), alimente le graphe Reporting |
| `motif` | texte | détail libre facultatif du motif de perte |
| `rappel` | rappel | date + type de déclenchement (voir §4.4) |
| `contacts_lies` | relation | vers un ou plusieurs Contacts |
| `taches_liees` | relation | vers une ou plusieurs Tâches |

**Valeurs de `phase`** (reprises du Notion, ordre du pipeline) :
`A venir` → `Étude` → `Finalisation` → `🤝 Négociation` →
`⏳ En attente de réponse` → `✅ Gagné` / `❌ Perdu` / `🚫 Abandonné`

Depuis le 2026-11-11, chaque onglet de service a ses propres colonnes
(`PIPELINE_PHASES_BY_SERVICE` dans crm.html) et `Finalisation` est supprimée
(ses AO repassent en `Étude`) :
- **Commerce** : A venir → A faire → Étude → Négociation → En attente de réponse →
  Gagné / Perdu / Abandonné
- **Travaux** : A venir → A faire → Étude → En attente de réponse → Exécution →
  Facturé / Fini (id `gagne`) / Perdu / Abandonné. `Exécution` compte comme
  `Gagné` côté résultat et Reporting.

Colonne `A faire` (id `a_faire`, ajoutée le 2026-11-11) entre `A venir` et
`Étude` : `A venir` = AO pas encore sortis (veille), `A faire` = travail
demandé mais pas encore démarré (avenants, sollicitations…). Comme `A venir`,
elle ne compte pas comme charge : `date_entree_etude` n'est posée qu'à la
sortie des deux, et le Reporting les exclut toutes les deux.

### 4.2 Tâches

Repris du Todo Notion existant, enrichi.

| Champ | Type | Notes |
|---|---|---|
| `id` | identifiant unique | |
| `tache` | texte | intitulé |
| `statut` | liste | Pas commencé, En cours, Terminé. Depuis la refonte ToDo du 2026-11-11, l'interface n'utilise plus qu'une case à cocher (Terminé / Pas commencé) ; « En cours » n'est plus proposé |
| `date_debut` | date | ajouté ultérieurement, facultatif : si renseignée, la tâche s'étale sur plusieurs jours dans le calendrier ToDo (barre continue) — `echeance` reste la date de fin |
| `echeance` | date | date de fin / échéance (seule date utilisée pour le tri, les rappels et les autres écrans si `date_debut` est vide) |
| `assigne_a` | multi-personnes | modifié le 2026-09-29 : tableau, pas un texte simple. Le 2026-11-11 (refonte ToDo) il avait été masqué ; **réintroduit le 2026-11-12** : cases « Assigné à » dans le formulaire (soi-même coché par défaut), pour assigner une tâche à quelqu'un d'autre (ex. le directeur qui assigne des tâches sur un AO). Au moins une personne obligatoire ; hors admin, se décocher demande confirmation (on perd l'accès, RLS §9) |
| `priorite` | liste | Normale, Haute (= flag rouge / critique) |
| `notes` | texte | |
| `rappel` | rappel | date + déclenchement (voir §4.4) |
| `sous_taches` | liste | ajouté le 2026-11-11 (`supabase/migrate_sous_taches.sql`) : `[{id, texte, fait}]`, simples lignes à cocher portées par la tâche |
| `ao_lie` | relation | vers l'AO parent |

### 4.3 Contacts (nouvelle entité)

| Champ | Type | Notes |
|---|---|---|
| `id` | identifiant unique | |
| `nom` | texte | |
| `fonction` | texte | rôle / poste |
| `organisme` | texte | structure (peut recouper `nom_client` d'un AO) |
| `categorie` | liste | ajouté le 2026-11-11 (`supabase/migrate_contact_categorie.sql`) : Client, Prospect, AMO / Bureau d'études, Partenaire / Sous-traitant, Fournisseur, Interne Veolia, Autre, ou vide (liste `CONTACT_CATEGORIES` dans crm.html) |
| `telephone` | texte | |
| `email` | texte | |
| `adresse` | texte | |
| `notes` | texte | |
| `rappel` | rappel | ex. « relancer le 15 » |
| `ao_lies` | relation | vers un ou plusieurs AO |

### 4.3 bis Entreprises (ajouté le 2026-11-12, `supabase/migrate_entreprises.sql`)

Référentiel unique des organismes, pour ne plus avoir de noms en champ libre
un peu partout. **Un seul rôle par entreprise** (Actia Concept = toujours
syndic, Soconer = toujours AMO / BE).

| Champ | Type | Notes |
|---|---|---|
| `id` | identifiant unique | |
| `nom` | texte | |
| `role` | liste | Maître d'ouvrage, Syndic / Gestionnaire, AMO / BE, Partenaire / Sous-traitant, Fournisseur, Interne Veolia, Autre (`ENTREPRISE_ROLES` dans crm.html) |
| `notes` | texte | |

Liens : `contacts.entreprise_id`, `aos.maitre_ouvrage_id`, `aos.amo_id` (et
plus tard les contrats). Un contact rattaché prend le rôle de son entreprise
comme catégorie ; sans entreprise il garde sa propre `categorie`. Les
anciennes colonnes texte (`aos.amo`, `contacts.organisme`) sont conservées :
la migration a créé une entreprise par valeur distincte (variantes de
casse / accents / espaces regroupées) et rattaché AO et contacts.
Plus de lien direct contact <-> AO (2026-11-12) : la fiche AO affiche les
contacts de son maître d'ouvrage et de son AMO ; les colonnes
`contacts.ao_lies` / `aos.contacts_lies` restent en base mais ne sont plus
modifiées. Écran : Contacts > vue **Entreprises** (tuiles par rôle, fiche avec ses
contacts et les AO où elle intervient) ; fiche AO : listes déroulantes
« Maître d'ouvrage » et « AMO / BE » (avec création à la volée).

### 4.3 ter Contrats — contrathèque (ajouté le 2026-11-12, `supabase/migrate_contrats.sql`)

Un contrat par affaire, **nommé comme l'affaire** (ex. « Résidence Les
Arènes »), pas comme le pouvoir adjudicateur, qui n'est qu'un lien (peut
changer).

| Champ | Type | Notes |
|---|---|---|
| `nom` | texte | nom de l'affaire |
| `maitre_ouvrage_id`, `amo_id` | relation | vers entreprises |
| `secteur` | liste | découpage de l'agence : B1, B2, B3 (reporting) |
| `prestations` | multi-liste | P1, P2, P3, P5, PFI, R1, R2, CPE |
| `statut` | liste | Actif, Terminé, Résilié |
| `date_debut`, `duree_mois`, `date_fin` | date / nombre | fin = y compris reconductions déjà prévues |
| `reconduction`, `duree_reconduction_mois` | liste / nombre | Tacite, Expresse, Non |
| `alerte_mois` | nombre | défaut 12 : la renégociation apparaît N mois avant l'échéance |
| `montant` | nombre | € |
| `lien` | texte | dossier Drive |
| `ao_origine_id` | relation | AO dont il est issu |
| `avenants` | liste | `[{id, date, prestations, statut, lien, notes, ao_id}]` |
| `notes` | texte | bloc-notes |

**Prochaine échéance** (calculée, `contratProchaineEcheance`) : date de fin
(ou début + durée) ; si tacite reconduction et date passée, on ajoute la
durée de reconduction jusqu'à tomber dans le futur ; échéance passée sans
moyen de la recalculer = « À vérifier ». **À renégocier** = contrat actif
dont l'échéance tombe dans les `alerte_mois` à venir. Écran Contrathèque
(liste triée par échéance, filtres statut / secteur / prestation / à
renégocier) + fiche pleine page avec bouton Enregistrer ; les fiches
entreprise listent aussi leurs contrats.

**Liens pipeline ↔ contrathèque (2026-11-12, `supabase/migrate_ao_contrat.sql`)** :
- `aos.contrat_id` : contrat auquel se rattache un AO de type Avenant
  (obligatoire, création bloquée sans) ou Renouvellement. Choisir le
  contrat reprend son maître d'ouvrage / AMO si l'AO n'en a pas.
- AO passé en Gagné (barre de phases ou glisser-déposer) :
  Avenant → proposé à l'ajout dans l'historique d'avenants du contrat ;
  Renouvellement rattaché → ouvre le contrat pour mettre ses dates à jour ;
  autre AO → propose de créer le contrat, pré-rempli et **nommé comme
  l'AO** (`contratPresetFromAO`), avec `ao_origine_id`.
- Fiche contrat : liste des AO liés + « Lancer un avenant dans le
  pipeline » (AO Avenant créé en « A faire », rattaché au contrat).

### 4.4 Rappel (mécanisme, pas une entité) — SUPPRIMÉ de l'interface le 2026-11-11

> Jamais utilisé en pratique : cloche, panneau « Rappels actifs » de l'accueil
> et champs Rappel des fiches AO / tâche / contact retirés. La colonne
> `rappel` reste en base (données existantes conservées, plus lues ni écrites).


Un rappel est un petit objet porté par un AO, une Tâche ou un Contact :

| Champ | Type | Notes |
|---|---|---|
| `date` | date | quand le rappel se déclenche |
| `declenchement` | liste | Sur date manuelle, X jours avant échéance remise, X jours avant visite, X jours avant prise d'effet |
| `jours_avant` | nombre | si déclenchement relatif à une date de l'AO |
| `message` | texte | libellé libre du rappel |
| `actif` | booléen | rappel traité ou non |

---

## 5. Fonctionnalités à construire

### 5.1 Écran d'accueil (récap)
- Compteurs : AO en cours, échéances < 7 jours, tâches ouvertes, AO en attente de résultat.
- Liste des échéances proches (calcul automatique des jours restants).
- Rappels actifs du jour (issus des AO, tâches, contacts).
- Points critiques : tâches en priorité Haute (flags rouges).

### 5.2 Pipeline
- Depuis le 2026-11-11 : colonnes Gagné / Perdu / Abandonné repliées par
  défaut (clic sur l'en-tête pour déplier ; on peut toujours y déposer une
  carte repliée), code couleur par priorité (voir `priorite` §4.1).
- Vue Kanban : colonnes = phases, cartes = AO.
- Glisser-déposer des cartes entre colonnes pour changer la phase.
- Sur chaque carte : nom, client, type de marché, jours restants avant remise, assigné.
- Filtres : par type de client, par type de marché, par personne.

### 5.2 bis Fiche AO (refonte 2026-11-11)
- Clic sur un AO = fiche quasi pleine page (façon Pipedrive) : nom éditable
  en en-tête, barre de phases cliquable (Gagné / Perdu / Abandonné à droite,
  pop-up motif obligatoire pour Perdu), infos clés dans une colonne à gauche,
  grand **bloc-notes libre** (champ `notes`) à droite + mes tâches liées.
- Enregistrement automatique champ par champ (pas de bouton Enregistrer) :
  seuls les champs modifiés sont envoyés, sans contrôle de version global,
  pour que deux personnes éditant des champs différents ne s'écrasent pas.
  Un nouvel AO garde un bouton « Créer l'AO ».

### 5.3 ToDo (deux niveaux)

Refonte du 2026-11-11 : vue **Liste** par défaut (tâches groupées En retard /
Aujourd'hui / Demain / 7 prochains jours / Plus tard / Sans échéance, puis
Terminées), case à cocher seule, sous-tâches ajoutables directement dans la
liste, champ d'ajout rapide (titre + échéance). Bouton pour basculer en vue
**Calendrier** (le calendrier mensuel existant). Plus de statut.

Tâches assignables (réintroduit le 2026-11-12) : filtre « Mes tâches »
(défaut, = celles où je suis dans `assigne_a`, y compris celles qu'on m'a
assignées) / « Tâches de X » / « Toutes les tâches » (toutes pour l'admin,
celles partagées avec moi sinon, RLS oblige). Avec « Tâches de X » choisi,
l'ajout rapide et le formulaire assignent par défaut soi-même + X. Chaque
tâche partagée affiche « 👥 avec X » (ou « 👥 X » si je n'y suis pas). L'accueil
reste sur « mes tâches ». Une tâche sans assigné n'est plus comptée comme
« mienne » : elle apparaît dans « Non assignées » (option du filtre), dans
« Toutes les tâches », et avec la mention « 👤 Non assignée ».

La fiche AO affiche **toutes les tâches du projet** (section « Tâches du
projet »), quel que soit l'assigné, avec la mention des assignés.

- Tâches rattachées à leur AO (visibles sur la fiche AO).
- Vue globale transversale, filtrable par personne, triée par échéance et priorité.
- Tâches en priorité Haute remontées en tête avec flag rouge.
- Cases à cocher pour marquer terminé.

### 5.4 Contacts
- Refonte du 2026-11-11 : une seule barre de recherche sur tous les champs
  (nom, organisme, fonction, téléphone, email, notes, nom des AO liés),
  insensible aux accents, chaque mot tapé devant apparaître quelque part ;
  accueil de l'annuaire = uniquement les catégories en tuiles (avec
  compteur) ; un clic ouvre la liste de la catégorie, avec des pastilles pour
  passer d'une catégorie à l'autre et « ← Catégories » pour revenir. Taper
  dans la recherche affiche directement les résultats, toutes catégories.
- Annuaire simple : liste + fiche détail.
- Lien vers les AO associés.
- Possibilité de poser un rappel de relance sur un contact.

### 5.5 Reporting
- Taux de réussite global (gagnés / déposés).
- Montant total gagné.
- Répartition par type de marché.
- Répartition / taux de réussite par type de client.
- Évolution dans le temps (par mois).

### 5.6 Moteur de rappels — supprimé le 2026-11-11 (voir §4.4)
- Au chargement de l'app : calcule quels rappels sont actifs (date atteinte,
  ou échéance AO dans X jours).
- Affiche une cloche de notifications avec le nombre de rappels actifs.
- Les rappels s'affichent aussi dans l'écran d'accueil.
- Un rappel peut être marqué comme traité.

---

## 6. Garde-fous techniques (à imposer)

- **Aucune dépendance à un service payant.** Tout doit tourner gratuitement.
- **Aucun stockage navigateur pour l'état applicatif hors adaptateur.** Toutes les
  données passent par l'adaptateur de stockage (§3), jamais en dur ailleurs.
- **Écriture sûre.** Quand on branchera Drive : écriture atomique du JSON
  (fichier temporaire puis renommage), jamais d'écriture partielle.
- **Anti-conflit à deux.** Chaque enregistrement (AO / tâche / contact) porte un
  `last_modified` et un `modified_by`. Avant d'écraser, vérifier qu'un autre
  n'a pas modifié entre-temps ; sinon recharger et signaler.
- **Verrouillage au niveau de l'enregistrement, pas du fichier global.** Éditer
  l'AO A et l'AO B en même temps ne doit jamais créer de conflit.
- **Sauvegarde.** Prévoir un export JSON complet manuel à tout moment (filet de
  sécurité, et mécanisme de partage en phase LocalStorage).
- **Compatible Chromebook.** HTML/CSS/JS standard, aucune API non supportée par
  ChromeOS, aucune install requise.

---

## 7. Ordre de construction suggéré

1. Structure du fichier `crm.html` + interface de l'adaptateur de stockage.
2. `LocalStorageAdapter` + export / import JSON.
3. Modèle de données (AO, Tâches, Contacts) selon le §4.
4. Écran d'accueil (récap).
5. Pipeline Kanban avec glisser-déposer.
6. ToDo (globale + par AO).
7. Contacts.
8. Moteur de rappels + cloche de notifications.
9. Reporting.
10. **Fait (2026-09-09)** : `SupabaseAdapter` branché à la place du
    `LocalStorageAdapter`, sans modification du reste de l'app. Gestion des
    utilisateurs (Supabase Auth) et accès différenciés par service (RLS) mis
    en place en même temps — voir §9.

---

## 8. Historique de la décision d'hébergement

- La DSI Veolia (demande ServiceNow « VED - Demande Data ») a confirmé lors
  du RDV de début septembre 2026 que l'accès à l'API Google Drive via compte
  pro n'est pas jouable en l'état.
- Décision (2026-09-09) : abandon de la piste `GoogleDriveAdapter`, passage
  direct sur `SupabaseAdapter` (hébergement externe, compte perso gratuit).
- `LocalStorageAdapter` reste dans `crm.html` comme secours / dev hors ligne,
  mais n'est plus l'adaptateur utilisé en usage courant.

---

## 9. Utilisateurs et accès différenciés (ajouté le 2026-09-09)

L'équipe dépasse les 2 personnes historiques (5-6 personnes visées). La
gestion des comptes s'appuie sur **Supabase Auth** ; les accès sont
différenciés par **rôle** et par **service**, imposés côté serveur (RLS
Postgres, `supabase/schema.sql`), pas seulement côté interface.

- **Comptes** : créés par l'admin depuis le Dashboard Supabase
  (Authentication → Add user), avec un mot de passe temporaire défini
  directement (pas d'email d'invitation : le mailer par défaut Supabase est
  trop limité en gratuit). Un trigger crée automatiquement la ligne
  `profiles` correspondante ; l'admin complète ensuite `role` et `service`
  via le Table Editor (ou `supabase/seed_team.sql` pour plusieurs comptes
  d'un coup). Chacun peut ensuite changer son mot de passe lui-même depuis
  l'app (bouton « Mot de passe » dans le header, sans email non plus).
- **`profiles`** (nouvelle table, hors schéma JSON du §4) : `display_name`,
  `role` (`admin` | `user`), `service` (multi-valeurs, ex. Commerce/Travaux).
- **Rôle `admin`** : voit et modifie tout, sans restriction.
- **Rôle `user`** : accès filtré par service.
  - **AO** : visible si son champ `service` (§4.1) recoupe le/les service(s)
    du profil, ou si `service` est vide (AO pas encore taggé — visible par
    tous par défaut).
  - **Tâches** : **personnelles par défaut, partageables** — visibles par
    toute personne présente dans `assigne_a` (tableau, comparé au
    `display_name` du profil) et par l'admin. Depuis le 2026-11-12
    (`supabase/migrate_taches_par_ao.sql`), une tâche liée à un AO est aussi
    visible et modifiable par toute personne qui voit cet AO (assignée à
    quelqu'un d'autre ou à personne) ; une tâche sans AO reste personnelle. À la création, `assigne_a` est
    automatiquement initialisé avec soi-même ; cocher d'autres personnes dans
    le formulaire partage la tâche avec elles (elles peuvent alors la voir et
    la modifier). La liste des personnes assignables (`ASSIGNE_OPTIONS` dans
    crm.html) est chargée dynamiquement depuis `profiles`, plus besoin de la
    maintenir à la main.
  - **Contacts** : aucun filtrage, visibles par tout le monde (à revoir plus
    tard si besoin).
- La vérification d'accès est faite à la fois par les policies RLS des
  tables (accès direct à l'API) et, en écriture, explicitement dans la
  fonction `save_crm_data` (voir commentaires dans `supabase/schema.sql`).

---

## 10. Plan de charge (ajouté le 2026-10-07)

Nouvel écran "Plan de charge" (nav principale) : un Gantt horizontal par
service (Commerce / Travaux), une barre par AO `En cours` dont
`date_entree_etude` ET `date_remise` sont renseignées (voir §4.1). Fenêtre
glissante d'environ un an (2 mois passés → 10 mois à venir) ; chaque service
a ses propres lanes (algorithme glouton déjà utilisé pour les tâches
multi-jours du calendrier ToDo) pour éviter que des AO qui se chevauchent
dans le temps se superposent visuellement. Un AO sans `date_entree_etude`
n'apparaît pas sur le Gantt tant qu'elle n'est pas renseignée.

**Refonte du 2026-11-11** : le Gantt à barres libres est remplacé par un
tableau par service, plus lisible. Une ligne par AO (nom, date de remise,
assignés et liseré de priorité dans une colonne à gauche), une colonne par
semaine (numéros ISO, regroupés par mois) sur la même fenêtre glissante
(2 mois passés → 10 à venir). Les cases sont remplies de la semaine d'entrée
en étude à celle de la remise (case finale plus foncée), la semaine en cours
est surlignée en rouge. Les colonnes se partagent la largeur de l'écran :
toute la fenêtre est visible sans défilement horizontal. Lignes triées par
date de remise ; les AO en cours sans les deux dates sont comptés sous le
tableau.

## 11. Travail futur demandé, pas commencé

**Contrathèque (en cours, validé le 2026-11-12)** — remplace l'idée
d'« onglet Client ». Ordre : 1. entreprises (fait) ; 2. table + onglet
Contrathèque (fait) (nom de l'affaire en premier, maître d'ouvrage / AMO en
champs) ; 3. AO gagné → contrat (titre de l'AO conservé), AO Avenant
rattaché obligatoirement à un contrat (fait) ; 4. renégociations (alerte 12 mois
avant échéance par défaut, prochaine échéance recalculée pour les tacites
reconductions, AO de renouvellement en un clic, lignes dans le plan de
charge) ; 5. import CSV dans l'app (contrathèque + portefeuille + feuille
Commerce 2027), jamais de données dans le dépôt (public). Secteurs
B1/B2/B3 = découpage de l'agence, champ des contrats pour le reporting.
Jonzac Énergies Vertes reste hors import.

Lors du même retour (2026-10-07), deux autres besoins ont été exprimés mais
mis en attente par Mathis ("dans un premier temps" = plan de charge
d'abord) :
- **Onglet Client** : suivi des infos/échéances du contrat en cours, lié au
  Pipeline (probablement : un AO Gagné devient un client suivi dans le
  temps). Aucune spécification détaillée encore donnée.
- **Onglet Prospection froide** : suivi des partenaires/futurs clients
  démarchés, en amont d'un AO formel. Aucune spécification détaillée encore
  donnée.
