-- Jasmine Bloom: require a Supabase account to read and post community chat.
-- Run this in Supabase Dashboard -> SQL Editor -> New query.
-- Existing chat rows remain readable by signed-in members; new rows are tied to auth.users.

alter table public.chat_messages
  add column if not exists user_id uuid references auth.users(id) on delete set null;

alter table public.chat_messages enable row level security;

-- Remove existing chat_messages policies so an older public/anon policy cannot
-- accidentally keep anonymous access enabled (permissive policies are OR-ed).
do $$
declare policy_row record;
begin
  for policy_row in
    select policyname
    from pg_policies
    where schemaname = 'public' and tablename = 'chat_messages'
  loop
    execute format('drop policy if exists %I on public.chat_messages', policy_row.policyname);
  end loop;
end
$$;

create policy "Signed-in members can read chat"
  on public.chat_messages
  for select
  to authenticated
  using (true);

create policy "Members can post as themselves"
  on public.chat_messages
  for insert
  to authenticated
  with check (auth.uid() = user_id);

grant select, insert on public.chat_messages to authenticated;
revoke all on public.chat_messages from anon;
