-- ===========================================================================
-- CRM AO Veolia Nouvelle-Aquitaine — schéma Supabase
--
-- À exécuter UNE FOIS dans l'éditeur SQL du projet Supabase (Dashboard >
-- SQL Editor > New query), en une seule fois, sur un projet neuf.
--
-- Correspond au modèle de données figé dans PROJET.md §4, enrichi du champ
-- `service` (accès différencié par service, voir plan de migration) et des
-- colonnes de suivi `last_modified` / `modified_by` déjà utilisées côté JS
-- (crm.html, fonction `stamp()`).
-- ===========================================================================
--
-- Réexécutable sans risque (idempotent) : relancer ce fichier en entier
-- réinitialise complètement le schéma (tables + policies + fonctions), y
-- compris pour corriger une erreur de conception après coup (ex. type des
-- identifiants). Toutes les données des tables aos/taches/contacts/profiles
-- sont perdues à chaque réexécution — ce n'est PAS un script de migration
-- incrémentale, seulement un script d'initialisation.
-- ===========================================================================

drop trigger if exists on_auth_user_created on auth.users;
drop table if exists public.taches cascade;
drop table if exists public.aos cascade;
drop table if exists public.contacts cascade;
drop table if exists public.contrats cascade;
drop table if exists public.entreprises cascade;
drop table if exists public.profiles cascade;
drop table if exists public.app_meta cascade;

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- 1. Profils utilisateurs
--
-- Un profil par compte Auth Supabase. Créé automatiquement à l'inscription
-- (trigger plus bas) avec role='user' et service='{}' ; à compléter ensuite
-- par l'admin depuis le Table Editor (role, service, display_name).
-- ---------------------------------------------------------------------------

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null default '',
  role text not null default 'user' check (role in ('admin', 'user')),
  service text[] not null default '{}',
  created_at timestamptz not null default now()
);

-- Fonction utilitaire : l'utilisateur courant est-il admin ?
-- SECURITY DEFINER : contourne le RLS sur profiles pour éviter toute
-- récursion des policies qui l'utilisent (select sur profiles depuis une
-- policy de profiles).
create or replace function public.is_admin()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.profiles where id = auth.uid() and role = 'admin'
  );
$$;

-- Création auto du profil à l'inscription d'un utilisateur (Dashboard >
-- Authentication > Add user). display_name par défaut = partie locale de
-- l'email ; à corriger ensuite manuellement si besoin.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name, role, service)
  values (new.id, split_part(new.email, '@', 1), 'user', '{}');
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Empêche un utilisateur non-admin de modifier son propre role/service
-- (seul display_name reste éditable par soi-même) ; l'admin peut tout
-- modifier sur n'importe quel profil.
create or replace function public.protect_profile_privileges()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- auth.uid() est NULL quand la requête vient du SQL Editor (ou d'un appel
  -- service_role) : ce sont des contextes de confiance (l'admin y a de toute
  -- façon les pleins pouvoirs), donc on ne protège que les appels faits par
  -- un utilisateur authentifié via l'app qui n'est pas admin.
  if auth.uid() is not null and not public.is_admin() then
    new.role := old.role;
    new.service := old.service;
  end if;
  return new;
end;
$$;

create trigger protect_profile_privileges_trigger
  before update on public.profiles
  for each row execute function public.protect_profile_privileges();

alter table public.profiles enable row level security;

create policy profiles_select on public.profiles
  for select to authenticated
  using (true);

create policy profiles_update on public.profiles
  for update to authenticated
  using (auth.uid() = id or public.is_admin())
  with check (auth.uid() = id or public.is_admin());

-- Pas de policy insert/delete : seule la fonction handle_new_user()
-- (SECURITY DEFINER) peut créer un profil ; aucune suppression via l'API.

-- ---------------------------------------------------------------------------
-- 3 bis. Entreprises (2026-11-12, migrate_entreprises.sql) — référentiel
-- unique des organismes (maîtres d'ouvrage, syndics, AMO / BE…) : les
-- contacts, les AO (maître d'ouvrage, AMO) et plus tard les contrats y sont
-- rattachés au lieu de porter un nom en champ libre. Un seul rôle par
-- entreprise. Aucun filtrage (visibles par tous, comme les contacts).
-- ---------------------------------------------------------------------------

create table public.entreprises (
  id text primary key default gen_random_uuid()::text,
  nom text not null default '',
  role text not null default '',
  notes text not null default '',
  last_modified timestamptz not null default now(),
  modified_by text not null default ''
);

alter table public.entreprises enable row level security;

create policy entreprises_all on public.entreprises
  for all to authenticated
  using (true)
  with check (true);

-- ---------------------------------------------------------------------------
-- 2. AO (appels d'offres) — PROJET.md §4.1
-- ---------------------------------------------------------------------------

-- id en `text`, pas `uuid` : les enregistrements existants (créés avant cette
-- migration, ex. exports LocalStorage) utilisent des identifiants du type
-- "ao_685804", pas des UUID. Les nouveaux id générés côté client
-- (crypto.randomUUID(), voir generateId() dans crm.html) restent des chaînes
-- valides pour une colonne text, donc aucune conversion n'est nécessaire.
create table public.aos (
  id text primary key default gen_random_uuid()::text,
  nom_projet text not null default '',
  type_client text not null default 'Habitat',
  -- Priorité commerciale (2026-11-11, migrate_ao_priorite.sql) : Haute,
  -- Moyenne, Basse ou '' (non définie). Colore les cartes du pipeline.
  priorite text not null default '',
  -- Maître d'ouvrage et AMO / BE (2026-11-12) : liens vers le référentiel
  -- entreprises. La colonne texte `amo` est l'ancien champ libre, conservée
  -- pour l'historique (plus écrite par l'app).
  maitre_ouvrage_id text references public.entreprises (id) on delete set null,
  amo_id text references public.entreprises (id) on delete set null,
  -- Tableau (comme taches.assigne_a) depuis migrate_ao_assignes.sql : un AO
  -- peut être suivi par plusieurs personnes.
  assigne_a text[] not null default '{}',
  phase text not null default 'a_venir',
  type text not null default 'Appel d''offres',
  type_marche text[] not null default '{}',
  service text[] not null default '{}',
  valeur_estimee_keur numeric,
  amo text not null default '',
  concurrence text not null default '',
  date_remise date,
  date_visite date,
  date_prise_effet date,
  -- Posée automatiquement (côté client) à la première sortie de "a_venir",
  -- mais reste un champ normal modifiable à la main (plan de charge, §9/§10
  -- PROJET.md) : pas d'historique fiable pour les AO déjà avancés avant
  -- l'ajout de ce champ.
  date_entree_etude date,
  lieu text not null default '',
  notes text not null default '',
  fichiers text[] not null default '{}',
  resultat text not null default 'En cours',
  motif_categorie text not null default '',
  motif text not null default '',
  rappel jsonb,
  contacts_lies text[] not null default '{}',
  taches_liees text[] not null default '{}',
  last_modified timestamptz not null default now(),
  modified_by text not null default ''
);

-- Visible si admin, si l'AO n'est pas encore taggé d'un service (migration
-- douce des AO existants), ou si le service de l'AO recoupe un des services
-- du profil courant.
create or replace function public.ao_visible(ao_service text[])
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select
    public.is_admin()
    or ao_service is null
    or array_length(ao_service, 1) is null
    or ao_service && coalesce(
      (select service from public.profiles where id = auth.uid()),
      '{}'::text[]
    );
$$;

alter table public.aos enable row level security;

create policy aos_select on public.aos
  for select to authenticated
  using (public.ao_visible(service));

create policy aos_insert on public.aos
  for insert to authenticated
  with check (true);

create policy aos_update on public.aos
  for update to authenticated
  using (public.ao_visible(service))
  with check (public.ao_visible(service));

create policy aos_delete on public.aos
  for delete to authenticated
  using (public.ao_visible(service));

-- ---------------------------------------------------------------------------
-- 3. Tâches — PROJET.md §4.2 (personnelles : visibles par leur assigné + admin)
-- ---------------------------------------------------------------------------

create table public.taches (
  id text primary key default gen_random_uuid()::text,
  tache text not null default '',
  statut text not null default 'Pas commencé',
  date_debut date,
  echeance date,
  -- Multi-valeurs : la tâche est personnelle par défaut (soi-même) mais peut
  -- être partagée avec d'autres (ajout du 2026-09-29).
  assigne_a text[] not null default '{}',
  priorite text not null default 'Normale',
  notes text not null default '',
  rappel jsonb,
  -- Sous-tâches (2026-11-11, migrate_sous_taches.sql) : simples lignes à
  -- cocher portées par la tâche, [{id, texte, fait}].
  sous_taches jsonb not null default '[]'::jsonb,
  ao_lie text references public.aos (id) on delete set null,
  last_modified timestamptz not null default now(),
  modified_by text not null default ''
);

-- Une tâche est visible par l'admin, par ses assignés, et (depuis
-- migrate_taches_par_ao.sql, 2026-11-12) par toute personne qui voit l'AO
-- auquel elle est liée : on retrouve toutes les tâches d'un projet sur sa
-- fiche, assignées à quelqu'un d'autre ou à personne. Une tâche sans AO
-- reste personnelle.
create or replace function public.tache_visible(t_assigne_a text[], t_ao_lie text)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select
    public.is_admin()
    or coalesce(
      (select display_name from public.profiles where id = auth.uid()),
      ''
    ) = any(t_assigne_a)
    or (
      t_ao_lie is not null
      and exists (select 1 from public.aos a where a.id = t_ao_lie and public.ao_visible(a.service))
    );
$$;

alter table public.taches enable row level security;

create policy taches_select on public.taches
  for select to authenticated
  using (public.tache_visible(assigne_a, ao_lie));

create policy taches_insert on public.taches
  for insert to authenticated
  with check (true);

create policy taches_update on public.taches
  for update to authenticated
  using (public.tache_visible(assigne_a, ao_lie))
  with check (public.tache_visible(assigne_a, ao_lie));

create policy taches_delete on public.taches
  for delete to authenticated
  using (public.tache_visible(assigne_a, ao_lie));

-- ---------------------------------------------------------------------------
-- 4. Contacts — PROJET.md §4.3 (aucun filtrage, visibles par tous)
-- ---------------------------------------------------------------------------

create table public.contacts (
  id text primary key default gen_random_uuid()::text,
  nom text not null default '',
  fonction text not null default '',
  organisme text not null default '',
  -- Catégorie d'annuaire (2026-11-11, migrate_contact_categorie.sql) :
  -- Client, Prospect, AMO / Bureau d'études… ou '' (sans catégorie).
  categorie text not null default '',
  -- Entreprise du contact (2026-11-12). Si renseignée, c'est son rôle qui
  -- sert de catégorie ; `organisme` reste le nom en clair (recopié).
  entreprise_id text references public.entreprises (id) on delete set null,
  telephone text not null default '',
  email text not null default '',
  adresse text not null default '',
  notes text not null default '',
  rappel jsonb,
  ao_lies text[] not null default '{}',
  last_modified timestamptz not null default now(),
  modified_by text not null default ''
);

alter table public.contacts enable row level security;

create policy contacts_all on public.contacts
  for all to authenticated
  using (true)
  with check (true);

-- ---------------------------------------------------------------------------
-- 4 bis. Contrathèque (2026-11-12, migrate_contrats.sql) — un contrat par
-- affaire, nommé comme l'affaire (ex. la résidence), pas comme le pouvoir
-- adjudicateur (qui peut changer : simple lien vers entreprises).
-- Avenants portés par le contrat (jsonb [{id, date, prestations, statut,
-- lien, notes, ao_id}]). La prochaine échéance est calculée côté client
-- (date_fin + reconductions tacites successives). Aucun filtrage.
-- ---------------------------------------------------------------------------

create table public.contrats (
  id text primary key default gen_random_uuid()::text,
  nom text not null default '',
  maitre_ouvrage_id text references public.entreprises (id) on delete set null,
  amo_id text references public.entreprises (id) on delete set null,
  secteur text not null default '',
  prestations text[] not null default '{}',
  statut text not null default 'Actif',
  date_debut date,
  duree_mois integer,
  date_fin date,
  reconduction text not null default '',
  duree_reconduction_mois integer,
  alerte_mois integer not null default 12,
  montant numeric,
  lien text not null default '',
  ao_origine_id text references public.aos (id) on delete set null,
  avenants jsonb not null default '[]'::jsonb,
  notes text not null default '',
  last_modified timestamptz not null default now(),
  modified_by text not null default ''
);

alter table public.contrats enable row level security;

create policy contrats_all on public.contrats
  for all to authenticated
  using (true)
  with check (true);

-- ---------------------------------------------------------------------------
-- 5. Statut global (indicatif uniquement — la concurrence réelle est gérée
-- par enregistrement via save_crm_data, pas par cette table).
-- ---------------------------------------------------------------------------

create table public.app_meta (
  id boolean primary key default true,
  last_modified timestamptz,
  modified_by text,
  constraint app_meta_singleton check (id)
);

insert into public.app_meta (id, last_modified, modified_by) values (true, null, null);

alter table public.app_meta enable row level security;

create policy app_meta_select on public.app_meta
  for select to authenticated
  using (true);

-- ---------------------------------------------------------------------------
-- 6. save_crm_data — écriture atomique avec conflits par enregistrement.
--
-- Le client (SupabaseAdapter.save() dans crm.html) envoie uniquement le DIFF
-- depuis son dernier load() : les lignes ajoutées/modifiées (avec
-- expected_last_modified = la valeur qu'il avait en mémoire, ou null pour une
-- création) et les lignes supprimées (id + expected_last_modified).
--
-- Pour chaque changement :
--   - création (expected_last_modified null) -> insert.
--   - modification/suppression -> n'aboutit que si last_modified en base
--     correspond encore à expected_last_modified ; sinon la ligne est
--     ajoutée à la liste de conflits renvoyée (le JS lève StorageConflictError
--     et mutateData() recharge + réapplique, voir crm.html:1982).
--
-- SECURITY DEFINER : nécessaire pour la logique de conflit personnalisée,
-- donc les contrôles d'accès (ao_visible / tache_visible / is_admin) sont
-- ré-appliqués explicitement ligne par ligne ci-dessous, indépendamment du
-- RLS de la table (qui reste actif pour un accès direct à l'API REST).
-- ---------------------------------------------------------------------------

-- Convertit une valeur JSON en text[] en acceptant aussi l'ancien format
-- texte simple (ex. "Mathis" -> {Mathis}, "" ou null -> {}) : un onglet
-- resté ouvert sur une ancienne version de crm.html peut encore envoyer
-- aos.assigne_a sous forme de texte après la migration.
create or replace function public.jsonb_text_array_lenient(v jsonb)
returns text[]
language sql
immutable
as $$
  select case jsonb_typeof(v)
    when 'array' then array(select jsonb_array_elements_text(v))
    when 'string' then case when v #>> '{}' = '' then '{}'::text[] else array[v #>> '{}'] end
    else '{}'::text[]
  end;
$$;

create or replace function public.save_crm_data(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller_name text;
  conflicts jsonb := '[]'::jsonb;
  forbidden jsonb := '[]'::jsonb;
  row_data jsonb;
  row_id text;
  expected timestamptz;
  affected int;
  table_name text;
begin
  select display_name into caller_name from public.profiles where id = auth.uid();
  caller_name := coalesce(caller_name, '');

  -- ---- entreprises (créations/modifications en premier : un AO ou un
  -- contact enregistré dans le même appel peut référencer une entreprise
  -- qui vient d'être créée ; suppressions en dernier, voir plus bas) ----
  for row_data in select * from jsonb_array_elements(coalesce(payload->'entreprises'->'upsert', '[]'::jsonb))
  loop
    row_id := row_data->>'id';
    expected := nullif(row_data->>'expected_last_modified', '')::timestamptz;

    if expected is null then
      insert into public.entreprises (id, nom, role, notes, last_modified, modified_by)
      values (
        coalesce(row_id, gen_random_uuid()::text),
        coalesce(row_data->>'nom', ''), coalesce(row_data->>'role', ''),
        coalesce(row_data->>'notes', ''), now(), caller_name
      );
    else
      update public.entreprises set
        nom = coalesce(row_data->>'nom', ''),
        role = coalesce(row_data->>'role', ''),
        notes = coalesce(row_data->>'notes', ''),
        last_modified = now(),
        modified_by = caller_name
      where id = row_id and last_modified = expected;

      get diagnostics affected = row_count;
      if affected = 0 then
        conflicts := conflicts || jsonb_build_object('table', 'entreprises', 'id', row_id);
      end if;
    end if;
  end loop;

  -- ---- aos ----
  for row_data in select * from jsonb_array_elements(coalesce(payload->'aos'->'upsert', '[]'::jsonb))
  loop
    row_id := row_data->>'id';
    expected := nullif(row_data->>'expected_last_modified', '')::timestamptz;

    -- Le contrôle d'accès porte sur la ligne EXISTANTE (pas sur le service
    -- qu'on est en train d'écrire) : une création est toujours permise, une
    -- modification/suppression exige que la ligne actuelle en base soit déjà
    -- visible par l'appelant (même règle que la lecture, ao_visible()).
    if expected is not null and not exists (
      select 1 from public.aos where id = row_id and public.ao_visible(service)
    ) then
      forbidden := forbidden || jsonb_build_object('table', 'aos', 'id', row_id);
      continue;
    end if;

    if expected is null then
      insert into public.aos (
        id, nom_projet, type_client, priorite, maitre_ouvrage_id, amo_id, assigne_a, phase, type, type_marche, service,
        valeur_estimee_keur, amo, concurrence, date_remise, date_visite, date_prise_effet,
        date_entree_etude,
        lieu, notes, fichiers, resultat, motif_categorie, motif, rappel,
        contacts_lies, taches_liees, last_modified, modified_by
      ) values (
        coalesce(row_id, gen_random_uuid()::text),
        coalesce(row_data->>'nom_projet', ''), coalesce(row_data->>'type_client', 'Habitat'),
        coalesce(row_data->>'priorite', ''),
        nullif(row_data->>'maitre_ouvrage_id', ''), nullif(row_data->>'amo_id', ''),
        public.jsonb_text_array_lenient(row_data->'assigne_a'), coalesce(row_data->>'phase', 'a_venir'),
        coalesce(row_data->>'type', 'Appel d''offres'),
        coalesce((select array(select jsonb_array_elements_text(row_data->'type_marche'))), '{}'),
        coalesce((select array(select jsonb_array_elements_text(row_data->'service'))), '{}'),
        nullif(row_data->>'valeur_estimee_keur', '')::numeric,
        coalesce(row_data->>'amo', ''), coalesce(row_data->>'concurrence', ''),
        nullif(row_data->>'date_remise', '')::date, nullif(row_data->>'date_visite', '')::date,
        nullif(row_data->>'date_prise_effet', '')::date,
        nullif(row_data->>'date_entree_etude', '')::date,
        coalesce(row_data->>'lieu', ''), coalesce(row_data->>'notes', ''),
        coalesce((select array(select jsonb_array_elements_text(row_data->'fichiers'))), '{}'),
        coalesce(row_data->>'resultat', 'En cours'), coalesce(row_data->>'motif_categorie', ''),
        coalesce(row_data->>'motif', ''), row_data->'rappel',
        coalesce((select array(select jsonb_array_elements_text(row_data->'contacts_lies'))), '{}'),
        coalesce((select array(select jsonb_array_elements_text(row_data->'taches_liees'))), '{}'),
        now(), caller_name
      );
    else
      update public.aos set
        nom_projet = coalesce(row_data->>'nom_projet', ''),
        type_client = coalesce(row_data->>'type_client', 'Habitat'),
        priorite = coalesce(row_data->>'priorite', ''),
        maitre_ouvrage_id = nullif(row_data->>'maitre_ouvrage_id', ''),
        amo_id = nullif(row_data->>'amo_id', ''),
        assigne_a = public.jsonb_text_array_lenient(row_data->'assigne_a'),
        phase = coalesce(row_data->>'phase', 'a_venir'),
        type = coalesce(row_data->>'type', 'Appel d''offres'),
        type_marche = coalesce((select array(select jsonb_array_elements_text(row_data->'type_marche'))), '{}'),
        service = coalesce((select array(select jsonb_array_elements_text(row_data->'service'))), '{}'),
        valeur_estimee_keur = nullif(row_data->>'valeur_estimee_keur', '')::numeric,
        amo = coalesce(row_data->>'amo', ''),
        concurrence = coalesce(row_data->>'concurrence', ''),
        date_remise = nullif(row_data->>'date_remise', '')::date,
        date_visite = nullif(row_data->>'date_visite', '')::date,
        date_prise_effet = nullif(row_data->>'date_prise_effet', '')::date,
        date_entree_etude = nullif(row_data->>'date_entree_etude', '')::date,
        lieu = coalesce(row_data->>'lieu', ''),
        notes = coalesce(row_data->>'notes', ''),
        fichiers = coalesce((select array(select jsonb_array_elements_text(row_data->'fichiers'))), '{}'),
        resultat = coalesce(row_data->>'resultat', 'En cours'),
        motif_categorie = coalesce(row_data->>'motif_categorie', ''),
        motif = coalesce(row_data->>'motif', ''),
        rappel = row_data->'rappel',
        contacts_lies = coalesce((select array(select jsonb_array_elements_text(row_data->'contacts_lies'))), '{}'),
        taches_liees = coalesce((select array(select jsonb_array_elements_text(row_data->'taches_liees'))), '{}'),
        last_modified = now(),
        modified_by = caller_name
      where id = row_id and last_modified = expected;

      get diagnostics affected = row_count;
      if affected = 0 then
        conflicts := conflicts || jsonb_build_object('table', 'aos', 'id', row_id);
      end if;
    end if;
  end loop;

  for row_data in select * from jsonb_array_elements(coalesce(payload->'aos'->'delete', '[]'::jsonb))
  loop
    row_id := row_data->>'id';
    expected := nullif(row_data->>'expected_last_modified', '')::timestamptz;

    if not exists (select 1 from public.aos where id = row_id and public.ao_visible(service)) then
      forbidden := forbidden || jsonb_build_object('table', 'aos', 'id', row_id);
      continue;
    end if;

    delete from public.aos where id = row_id and last_modified = expected;
    get diagnostics affected = row_count;
    if affected = 0 then
      conflicts := conflicts || jsonb_build_object('table', 'aos', 'id', row_id);
    end if;
  end loop;

  -- ---- contrats (après les aos : ao_origine_id peut viser un AO créé
  -- dans le même appel) ----
  for row_data in select * from jsonb_array_elements(coalesce(payload->'contrats'->'upsert', '[]'::jsonb))
  loop
    row_id := row_data->>'id';
    expected := nullif(row_data->>'expected_last_modified', '')::timestamptz;

    if expected is null then
      insert into public.contrats (
        id, nom, maitre_ouvrage_id, amo_id, secteur, prestations, statut,
        date_debut, duree_mois, date_fin, reconduction, duree_reconduction_mois,
        alerte_mois, montant, lien, ao_origine_id, avenants, notes,
        last_modified, modified_by
      ) values (
        coalesce(row_id, gen_random_uuid()::text),
        coalesce(row_data->>'nom', ''),
        nullif(row_data->>'maitre_ouvrage_id', ''), nullif(row_data->>'amo_id', ''),
        coalesce(row_data->>'secteur', ''),
        public.jsonb_text_array_lenient(row_data->'prestations'),
        coalesce(nullif(row_data->>'statut', ''), 'Actif'),
        nullif(row_data->>'date_debut', '')::date, nullif(row_data->>'duree_mois', '')::integer,
        nullif(row_data->>'date_fin', '')::date, coalesce(row_data->>'reconduction', ''),
        nullif(row_data->>'duree_reconduction_mois', '')::integer,
        coalesce(nullif(row_data->>'alerte_mois', '')::integer, 12),
        nullif(row_data->>'montant', '')::numeric, coalesce(row_data->>'lien', ''),
        nullif(row_data->>'ao_origine_id', ''),
        case when jsonb_typeof(row_data->'avenants') = 'array' then row_data->'avenants' else '[]'::jsonb end,
        coalesce(row_data->>'notes', ''),
        now(), caller_name
      );
    else
      update public.contrats set
        nom = coalesce(row_data->>'nom', ''),
        maitre_ouvrage_id = nullif(row_data->>'maitre_ouvrage_id', ''),
        amo_id = nullif(row_data->>'amo_id', ''),
        secteur = coalesce(row_data->>'secteur', ''),
        prestations = public.jsonb_text_array_lenient(row_data->'prestations'),
        statut = coalesce(nullif(row_data->>'statut', ''), 'Actif'),
        date_debut = nullif(row_data->>'date_debut', '')::date,
        duree_mois = nullif(row_data->>'duree_mois', '')::integer,
        date_fin = nullif(row_data->>'date_fin', '')::date,
        reconduction = coalesce(row_data->>'reconduction', ''),
        duree_reconduction_mois = nullif(row_data->>'duree_reconduction_mois', '')::integer,
        alerte_mois = coalesce(nullif(row_data->>'alerte_mois', '')::integer, 12),
        montant = nullif(row_data->>'montant', '')::numeric,
        lien = coalesce(row_data->>'lien', ''),
        ao_origine_id = nullif(row_data->>'ao_origine_id', ''),
        avenants = case when jsonb_typeof(row_data->'avenants') = 'array' then row_data->'avenants' else '[]'::jsonb end,
        notes = coalesce(row_data->>'notes', ''),
        last_modified = now(),
        modified_by = caller_name
      where id = row_id and last_modified = expected;

      get diagnostics affected = row_count;
      if affected = 0 then
        conflicts := conflicts || jsonb_build_object('table', 'contrats', 'id', row_id);
      end if;
    end if;
  end loop;

  for row_data in select * from jsonb_array_elements(coalesce(payload->'contrats'->'delete', '[]'::jsonb))
  loop
    row_id := row_data->>'id';
    expected := nullif(row_data->>'expected_last_modified', '')::timestamptz;
    delete from public.contrats where id = row_id and last_modified = expected;
    get diagnostics affected = row_count;
    if affected = 0 then
      conflicts := conflicts || jsonb_build_object('table', 'contrats', 'id', row_id);
    end if;
  end loop;

  -- ---- taches ----
  for row_data in select * from jsonb_array_elements(coalesce(payload->'taches'->'upsert', '[]'::jsonb))
  loop
    row_id := row_data->>'id';
    expected := nullif(row_data->>'expected_last_modified', '')::timestamptz;

    -- Comme pour aos : contrôle sur la ligne existante, pas sur la nouvelle
    -- valeur d'assigne_a. Une création est toujours permise.
    if expected is not null and not exists (
      select 1 from public.taches where id = row_id and public.tache_visible(assigne_a, ao_lie)
    ) then
      forbidden := forbidden || jsonb_build_object('table', 'taches', 'id', row_id);
      continue;
    end if;

    if expected is null then
      insert into public.taches (
        id, tache, statut, date_debut, echeance, assigne_a, priorite, notes,
        rappel, sous_taches, ao_lie, last_modified, modified_by
      ) values (
        coalesce(row_id, gen_random_uuid()::text),
        coalesce(row_data->>'tache', ''), coalesce(row_data->>'statut', 'Pas commencé'),
        nullif(row_data->>'date_debut', '')::date, nullif(row_data->>'echeance', '')::date,
        coalesce((select array(select jsonb_array_elements_text(row_data->'assigne_a'))), '{}'),
        coalesce(row_data->>'priorite', 'Normale'),
        coalesce(row_data->>'notes', ''), row_data->'rappel',
        coalesce(row_data->'sous_taches', '[]'::jsonb),
        nullif(row_data->>'ao_lie', ''), now(), caller_name
      );
    else
      update public.taches set
        tache = coalesce(row_data->>'tache', ''),
        statut = coalesce(row_data->>'statut', 'Pas commencé'),
        date_debut = nullif(row_data->>'date_debut', '')::date,
        echeance = nullif(row_data->>'echeance', '')::date,
        assigne_a = coalesce((select array(select jsonb_array_elements_text(row_data->'assigne_a'))), '{}'),
        priorite = coalesce(row_data->>'priorite', 'Normale'),
        notes = coalesce(row_data->>'notes', ''),
        rappel = row_data->'rappel',
        sous_taches = coalesce(row_data->'sous_taches', '[]'::jsonb),
        ao_lie = nullif(row_data->>'ao_lie', ''),
        last_modified = now(),
        modified_by = caller_name
      where id = row_id and last_modified = expected;

      get diagnostics affected = row_count;
      if affected = 0 then
        conflicts := conflicts || jsonb_build_object('table', 'taches', 'id', row_id);
      end if;
    end if;
  end loop;

  for row_data in select * from jsonb_array_elements(coalesce(payload->'taches'->'delete', '[]'::jsonb))
  loop
    row_id := row_data->>'id';
    expected := nullif(row_data->>'expected_last_modified', '')::timestamptz;

    if not exists (select 1 from public.taches where id = row_id and public.tache_visible(assigne_a, ao_lie)) then
      forbidden := forbidden || jsonb_build_object('table', 'taches', 'id', row_id);
      continue;
    end if;

    delete from public.taches where id = row_id and last_modified = expected;
    get diagnostics affected = row_count;
    if affected = 0 then
      conflicts := conflicts || jsonb_build_object('table', 'taches', 'id', row_id);
    end if;
  end loop;

  -- ---- contacts (pas de filtrage d'accès) ----
  for row_data in select * from jsonb_array_elements(coalesce(payload->'contacts'->'upsert', '[]'::jsonb))
  loop
    row_id := row_data->>'id';
    expected := nullif(row_data->>'expected_last_modified', '')::timestamptz;

    if expected is null then
      insert into public.contacts (
        id, nom, fonction, organisme, categorie, entreprise_id, telephone, email, adresse, notes,
        rappel, ao_lies, last_modified, modified_by
      ) values (
        coalesce(row_id, gen_random_uuid()::text),
        coalesce(row_data->>'nom', ''), coalesce(row_data->>'fonction', ''),
        coalesce(row_data->>'organisme', ''), coalesce(row_data->>'categorie', ''),
        nullif(row_data->>'entreprise_id', ''),
        coalesce(row_data->>'telephone', ''),
        coalesce(row_data->>'email', ''), coalesce(row_data->>'adresse', ''),
        coalesce(row_data->>'notes', ''), row_data->'rappel',
        coalesce((select array(select jsonb_array_elements_text(row_data->'ao_lies'))), '{}'),
        now(), caller_name
      );
    else
      update public.contacts set
        nom = coalesce(row_data->>'nom', ''),
        fonction = coalesce(row_data->>'fonction', ''),
        organisme = coalesce(row_data->>'organisme', ''),
        categorie = coalesce(row_data->>'categorie', ''),
        entreprise_id = nullif(row_data->>'entreprise_id', ''),
        telephone = coalesce(row_data->>'telephone', ''),
        email = coalesce(row_data->>'email', ''),
        adresse = coalesce(row_data->>'adresse', ''),
        notes = coalesce(row_data->>'notes', ''),
        rappel = row_data->'rappel',
        ao_lies = coalesce((select array(select jsonb_array_elements_text(row_data->'ao_lies'))), '{}'),
        last_modified = now(),
        modified_by = caller_name
      where id = row_id and last_modified = expected;

      get diagnostics affected = row_count;
      if affected = 0 then
        conflicts := conflicts || jsonb_build_object('table', 'contacts', 'id', row_id);
      end if;
    end if;
  end loop;

  for row_data in select * from jsonb_array_elements(coalesce(payload->'contacts'->'delete', '[]'::jsonb))
  loop
    row_id := row_data->>'id';
    expected := nullif(row_data->>'expected_last_modified', '')::timestamptz;
    delete from public.contacts where id = row_id and last_modified = expected;
    get diagnostics affected = row_count;
    if affected = 0 then
      conflicts := conflicts || jsonb_build_object('table', 'contacts', 'id', row_id);
    end if;
  end loop;

  for row_data in select * from jsonb_array_elements(coalesce(payload->'entreprises'->'delete', '[]'::jsonb))
  loop
    row_id := row_data->>'id';
    expected := nullif(row_data->>'expected_last_modified', '')::timestamptz;
    delete from public.entreprises where id = row_id and last_modified = expected;
    get diagnostics affected = row_count;
    if affected = 0 then
      conflicts := conflicts || jsonb_build_object('table', 'entreprises', 'id', row_id);
    end if;
  end loop;

  update public.app_meta set last_modified = now(), modified_by = caller_name where id = true;

  return jsonb_build_object('conflicts', conflicts, 'forbidden', forbidden, 'last_modified', now());
end;
$$;

grant execute on function public.save_crm_data(jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Temps réel : à activer une fois dans le Dashboard (Database > Replication)
-- ou via ce bloc, pour que SupabaseAdapter.subscribe() reçoive les
-- changements des autres utilisateurs (aos, taches, contacts).
-- ---------------------------------------------------------------------------

alter publication supabase_realtime add table public.aos;
alter publication supabase_realtime add table public.taches;
alter publication supabase_realtime add table public.contacts;
alter publication supabase_realtime add table public.entreprises;
alter publication supabase_realtime add table public.contrats;

-- ---------------------------------------------------------------------------
-- 8. Rattrapage des comptes Auth déjà créés avant ce (re)passage du script
-- (le trigger handle_new_user() ne se déclenche qu'à la création d'un
-- nouveau compte, pas rétroactivement sur les comptes existants). Après ce
-- script, retourner dans Table Editor > profiles pour repasser `role` en
-- 'admin' sur ta propre ligne (réinitialisé à 'user' par défaut).
-- ---------------------------------------------------------------------------

insert into public.profiles (id, display_name, role, service)
select id, split_part(email, '@', 1), 'user', '{}'
from auth.users
on conflict (id) do nothing;
