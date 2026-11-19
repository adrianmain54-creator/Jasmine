-- Jasmine Bloom social messaging
-- Run once in Supabase SQL Editor after the existing chat-auth migration, if that one was already run.
create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'Jasmine member',
  created_at timestamptz not null default now()
);

create or replace function public.handle_new_jasmine_user()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  insert into public.profiles(id, display_name)
  values (new.id, coalesce(nullif(trim(new.raw_user_meta_data->>'display_name'), ''), split_part(new.email, '@', 1), 'Jasmine member'))
  on conflict (id) do update set display_name = excluded.display_name;
  return new;
end;
$$;

drop trigger if exists on_jasmine_auth_user_created on auth.users;
create trigger on_jasmine_auth_user_created
after insert on auth.users for each row execute procedure public.handle_new_jasmine_user();

insert into public.profiles(id, display_name)
select id, coalesce(nullif(trim(raw_user_meta_data->>'display_name'), ''), split_part(email, '@', 1), 'Jasmine member')
from auth.users
on conflict (id) do nothing;

create table if not exists public.friend_requests (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.profiles(id) on delete cascade,
  receiver_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted','declined','cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint friend_requests_not_self check (sender_id <> receiver_id),
  constraint friend_requests_unique_pair unique(sender_id, receiver_id)
);
create index if not exists friend_requests_receiver_status_idx on public.friend_requests(receiver_id, status);
create index if not exists friend_requests_sender_status_idx on public.friend_requests(sender_id, status);

create table if not exists public.friendships (
  user_a uuid not null references public.profiles(id) on delete cascade,
  user_b uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(user_a,user_b),
  check(user_a < user_b)
);

create or replace function public.jasmine_friend_request_accepted()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.status = 'accepted' and old.status is distinct from 'accepted' then
    insert into public.friendships(user_a,user_b)
    values (least(new.sender_id,new.receiver_id), greatest(new.sender_id,new.receiver_id))
    on conflict do nothing;
  end if;
  new.updated_at = now();
  return new;
end;
$$;
drop trigger if exists on_jasmine_friend_request_accepted on public.friend_requests;
create trigger on_jasmine_friend_request_accepted
before update on public.friend_requests for each row execute procedure public.jasmine_friend_request_accepted();

create table if not exists public.conversations (
  id uuid primary key default gen_random_uuid(),
  title text,
  is_group boolean not null default false,
  created_by uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.conversation_members (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null default 'member' check (role in ('owner','member')),
  joined_at timestamptz not null default now(),
  primary key(conversation_id,user_id)
);
create index if not exists conversation_members_user_idx on public.conversation_members(user_id,conversation_id);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(trim(body)) between 1 and 2000),
  created_at timestamptz not null default now()
);
create index if not exists messages_conversation_created_idx on public.messages(conversation_id,created_at desc);

create or replace function public.jasmine_is_conversation_member(p_conversation_id uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists(select 1 from public.conversation_members cm where cm.conversation_id=p_conversation_id and cm.user_id=auth.uid());
$$;

create or replace function public.jasmine_are_friends(p_one uuid,p_two uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists(
    select 1 from public.friendships f
    where f.user_a=least(p_one,p_two) and f.user_b=greatest(p_one,p_two)
  );
$$;

create or replace function public.jasmine_create_conversation(p_title text, p_is_group boolean, p_member_ids uuid[])
returns uuid language plpgsql security definer set search_path = public
as $$
declare
  v_id uuid;
  v_member uuid;
  v_ids uuid[];
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  select array_agg(distinct x) into v_ids from unnest(coalesce(p_member_ids,'{}'::uuid[]) || array[auth.uid()]) as x;
  if p_is_group and (select count(*) from unnest(v_ids)) < 3 then
    raise exception 'A group chat needs at least two friends';
  end if;
  if not p_is_group and (select count(*) from unnest(v_ids)) <> 2 then
    raise exception 'A private chat needs exactly one friend';
  end if;
  foreach v_member in array v_ids loop
    if v_member <> auth.uid() and not public.jasmine_are_friends(auth.uid(),v_member) then
      raise exception 'You can only chat with friends';
    end if;
  end loop;
  insert into public.conversations(title,is_group,created_by)
  values (case when p_is_group then coalesce(nullif(trim(p_title),''),'Garden group') else null end,p_is_group,auth.uid())
  returning id into v_id;
  insert into public.conversation_members(conversation_id,user_id,role)
  select v_id, x, case when x=auth.uid() then 'owner' else 'member' end from unnest(v_ids) as x;
  return v_id;
end;
$$;

alter table public.profiles enable row level security;
alter table public.friend_requests enable row level security;
alter table public.friendships enable row level security;
alter table public.conversations enable row level security;
alter table public.conversation_members enable row level security;
alter table public.messages enable row level security;

drop policy if exists "Jasmine profiles visible to members" on public.profiles;
create policy "Jasmine profiles visible to members" on public.profiles for select to authenticated using (true);

drop policy if exists "Participants can read friend requests" on public.friend_requests;
create policy "Participants can read friend requests" on public.friend_requests for select to authenticated using (auth.uid() in (sender_id,receiver_id));
drop policy if exists "Members can send friend requests" on public.friend_requests;
create policy "Members can send friend requests" on public.friend_requests for insert to authenticated with check (sender_id=auth.uid() and sender_id<>receiver_id and status='pending');
drop policy if exists "Receiver can respond to friend requests" on public.friend_requests;
create policy "Receiver can respond to friend requests" on public.friend_requests for update to authenticated using (receiver_id=auth.uid() and status='pending') with check (receiver_id=auth.uid() and status in ('accepted','declined'));

drop policy if exists "Members can view their friendships" on public.friendships;
create policy "Members can view their friendships" on public.friendships for select to authenticated using (auth.uid() in (user_a,user_b));

drop policy if exists "Conversation members can view conversations" on public.conversations;
create policy "Conversation members can view conversations" on public.conversations for select to authenticated using (public.jasmine_is_conversation_member(id));
drop policy if exists "Members can view conversation roster" on public.conversation_members;
create policy "Members can view conversation roster" on public.conversation_members for select to authenticated using (public.jasmine_is_conversation_member(conversation_id));
drop policy if exists "Members can view messages" on public.messages;
create policy "Members can view messages" on public.messages for select to authenticated using (public.jasmine_is_conversation_member(conversation_id));
drop policy if exists "Members can send messages" on public.messages;
create policy "Members can send messages" on public.messages for insert to authenticated with check (sender_id=auth.uid() and public.jasmine_is_conversation_member(conversation_id));

grant select on public.profiles, public.friend_requests, public.friendships, public.conversations, public.conversation_members, public.messages to authenticated;
grant insert on public.friend_requests, public.messages to authenticated;
grant update(status) on public.friend_requests to authenticated;
grant execute on function public.jasmine_create_conversation(text,boolean,uuid[]) to authenticated;
grant execute on function public.jasmine_is_conversation_member(uuid) to authenticated;
grant execute on function public.jasmine_are_friends(uuid,uuid) to authenticated;
revoke all on public.profiles, public.friend_requests, public.friendships, public.conversations, public.conversation_members, public.messages from anon;


-- Enable Supabase Realtime for the social features. Safe to run more than once.
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='messages') then
    alter publication supabase_realtime add table public.messages;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='friend_requests') then
    alter publication supabase_realtime add table public.friend_requests;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='friendships') then
    alter publication supabase_realtime add table public.friendships;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='conversation_members') then
    alter publication supabase_realtime add table public.conversation_members;
  end if;
end $$;
