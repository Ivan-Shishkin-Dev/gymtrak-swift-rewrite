-- GymTrak accounts: one private data row per signed-in user.
-- Run once in the GymTrak Supabase project: Dashboard → SQL Editor → paste → Run.
-- Additive only: the web app's public gt_state row is left untouched.

create table if not exists public.gt_user_state (
  user_id    uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  data       jsonb  not null,
  updated_at bigint not null default (extract(epoch from now()) * 1000)::bigint
);

alter table public.gt_user_state enable row level security;

drop policy if exists "own row: read"   on public.gt_user_state;
drop policy if exists "own row: insert" on public.gt_user_state;
drop policy if exists "own row: update" on public.gt_user_state;
create policy "own row: read"   on public.gt_user_state for select to authenticated using (user_id = (select auth.uid()));
create policy "own row: insert" on public.gt_user_state for insert to authenticated with check (user_id = (select auth.uid()));
create policy "own row: update" on public.gt_user_state for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

grant select, insert, update on public.gt_user_state to authenticated;

-- Save with a conflict check: fails if another device saved since `p_expected`.
-- Returns the new updated_at. Runs as the caller, so RLS still applies.
create or replace function public.save_user_state(p_data jsonb, p_expected bigint)
returns bigint
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_now bigint := (extract(epoch from clock_timestamp()) * 1000)::bigint;
  v_cur bigint;
begin
  select updated_at into v_cur from public.gt_user_state where user_id = auth.uid() for update;
  if v_cur is not null and p_expected is not null and v_cur > p_expected then
    raise exception 'conflict: newer data on another device';
  end if;
  insert into public.gt_user_state (user_id, data, updated_at)
  values (auth.uid(), p_data, v_now)
  on conflict (user_id) do update set data = excluded.data, updated_at = excluded.updated_at;
  return v_now;
end;
$$;

revoke all on function public.save_user_state(jsonb, bigint) from public, anon;
grant execute on function public.save_user_state(jsonb, bigint) to authenticated;
