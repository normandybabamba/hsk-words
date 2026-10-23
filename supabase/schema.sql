-- =====================================================================
-- HSK 단어 서랍 · Supabase 스키마
-- Supabase 대시보드 → SQL Editor → New query 에 이 파일 전체를 붙여넣고 Run.
-- 그다음 seed.sql 을 같은 방법으로 실행하면 기본 서랍·단어·관리자 계정이 들어갑니다.
--
-- 구조
--   hsk_app_users      계정 (이름 + 암호 4자리, bcrypt 해시)
--   hsk_sessions       로그인 토큰
--   hsk_decks          서랍 (HSK 3급, HSK 4급 …)
--   hsk_words          서랍 속 단어 (한자, 병음, 뜻)
--   hsk_progress       계정별 진도 (외움/헷갈림/횟수/최근/메모)
--   hsk_user_settings  계정별 설정 (하루 단어 수, 가리기 등)
-- 테이블은 RLS 로 잠그고, 앱은 아래 hsk_* 함수(RPC)로만 접근합니다.
-- =====================================================================

create extension if not exists pgcrypto;

create table if not exists hsk_app_users(
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (char_length(name) between 1 and 20),
  pin_hash text not null,
  is_admin boolean not null default false,
  failed int not null default 0,
  locked_until timestamptz,
  created_at timestamptz not null default now()
);
create table if not exists hsk_sessions(
  token uuid primary key default gen_random_uuid(),
  user_id uuid not null references hsk_app_users(id) on delete cascade,
  created_at timestamptz not null default now(),
  last_seen timestamptz not null default now()
);
create table if not exists hsk_decks(
  id text primary key,
  name text not null,
  color text,
  sort int not null default 100,
  created_at timestamptz not null default now()
);
create table if not exists hsk_words(
  deck_id text not null references hsk_decks(id) on delete cascade,
  ord int not null,
  han text not null,
  py text not null default '',
  mn text not null default '',
  primary key(deck_id, han)
);
create index if not exists hsk_words_deck_ord on hsk_words(deck_id, ord);
create table if not exists hsk_progress(
  user_id uuid not null references hsk_app_users(id) on delete cascade,
  deck_id text not null references hsk_decks(id) on delete cascade,
  han text not null,
  d smallint not null default 0,
  x smallint not null default 0,
  c int not null default 0,
  t date,
  m text not null default '',
  updated_at timestamptz not null default now(),
  primary key(user_id, deck_id, han)
);
create table if not exists hsk_user_settings(
  user_id uuid primary key references hsk_app_users(id) on delete cascade,
  data jsonb not null default '{}'::jsonb
);

alter table hsk_app_users enable row level security;
alter table hsk_sessions enable row level security;
alter table hsk_decks enable row level security;
alter table hsk_words enable row level security;
alter table hsk_progress enable row level security;
alter table hsk_user_settings enable row level security;
revoke all on hsk_app_users, hsk_sessions, hsk_decks, hsk_words, hsk_progress, hsk_user_settings from anon, authenticated;

-- ---------- 내부 도우미 (앱에서 직접 호출 불가) ----------
create or replace function hsk__auth(p_token uuid) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare v uuid;
begin
  select user_id into v from hsk_sessions where token = p_token;
  if v is null then raise exception 'AUTH'; end if;
  update hsk_sessions set last_seen = now() where token = p_token;
  return v;
end $$;

create or replace function hsk__admin(p_token uuid) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare v uuid := hsk__auth(p_token);
begin
  if not exists(select 1 from hsk_app_users where id = v and is_admin) then raise exception 'ADMIN'; end if;
  return v;
end $$;

create or replace function hsk__deck_list(v uuid) returns json
language sql security definer set search_path = public, extensions as $$
  select coalesce(json_agg(json_build_object(
    'id', d.id, 'name', d.name, 'color', d.color,
    'n',  (select count(*) from hsk_words w where w.deck_id = d.id),
    'dn', (select count(*) from hsk_progress p join hsk_words w on w.deck_id = p.deck_id and w.han = p.han where p.user_id = v and p.deck_id = d.id and p.d = 1),
    'xn', (select count(*) from hsk_progress p join hsk_words w on w.deck_id = p.deck_id and w.han = p.han where p.user_id = v and p.deck_id = d.id and p.x = 1)
  ) order by d.sort, d.created_at), '[]'::json) from hsk_decks d
$$;

-- ---------- 계정 ----------
create or replace function hsk_users() returns table(id uuid, name text)
language sql security definer set search_path = public, extensions as $$
  select id, name from hsk_app_users order by created_at
$$;

create or replace function hsk_signup(p_name text, p_pin text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare v uuid; tk uuid; n text := btrim(p_name);
begin
  if n is null or char_length(n) < 1 or char_length(n) > 20 then raise exception 'NAME'; end if;
  if p_pin !~ '^\d{4}$' then raise exception 'PINFMT'; end if;
  if exists(select 1 from hsk_app_users where name = n) then raise exception 'NAME_TAKEN'; end if;
  insert into hsk_app_users(name, pin_hash) values (n, crypt(p_pin, gen_salt('bf'))) returning id into v;
  insert into hsk_sessions(user_id) values (v) returning token into tk;
  return json_build_object('token', tk, 'uid', v);
end $$;

create or replace function hsk_login(p_uid uuid, p_pin text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare u hsk_app_users; tk uuid;
begin
  select * into u from hsk_app_users where id = p_uid;
  if u.id is null then return json_build_object('error', 'NOUSER'); end if;
  if u.locked_until is not null and u.locked_until > now() then return json_build_object('error', 'LOCKED'); end if;
  if u.pin_hash <> crypt(p_pin, u.pin_hash) then
    -- 5번 틀리면 5분 잠금 (예외 대신 값을 돌려줘야 실패 횟수가 저장됨)
    update hsk_app_users set
      locked_until = case when failed + 1 >= 5 then now() + interval '5 minutes' else null end,
      failed = case when failed + 1 >= 5 then 0 else failed + 1 end
    where id = u.id;
    return json_build_object('error', case when u.failed + 1 >= 5 then 'LOCKED' else 'PIN' end);
  end if;
  update hsk_app_users set failed = 0, locked_until = null where id = u.id;
  delete from hsk_sessions where user_id = u.id and last_seen < now() - interval '60 days';
  insert into hsk_sessions(user_id) values (u.id) returning token into tk;
  return json_build_object('token', tk, 'uid', u.id);
end $$;

create or replace function hsk_logout(p_token uuid) returns void
language sql security definer set search_path = public, extensions as $$
  delete from hsk_sessions where token = p_token
$$;

-- ---------- 상태 · 진도 ----------
create or replace function hsk_state(p_token uuid) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare v uuid := hsk__auth(p_token); u hsk_app_users;
begin
  select * into u from hsk_app_users where id = v;
  return json_build_object(
    'user', json_build_object('id', u.id, 'name', u.name, 'admin', u.is_admin, 'created', to_char(u.created_at, 'YYYY-MM-DD')),
    'settings', coalesce((select data from hsk_user_settings where user_id = v), '{}'::jsonb),
    'decks', hsk__deck_list(v));
end $$;

create or replace function hsk_deck(p_token uuid, p_deck text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare v uuid := hsk__auth(p_token);
begin
  return json_build_object(
    'words', coalesce((select json_agg(json_build_array(han, py, mn) order by ord) from hsk_words where deck_id = p_deck), '[]'::json),
    'prog',  coalesce((select json_object_agg(han, json_build_object('d', d, 'x', x, 'c', c, 't', t, 'm', m)) from hsk_progress where user_id = v and deck_id = p_deck), '{}'::json));
end $$;

create or replace function hsk_save_progress(p_token uuid, p_deck text, p_items jsonb) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v uuid := hsk__auth(p_token);
begin
  insert into hsk_progress(user_id, deck_id, han, d, x, c, t, m, updated_at)
  select v, p_deck, k,
         coalesce((val->>'d')::smallint, 0), coalesce((val->>'x')::smallint, 0), coalesce((val->>'c')::int, 0),
         nullif(val->>'t', '')::date, coalesce(val->>'m', ''), now()
  from jsonb_each(p_items) as j(k, val)
  on conflict (user_id, deck_id, han) do update
    set d = excluded.d, x = excluded.x, c = excluded.c, t = excluded.t, m = excluded.m, updated_at = now();
end $$;

create or replace function hsk_clear_progress(p_token uuid, p_deck text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v uuid := hsk__auth(p_token);
begin
  delete from hsk_progress where user_id = v and deck_id = p_deck;
end $$;

create or replace function hsk_save_settings(p_token uuid, p_data jsonb) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v uuid := hsk__auth(p_token);
begin
  insert into hsk_user_settings(user_id, data) values (v, p_data)
  on conflict (user_id) do update set data = excluded.data;
end $$;

-- ---------- 서랍 관리 (관리자만) ----------
create or replace function hsk_deck_create(p_token uuid, p_name text, p_color text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare v uuid := hsk__admin(p_token); nid text := 'd' || substr(md5(random()::text || clock_timestamp()::text), 1, 10);
begin
  if btrim(coalesce(p_name, '')) = '' then raise exception 'NAME'; end if;
  insert into hsk_decks(id, name, color, sort) values (nid, btrim(p_name), p_color, coalesce((select max(sort) from hsk_decks), 0) + 1);
  return json_build_object('id', nid, 'decks', hsk__deck_list(v));
end $$;

create or replace function hsk_deck_rename(p_token uuid, p_deck text, p_name text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare v uuid := hsk__admin(p_token);
begin
  update hsk_decks set name = btrim(p_name) where id = p_deck;
  return hsk__deck_list(v);
end $$;

create or replace function hsk_deck_delete(p_token uuid, p_deck text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare v uuid := hsk__admin(p_token);
begin
  delete from hsk_decks where id = p_deck;
  return hsk__deck_list(v);
end $$;

create or replace function hsk_deck_clear(p_token uuid, p_deck text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare v uuid := hsk__admin(p_token);
begin
  delete from hsk_words where deck_id = p_deck;
  return hsk__deck_list(v);
end $$;

create or replace function hsk_deck_put_words(p_token uuid, p_deck text, p_words jsonb, p_replace boolean) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare v uuid := hsk__admin(p_token); base int; n_in int; n_add int;
begin
  if not exists(select 1 from hsk_decks where id = p_deck) then raise exception 'NODECK'; end if;
  if p_replace then delete from hsk_words where deck_id = p_deck; end if;
  select coalesce(max(ord), 0) into base from hsk_words where deck_id = p_deck;
  with src as (
    select btrim(e->>0) han, coalesce(btrim(e->>1), '') py, coalesce(btrim(e->>2), '') mn, o
    from jsonb_array_elements(p_words) with ordinality as t(e, o)
    where coalesce(btrim(e->>0), '') <> ''),
  ins as (
    insert into hsk_words(deck_id, ord, han, py, mn)
    select p_deck, base + o::int, han, py, mn from src
    on conflict do nothing returning 1)
  select count(*) into n_add from ins;
  n_in := jsonb_array_length(p_words);
  return json_build_object('added', n_add, 'dup', n_in - n_add, 'decks', hsk__deck_list(v));
end $$;

-- ---------- 권한 ----------
revoke execute on function hsk__auth(uuid), hsk__admin(uuid), hsk__deck_list(uuid) from public, anon, authenticated;
grant execute on function
  hsk_users(), hsk_signup(text, text), hsk_login(uuid, text), hsk_logout(uuid),
  hsk_state(uuid), hsk_deck(uuid, text), hsk_save_progress(uuid, text, jsonb), hsk_clear_progress(uuid, text),
  hsk_save_settings(uuid, jsonb), hsk_deck_create(uuid, text, text), hsk_deck_rename(uuid, text, text),
  hsk_deck_delete(uuid, text), hsk_deck_clear(uuid, text), hsk_deck_put_words(uuid, text, jsonb, boolean)
to anon, authenticated;
