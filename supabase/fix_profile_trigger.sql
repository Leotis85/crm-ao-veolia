-- Correctif ciblé (ne touche à aucune donnée aos/taches/contacts) :
-- le trigger de protection des profils bloquait aussi les mises à jour
-- faites depuis le SQL Editor (auth.uid() y est NULL, donc is_admin()
-- retournait faux même pour toi).

create or replace function public.protect_profile_privileges()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    new.role := old.role;
    new.service := old.service;
  end if;
  return new;
end;
$$;

-- Relance le seed maintenant que le trigger ne bloque plus service/role.
update public.profiles p
set display_name = v.display_name,
    service = v.service
from (values
  ('mathis.rabille@veolia.com', 'Mathis', array['Commerce']),
  ('maxime.pellilli@veolia.com', 'Maxime', array['Commerce']),
  ('arnaud.pourcel@veolia.com', 'Arnaud', array['Travaux']),
  ('dorian.bovin@veolia.com', 'Dorian', array['Travaux']),
  ('aingel.arbaud@veolia.com', 'Aingel', array['Commerce', 'Travaux'])
) as v(email, display_name, service)
join auth.users u on u.email = v.email
where p.id = u.id;

-- Toi en admin.
update public.profiles set role = 'admin' where id in (
  select id from auth.users where email = 'mathis.rabille@veolia.com'
);

select id, display_name, role, service from public.profiles;
