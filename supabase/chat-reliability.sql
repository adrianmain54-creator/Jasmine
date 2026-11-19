-- Jasmine Bloom chat reliability patch (safe to run once)
-- Adds the social tables to Supabase Realtime so message/friend updates arrive live.
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['friend_requests','friendships','conversation_members','messages'] loop
      if not exists (
        select 1 from pg_publication_tables
        where pubname='supabase_realtime' and schemaname='public' and tablename=t
      ) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;

-- Permit a new request after a previous request was declined/cancelled.
alter table public.friend_requests drop constraint if exists friend_requests_unique_pair;
create unique index if not exists friend_requests_one_pending_pair
on public.friend_requests(sender_id, receiver_id) where status='pending';
create index if not exists messages_conversation_created_asc_idx
on public.messages(conversation_id, created_at asc);
