-- =====================================================================
--  Chirayu MedEquip — Supabase setup
--  Supabase Dashboard → SQL Editor → New query → poora paste karo → Run
--  Safe to re-run (idempotent). Saari tables "meq_" prefix wali hain,
--  isliye kisi existing project ki tables ko touch nahi karegi.
--
--  Security model:
--   * Saari tables par RLS ON hai aur koi policy nahi → browser (anon key)
--     se direct table read/write NAHI ho sakta.
--   * Sab kaam SECURITY DEFINER functions (RPC) se hota hai jo login token
--     check karte hain. PIN bcrypt hash me save hote hain.
--
--  Default admins (LIVE karte hi PIN badal do — Users tab se):
--     admin1 / Chirayu@1     admin2 / Chirayu@2     admin3 / Chirayu@3
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------- tables
create table if not exists public.meq_users (
  id              uuid primary key default gen_random_uuid(),
  role            text not null check (role in ('admin','technician')),
  name            text not null,
  post            text not null default '',
  mobile          text not null default '',
  username        text not null unique,
  pin_hash        text not null,
  active          boolean not null default true,
  failed_attempts int not null default 0,
  locked_until    timestamptz,
  created_at      timestamptz not null default now()
);

create table if not exists public.meq_sessions (
  token      uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.meq_users(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '12 hours'
);
create index if not exists meq_sessions_user_idx on public.meq_sessions(user_id);

create sequence if not exists public.meq_equipment_seq start 100001;

create table if not exists public.meq_equipment (
  id               text primary key default nextval('public.meq_equipment_seq')::text,
  name             text not null,
  category         text not null default '',
  manufacturer     text not null default '',
  model            text not null default '',
  serial           text not null default '',
  department       text not null default '',
  location         text not null default '',
  status           text not null default 'Operational'
                   check (status in ('Operational','In Maintenance','Out of Service','Condemned')),
  contract_type    text not null default '',
  contract_from    date,
  contract_to      date,
  criticality      text not null default 'Critical',
  consumables      text not null default '',
  last_maint       date,
  next_maint       date,
  calibration_done date,
  next_calibration date,
  img_front        text not null default '',
  img_back         text not null default '',
  img_label        text not null default '',
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create sequence if not exists public.meq_complaint_seq start 1;

create table if not exists public.meq_complaints (
  id               uuid primary key default gen_random_uuid(),
  code             text not null unique
                   default 'CMP-' || lpad(nextval('public.meq_complaint_seq')::text, 5, '0'),
  equipment_id     text not null,
  equipment_name   text not null default '',
  department       text not null default '',
  location         text not null default '',
  reporter_name    text not null default '',
  reporter_mobile  text not null default '',
  message          text not null,
  status           text not null default 'Open' check (status in ('Open','In Progress','Closed')),
  assigned_to      uuid references public.meq_users(id) on delete set null,
  tat_hours        numeric not null default 24 check (tat_hours > 0),
  resolution_notes text not null default '',
  opened_at        timestamptz not null default now(),
  closed_at        timestamptz,
  closed_by        text,
  updated_at       timestamptz not null default now(),
  edit_log         jsonb not null default '[]'::jsonb
);
create index if not exists meq_complaints_eq_idx     on public.meq_complaints(equipment_id);
create index if not exists meq_complaints_mobile_idx on public.meq_complaints(reporter_mobile);
create index if not exists meq_complaints_assign_idx on public.meq_complaints(assigned_to);

create table if not exists public.meq_settings (
  key   text primary key,
  value jsonb not null
);

-- ------------------------------------------------------ lock the tables
alter table public.meq_users      enable row level security;
alter table public.meq_sessions   enable row level security;
alter table public.meq_equipment  enable row level security;
alter table public.meq_complaints enable row level security;
alter table public.meq_settings   enable row level security;

revoke all on public.meq_users, public.meq_sessions, public.meq_equipment,
              public.meq_complaints, public.meq_settings from anon, authenticated;
revoke all on sequence public.meq_equipment_seq, public.meq_complaint_seq from anon, authenticated;

-- ------------------------------------------------------------- defaults
insert into public.meq_settings(key, value) values
  ('tat_critical',          '24'),
  ('tat_noncritical',       '72'),
  ('remind_days_maint',     '7'),
  ('remind_days_cal',       '15'),
  ('remind_days_contract',  '30'),
  ('public_base_url',       '""'),
  ('popup_on_login',        'true'),
  ('poll_minutes',          '1'),
  ('qr_label_size',         '"medium"'),
  ('qr_per_row',            '3'),
  ('qr_show_location',      'true')
on conflict (key) do nothing;

insert into public.meq_users(role, name, post, username, pin_hash) values
  ('admin','Admin 1','Administrator','admin1', extensions.crypt('Chirayu@1', extensions.gen_salt('bf'))),
  ('admin','Admin 2','Administrator','admin2', extensions.crypt('Chirayu@2', extensions.gen_salt('bf'))),
  ('admin','Admin 3','Administrator','admin3', extensions.crypt('Chirayu@3', extensions.gen_salt('bf')))
on conflict (username) do nothing;

-- ============================================================ helpers
create or replace function public.meq__user_json(u public.meq_users)
returns jsonb language sql immutable set search_path = public as $$
  select jsonb_build_object('id',u.id,'role',u.role,'name',u.name,'post',u.post,
                            'mobile',u.mobile,'username',u.username,'active',u.active,
                            'created_at',u.created_at);
$$;

create or replace function public.meq__auth(p_token uuid, p_role text default null)
returns public.meq_users
language plpgsql security definer set search_path = public, extensions as $$
declare u public.meq_users;
begin
  select usr.* into u
    from public.meq_sessions s join public.meq_users usr on usr.id = s.user_id
   where s.token = p_token and s.expires_at > now() and usr.active;
  if not found then raise exception 'SESSION_EXPIRED'; end if;
  if p_role is not null and u.role <> p_role then raise exception 'FORBIDDEN'; end if;
  update public.meq_sessions set expires_at = now() + interval '12 hours' where token = p_token;
  return u;
end $$;

create or replace function public.meq__setting_num(p_key text, p_default numeric)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce((select (value #>> '{}')::numeric from public.meq_settings where key = p_key), p_default);
$$;

create or replace function public.meq__complaint_json(c public.meq_complaints)
returns jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(c) - 'edit_log'
         || jsonb_build_object(
              'assigned_name',   coalesce(u.name,''),
              'assigned_post',   coalesce(u.post,''),
              'assigned_mobile', coalesce(u.mobile,''),
              'edit_count',      jsonb_array_length(c.edit_log))
    from (select 1) x left join public.meq_users u on u.id = c.assigned_to;
$$;

create or replace function public.meq__admin_count(p_exclude uuid default null)
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from public.meq_users
   where role = 'admin' and active and (p_exclude is null or id <> p_exclude);
$$;

-- ======================================================== auth (public)
create or replace function public.meq_login(p_username text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u public.meq_users; t uuid; uname text := lower(trim(coalesce(p_username,'')));
begin
  delete from public.meq_sessions where expires_at < now();
  select * into u from public.meq_users
   where lower(username) = uname or (role = 'technician' and mobile = trim(p_username))
   order by (lower(username) = uname) desc limit 1;
  if not found or not u.active then
    return jsonb_build_object('error','INVALID_LOGIN');
  end if;
  if u.locked_until is not null and u.locked_until > now() then
    return jsonb_build_object('error','LOCKED');
  end if;
  if u.pin_hash <> extensions.crypt(coalesce(p_pin,''), u.pin_hash) then
    update public.meq_users
       set failed_attempts = failed_attempts + 1,
           locked_until = case when failed_attempts + 1 >= 5 then now() + interval '10 minutes' end
     where id = u.id;
    return jsonb_build_object('error','INVALID_LOGIN');
  end if;
  update public.meq_users set failed_attempts = 0, locked_until = null where id = u.id;
  insert into public.meq_sessions(user_id) values (u.id) returning token into t;
  return jsonb_build_object('token', t, 'user', public.meq__user_json(u));
end $$;

create or replace function public.meq_logout(p_token uuid)
returns void language sql security definer set search_path = public as $$
  delete from public.meq_sessions where token = p_token;
$$;

create or replace function public.meq_me(p_token uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u public.meq_users;
begin
  u := public.meq__auth(p_token);
  return public.meq__user_json(u);
exception when others then
  return null;
end $$;

create or replace function public.meq_change_pin(p_token uuid, p_old text, p_new text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare u public.meq_users;
begin
  u := public.meq__auth(p_token);
  if u.pin_hash <> extensions.crypt(coalesce(p_old,''), u.pin_hash) then raise exception 'WRONG_OLD_PIN'; end if;
  if length(coalesce(p_new,'')) < 4 then raise exception 'PIN_TOO_SHORT'; end if;
  update public.meq_users set pin_hash = extensions.crypt(p_new, extensions.gen_salt('bf')) where id = u.id;
end $$;

-- ===================================================== public functions
create or replace function public.meq_get_equipment(p_id text)
returns jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(e) from public.meq_equipment e where e.id = trim(p_id);
$$;

create or replace function public.meq_equipment_history(p_id text)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x.opened_at desc), '[]'::jsonb) from (
    select code, opened_at, message, status, closed_at, resolution_notes, tat_hours
      from public.meq_complaints where equipment_id = trim(p_id)
     order by opened_at desc limit 50) x;
$$;

create or replace function public.meq_submit_complaint(p_equipment_id text, p_name text,
                                                       p_mobile text, p_message text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare e public.meq_equipment; c public.meq_complaints; v_tat numeric;
        v_msg text := trim(coalesce(p_message,'')); v_mob text := trim(coalesce(p_mobile,''));
begin
  if trim(coalesce(p_equipment_id,'')) !~ '^\d{6}$' then raise exception 'INVALID_EQUIPMENT_ID'; end if;
  if v_mob !~ '^\d{10}$' then raise exception 'INVALID_MOBILE'; end if;
  if length(v_msg) < 5 or length(v_msg) > 2000 then raise exception 'INVALID_MESSAGE'; end if;
  select * into e from public.meq_equipment where id = trim(p_equipment_id);
  if not found then raise exception 'EQUIPMENT_NOT_FOUND'; end if;
  -- simple spam guard: same mobile, max 5 complaints in 10 minutes
  if (select count(*) from public.meq_complaints
       where reporter_mobile = v_mob and opened_at > now() - interval '10 minutes') >= 5 then
    raise exception 'TOO_MANY_REQUESTS';
  end if;
  v_tat := case when e.criticality = 'Critical'
                then public.meq__setting_num('tat_critical', 24)
                else public.meq__setting_num('tat_noncritical', 72) end;
  insert into public.meq_complaints(equipment_id, equipment_name, department, location,
                                    reporter_name, reporter_mobile, message, tat_hours)
  values (e.id, e.name, e.department, e.location, left(trim(coalesce(p_name,'')),100), v_mob, v_msg, v_tat)
  returning * into c;
  return jsonb_build_object('code', c.code, 'tat_hours', c.tat_hours, 'equipment_name', c.equipment_name,
                            'opened_at', c.opened_at);
end $$;

create or replace function public.meq_track_complaints(p_mobile text)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x.opened_at desc), '[]'::jsonb) from (
    select code, equipment_id, equipment_name, department, opened_at, message, status,
           closed_at, resolution_notes, tat_hours
      from public.meq_complaints
     where reporter_mobile = trim(p_mobile) and trim(p_mobile) ~ '^\d{10}$'
     order by opened_at desc limit 100) x;
$$;

-- ======================================================= admin functions
create or replace function public.meq_admin_data(p_token uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public.meq__auth(p_token, 'admin');
  return jsonb_build_object(
    'equipment', coalesce((select jsonb_agg(to_jsonb(e) - 'img_front' - 'img_back' - 'img_label'
                                            order by e.created_at desc)
                             from public.meq_equipment e), '[]'::jsonb),
    'complaints', coalesce((select jsonb_agg(public.meq__complaint_json(c) order by c.opened_at desc)
                              from (select * from public.meq_complaints order by opened_at desc limit 5000) c),
                           '[]'::jsonb),
    'users', coalesce((select jsonb_agg(public.meq__user_json(u) order by u.role, u.name)
                         from public.meq_users u), '[]'::jsonb),
    'settings', coalesce((select jsonb_object_agg(key, value) from public.meq_settings), '{}'::jsonb)
  );
end $$;

create or replace function public.meq_save_equipment(p_token uuid, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u public.meq_users; e public.meq_equipment; v_id text := nullif(trim(coalesce(p_data->>'id','')),'');
begin
  u := public.meq__auth(p_token, 'admin');
  if trim(coalesce(p_data->>'name','')) = '' then raise exception 'NAME_REQUIRED'; end if;
  if v_id is not null and exists (select 1 from public.meq_equipment where id = v_id) then
    update public.meq_equipment set
      name = trim(p_data->>'name'),
      category = coalesce(p_data->>'category',''), manufacturer = coalesce(p_data->>'manufacturer',''),
      model = coalesce(p_data->>'model',''), serial = coalesce(p_data->>'serial',''),
      department = coalesce(p_data->>'department',''), location = coalesce(p_data->>'location',''),
      status = coalesce(nullif(p_data->>'status',''),'Operational'),
      contract_type = coalesce(p_data->>'contract_type',''),
      contract_from = nullif(p_data->>'contract_from','')::date,
      contract_to = nullif(p_data->>'contract_to','')::date,
      criticality = coalesce(nullif(p_data->>'criticality',''),'Critical'),
      consumables = coalesce(p_data->>'consumables',''),
      last_maint = nullif(p_data->>'last_maint','')::date,
      next_maint = nullif(p_data->>'next_maint','')::date,
      calibration_done = nullif(p_data->>'calibration_done','')::date,
      next_calibration = nullif(p_data->>'next_calibration','')::date,
      img_front = coalesce(p_data->>'img_front',''), img_back = coalesce(p_data->>'img_back',''),
      img_label = coalesce(p_data->>'img_label',''),
      updated_at = now()
    where id = v_id returning * into e;
  else
    insert into public.meq_equipment(name, category, manufacturer, model, serial, department, location,
      status, contract_type, contract_from, contract_to, criticality, consumables, last_maint, next_maint,
      calibration_done, next_calibration, img_front, img_back, img_label)
    values (trim(p_data->>'name'), coalesce(p_data->>'category',''), coalesce(p_data->>'manufacturer',''),
      coalesce(p_data->>'model',''), coalesce(p_data->>'serial',''), coalesce(p_data->>'department',''),
      coalesce(p_data->>'location',''), coalesce(nullif(p_data->>'status',''),'Operational'),
      coalesce(p_data->>'contract_type',''), nullif(p_data->>'contract_from','')::date,
      nullif(p_data->>'contract_to','')::date, coalesce(nullif(p_data->>'criticality',''),'Critical'),
      coalesce(p_data->>'consumables',''), nullif(p_data->>'last_maint','')::date,
      nullif(p_data->>'next_maint','')::date, nullif(p_data->>'calibration_done','')::date,
      nullif(p_data->>'next_calibration','')::date, coalesce(p_data->>'img_front',''),
      coalesce(p_data->>'img_back',''), coalesce(p_data->>'img_label',''))
    returning * into e;
  end if;
  return to_jsonb(e) - 'img_front' - 'img_back' - 'img_label';
end $$;

create or replace function public.meq_delete_equipment(p_token uuid, p_ids text[])
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform public.meq__auth(p_token, 'admin');
  delete from public.meq_equipment where id = any(p_ids);
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.meq_save_complaint(p_token uuid, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u public.meq_users; c public.meq_complaints; v_status text; v_assign uuid;
begin
  u := public.meq__auth(p_token, 'admin');
  select * into c from public.meq_complaints where id = (p_data->>'id')::uuid;
  if not found then raise exception 'NOT_FOUND'; end if;
  v_status := coalesce(nullif(p_data->>'status',''), c.status);
  v_assign := nullif(p_data->>'assigned_to','')::uuid;
  if v_status = 'Closed' and trim(coalesce(p_data->>'resolution_notes', c.resolution_notes)) = '' then
    raise exception 'NOTES_REQUIRED';
  end if;
  update public.meq_complaints set
    message          = coalesce(nullif(trim(p_data->>'message'),''), message),
    reporter_name    = coalesce(p_data->>'reporter_name', reporter_name),
    reporter_mobile  = coalesce(p_data->>'reporter_mobile', reporter_mobile),
    tat_hours        = coalesce(nullif(p_data->>'tat_hours','')::numeric, tat_hours),
    assigned_to      = case when p_data ? 'assigned_to' then v_assign else assigned_to end,
    resolution_notes = coalesce(p_data->>'resolution_notes', resolution_notes),
    status           = v_status,
    closed_at        = case when v_status = 'Closed' then coalesce(closed_at, now()) else null end,
    closed_by        = case when v_status = 'Closed' then coalesce(closed_by, u.name) else null end,
    updated_at       = now(),
    edit_log         = edit_log || jsonb_build_array(jsonb_build_object('at', now(), 'by', u.name))
  where id = c.id returning * into c;
  return public.meq__complaint_json(c);
end $$;

create or replace function public.meq_close_complaint(p_token uuid, p_id uuid, p_notes text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u public.meq_users; c public.meq_complaints;
begin
  u := public.meq__auth(p_token, 'admin');
  if trim(coalesce(p_notes,'')) = '' then raise exception 'NOTES_REQUIRED'; end if;
  update public.meq_complaints
     set status = 'Closed', resolution_notes = trim(p_notes), closed_at = now(), closed_by = u.name,
         updated_at = now()
   where id = p_id and status <> 'Closed' returning * into c;
  if not found then raise exception 'NOT_FOUND'; end if;
  return public.meq__complaint_json(c);
end $$;

create or replace function public.meq_delete_complaint(p_token uuid, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.meq__auth(p_token, 'admin');
  delete from public.meq_complaints where id = p_id;
end $$;

create or replace function public.meq_save_user(p_token uuid, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare me public.meq_users; u public.meq_users; v_id uuid := nullif(p_data->>'id','')::uuid;
        v_role text := coalesce(nullif(p_data->>'role',''),'technician');
        v_mobile text := trim(coalesce(p_data->>'mobile',''));
        v_username text; v_pin text := coalesce(p_data->>'pin','');
        v_active boolean := coalesce((p_data->>'active')::boolean, true);
begin
  me := public.meq__auth(p_token, 'admin');
  if v_role not in ('admin','technician') then raise exception 'INVALID_ROLE'; end if;
  if trim(coalesce(p_data->>'name','')) = '' then raise exception 'NAME_REQUIRED'; end if;
  if v_role = 'technician' then
    if v_mobile !~ '^\d{10}$' then raise exception 'INVALID_MOBILE'; end if;
    v_username := v_mobile;                      -- technician login ID = mobile number
  else
    v_username := lower(trim(coalesce(p_data->>'username','')));
    if v_username = '' then raise exception 'USERNAME_REQUIRED'; end if;
  end if;
  if exists (select 1 from public.meq_users where lower(username) = lower(v_username)
             and (v_id is null or id <> v_id)) then
    raise exception 'USERNAME_TAKEN';
  end if;
  if v_pin <> '' and length(v_pin) < 4 then raise exception 'PIN_TOO_SHORT'; end if;

  if v_id is null then
    if v_pin = '' then raise exception 'PIN_REQUIRED'; end if;
    insert into public.meq_users(role, name, post, mobile, username, pin_hash, active)
    values (v_role, trim(p_data->>'name'), coalesce(p_data->>'post',''), v_mobile, v_username,
            extensions.crypt(v_pin, extensions.gen_salt('bf')), v_active)
    returning * into u;
  else
    select * into u from public.meq_users where id = v_id;
    if not found then raise exception 'NOT_FOUND'; end if;
    if u.role = 'admin' and u.active and (v_role <> 'admin' or not v_active)
       and public.meq__admin_count(u.id) < 3 then
      raise exception 'MIN_3_ADMINS';
    end if;
    update public.meq_users set
      role = v_role, name = trim(p_data->>'name'), post = coalesce(p_data->>'post',''),
      mobile = v_mobile, username = v_username, active = v_active,
      pin_hash = case when v_pin <> '' then extensions.crypt(v_pin, extensions.gen_salt('bf')) else pin_hash end,
      failed_attempts = 0, locked_until = null
    where id = v_id returning * into u;
    if not v_active then delete from public.meq_sessions where user_id = u.id; end if;
  end if;
  return public.meq__user_json(u);
end $$;

create or replace function public.meq_delete_user(p_token uuid, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me public.meq_users; u public.meq_users;
begin
  me := public.meq__auth(p_token, 'admin');
  if me.id = p_id then raise exception 'CANNOT_DELETE_SELF'; end if;
  select * into u from public.meq_users where id = p_id;
  if not found then return; end if;
  if u.role = 'admin' and u.active and public.meq__admin_count(u.id) < 3 then
    raise exception 'MIN_3_ADMINS';
  end if;
  delete from public.meq_users where id = p_id;
end $$;

create or replace function public.meq_save_settings(p_token uuid, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare k text; v jsonb;
begin
  perform public.meq__auth(p_token, 'admin');
  for k, v in select * from jsonb_each(p_data) loop
    if k in ('tat_critical','tat_noncritical','remind_days_maint','remind_days_cal',
             'remind_days_contract','public_base_url','popup_on_login','poll_minutes',
             'qr_label_size','qr_per_row','qr_show_location') then
      insert into public.meq_settings(key, value) values (k, v)
      on conflict (key) do update set value = excluded.value;
    end if;
  end loop;
  return (select jsonb_object_agg(key, value) from public.meq_settings);
end $$;

-- ================================================== technician functions
create or replace function public.meq_tech_data(p_token uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u public.meq_users;
begin
  u := public.meq__auth(p_token, 'technician');
  return jsonb_build_object('complaints',
    coalesce((select jsonb_agg(public.meq__complaint_json(c) order by c.opened_at desc)
                from public.meq_complaints c where c.assigned_to = u.id), '[]'::jsonb));
end $$;

create or replace function public.meq_tech_save_notes(p_token uuid, p_id uuid, p_notes text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u public.meq_users; c public.meq_complaints;
begin
  u := public.meq__auth(p_token, 'technician');
  update public.meq_complaints
     set resolution_notes = trim(coalesce(p_notes,'')),
         status = case when status = 'Open' then 'In Progress' else status end,
         updated_at = now()
   where id = p_id and assigned_to = u.id and status <> 'Closed'
  returning * into c;
  if not found then raise exception 'NOT_FOUND'; end if;
  return public.meq__complaint_json(c);
end $$;

-- ============================================================ grants
-- internal helpers: koi bhi bahar se call na kar sake
revoke execute on function public.meq__user_json(public.meq_users)            from public, anon, authenticated;
revoke execute on function public.meq__auth(uuid, text)                       from public, anon, authenticated;
revoke execute on function public.meq__setting_num(text, numeric)             from public, anon, authenticated;
revoke execute on function public.meq__complaint_json(public.meq_complaints)  from public, anon, authenticated;
revoke execute on function public.meq__admin_count(uuid)                      from public, anon, authenticated;

-- public API
grant execute on function
  public.meq_login(text, text), public.meq_logout(uuid), public.meq_me(uuid),
  public.meq_change_pin(uuid, text, text),
  public.meq_get_equipment(text), public.meq_equipment_history(text),
  public.meq_submit_complaint(text, text, text, text), public.meq_track_complaints(text),
  public.meq_admin_data(uuid), public.meq_save_equipment(uuid, jsonb),
  public.meq_delete_equipment(uuid, text[]), public.meq_save_complaint(uuid, jsonb),
  public.meq_close_complaint(uuid, uuid, text), public.meq_delete_complaint(uuid, uuid),
  public.meq_save_user(uuid, jsonb), public.meq_delete_user(uuid, uuid),
  public.meq_save_settings(uuid, jsonb),
  public.meq_tech_data(uuid), public.meq_tech_save_notes(uuid, uuid, text)
to anon, authenticated;

notify pgrst, 'reload schema';
