-- =============================================================
--  오늘도 참았다 · 익명 이용 통계 설정 (Supabase SQL Editor 에 통째로 붙여넣고 Run)
--  1) 맨 아래 '여기에-대시보드-비밀번호' 를 원하는 비밀번호로 바꾼 뒤 실행하세요.
--  2) 수집하는 것: 익명 방문자 ID(무작위), 이벤트 이름, 게임 종류, 숫자 값.
--     상사 이름·직접 쓴 내용 같은 개인 정보는 수집하지 않습니다.
-- =============================================================

create extension if not exists pgcrypto;

create table if not exists public.events (
  id         uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  vid        text not null check (char_length(vid) <= 64),   -- 익명 방문자 ID
  sid        text not null check (char_length(sid) <= 64),   -- 방문(세션) ID
  name       text not null check (char_length(name) <= 40), -- 이벤트 이름
  room       text check (room is null or char_length(room) <= 20),
  value      numeric,
  props      jsonb not null default '{}'::jsonb check (pg_column_size(props) < 2000)
);
create index if not exists events_created_at_idx on public.events (created_at);
create index if not exists events_name_idx on public.events (name);
create index if not exists events_vid_idx on public.events (vid);

-- 누구나 '쓰기'만 가능, '읽기'는 불가 (읽기는 아래 비밀번호 함수로만)
alter table public.events enable row level security;
drop policy if exists "anon can insert events" on public.events;
create policy "anon can insert events" on public.events for insert to anon with check (true);
grant insert on public.events to anon;
revoke select, update, delete on public.events from anon, authenticated;

-- 대시보드 비밀번호 (테이블은 외부에서 읽을 수 없음)
create table if not exists public.dash_secret (pass text not null);
alter table public.dash_secret enable row level security;
revoke all on public.dash_secret from anon, authenticated;

-- 대시보드용 통계 함수: 비밀번호가 맞을 때만 '합계 숫자'만 돌려줍니다.
create or replace function public.dashboard_stats(p_pass text, p_days int default 30)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_days  int := greatest(1, least(coalesce(p_days, 30), 365));
  v_since timestamptz;
  v_out   jsonb;
begin
  if not exists (select 1 from dash_secret where pass = p_pass) then
    raise exception 'invalid password' using errcode = '28P01';
  end if;
  -- 한국 시간 기준 'N일 전 0시' 부터
  v_since := (date_trunc('day', now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul') - make_interval(days => v_days - 1);

  with e as (select * from events where created_at >= v_since),
  sess as (
    select sid, max(vid) vid, min(created_at) st,
           coalesce(max(value) filter (where name in ('hb', 'leave')), 0) dur
    from e group by sid
  ),
  vids as (select distinct vid from e),
  firsts as (select vid, min(created_at) f from events where vid in (select vid from vids) group by vid),
  days_per_vid as (
    select vid, count(distinct (created_at at time zone 'Asia/Seoul')::date) d
    from events where vid in (select vid from vids) group by vid
  ),
  ends as (select * from e where name = 'game_end')
  select jsonb_build_object(
    'days', v_days,
    'since', v_since,
    'generated_at', now(),
    'online_now', (select count(distinct sid) from events where created_at > now() - interval '2 minutes'),
    'visitors', (select count(*) from vids),
    'new_visitors', (select count(*) from firsts where f >= v_since),
    'returning_visitors', (select count(*) from days_per_vid where d >= 2),
    'sessions', (select count(*) from sess),
    'pageviews', (select count(*) from e where name = 'page_view'),
    'avg_session_sec', (select coalesce(round(avg(dur)), 0) from sess where dur > 0),
    'median_session_sec', (select coalesce(round(percentile_cont(0.5) within group (order by dur)::numeric), 0) from sess where dur > 0),
    'total_active_sec', (select coalesce(round(sum(dur)), 0) from sess),
    'plays', (select count(*) from e where name = 'game_start'),
    'finishes', (select count(*) from ends),
    'quits', (select count(*) from e where name = 'game_quit'),
    'avg_stress', (select round(avg(value)) from ends),
    'avg_plays_per_visitor', (select round(count(*)::numeric / nullif((select count(*) from vids), 0), 2) from e where name = 'game_start'),
    'shares', (select count(*) from e where name = 'share_click'),
    'motion', (select jsonb_build_object(
                 'motion', count(*) filter (where coalesce((props->>'motion')::boolean, false)),
                 'touch',  count(*) filter (where not coalesce((props->>'motion')::boolean, false))) from ends),
    'stress_buckets', (select jsonb_build_object(
                 'l1', count(*) filter (where value < 30),
                 'l2', count(*) filter (where value >= 30 and value < 60),
                 'l3', count(*) filter (where value >= 60 and value < 85),
                 'l4', count(*) filter (where value >= 85)) from ends),
    'daily', (select coalesce(jsonb_agg(d order by d.day), '[]'::jsonb) from (
                 select (created_at at time zone 'Asia/Seoul')::date as day,
                        count(distinct vid) visitors, count(distinct sid) sessions,
                        count(*) filter (where name = 'game_start') plays,
                        round(avg(value) filter (where name = 'game_end')) avg_stress
                 from e group by 1) d),
    'rooms', (select coalesce(jsonb_agg(r), '[]'::jsonb) from (
                 select room,
                        count(*) filter (where name = 'game_start') plays,
                        count(*) filter (where name = 'game_end') finishes,
                        round(avg(value) filter (where name = 'game_end')) avg_stress,
                        round(avg((props->>'count')::numeric) filter (where name = 'game_end'), 1) avg_count,
                        count(*) filter (where name = 'game_end' and coalesce((props->>'motion')::boolean, false)) motion_plays,
                        count(*) filter (where name = 'game_end' and coalesce((props->>'fever')::boolean, false)) fever_plays,
                        count(*) filter (where name = 'game_start' and coalesce((props->>'custom')::int, 0) > 0) custom_plays
                 from e where room is not null and name in ('game_start', 'game_end') group by room) r),
    'clicks', (select coalesce(jsonb_agg(c order by c.n desc), '[]'::jsonb) from (
                 select name, room, count(*) n from e
                 where name not in ('hb', 'leave', 'page_view') group by name, room) c),
    'hours', (select coalesce(jsonb_agg(h order by h.hour), '[]'::jsonb) from (
                 select extract(hour from created_at at time zone 'Asia/Seoul')::int as hour, count(*) plays
                 from e where name = 'game_start' group by 1) h),
    'weekdays', (select coalesce(jsonb_agg(w order by w.dow), '[]'::jsonb) from (
                 select extract(dow from created_at at time zone 'Asia/Seoul')::int as dow, count(*) plays, round(avg(value) filter (where name = 'game_end')) avg_stress
                 from e where name in ('game_start', 'game_end') group by 1) w),
    'devices', (select coalesce(jsonb_agg(x order by x.n desc), '[]'::jsonb) from (
                 select coalesce(props->>'device', '기타') device, count(distinct vid) n
                 from e where name = 'page_view' group by 1) x),
    'sources', (select coalesce(jsonb_agg(x order by x.n desc), '[]'::jsonb) from (
                 select coalesce(nullif(props->>'src', ''), '직접 방문') src, count(distinct vid) n
                 from e where name = 'page_view' group by 1 order by 2 desc limit 10) x)
  ) into v_out;
  return v_out;
end;
$$;
revoke all on function public.dashboard_stats(text, int) from public;
grant execute on function public.dashboard_stats(text, int) to anon;

-- ▼ 대시보드 비밀번호 설정 (따옴표 안을 바꾸세요). 나중에 바꾸려면 이 두 줄만 다시 실행.
delete from public.dash_secret;
insert into public.dash_secret (pass) values ('여기에-대시보드-비밀번호');
