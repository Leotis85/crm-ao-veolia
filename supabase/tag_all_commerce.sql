-- Tague tous les AO existants en Commerce (rien n'est encore en Travaux).
-- À lancer une seule fois dans le SQL Editor.

update public.aos set service = array['Commerce'];

select count(*) as nb_aos_commerce from public.aos where service = array['Commerce'];
