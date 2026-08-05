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

- **`LocalStorageAdapter`** (pour démarrer maintenant) : données dans le
  navigateur + export / import JSON manuel. Permet de développer et tester à deux
  immédiatement, sans attendre aucune validation.
- **`SupabaseAdapter`** (cible probable) : base PostgreSQL en ligne, temps réel
  natif, gratuit, compte perso. À brancher si la voie Google est refusée.
- **`GoogleDriveAdapter`** (cible alternative) : lecture/écriture d'un fichier
  JSON sur Drive via l'API Google Drive. À brancher si la DSI Veolia accorde
  les accès (demande ServiceNow en cours).

> IMPORTANT : commencer par `LocalStorageAdapter`. Le choix Supabase vs Drive
> dépend d'une réponse de la DSI Veolia encore en attente. L'architecture doit
> permettre de brancher l'un ou l'autre en fin de projet sans réécriture.

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
| `assigne_a` | texte | ajouté à l'étape 5 : nécessaire pour l'affichage et le filtre par personne sur les cartes Kanban (§5.2), absent du schéma initial |
| `phase` | liste | voir valeurs ci-dessous |
| `type` | liste | Appel d'offres, Renouvellement, Avenant, Sollicitation directe, Proposition travaux |
| `type_marche` | multi-liste | P1, P2, P3, CPE, R1, R2, GTR, Gaz |
| `valeur_estimee_keur` | nombre | en k€ |
| `amo` | texte | assistance à maîtrise d'ouvrage |
| `concurrence` | texte | concurrents identifiés |
| `date_remise` | date | date limite de remise de l'offre |
| `date_visite` | date | visite éventuelle |
| `date_prise_effet` | date | prise d'effet du contrat |
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

### 4.2 Tâches

Repris du Todo Notion existant, enrichi.

| Champ | Type | Notes |
|---|---|---|
| `id` | identifiant unique | |
| `tache` | texte | intitulé |
| `statut` | liste | Pas commencé, En cours, Terminé |
| `echeance` | date | |
| `assigne_a` | personne | Mathis ou collègue |
| `priorite` | liste | Normale, Haute (= flag rouge / critique) |
| `notes` | texte | |
| `rappel` | rappel | date + déclenchement (voir §4.4) |
| `ao_lie` | relation | vers l'AO parent |

### 4.3 Contacts (nouvelle entité)

| Champ | Type | Notes |
|---|---|---|
| `id` | identifiant unique | |
| `nom` | texte | |
| `fonction` | texte | rôle / poste |
| `organisme` | texte | structure (peut recouper `nom_client` d'un AO) |
| `telephone` | texte | |
| `email` | texte | |
| `adresse` | texte | |
| `notes` | texte | |
| `rappel` | rappel | ex. « relancer le 15 » |
| `ao_lies` | relation | vers un ou plusieurs AO |

### 4.4 Rappel (mécanisme, pas une entité)

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
- Vue Kanban : colonnes = phases, cartes = AO.
- Glisser-déposer des cartes entre colonnes pour changer la phase.
- Sur chaque carte : nom, client, type de marché, jours restants avant remise, assigné.
- Filtres : par type de client, par type de marché, par personne.

### 5.3 ToDo (deux niveaux)
- Tâches rattachées à leur AO (visibles sur la fiche AO).
- Vue globale transversale, filtrable par personne, triée par échéance et priorité.
- Tâches en priorité Haute remontées en tête avec flag rouge.
- Cases à cocher pour marquer terminé.

### 5.4 Contacts
- Annuaire simple : liste + fiche détail.
- Lien vers les AO associés.
- Possibilité de poser un rappel de relance sur un contact.

### 5.5 Reporting
- Taux de réussite global (gagnés / déposés).
- Montant total gagné.
- Répartition par type de marché.
- Répartition / taux de réussite par type de client.
- Évolution dans le temps (par mois).

### 5.6 Moteur de rappels
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
10. (Plus tard, selon réponse DSI) `SupabaseAdapter` OU `GoogleDriveAdapter`,
    branché à la place du `LocalStorageAdapter` sans toucher au reste.

---

## 8. Ce qui reste en attente (ne pas bloquer dessus)

- Réponse de la DSI Veolia (demande ServiceNow « VED - Demande Data ») sur
  l'accès à l'API Google Drive.
- Selon la réponse : on branche `GoogleDriveAdapter` (si accès accordé) ou
  `SupabaseAdapter` (solution externe autonome, compte perso).
- Tant que la réponse n'est pas là, on développe et on utilise l'outil avec
  `LocalStorageAdapter` + export/import JSON.
