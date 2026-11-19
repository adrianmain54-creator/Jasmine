-- Jasmine Bloom username-only chat accounts
-- Run in Supabase SQL Editor after social-chat.sql.
alter table public.profiles add column if not exists username text;

with source as (
  select p.id,
         coalesce(
           nullif(regexp_replace(lower(coalesce(u.raw_user_meta_data->>'username','')), '[^a-z0-9_]', '', 'g'), ''),
           nullif(regexp_replace(lower(split_part(coalesce(u.email,''),'@',1)), '[^a-z0-9_]', '', 'g'), ''),
           'jasmine'
         ) as base_name
  from public.profiles p
  join auth.users u on u.id=p.id
), numbered as (
  select id, base_name,
         row_number() over (partition by base_name order by id) as duplicate_no
  from source
)
update public.profiles p
set username = case
  when n.duplicate_no=1 then left(n.base_name,20)
  else left(n.base_name,13) || '_' || left(replace(n.id::text,'-',''),6)
end
from numbered n
where p.id=n.id and (p.username is null or p.username='');

create unique index if not exists profiles_username_unique
on public.profiles (lower(username));

alter table public.profiles alter column username set not null;

create or replace function public.handle_new_jasmine_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_username text;
begin
  v_username := lower(coalesce(new.raw_user_meta_data->>'username', split_part(new.email,'@',1)));
  v_username := regexp_replace(v_username, '[^a-z0-9_]', '', 'g');
  if length(v_username) < 3 or length(v_username) > 20 then
    raise exception 'Username must be 3–20 characters using letters, numbers, or underscores';
  end if;

  insert into public.profiles(id, username, display_name)
  values (new.id, v_username, coalesce(nullif(trim(new.raw_user_meta_data->>'display_name'), ''), v_username))
  on conflict (id) do update
    set username=excluded.username,
        display_name=excluded.display_name;
  return new;
end;
$$;

-- New accounts use a generated internal email address; no email is collected.
-- In Supabase Dashboard > Authentication > Providers > Email, turn OFF
-- "Confirm email" so username/password signup can create an immediate session.
