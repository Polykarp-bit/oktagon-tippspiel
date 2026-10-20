-- =====================================================================
-- Oktagon Tippspiel – Datenbank für Supabase
-- Einmal komplett im Supabase "SQL Editor" ausführen. Kein Admin nötig:
--  * Jeder Mitspieler kann einen Kampf sperren, sobald er beginnt.
--    Die Sperre ist sofort endgültig.
--  * Die Tipps der anderen bleiben verdeckt, bis das Ergebnis bestätigt ist.
--  * Jede Aktion (Tipp, Änderung, Sperren, Entsperren, Ergebnis) wird protokolliert.
--    Das Protokoll eines Kampfes sehen alle, sobald der Kampf entschieden ist.
--  * Das Ergebnis gilt, sobald mehr als die Hälfte der Tipper dieses
--    Kampfes dasselbe Ergebnis bestätigt hat. Abstimmen dürfen nur Tipper (Anteil siehe Abschnitt 4).
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
  result    text check (result in ('A', 'B', 'draw')),
  locked_by text,
  locked_at timestamptz
);

create table if not exists bets (
  player_id uuid not null references players(id) on delete cascade,
  fight_id  int  not null references fights(id)  on delete cascade,
  pick      text not null check (pick in ('A', 'B')),
  placed_at timestamptz not null default now(),
  primary key (player_id, fight_id)
);

-- Ergebnis-Bestätigungen der Mitspieler
create table if not exists votes (
  player_id uuid not null references players(id) on delete cascade,
  fight_id  int  not null references fights(id)  on delete cascade,
  vote      text not null check (vote in ('A', 'B', 'draw')),
  primary key (player_id, fight_id)
);

-- Anträge auf Entsperren (2 verschiedene Mitspieler nötig)
create table if not exists unlock_requests (
  fight_id  int  not null references fights(id)  on delete cascade,
  player_id uuid not null references players(id) on delete cascade,
  primary key (fight_id, player_id)
);

-- Protokoll: wird nur angehängt, nie geändert
create table if not exists events (
  id       bigserial primary key,
  fight_id int  not null references fights(id) on delete cascade,
  player   text not null,
  action   text not null,
  at       timestamptz not null default now()
);

-- Kein direkter Tabellenzugriff von außen: alles läuft über die Funktionen unten.
alter table settings enable row level security;
alter table players  enable row level security;
alter table fights   enable row level security;
alter table bets     enable row level security;
alter table votes    enable row level security;
alter table unlock_requests enable row level security;
alter table events   enable row level security;

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

create or replace function _log(p_fight int, p_player uuid, p_action text) returns void
language sql security definer set search_path = public, extensions as $$
  insert into events (fight_id, player, action) values (p_fight, (select name from players where id = p_player), p_action)
$$;

-- Nötige Bestätigungen: mehr als <quorum> der Tipper dieses Kampfes, mindestens 1.
create or replace function _needed(p_fight int) returns int
language sql stable security definer set search_path = public, extensions as $$
  select greatest(1, floor(count(*) * coalesce((select value::numeric from settings where key = 'quorum'), 0.5))::int + 1)
    from bets where fight_id = p_fight
$$;

-- Ergebnis aus den Bestätigungen neu bestimmen
create or replace function _recount(p_fight int) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_vote text; v_n int;
begin
  select vote, count(*) into v_vote, v_n from votes v where fight_id = p_fight
     and exists (select 1 from bets b where b.player_id = v.player_id and b.fight_id = p_fight)
   group by vote order by count(*) desc limit 1;
  if v_n is not null and v_n >= _needed(p_fight) then
    update fights set status = 'done', result = v_vote where id = p_fight and status <> 'open';
  else
    update fights set status = 'locked', result = null where id = p_fight and status <> 'open';
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

-- Sekunden, in denen eine Sperre noch rückgängig gemacht werden kann
create or replace function _undo_left(p_fight int) returns int
language sql stable security definer set search_path = public, extensions as $$
  select case when status = 'locked' and locked_at is not null
              then greatest(0, ceil(coalesce((select value::int from settings where key = 'grace_seconds'), 0) - extract(epoch from now() - locked_at)))::int else 0 end
    from fights where id = p_fight
$$;

-- Gesamtzustand. Tipps anderer werden erst sichtbar, wenn das Ergebnis bestätigt ist.
create or replace function _state(v_player uuid) returns json
language sql security definer set search_path = public, extensions as $$
  select json_build_object(
    'fights', coalesce((
      select json_agg(json_build_object(
        'id', f.id, 'pos', f.pos, 'a', f.fighter_a, 'b', f.fighter_b, 'info', f.info,
        'status', f.status, 'result', f.result, 'locked_by', f.locked_by, 'undo_left', _undo_left(f.id),
        'count', (select count(*) from bets b where b.fight_id = f.id),
        'mine', (select pick from bets b where b.fight_id = f.id and b.player_id = v_player),
        'my_vote', (select vote from votes v where v.fight_id = f.id and v.player_id = v_player),
        'unlock_count', (select count(*) from unlock_requests u where u.fight_id = f.id),
        'my_unlock', exists (select 1 from unlock_requests u where u.fight_id = f.id and u.player_id = v_player),
        'log', case when f.status = 'done' then (
          select json_agg(json_build_object('player', e.player, 'action', e.action, 'at', e.at) order by e.id)
            from events e where e.fight_id = f.id) end,
        'needed', _needed(f.id),
        'votes', (select json_build_object(
                    'A', count(*) filter (where vote = 'A'),
                    'B', count(*) filter (where vote = 'B'),
                    'draw', count(*) filter (where vote = 'draw'))
                    from votes v where v.fight_id = f.id
                     and exists (select 1 from bets b where b.player_id = v.player_id and b.fight_id = f.id)),
        'bets', case when f.status <> 'done' then null else (
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
               count(f.id) filter (where f.result <> 'draw' and b.pick = f.result) as won,
               count(f.id) filter (where f.result <> 'draw' and b.pick <> f.result) as lost
          from players p
          left join bets b on b.player_id = p.id
          left join fights f on f.id = b.fight_id and f.status = 'done'
          left join _payouts po on po.player_id = b.player_id and po.fight_id = b.fight_id
         group by p.id, p.name) x), '[]')
  )
$$;

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
    insert into players (name, pin_hash) values (v_name, crypt(p_pin, gen_salt('bf')));
  end if;
  perform _player(v_name, p_pin);
  return json_build_object('name', (select name from players where lower(name) = lower(v_name)));
end $$;

create or replace function get_state(p_name text, p_pin text) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  return _state(_player(p_name, p_pin));
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
    if found then perform _log(p_fight, v_player, 'Tipp gelöscht'); end if;
  else
    perform _log(p_fight, v_player,
      case when exists (select 1 from bets where player_id = v_player and fight_id = p_fight) then 'Tipp geändert auf ' else 'Tipp auf ' end
      || (select case when p_pick = 'A' then fighter_a else fighter_b end from fights where id = p_fight));
    insert into bets (player_id, fight_id, pick) values (v_player, p_fight, p_pick)
    on conflict (player_id, fight_id) do update set pick = excluded.pick, placed_at = now();
  end if;
end $$;

-- Kampf beginnt: jeder Mitspieler kann sperren. Danach sind die Tipps endgültig.
create or replace function lock_fight(p_name text, p_pin text, p_fight int) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_player uuid := _player(p_name, p_pin);
begin
  update fights set status = 'locked', locked_at = now(), locked_by = (select name from players where id = v_player)
   where id = p_fight and status = 'open';
  if found then
    delete from unlock_requests where fight_id = p_fight;
    perform _log(p_fight, v_player, 'Kampf gesperrt');
  end if;
end $$;

-- Nur aktiv, wenn grace_seconds > 0 (Standard 0 = Sperre sofort endgültig). Dann können 2 verschiedene Mitspieler
-- die Sperre gemeinsam aufheben. Danach gibt es KEINE Möglichkeit mehr, den Kampf zu öffnen.
-- p_withdraw = true zieht den eigenen Antrag zurück. Gibt true zurück, wenn entsperrt wurde.
create or replace function unlock_fight(p_name text, p_pin text, p_fight int, p_withdraw boolean default false) returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare v_player uuid := _player(p_name, p_pin);
begin
  perform 1 from fights where id = p_fight for update;
  if not exists (select 1 from fights where id = p_fight and status = 'locked' and _undo_left(id) > 0) then
    raise exception 'Zu spät: Die Sperre ist endgültig';
  end if;
  if p_withdraw then
    delete from unlock_requests where fight_id = p_fight and player_id = v_player;
    if found then perform _log(p_fight, v_player, 'Entsperren zurückgezogen'); end if;
    return false;
  end if;
  insert into unlock_requests values (p_fight, v_player) on conflict do nothing;
  if found then perform _log(p_fight, v_player, 'Entsperren beantragt'); end if;
  if (select count(*) from unlock_requests where fight_id = p_fight) >= 2 then
    update fights set status = 'open', locked_at = null, locked_by = null where id = p_fight;
    delete from unlock_requests where fight_id = p_fight;
    perform _log(p_fight, v_player, 'Kampf entsperrt');
    return true;
  end if;
  return false;
end $$;

-- Ergebnis bestätigen ('A', 'B', 'draw') oder Bestätigung zurückziehen (null). Änderbar.
-- Nur wer diesen Kampf getippt hat, darf abstimmen.
create or replace function vote_result(p_name text, p_pin text, p_fight int, p_vote text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_player uuid := _player(p_name, p_pin);
begin
  perform 1 from fights where id = p_fight and status <> 'open' for update;
  if not found then
    raise exception 'Der Kampf hat noch nicht begonnen';
  end if;
  if _undo_left(p_fight) > 0 then
    raise exception 'Ergebnis erst nach Ablauf der Sperr-Frist bestätigen';
  end if;
  if p_vote is not null and not exists (select 1 from bets where player_id = v_player and fight_id = p_fight) then
    raise exception 'Nur wer diesen Kampf getippt hat, kann das Ergebnis bestätigen';
  end if;
  if p_vote is null then
    delete from votes where player_id = v_player and fight_id = p_fight;
  else
    insert into votes (player_id, fight_id, vote) values (v_player, p_fight, p_vote)
    on conflict (player_id, fight_id) do update set vote = excluded.vote;
  end if;
  perform _log(p_fight, v_player, case p_vote when 'A' then 'Ergebnis bestätigt: ' || (select fighter_a from fights where id = p_fight)
                                              when 'B' then 'Ergebnis bestätigt: ' || (select fighter_b from fights where id = p_fight)
                                              when 'draw' then 'Ergebnis bestätigt: Unentschieden/NC'
                                              else 'Ergebnis-Stimme zurückgezogen' end);
  perform _recount(p_fight);
end $$;

-- Kampf zur Fight Card hinzufügen (falls sich die Card noch ändert)
create or replace function add_fight(p_name text, p_pin text, p_a text, p_b text, p_info text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _player(p_name, p_pin);
  if length(trim(p_a)) < 2 or length(trim(p_b)) < 2 then raise exception 'Bitte beide Kämpfer eintragen'; end if;
  insert into fights (pos, fighter_a, fighter_b, info)
  values ((select coalesce(max(pos), 0) + 1 from fights), trim(p_a), trim(p_b), coalesce(trim(p_info), ''));
end $$;

-- Kampf entfernen: nur solange er offen ist und noch niemand getippt hat
create or replace function delete_fight(p_name text, p_pin text, p_fight int) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _player(p_name, p_pin);
  if exists (select 1 from bets where fight_id = p_fight) or
     not exists (select 1 from fights where id = p_fight and status = 'open') then
    raise exception 'Nur offene Kämpfe ohne Tipps können entfernt werden';
  end if;
  delete from fights where id = p_fight;
end $$;

-- Nur interne Funktionen sperren; der Rest ist per anon-Key aufrufbar.
revoke execute on function _player(text, text), _needed(int), _recount(int), _undo_left(int), _log(int, uuid, text), _state(uuid)
  from public, anon, authenticated;
grant execute on function join_game(text, text), get_state(text, text), place_bet(text, text, int, text),
  lock_fight(text, text, int), unlock_fight(text, text, int, boolean), vote_result(text, text, int, text),
  add_fight(text, text, text, text, text), delete_fight(text, text, int)
  to anon;

-- ---------------------------------------------------------------------
-- 4. Mehrheit für Ergebnisse: 0.5 = mehr als die Hälfte der Tipper
-- ---------------------------------------------------------------------
insert into settings (key, value) values ('quorum', '0.5') on conflict (key) do nothing;
-- Sekunden nach dem Sperren, in denen 2 Mitspieler noch entsperren können (0 = Sperre sofort endgültig)
insert into settings (key, value) values ('grace_seconds', '0') on conflict (key) do nothing;

-- ---------------------------------------------------------------------
-- 5. Fight Card OKTAGON 96, 31.10.2026, SAP Garden München
--    (Stand 20.10.2026, nur wenn noch keine Kämpfe angelegt sind).
-- ---------------------------------------------------------------------
insert into fights (pos, fighter_a, fighter_b, info)
select * from (values
  (1, 'Madureira',          'Schordje',          'Federgewicht'),
  (2, 'Ayari',              'Surdu',             ''),
  (3, 'Bartl',              'Manning',           ''),
  (4, 'Lazar Todev',        'Simon Biyong',      'Schwergewicht'),
  (5, 'Gökhan Aksu',        'Niko Samsonidse',   ''),
  (6, 'Ronald Paradeiser',  'Tyrone Pfeifer',    'Co-Main Event'),
  (7, 'Amiran Gogoladze',   'Felix Klinkhammer', 'Main Event · Weltergewicht-Titel')
) v(pos, a, b, info)
where not exists (select 1 from fights);
