-- Migration : contrathèque (2026-11-12). Crée la table contrats (vide :
-- l'import des contrats existants se fera depuis l'app) et remplace
-- save_crm_data pour l'enregistrer. Ré-exécutable sans danger.
--
-- À exécuter dans le SQL Editor Supabase AVANT de publier la nouvelle
-- version de crm.html.

-- ---------------------------------------------------------------------------
-- 4 bis. Contrathèque (2026-11-12, migrate_contrats.sql) — un contrat par
-- affaire, nommé comme l'affaire (ex. la résidence), pas comme le pouvoir
-- adjudicateur (qui peut changer : simple lien vers entreprises).
-- Avenants portés par le contrat (jsonb [{id, date, prestations, statut,
-- lien, notes, ao_id}]). La prochaine échéance est calculée côté client
-- (date_fin + reconductions tacites successives). Aucun filtrage.
-- ---------------------------------------------------------------------------

create table if not exists public.contrats (
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

drop policy if exists contrats_all on public.contrats;
create policy contrats_all on public.contrats
  for all to authenticated
  using (true)
  with check (true);

do $$
begin
  alter publication supabase_realtime add table public.contrats;
exception when duplicate_object then null;
end $$;

-- Remplace save_crm_data (ajout de la section contrats).
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
