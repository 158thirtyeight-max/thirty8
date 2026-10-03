-- =========================================================================
-- Checks for 20261002001400_stop_timeline_validation.sql: the server independently validates the
-- chronology of a journey (overnight included). Everything is rolled back.
-- =========================================================================
begin;
insert into public.countries (code, name) values ('ZZ', 'Testland') on conflict (code) do nothing;
create temp table t_loc (tag text, id uuid);
with c as (insert into public.locations (country_id, name) values ((select id from public.countries where code = 'ZZ'), 'L Src') returning id) insert into t_loc select 'S', id from c;
with c as (insert into public.locations (country_id, name) values ((select id from public.countries where code = 'ZZ'), 'L Mid') returning id) insert into t_loc select 'M', id from c;
with c as (insert into public.locations (country_id, name) values ((select id from public.countries where code = 'ZZ'), 'L Dst') returning id) insert into t_loc select 'D', id from c;

create function pg_temp.st(p_tag text, p_b boolean, p_d boolean, p_arr int, p_dep int) returns jsonb language sql as $f$
  select jsonb_build_object('city_id', (select id from t_loc where tag = p_tag), 'is_boarding', p_b, 'is_dropping', p_d,
                            'arrival_offset_min', p_arr, 'departure_offset_min', p_dep) $f$;
create function pg_temp.v(p_dur int, p_stops jsonb) returns text[] language sql as $f$
  select private.validate_route_journey(null, (select id from t_loc where tag = 'S'), (select id from t_loc where tag = 'D'),
                                        time '22:00', p_dur, '{1}'::smallint[], p_stops) $f$;

do $$
declare e text[];
begin
  -- 22:00 start, stop 23:30 (offset 90) for 5 minutes, destination 02:00 next day (offset 240)
  e := pg_temp.v(240, jsonb_build_array(pg_temp.st('S', true, false, 0, 0), pg_temp.st('M', true, true, 90, 95), pg_temp.st('D', false, true, 240, 240)));
  if coalesce(array_length(e, 1), 0) <> 0 then raise exception 'FAIL 1: overnight journey rejected: %', e; end if;

  e := pg_temp.v(240, jsonb_build_array(pg_temp.st('S', true, false, 0, 0), pg_temp.st('M', true, true, 90, 95), pg_temp.st('D', false, true, 200, 200)));
  if not e::text like '%destination arrival must match%' then raise exception 'FAIL 2: destination arrival mismatch accepted: %', e; end if;

  e := pg_temp.v(240, jsonb_build_array(pg_temp.st('S', true, false, 0, 10), pg_temp.st('M', true, true, 90, 95), pg_temp.st('D', false, true, 240, 240)));
  if not e::text like '%origin must depart at the start%' then raise exception 'FAIL 3: origin offset accepted: %', e; end if;

  e := pg_temp.v(900, jsonb_build_array(pg_temp.st('S', true, false, 0, 0), pg_temp.st('M', true, true, 90, 500), pg_temp.st('D', false, true, 900, 900)));
  if not e::text like '%waits over 6 hours%' then raise exception 'FAIL 4: long dwell accepted: %', e; end if;

  e := pg_temp.v(240, jsonb_build_array(pg_temp.st('S', true, false, 0, 0), pg_temp.st('M', true, true, 250, 255), pg_temp.st('D', false, true, 240, 240)));
  if coalesce(array_length(e, 1), 0) = 0 then raise exception 'FAIL 5: a stop after the destination arrival was accepted'; end if;

  e := pg_temp.v(240, jsonb_build_array(pg_temp.st('S', true, false, 0, 0), pg_temp.st('M', true, true, 100, 90), pg_temp.st('D', false, true, 240, 240)));
  if not e::text like '%departs before it arrives%' then raise exception 'FAIL 6: negative dwell accepted: %', e; end if;

  e := pg_temp.v(5000, jsonb_build_array(pg_temp.st('S', true, false, 0, 0), pg_temp.st('D', false, true, 5000, 5000)));
  if not e::text like '%over 72 hours%' then raise exception 'FAIL 7: 72h limit not enforced: %', e; end if;
end $$;
rollback;
