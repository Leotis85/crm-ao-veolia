-- À exécuter UNE FOIS dans le SQL Editor Supabase, APRÈS avoir créé les 3
-- comptes via Authentication > Add user (sinon les email ne matcheront rien).

update public.profiles p
set display_name = v.display_name,
    service = v.service
from (values
  ('mathis.rabille@veolia.com', 'Mathis', array['Commerce']),
  ('maxime.pellilli@veolia.com', 'Maxime', array['Commerce']),
  ('arnaud.pourcel@veolia.com', 'Arnaud', array['Travaux']),
  ('dorian.bovin@veolia.com', 'Dorian', array['Travaux'])
) as v(email, display_name, service)
join auth.users u on u.email = v.email
where p.id = u.id;

-- Vérification : doit lister les 4 profils avec leur role/service à jour.
select id, display_name, role, service from public.profiles;
