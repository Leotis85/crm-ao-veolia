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
  assigne_a text not null default '',
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
  assigne_a text not null default '',
  priorite text not null default 'Normale',
  notes text not null default '',
  rappel jsonb,
  ao_lie text references public.aos (id) on delete set null,
  last_modified timestamptz not null default now(),
  modified_by text not null default ''
);

create or replace function public.tache_visible(t_assigne_a text)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select
    public.is_admin()
    or t_assigne_a = coalesce(
      (select display_name from public.profiles where id = auth.uid()),
      ''
    );
$$;

alter table public.taches enable row level security;

create policy taches_select on public.taches
  for select to authenticated
  using (public.tache_visible(assigne_a));

create policy taches_insert on public.taches
  for insert to authenticated
  with check (true);

create policy taches_update on public.taches
  for update to authenticated
  using (public.tache_visible(assigne_a))
  with check (public.tache_visible(assigne_a));

create policy taches_delete on public.taches
  for delete to authenticated
  using (public.tache_visible(assigne_a));

-- ---------------------------------------------------------------------------
-- 4. Contacts — PROJET.md §4.3 (aucun filtrage, visibles par tous)
-- ---------------------------------------------------------------------------

create table public.contacts (
  id text primary key default gen_random_uuid()::text,
  nom text not null default '',
  fonction text not null default '',
  organisme text not null default '',
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
        id, nom_projet, type_client, assigne_a, phase, type, type_marche, service,
        valeur_estimee_keur, amo, concurrence, date_remise, date_visite, date_prise_effet,
        lieu, notes, fichiers, resultat, motif_categorie, motif, rappel,
        contacts_lies, taches_liees, last_modified, modified_by
      ) values (
        coalesce(row_id, gen_random_uuid()::text),
        coalesce(row_data->>'nom_projet', ''), coalesce(row_data->>'type_client', 'Habitat'),
        coalesce(row_data->>'assigne_a', ''), coalesce(row_data->>'phase', 'a_venir'),
        coalesce(row_data->>'type', 'Appel d''offres'),
        coalesce((select array(select jsonb_array_elements_text(row_data->'type_marche'))), '{}'),
        coalesce((select array(select jsonb_array_elements_text(row_data->'service'))), '{}'),
        nullif(row_data->>'valeur_estimee_keur', '')::numeric,
        coalesce(row_data->>'amo', ''), coalesce(row_data->>'concurrence', ''),
        nullif(row_data->>'date_remise', '')::date, nullif(row_data->>'date_visite', '')::date,
        nullif(row_data->>'date_prise_effet', '')::date,
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
        assigne_a = coalesce(row_data->>'assigne_a', ''),
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

  -- ---- taches ----
  for row_data in select * from jsonb_array_elements(coalesce(payload->'taches'->'upsert', '[]'::jsonb))
  loop
    row_id := row_data->>'id';
    expected := nullif(row_data->>'expected_last_modified', '')::timestamptz;

    -- Comme pour aos : contrôle sur la ligne existante, pas sur la nouvelle
    -- valeur d'assigne_a. Une création est toujours permise.
    if expected is not null and not exists (
      select 1 from public.taches where id = row_id and public.tache_visible(assigne_a)
    ) then
      forbidden := forbidden || jsonb_build_object('table', 'taches', 'id', row_id);
      continue;
    end if;

    if expected is null then
      insert into public.taches (
        id, tache, statut, date_debut, echeance, assigne_a, priorite, notes,
        rappel, ao_lie, last_modified, modified_by
      ) values (
        coalesce(row_id, gen_random_uuid()::text),
        coalesce(row_data->>'tache', ''), coalesce(row_data->>'statut', 'Pas commencé'),
        nullif(row_data->>'date_debut', '')::date, nullif(row_data->>'echeance', '')::date,
        coalesce(row_data->>'assigne_a', ''), coalesce(row_data->>'priorite', 'Normale'),
        coalesce(row_data->>'notes', ''), row_data->'rappel',
        nullif(row_data->>'ao_lie', ''), now(), caller_name
      );
    else
      update public.taches set
        tache = coalesce(row_data->>'tache', ''),
        statut = coalesce(row_data->>'statut', 'Pas commencé'),
        date_debut = nullif(row_data->>'date_debut', '')::date,
        echeance = nullif(row_data->>'echeance', '')::date,
        assigne_a = coalesce(row_data->>'assigne_a', ''),
        priorite = coalesce(row_data->>'priorite', 'Normale'),
        notes = coalesce(row_data->>'notes', ''),
        rappel = row_data->'rappel',
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

    if not exists (select 1 from public.taches where id = row_id and public.tache_visible(assigne_a)) then
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
        id, nom, fonction, organisme, telephone, email, adresse, notes,
        rappel, ao_lies, last_modified, modified_by
      ) values (
        coalesce(row_id, gen_random_uuid()::text),
        coalesce(row_data->>'nom', ''), coalesce(row_data->>'fonction', ''),
        coalesce(row_data->>'organisme', ''), coalesce(row_data->>'telephone', ''),
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
