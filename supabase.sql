-- =====================================================================
-- Oktagon Tippspiel – Datenbank für Supabase
-- Einmal komplett im Supabase "SQL Editor" ausführen.
-- VORHER unten (Abschnitt 5) das Admin-Passwort ändern!
-- =====================================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
-- 1. Tabellen
-- ---------------------------------------------------------------------
create table if not exists settings (
  key   text primary key,
  value text not null
);

create table if not exists players (
  id         uuid primary key default extensions.gen_random_uuid(),
  name       text not null,
  pin_hash   text not null,
  created_at timestamptz not null default now()
);
create unique index if not exists players_name_lower on players (lower(name));

create table if not exists fights (
  id        serial primary key,
  pos       int  not null default 0,
  fighter_a text not null,
  fighter_b text not null,
  info      text not null default '',
  status    text not null default 'open' check (status in ('open', 'locked', 'done')),
  result    text check (result in ('A', 'B', 'draw'))
);

create table if not exists bets (
  player_id uuid not null references players(id) on delete cascade,
  fight_id  int  not null references fights(id)  on delete cascade,
  pick      text not null check (pick in ('A', 'B')),
  placed_at timestamptz not null default now(),
  primary key (player_id, fight_id)
);

-- Kein direkter Tabellenzugriff von außen: alles läuft über die Funktionen unten.
alter table settings enable row level security;
alter table players  enable row level security;
alter table fights   enable row level security;
alter table bets     enable row level security;

-- ---------------------------------------------------------------------
-- 2. Hilfsfunktionen (nicht öffentlich aufrufbar)
-- ---------------------------------------------------------------------
create or replace function _player(p_name text, p_pin text) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare v_id uuid;
begin
  select id into v_id from players
   where lower(name) = lower(trim(p_name)) and pin_hash = crypt(p_pin, pin_hash);
  if v_id is null then
    raise exception 'Name oder PIN falsch';
  end if;
  return v_id;
end $$;

create or replace function _admin(p_pw text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not exists (select 1 from settings where key = 'admin_pw' and value = crypt(p_pw, value)) then
    raise exception 'Admin-Passwort falsch';
  end if;
end $$;

-- Gewinn/Verlust pro Tipp: Verlierer-Einsätze (je 10 €) werden auf die Gewinner aufgeteilt.
-- Unentschieden, alle richtig oder alle falsch => 0 für alle (Einsatz zurück).
create or replace view _payouts with (security_invoker = false) as
with stats as (
  select f.id as fight_id, f.result,
         count(b.*) filter (where b.pick = f.result)  as w,
         count(b.*) filter (where b.pick <> f.result) as l
    from fights f left join bets b on b.fight_id = f.id
   where f.status = 'done'
   group by f.id, f.result
)
select b.player_id, b.fight_id,
       case
         when s.result = 'draw' or s.w = 0 or s.l = 0 then 0::numeric
         when b.pick = s.result then round(10.0 * s.l / s.w, 2)
         else -10::numeric
       end as net
  from bets b join stats s on s.fight_id = b.fight_id;
revoke all on _payouts from anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. Funktionen für Mitspieler
-- ---------------------------------------------------------------------

-- Anmelden. Gibt es den Namen noch nicht, wird der Spieler angelegt.
create or replace function join_game(p_name text, p_pin text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare v_name text := trim(p_name);
begin
  if length(v_name) < 2 or length(v_name) > 20 then
    raise exception 'Name muss 2 bis 20 Zeichen lang sein';
  end if;
  if p_pin !~ '^[0-9]{4}$' then
    raise exception 'PIN muss aus 4 Ziffern bestehen';
  end if;
  if not exists (select 1 from players where lower(name) = lower(v_name)) then
    if exists (select 1 from settings where key = 'registration_closed') then
      raise exception 'Anmeldung ist geschlossen';
    end if;
    insert into players (name, pin_hash) values (v_name, crypt(p_pin, gen_salt('bf')));
  end if;
  perform _player(v_name, p_pin);
  return json_build_object('name', (select name from players where lower(name) = lower(v_name)));
end $$;

-- Tipp abgeben oder ändern (p_pick = 'A', 'B' oder null zum Löschen). Nur solange der Kampf offen ist.
create or replace function place_bet(p_name text, p_pin text, p_fight int, p_pick text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_player uuid := _player(p_name, p_pin);
begin
  perform 1 from fights where id = p_fight and status = 'open' for update;
  if not found then
    raise exception 'Dieser Kampf ist gesperrt, Tipp nicht mehr möglich';
  end if;
  if p_pick is null then
    delete from bets where player_id = v_player and fight_id = p_fight;
  else
    insert into bets (player_id, fight_id, pick) values (v_player, p_fight, p_pick)
    on conflict (player_id, fight_id) do update set pick = excluded.pick, placed_at = now();
  end if;
end $$;

-- Interner Gesamtzustand. Tipps anderer werden erst ab Sperrung sichtbar.
create or replace function _state(v_player uuid) returns json
language sql security definer set search_path = public, extensions as $$
  select json_build_object(
    'fights', coalesce((
      select json_agg(json_build_object(
        'id', f.id, 'pos', f.pos, 'a', f.fighter_a, 'b', f.fighter_b, 'info', f.info,
        'status', f.status, 'result', f.result,
        'count', (select count(*) from bets b where b.fight_id = f.id),
        'mine', (select pick from bets b where b.fight_id = f.id and b.player_id = v_player),
        'bets', case when f.status = 'open' then null else (
          select coalesce(json_agg(json_build_object('name', p.name, 'pick', b.pick, 'net', po.net)
                                   order by b.pick, p.name), '[]')
            from bets b join players p on p.id = b.player_id
            left join _payouts po on po.player_id = b.player_id and po.fight_id = b.fight_id
           where b.fight_id = f.id) end
      ) order by f.pos, f.id) from fights f), '[]'),
    'board', coalesce((
      select json_agg(x order by x.net desc, x.name) from (
        select p.name,
               coalesce(sum(po.net), 0) as net,
               count(po.*) filter (where po.net > 0) as won,
               count(po.*) filter (where po.net < 0) as lost
          from players p left join _payouts po on po.player_id = p.id
         group by p.id, p.name) x), '[]'),
    'registration_closed', exists (select 1 from settings where key = 'registration_closed')
  )
$$;

create or replace function get_state(p_name text, p_pin text) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  return _state(_player(p_name, p_pin));
end $$;

-- ---------------------------------------------------------------------
-- 4. Funktionen für den Admin
-- ---------------------------------------------------------------------
create or replace function admin_state(p_pw text) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _admin(p_pw);
  return _state(null);
end $$;

-- Kampf anlegen (p_id = null) oder bearbeiten
create or replace function admin_save_fight(p_pw text, p_id int, p_pos int, p_a text, p_b text, p_info text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _admin(p_pw);
  if p_id is null then
    insert into fights (pos, fighter_a, fighter_b, info)
    values (coalesce(p_pos, (select coalesce(max(pos), 0) + 1 from fights)), trim(p_a), trim(p_b), coalesce(trim(p_info), ''));
  else
    update fights set pos = coalesce(p_pos, pos), fighter_a = trim(p_a), fighter_b = trim(p_b),
                      info = coalesce(trim(p_info), '')
     where id = p_id;
  end if;
end $$;

create or replace function admin_delete_fight(p_pw text, p_id int) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _admin(p_pw);
  delete from fights where id = p_id;
end $$;

-- Status setzen: 'open' (Tipps möglich) oder 'locked' (Kampf läuft, Tipps fix)
create or replace function admin_set_status(p_pw text, p_id int, p_status text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _admin(p_pw);
  if p_status not in ('open', 'locked') then raise exception 'Ungültiger Status'; end if;
  update fights set status = p_status, result = null where id = p_id;
end $$;

-- Ergebnis eintragen: 'A', 'B' oder 'draw' (Unentschieden / No Contest). null = Ergebnis zurücknehmen.
create or replace function admin_set_result(p_pw text, p_id int, p_result text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _admin(p_pw);
  update fights set result = p_result,
                    status = case when p_result is null then 'locked' else 'done' end
   where id = p_id;
end $$;

create or replace function admin_delete_player(p_pw text, p_name text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _admin(p_pw);
  delete from players where lower(name) = lower(trim(p_name));
end $$;

create or replace function admin_set_registration(p_pw text, p_closed boolean) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _admin(p_pw);
  if p_closed then
    insert into settings values ('registration_closed', 'yes') on conflict do nothing;
  else
    delete from settings where key = 'registration_closed';
  end if;
end $$;

-- Nur interne Funktionen sperren; der Rest ist per anon-Key aufrufbar.
revoke execute on function _player(text, text), _admin(text), _state(uuid) from public, anon, authenticated;
grant execute on function join_game(text, text), place_bet(text, text, int, text), get_state(text, text),
  admin_state(text), admin_save_fight(text, int, int, text, text, text), admin_delete_fight(text, int),
  admin_set_status(text, int, text), admin_set_result(text, int, text), admin_delete_player(text, text),
  admin_set_registration(text, boolean)
  to anon;

-- ---------------------------------------------------------------------
-- 5. Admin-Passwort  >>> HIER ÄNDERN <<<
-- ---------------------------------------------------------------------
insert into settings (key, value)
values ('admin_pw', extensions.crypt('HIER-ADMIN-PASSWORT', extensions.gen_salt('bf')))
on conflict (key) do update set value = excluded.value;

-- ---------------------------------------------------------------------
-- 6. Fight Card OKTAGON 96, 31.10.2026, SAP Garden München
--    (Stand 20.10.2026, nur wenn noch keine Kämpfe angelegt sind).
--    Reihenfolge = pos; kann später in der App unter "Admin" geändert werden.
-- ---------------------------------------------------------------------
insert into fights (pos, fighter_a, fighter_b, info)
select * from (values
  (1, 'Madureira',          'Schordje',        'Federgewicht'),
  (2, 'Ayari',              'Surdu',           ''),
  (3, 'Bartl',              'Manning',         ''),
  (4, 'Lazar Todev',        'Simon Biyong',    'Schwergewicht'),
  (5, 'Gökhan Aksu',        'Niko Samsonidse', ''),
  (6, 'Ronald Paradeiser',  'Tyrone Pfeifer',  'Co-Main Event'),
  (7, 'Amiran Gogoladze',   'Felix Klinkhammer', 'Main Event · Weltergewicht-Titel')
) v(pos, a, b, info)
where not exists (select 1 from fights);
