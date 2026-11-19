-- Jasmine Bloom online game rooms
-- Run once in Supabase SQL Editor after social-chat.sql and chat-reliability.sql.
create extension if not exists pgcrypto;

create table if not exists public.game_rooms (
  id uuid primary key default gen_random_uuid(),
  game_id text not null check (char_length(game_id) between 1 and 40),
  host_id uuid not null references auth.users(id) on delete cascade,
  guest_id uuid references auth.users(id) on delete set null,
  status text not null default 'waiting' check (status in ('waiting','playing','finished','cancelled')),
  current_turn uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (guest_id is null or guest_id <> host_id)
);
create index if not exists game_rooms_waiting_idx on public.game_rooms(status, created_at desc);
create index if not exists game_rooms_host_idx on public.game_rooms(host_id, status);
create index if not exists game_rooms_guest_idx on public.game_rooms(guest_id, status);

create table if not exists public.game_room_events (
  id bigint generated always as identity primary key,
  room_id uuid not null references public.game_rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  event_type text not null check (event_type in ('move','state','score','ready','forfeit')),
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists game_room_events_room_id_idx on public.game_room_events(room_id, id);

create or replace function public.jasmine_create_game_room(p_game_id text)
returns uuid language plpgsql security definer set search_path = public
as $$
declare v_room uuid;
begin
  if auth.uid() is null then raise exception 'Sign in to create an online game'; end if;
  if p_game_id is null or char_length(trim(p_game_id)) not between 1 and 40 then
    raise exception 'Invalid game';
  end if;
  insert into public.game_rooms(game_id,host_id,current_turn)
  values (trim(p_game_id),auth.uid(),auth.uid())
  returning id into v_room;
  return v_room;
end;
$$;

create or replace function public.jasmine_join_game_room(p_room_id uuid)
returns uuid language plpgsql security definer set search_path = public
as $$
declare v_room public.game_rooms%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in to join an online game'; end if;
  select * into v_room from public.game_rooms where id=p_room_id for update;
  if not found then raise exception 'Game room not found'; end if;
  if v_room.host_id=auth.uid() then return v_room.id; end if;
  if v_room.status <> 'waiting' or v_room.guest_id is not null then
    raise exception 'This game room is already full';
  end if;
  if not public.jasmine_are_friends(v_room.host_id,auth.uid()) then
    raise exception 'You can only play online with an accepted Jasmine friend';
  end if;
  update public.game_rooms
    set guest_id=auth.uid(), status='playing', updated_at=now()
    where id=v_room.id;
  return v_room.id;
end;
$$;

create or replace function public.jasmine_finish_game_room(p_room_id uuid, p_status text default 'finished')
returns void language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  if p_status not in ('finished','cancelled') then raise exception 'Invalid room status'; end if;
  update public.game_rooms
    set status=p_status, updated_at=now()
    where id=p_room_id and auth.uid() in (host_id,guest_id) and status='playing';
  if not found then raise exception 'Game room unavailable'; end if;
end;
$$;

alter table public.game_rooms enable row level security;
alter table public.game_room_events enable row level security;

drop policy if exists "Game participants can read rooms" on public.game_rooms;
create policy "Game participants can read rooms" on public.game_rooms
for select to authenticated using (auth.uid() in (host_id,guest_id));

drop policy if exists "Game participants can read events" on public.game_room_events;
create policy "Game participants can read events" on public.game_room_events
for select to authenticated using (
  exists (select 1 from public.game_rooms r where r.id=room_id and auth.uid() in (r.host_id,r.guest_id))
);

drop policy if exists "Game participants can send events" on public.game_room_events;
create policy "Game participants can send events" on public.game_room_events
for insert to authenticated with check (
  user_id=auth.uid() and exists (
    select 1 from public.game_rooms r
    where r.id=room_id and r.status='playing' and auth.uid() in (r.host_id,r.guest_id)
  )
);

grant select on public.game_rooms, public.game_room_events to authenticated;
grant insert on public.game_room_events to authenticated;
grant usage, select on sequence public.game_room_events_id_seq to authenticated;
grant execute on function public.jasmine_create_game_room(text) to authenticated;
grant execute on function public.jasmine_join_game_room(uuid) to authenticated;
grant execute on function public.jasmine_finish_game_room(uuid,text) to authenticated;
revoke all on public.game_rooms, public.game_room_events from anon;

do $$
begin
  if exists (select 1 from pg_publication where pubname='supabase_realtime') then
    if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='game_rooms') then
      alter publication supabase_realtime add table public.game_rooms;
    end if;
    if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='game_room_events') then
      alter publication supabase_realtime add table public.game_room_events;
    end if;
  end if;
end $$;
