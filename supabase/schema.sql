-- Kammer – Datenbank für die gemeinsame Nutzung
-- In Supabase: SQL Editor → New query → alles einfügen → Run.

create table if not exists public.records (
  household_id uuid        not null,
  kind         text        not null,
  id           uuid        not null,
  data         jsonb       not null,
  deleted      boolean     not null default false,
  updated_at   timestamptz not null default now(),
  primary key (household_id, id)
);

create index if not exists records_household_updated on public.records (household_id, updated_at);

-- Zugriff nur mit dem Haushalts-Code (wird von der App als Header x-household mitgeschickt)
create or replace function public.request_household() returns uuid
language sql stable as $$
  select nullif(current_setting('request.headers', true)::json ->> 'x-household', '')::uuid
$$;

alter table public.records enable row level security;

drop policy if exists "household read" on public.records;
drop policy if exists "household insert" on public.records;
drop policy if exists "household update" on public.records;

create policy "household read" on public.records
  for select using (household_id = public.request_household());
create policy "household insert" on public.records
  for insert with check (household_id = public.request_household());
create policy "household update" on public.records
  for update using (household_id = public.request_household())
  with check (household_id = public.request_household());

grant select, insert, update on public.records to anon, authenticated;

-- Server-Zeitstempel bei jeder Änderung (damit beide iPhones dieselbe Uhr nutzen)
create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at = clock_timestamp();
  return new;
end $$;

drop trigger if exists records_touch on public.records;
create trigger records_touch before insert or update on public.records
  for each row execute function public.touch_updated_at();
