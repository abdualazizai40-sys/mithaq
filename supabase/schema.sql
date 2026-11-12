-- ميثاق الأداء للمراقبين: بنية قاعدة البيانات (Supabase / PostgreSQL)
--
-- يُنفَّذ هذا الملف مرة واحدة على مشروع Supabase فارغ لإعادة بناء النظام،
-- ثم يُنفَّذ seed.sql لإضافة المعادلة والأسماء.
--
-- الفكرة: الجداول مغلقة تماماً أمام الموقع (لا قراءة ولا كتابة مباشرة).
-- الموقع يتعامل فقط مع إجراءات m_* أدناه، وكل إجراء يتحقق من جلسة المستخدم
-- ودوره (مراقب، مشرف، مدير) قبل أن يقرأ أو يكتب.
--
-- لتعديل إجراء قائم: انسخه من هنا، عدّله، ونفّذه في SQL Editor في Supabase
-- (CREATE OR REPLACE يستبدل القديم)، ثم حدّث هذا الملف بنفس التعديل.

create extension if not exists pgcrypto with schema extensions;

-- ---------- الجداول ----------

-- المعادلة والإعدادات (صف واحد بمفتاح 'main')
create table if not exists public.m_config(
  key text primary key,
  data jsonb not null,
  updated_at timestamptz not null default now());

-- الأسماء: المراقبون والمشرفون، مع الرقم السري مشفّراً
create table if not exists public.m_people(
  id text primary key check (id ~ '^[A-Za-z0-9_-]{1,40}$'),
  name text not null check (char_length(name) between 1 and 80),
  role text not null default 'employee' check (role in ('employee','supervisor')),
  supervisor_id text,
  pin_hash text,
  must_change boolean not null default false,  -- رقم أولي من المدير لم يغيّره صاحبه بعد
  fails int not null default 0,
  locked_until timestamptz,
  sort int not null default 0);

-- رمز المدير (صف واحد)
create table if not exists public.m_admin(
  id int primary key default 1 check (id = 1),
  code_hash text,
  fails int not null default 0,
  locked_until timestamptz);
insert into public.m_admin(id) values (1) on conflict do nothing;

-- جلسات الدخول
create table if not exists public.m_sessions(
  token uuid primary key default gen_random_uuid(),
  person_id text references public.m_people(id) on delete cascade,
  is_manager boolean not null default false,
  expires_at timestamptz not null default now() + interval '60 days');

-- الأعمال المرسلة: صف لكل مراقب لكل شهر
create table if not exists public.m_charters(
  person_id text not null references public.m_people(id) on delete cascade,
  month text not null check (month ~ '^\d{4}-(0[1-9]|1[0-2])$'),
  vals jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (person_id, month));

-- ملاحظات المشرف: صف لكل مراقب لكل شهر
create table if not exists public.m_reviews(
  person_id text not null references public.m_people(id) on delete cascade,
  month text not null,
  by_id text,
  note text not null default '',
  at timestamptz not null default now(),
  primary key (person_id, month));

alter table public.m_config   enable row level security;
alter table public.m_people   enable row level security;
alter table public.m_admin    enable row level security;
alter table public.m_sessions enable row level security;
alter table public.m_charters enable row level security;
alter table public.m_reviews  enable row level security;
revoke all on public.m_config, public.m_people, public.m_admin, public.m_sessions, public.m_charters, public.m_reviews from anon, authenticated;

-- ---------- إجراء داخلي: من صاحب الجلسة؟ ----------

create or replace function public.m__who(p_token uuid, out person_id text, out is_manager boolean, out role text)
language plpgsql security definer set search_path = public, extensions as $$
begin
  select s.person_id, s.is_manager, p.role into person_id, is_manager, role
  from m_sessions s left join m_people p on p.id = s.person_id
  where s.token = p_token and s.expires_at > now();
  if not found then raise exception 'no_session' using errcode = 'P0001'; end if;
end $$;
revoke all on function public.m__who(uuid) from public, anon, authenticated;

-- ---------- عام (بلا دخول): المعادلة وقائمة الأسماء لشاشة الدخول ----------

create or replace function public.m_public() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object(
    'config', (select data from m_config where key = 'main'),
    'people', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'role', role, 'supervisorPid', supervisor_id, 'hasPin', pin_hash is not null, 'mustChange', must_change) order by sort, name) from m_people), '[]'::jsonb),
    'managerSet', (select code_hash is not null from m_admin where id = 1));
$$;

-- ---------- الدخول والخروج ----------

-- المراقب أو المشرف: لا دخول قبل أن يعيّن المدير رقماً أولياً. 5 أخطاء = قفل 15 دقيقة
create or replace function public.m_login(p_person text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r m_people; t uuid;
begin
  if p_pin is null or char_length(p_pin) < 4 or char_length(p_pin) > 20 then return jsonb_build_object('error', 'short'); end if;
  select * into r from m_people where id = p_person for update;
  if not found then return jsonb_build_object('error', 'unknown'); end if;
  if r.locked_until is not null and r.locked_until > now() then return jsonb_build_object('error', 'locked'); end if;
  if r.pin_hash is null then return jsonb_build_object('error', 'nopin'); end if;
  if r.pin_hash = crypt(p_pin, r.pin_hash) then
    update m_people set fails = 0, locked_until = null where id = r.id;
  else
    update m_people set fails = case when fails + 1 >= 5 then 0 else fails + 1 end,
                        locked_until = case when fails + 1 >= 5 then now() + interval '15 minutes' else null end where id = r.id;
    return jsonb_build_object('error', 'wrong');
  end if;
  insert into m_sessions(person_id) values (r.id) returning token into t;
  return jsonb_build_object('token', t, 'mustChange', r.must_change);
end $$;

-- المدير: أول رمز يُكتب على قاعدة بيانات جديدة يصبح رمز المدير
create or replace function public.m_login_manager(p_code text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare a m_admin; t uuid; first boolean := false;
begin
  if p_code is null or char_length(p_code) < 6 or char_length(p_code) > 60 then return jsonb_build_object('error', 'short'); end if;
  select * into a from m_admin where id = 1 for update;
  if a.locked_until is not null and a.locked_until > now() then return jsonb_build_object('error', 'locked'); end if;
  if a.code_hash is null then
    update m_admin set code_hash = crypt(p_code, gen_salt('bf', 10)), fails = 0 where id = 1; first := true;
  elsif a.code_hash = crypt(p_code, a.code_hash) then
    update m_admin set fails = 0, locked_until = null where id = 1;
  else
    update m_admin set fails = case when fails + 1 >= 5 then 0 else fails + 1 end,
                       locked_until = case when fails + 1 >= 5 then now() + interval '15 minutes' else null end where id = 1;
    return jsonb_build_object('error', 'wrong');
  end if;
  insert into m_sessions(is_manager) values (true) returning token into t;
  return jsonb_build_object('token', t, 'first', first);
end $$;

create or replace function public.m_logout(p_token uuid) returns jsonb
language sql security definer set search_path = public, extensions as $$
  with d as (delete from m_sessions where token = p_token returning 1) select jsonb_build_object('ok', true);
$$;

-- ---------- الأرقام السرية ----------

-- المدير يعيّن رقماً أولياً، ويُلزم صاحبه بتغييره في أول دخول
create or replace function public.m_set_pin(p_token uuid, p_person text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare w record;
begin
  begin select * into w from m__who(p_token); exception when others then return jsonb_build_object('error', 'no_session'); end;
  if not w.is_manager then return jsonb_build_object('error', 'forbidden'); end if;
  if p_pin is null or char_length(p_pin) < 4 or char_length(p_pin) > 20 then return jsonb_build_object('error', 'short'); end if;
  update m_people set pin_hash = crypt(p_pin, gen_salt('bf', 8)), must_change = true, fails = 0, locked_until = null where id = p_person;
  if not found then return jsonb_build_object('error', 'unknown'); end if;
  delete from m_sessions where person_id = p_person;
  return jsonb_build_object('ok', true);
end $$;

-- صاحب الحساب يغيّر رقمه (يجب أن يختلف عن الرقم الحالي)
create or replace function public.m_change_pin(p_token uuid, p_new text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare w record; cur text;
begin
  begin select * into w from m__who(p_token); exception when others then return jsonb_build_object('error', 'no_session'); end;
  if w.person_id is null then return jsonb_build_object('error', 'forbidden'); end if;
  if p_new is null or char_length(p_new) < 4 or char_length(p_new) > 20 then return jsonb_build_object('error', 'short'); end if;
  select pin_hash into cur from m_people where id = w.person_id;
  if cur = crypt(p_new, cur) then return jsonb_build_object('error', 'same'); end if;
  update m_people set pin_hash = crypt(p_new, gen_salt('bf', 8)), must_change = false where id = w.person_id;
  delete from m_sessions where person_id = w.person_id and token <> p_token;
  return jsonb_build_object('ok', true);
end $$;

-- المدير يمسح رقم شخص (يصبح بلا رقم ولا يستطيع الدخول حتى يُعيَّن له رقم)
create or replace function public.m_reset_pin(p_token uuid, p_person text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare w record;
begin
  begin select * into w from m__who(p_token); exception when others then return jsonb_build_object('error', 'no_session'); end;
  if not w.is_manager then return jsonb_build_object('error', 'forbidden'); end if;
  update m_people set pin_hash = null, must_change = false, fails = 0, locked_until = null where id = p_person;
  delete from m_sessions where person_id = p_person;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.m_change_manager_code(p_token uuid, p_new text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare w record;
begin
  begin select * into w from m__who(p_token); exception when others then return jsonb_build_object('error', 'no_session'); end;
  if not w.is_manager then return jsonb_build_object('error', 'forbidden'); end if;
  if p_new is null or char_length(p_new) < 6 or char_length(p_new) > 60 then return jsonb_build_object('error', 'short'); end if;
  update m_admin set code_hash = crypt(p_new, gen_salt('bf', 10)), fails = 0, locked_until = null where id = 1;
  delete from m_sessions where is_manager and token <> p_token;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- قراءة البيانات حسب الدور ----------
-- المدير: الجميع. المشرف: مراقبوه. المراقب: نفسه فقط.
-- 'anon' = أعمال بقية المراقبين بلا أسماء، لحساب الترتيب ومتوسط الفريق.
-- من لم يغيّر رقمه الأولي لا يحصل على أي بيانات.

create or replace function public.m_data(p_token uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare w record; vis text[]; mc boolean := false;
begin
  begin select * into w from m__who(p_token); exception when others then return jsonb_build_object('error', 'no_session'); end;
  if w.person_id is not null then select must_change into mc from m_people where id = w.person_id; end if;
  if mc then return jsonb_build_object('me', jsonb_build_object('id', w.person_id, 'manager', false, 'role', w.role, 'mustChange', true),
    'charters', '{}'::jsonb, 'anon', '[]'::jsonb, 'reviews', '{}'::jsonb, 'now', now()); end if;
  if w.is_manager then select coalesce(array_agg(id), '{}') into vis from m_people;
  elsif w.role = 'supervisor' then select coalesce(array_agg(id), '{}') into vis from m_people where supervisor_id = w.person_id;
  else vis := array[w.person_id]; end if;
  return jsonb_build_object(
    'me', jsonb_build_object('id', w.person_id, 'manager', w.is_manager, 'role', w.role, 'mustChange', false),
    'charters', coalesce((select jsonb_object_agg(pid, jsonb_build_object('months', ms)) from (
        select person_id pid, jsonb_object_agg(month, jsonb_build_object('values', vals, 'updatedAt', updated_at)) ms
        from m_charters where person_id = any(vis) group by person_id) q), '{}'::jsonb),
    'anon', coalesce((select jsonb_agg(jsonb_build_object('months', ms)) from (
        select jsonb_object_agg(c.month, jsonb_build_object('values', c.vals)) ms
        from m_charters c join m_people p on p.id = c.person_id
        where p.role = 'employee' and not (c.person_id = any(vis)) group by c.person_id) q), '[]'::jsonb),
    'reviews', coalesce((select jsonb_object_agg(person_id || '__' || month, jsonb_build_object('note', note, 'by', by_id, 'at', at, 'seen', true))
        from m_reviews where person_id = any(vis)), '{}'::jsonb),
    'now', now());
end $$;

-- ---------- الكتابة ----------

-- المراقب يرسل أعمال شهر. مفتوح فقط من (آخر يوم - sendOpenDays + 1) حتى (آخر يوم + sendGraceDays)
-- بتوقيت الرياض، إلا إن فعّل المدير sendAlways.
create or replace function public.m_submit(p_token uuid, p_month text, p_vals jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare w record; cfg jsonb; od int; gd int; today date; first_day date; last_day date;
begin
  begin select * into w from m__who(p_token); exception when others then return jsonb_build_object('error', 'no_session'); end;
  if w.person_id is null or w.role <> 'employee' then return jsonb_build_object('error', 'forbidden'); end if;
  if (select must_change from m_people where id = w.person_id) then return jsonb_build_object('error', 'must_change'); end if;
  if p_month !~ '^\d{4}-(0[1-9]|1[0-2])$' or jsonb_typeof(p_vals) <> 'object' or length(p_vals::text) > 6000 then return jsonb_build_object('error', 'bad'); end if;
  select data into cfg from m_config where key = 'main';
  if not coalesce((cfg->>'sendAlways')::boolean, false) then
    od := greatest(1, coalesce((cfg->>'sendOpenDays')::numeric, 3)::int); gd := greatest(0, coalesce((cfg->>'sendGraceDays')::numeric, 5)::int);
    today := (now() at time zone 'Asia/Riyadh')::date;
    first_day := to_date(p_month || '-01', 'YYYY-MM-DD'); last_day := (first_day + interval '1 month' - interval '1 day')::date;
    if today < last_day - (od - 1) or today > last_day + gd then return jsonb_build_object('error', 'closed'); end if;
  end if;
  insert into m_charters(person_id, month, vals) values (w.person_id, p_month, p_vals)
    on conflict (person_id, month) do update set vals = excluded.vals, updated_at = now();
  return jsonb_build_object('ok', true);
end $$;

-- المشرف (لمراقبيه فقط) أو المدير يكتب ملاحظة على شهر
create or replace function public.m_review(p_token uuid, p_person text, p_month text, p_note text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare w record;
begin
  begin select * into w from m__who(p_token); exception when others then return jsonb_build_object('error', 'no_session'); end;
  if not (w.is_manager or exists (select 1 from m_people where id = p_person and supervisor_id = w.person_id and w.role = 'supervisor')) then
    return jsonb_build_object('error', 'forbidden'); end if;
  if p_month !~ '^\d{4}-(0[1-9]|1[0-2])$' then return jsonb_build_object('error', 'bad'); end if;
  insert into m_reviews(person_id, month, by_id, note) values (p_person, p_month, w.person_id, left(coalesce(p_note, ''), 600))
    on conflict (person_id, month) do update set by_id = excluded.by_id, note = excluded.note, at = now();
  return jsonb_build_object('ok', true);
end $$;

-- المدير يحفظ المعادلة والإعدادات
create or replace function public.m_save_config(p_token uuid, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare w record;
begin
  begin select * into w from m__who(p_token); exception when others then return jsonb_build_object('error', 'no_session'); end;
  if not w.is_manager then return jsonb_build_object('error', 'forbidden'); end if;
  if jsonb_typeof(p_data) <> 'object' or length(p_data::text) > 60000 then return jsonb_build_object('error', 'bad'); end if;
  insert into m_config(key, data) values ('main', p_data) on conflict (key) do update set data = excluded.data, updated_at = now();
  return jsonb_build_object('ok', true);
end $$;

-- المدير يحفظ قائمة الأسماء كاملة. الاسم المحذوف من القائمة يُحذف مع أعماله.
create or replace function public.m_save_people(p_token uuid, p_people jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare w record; e jsonb; i int := 0; ids text[] := '{}';
begin
  begin select * into w from m__who(p_token); exception when others then return jsonb_build_object('error', 'no_session'); end;
  if not w.is_manager then return jsonb_build_object('error', 'forbidden'); end if;
  if jsonb_typeof(p_people) <> 'array' or jsonb_array_length(p_people) > 300 then return jsonb_build_object('error', 'bad'); end if;
  for e in select * from jsonb_array_elements(p_people) loop
    i := i + 1; ids := ids || (e->>'id');
    insert into m_people(id, name, role, supervisor_id, sort)
      values (e->>'id', left(e->>'name', 80), case when e->>'role' = 'supervisor' then 'supervisor' else 'employee' end, nullif(e->>'supervisorPid', ''), i)
      on conflict (id) do update set name = excluded.name, role = excluded.role, supervisor_id = excluded.supervisor_id, sort = excluded.sort;
  end loop;
  delete from m_people where not (id = any(ids));
  return jsonb_build_object('ok', true);
end $$;

-- ---------- الصلاحيات: الموقع يستدعي الإجراءات فقط ----------

revoke all on function
  public.m_public(), public.m_login(text,text), public.m_login_manager(text), public.m_logout(uuid),
  public.m_set_pin(uuid,text,text), public.m_change_pin(uuid,text), public.m_reset_pin(uuid,text), public.m_change_manager_code(uuid,text),
  public.m_data(uuid), public.m_submit(uuid,text,jsonb), public.m_review(uuid,text,text,text),
  public.m_save_config(uuid,jsonb), public.m_save_people(uuid,jsonb)
from public;
grant execute on function
  public.m_public(), public.m_login(text,text), public.m_login_manager(text), public.m_logout(uuid),
  public.m_set_pin(uuid,text,text), public.m_change_pin(uuid,text), public.m_reset_pin(uuid,text), public.m_change_manager_code(uuid,text),
  public.m_data(uuid), public.m_submit(uuid,text,jsonb), public.m_review(uuid,text,text,text),
  public.m_save_config(uuid,jsonb), public.m_save_people(uuid,jsonb)
to anon, authenticated;
