-- Migration ciblée (2026-11-12) : toutes les tâches d'un AO deviennent
-- visibles (et modifiables) par toute personne qui voit cet AO, qu'elles
-- soient assignées à quelqu'un d'autre ou à personne. Les tâches sans AO
-- restent personnelles (assignés + admin). Aucune donnée modifiée.
--
-- À exécuter dans le SQL Editor Supabase. Peut passer avant ou après la
-- publication de crm.html : sans la migration, un non-admin ne voit
-- simplement pas les tâches des autres sur la fiche AO.

begin;

drop policy if exists taches_select on public.taches;
drop policy if exists taches_update on public.taches;
drop policy if exists taches_delete on public.taches;

drop function if exists public.tache_visible(text[]);

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

create policy taches_select on public.taches
  for select to authenticated
  using (public.tache_visible(assigne_a, ao_lie));

create policy taches_update on public.taches
  for update to authenticated
  using (public.tache_visible(assigne_a, ao_lie))
  with check (public.tache_visible(assigne_a, ao_lie));

create policy taches_delete on public.taches
  for delete to authenticated
  using (public.tache_visible(assigne_a, ao_lie));

-- Remplace save_crm_data : mêmes contrôles d'accès que les policies
-- ci-dessus (tache_visible prend désormais aussi ao_lie).
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
        id, nom_projet, type_client, priorite, assigne_a, phase, type, type_marche, service,
        valeur_estimee_keur, amo, concurrence, date_remise, date_visite, date_prise_effet,
        date_entree_etude,
        lieu, notes, fichiers, resultat, motif_categorie, motif, rappel,
        contacts_lies, taches_liees, last_modified, modified_by
      ) values (
        coalesce(row_id, gen_random_uuid()::text),
        coalesce(row_data->>'nom_projet', ''), coalesce(row_data->>'type_client', 'Habitat'),
        coalesce(row_data->>'priorite', ''),
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
        id, nom, fonction, organisme, categorie, telephone, email, adresse, notes,
        rappel, ao_lies, last_modified, modified_by
      ) values (
        coalesce(row_id, gen_random_uuid()::text),
        coalesce(row_data->>'nom', ''), coalesce(row_data->>'fonction', ''),
        coalesce(row_data->>'organisme', ''), coalesce(row_data->>'categorie', ''),
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

commit;
