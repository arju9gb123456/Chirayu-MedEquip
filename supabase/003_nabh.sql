-- =====================================================================
--  Chirayu MedEquip / BioTrack — v3: NABH & maintenance pack
--   * PM checklists (per category) + signed PM records
--   * Calibration records with mandatory certificate upload
--   * Condemnation workflow (proposal → committee → condemned register)
--   * Audit log (who changed what, when) — automatic, via triggers
--   * Complaints: photo, spare parts + cost, 1–5 star rating, escalation
--  Run AFTER setup.sql + 002_documents.sql. Safe to re-run.
-- =====================================================================

-- ------------------------------------------------------------ complaints
alter table public.meq_complaints add column if not exists photo        text    not null default '';
alter table public.meq_complaints add column if not exists parts        jsonb   not null default '[]'::jsonb;
alter table public.meq_complaints add column if not exists parts_cost   numeric not null default 0;
alter table public.meq_complaints add column if not exists rating       int     check (rating between 1 and 5);
alter table public.meq_complaints add column if not exists feedback     text    not null default '';
alter table public.meq_complaints add column if not exists rated_at     timestamptz;
alter table public.meq_complaints add column if not exists escalated_at timestamptz;
alter table public.meq_complaints add column if not exists escalated_to text    not null default '';

-- photo is heavy → never inside the complaint list, fetched on demand
create or replace function public.meq__complaint_json(c public.meq_complaints)
returns jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(c) - 'edit_log' - 'photo'
         || jsonb_build_object(
              'has_photo',       c.photo <> '',
              'assigned_name',   coalesce(u.name,''),
              'assigned_post',   coalesce(u.post,''),
              'assigned_mobile', coalesce(u.mobile,''),
              'edit_count',      jsonb_array_length(c.edit_log))
    from (select 1) x left join public.meq_users u on u.id = c.assigned_to;
$$;

-- ------------------------------------------------------------ new tables
create table if not exists public.meq_pm_templates (
  category   text primary key,
  items      jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by text not null default ''
);

create table if not exists public.meq_pm_records (
  id           uuid primary key default gen_random_uuid(),
  equipment_id text not null references public.meq_equipment(id) on delete cascade,
  pm_date      date not null,
  next_due     date,
  results      jsonb not null default '[]'::jsonb,
  overall      text not null check (overall in ('Pass','Pass with remarks','Fail')),
  remarks      text not null default '',
  done_by      text not null,
  done_by_role text not null default '',
  done_by_id   uuid,
  signature    text not null default '',
  created_at   timestamptz not null default now()
);
create index if not exists meq_pm_records_eq_idx on public.meq_pm_records(equipment_id, pm_date desc);

create table if not exists public.meq_calibrations (
  id             uuid primary key default gen_random_uuid(),
  equipment_id   text not null references public.meq_equipment(id) on delete cascade,
  cal_date       date not null,
  next_due       date,
  agency         text not null default '',
  certificate_no text not null default '',
  result         text not null default 'Pass' check (result in ('Pass','Fail')),
  doc_id         uuid references public.meq_documents(id) on delete set null,
  remarks        text not null default '',
  created_by     text not null default '',
  created_at     timestamptz not null default now()
);
create index if not exists meq_calibrations_eq_idx on public.meq_calibrations(equipment_id, cal_date desc);

create table if not exists public.meq_condemnations (
  id              uuid primary key default gen_random_uuid(),
  equipment_id    text not null references public.meq_equipment(id) on delete cascade,
  reason          text not null,
  condition       text not null default '',
  purchase_year   text not null default '',
  book_value      numeric,
  repair_estimate numeric,
  committee       jsonb not null default '[]'::jsonb,
  status          text not null default 'Proposed' check (status in ('Proposed','Approved','Rejected')),
  disposal_method text not null default '',
  remarks         text not null default '',
  proposed_by     text not null default '',
  proposed_at     timestamptz not null default now(),
  decided_by      text not null default '',
  decided_at      timestamptz,
  prev_status     text not null default ''
);
create index if not exists meq_condemnations_eq_idx on public.meq_condemnations(equipment_id);

create table if not exists public.meq_audit (
  id        bigserial primary key,
  at        timestamptz not null default now(),
  user_name text not null default '',
  user_role text not null default '',
  action    text not null,
  entity    text not null,
  entity_id text not null default '',
  summary   text not null default '',
  changes   jsonb not null default '{}'::jsonb
);
create index if not exists meq_audit_at_idx on public.meq_audit(at desc);

alter table public.meq_pm_templates  enable row level security;
alter table public.meq_pm_records    enable row level security;
alter table public.meq_calibrations  enable row level security;
alter table public.meq_condemnations enable row level security;
alter table public.meq_audit         enable row level security;
revoke all on public.meq_pm_templates, public.meq_pm_records, public.meq_calibrations,
              public.meq_condemnations, public.meq_audit from anon, authenticated;
revoke all on sequence public.meq_audit_id_seq from anon, authenticated;

-- default PM checklists (only inserted once — admins edit them later)
insert into public.meq_pm_templates(category, items) values
 ('Default', '["Visual inspection: body, casing, knobs and display free from damage","Power cord, plug and mains connection checked","External cleaning and dust / filter cleaning done","Alarms and indicators working","Electrical safety test (earth resistance / leakage current) done","Functional / performance test as per manufacturer done","Accessories, probes and cables checked","Battery / backup checked (if applicable)"]'),
 ('Imaging', '["Visual inspection of gantry / table / console","Power supply, UPS and earthing checked","Cooling system / chiller and filters cleaned and checked","Table and gantry movements and emergency stop checked","Image quality checked with phantom","Radiation safety: shielding, interlocks and warning lights checked","Console, workstation and printer / PACS link checked","Electrical safety test done"]'),
 ('Critical Care', '["Visual inspection: casing, knobs, display, wheels and brakes","Power cord, plug and battery backup checked","Gas supply hoses, connectors and fittings checked for leaks","Filters and flow sensors cleaned / replaced","Delivered parameters verified with analyser / simulator","All alarms tested (power fail, disconnect, high / low limits)","Patient circuit and accessories checked","Electrical safety test done"]'),
 ('Life Support', '["Visual inspection: casing, paddles / cables and display","Battery condition and runtime tested","Energy / output delivery verified with analyser","Charge time within manufacturer limit","Self-test and alarms working","Pads, electrodes and consumables in date","Printer / recorder checked","Electrical safety test done"]'),
 ('Monitoring', '["Visual inspection: casing, mounting and display","Power cord and battery backup checked","ECG accuracy checked with simulator","SpO2 accuracy checked with simulator","NIBP accuracy and leak test done","Temperature / other parameters checked","Alarm limits and audio alarms tested","Cables, probes and cuffs checked","Electrical safety test done"]'),
 ('Laboratory', '["Visual inspection and cleaning of analyser","Power supply and UPS checked","Temperature / incubation checked","Aspiration, pipetting and tubing checked","Calibration / QC with control samples done","Printer and LIS interface checked","Waste and reagent lines checked"]'),
 ('Surgical', '["Visual inspection: casing, cables, handpieces and footswitch","Power cord and earthing checked","Output power verified with analyser","Alarms and safety cut-off tested","Light intensity / suction / pressure checked (as applicable)","Accessories cleaned and checked","Electrical safety test done"]'),
 ('Therapeutic', '["Visual inspection of unit and accessories","Power cord and earthing checked","Output / dose accuracy verified","Timer and controls working","Safety cut-off and alarms tested","Electrodes / applicators checked","Electrical safety test done"]'),
 ('Diagnostic', '["Visual inspection of unit and accessories","Power cord and earthing checked","Measurement accuracy verified","Probes / transducers checked","Printer / software / data transfer checked","Electrical safety test done"]'),
 ('Sterilization', '["Visual inspection of chamber, door and gasket","Door seal and safety lock checked","Chamber temperature and pressure verified","Safety valve checked","Bowie-Dick / chemical indicator test done","Water supply, drain and filters checked","Printer / cycle record checked"]')
on conflict (category) do nothing;

insert into public.meq_settings(key, value) values
  ('pm_interval_days',       '90'),
  ('cal_interval_days',      '365'),
  ('escalation_name',        '""'),
  ('escalation_mobile',      '""'),
  ('escalation_after_hours', '24')
on conflict (key) do nothing;

-- ------------------------------------------------------------ audit log
-- meq__auth remembers who is calling (transaction-local) so triggers can log it
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
  perform set_config('meq.user', u.name, true);
  perform set_config('meq.role', u.role, true);
  return u;
end $$;

create or replace function public.meq__audit_trg()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  skip text[] := array['img_front','img_back','img_label','data','photo','signature','pin_hash',
                       'edit_log','updated_at','failed_attempts','locked_until'];
  o jsonb; n jsonb; ch jsonb := '{}'::jsonb; k text; v_id text; v_sum text; v_ent text;
begin
  if tg_op <> 'INSERT' then o := to_jsonb(old) - skip; end if;
  if tg_op <> 'DELETE' then n := to_jsonb(new) - skip; end if;
  if tg_op = 'UPDATE' then
    for k in select jsonb_object_keys(n) loop
      if (n -> k) is distinct from (o -> k) then
        ch := ch || jsonb_build_object(k, jsonb_build_array(o -> k, n -> k));
      end if;
    end loop;
    if ch = '{}'::jsonb then return null; end if;
  elsif tg_op = 'INSERT' then
    ch := n;
  else
    ch := o;
  end if;
  v_ent := replace(tg_table_name, 'meq_', '');
  v_id  := coalesce(n->>'id', o->>'id', n->>'key', o->>'key', n->>'category', o->>'category', '');
  v_sum := coalesce(n->>'code', o->>'code', n->>'name', o->>'name', n->>'file_name', o->>'file_name',
                    n->>'equipment_id', o->>'equipment_id', v_id);
  insert into public.meq_audit(user_name, user_role, action, entity, entity_id, summary, changes)
  values (coalesce(nullif(current_setting('meq.user', true), ''), 'Public'),
          coalesce(nullif(current_setting('meq.role', true), ''), 'public'),
          lower(tg_op), v_ent, v_id, left(v_sum, 200), ch);
  return null;
end $$;

do $$
declare t text;
begin
  foreach t in array array['meq_equipment','meq_complaints','meq_users','meq_settings','meq_documents',
                           'meq_pm_templates','meq_pm_records','meq_calibrations','meq_condemnations'] loop
    execute format('drop trigger if exists meq_audit_trg on public.%I', t);
    execute format('create trigger meq_audit_trg after insert or update or delete on public.%I
                    for each row execute function public.meq__audit_trg()', t);
  end loop;
end $$;

create or replace function public.meq_audit_list(p_token uuid, p_before bigint default null,
                                                 p_limit int default 200)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public.meq__auth(p_token, 'admin');
  return coalesce((select jsonb_agg(to_jsonb(a) order by a.id desc) from (
      select * from public.meq_audit
       where p_before is null or id < p_before
       order by id desc limit least(greatest(coalesce(p_limit, 200), 1), 1000)) a), '[]'::jsonb);
end $$;

-- ------------------------------------------------------------ helpers
create or replace function public.meq__clean_parts(p jsonb)
returns jsonb language sql immutable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'name', left(trim(x->>'name'), 120),
           'qty',  greatest(coalesce(nullif(x->>'qty','')::numeric, 1), 0),
           'cost', greatest(coalesce(nullif(x->>'cost','')::numeric, 0), 0))), '[]'::jsonb)
    from jsonb_array_elements(case when jsonb_typeof(p) = 'array' then p else '[]'::jsonb end) x
   where trim(coalesce(x->>'name','')) <> '';
$$;

create or replace function public.meq__parts_cost(p jsonb)
returns numeric language sql immutable set search_path = public as $$
  select coalesce(sum((x->>'qty')::numeric * (x->>'cost')::numeric), 0)
    from jsonb_array_elements(p) x;
$$;

create or replace function public.meq__check_image(p text, p_max int)
returns void language plpgsql immutable set search_path = public as $$
begin
  if coalesce(p,'') = '' then return; end if;
  if p !~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$' then raise exception 'INVALID_FILE'; end if;
  if length(p) > p_max then raise exception 'FILE_TOO_LARGE'; end if;
end $$;

-- ------------------------------------------------------------ complaints API v3
drop function if exists public.meq_submit_complaint(text, text, text, text);
create or replace function public.meq_submit_complaint(p_equipment_id text, p_name text,
                                                       p_mobile text, p_message text, p_photo text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare e public.meq_equipment; c public.meq_complaints; v_tat numeric;
        v_msg text := trim(coalesce(p_message,'')); v_mob text := trim(coalesce(p_mobile,''));
begin
  if trim(coalesce(p_equipment_id,'')) !~ '^\d{6}$' then raise exception 'INVALID_EQUIPMENT_ID'; end if;
  if v_mob !~ '^\d{10}$' then raise exception 'INVALID_MOBILE'; end if;
  if length(v_msg) < 5 or length(v_msg) > 2000 then raise exception 'INVALID_MESSAGE'; end if;
  perform public.meq__check_image(p_photo, 1500000);
  select * into e from public.meq_equipment where id = trim(p_equipment_id);
  if not found then raise exception 'EQUIPMENT_NOT_FOUND'; end if;
  if (select count(*) from public.meq_complaints
       where reporter_mobile = v_mob and opened_at > now() - interval '10 minutes') >= 5 then
    raise exception 'TOO_MANY_REQUESTS';
  end if;
  v_tat := case when e.criticality = 'Critical'
                then public.meq__setting_num('tat_critical', 24)
                else public.meq__setting_num('tat_noncritical', 72) end;
  insert into public.meq_complaints(equipment_id, equipment_name, department, location,
                                    reporter_name, reporter_mobile, message, tat_hours, photo)
  values (e.id, e.name, e.department, e.location, left(trim(coalesce(p_name,'')),100), v_mob, v_msg, v_tat,
          coalesce(p_photo,''))
  returning * into c;
  return jsonb_build_object('code', c.code, 'tat_hours', c.tat_hours, 'equipment_name', c.equipment_name,
                            'opened_at', c.opened_at);
end $$;

create or replace function public.meq_track_complaints(p_mobile text)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x.opened_at desc), '[]'::jsonb) from (
    select code, equipment_id, equipment_name, department, opened_at, message, status,
           closed_at, resolution_notes, tat_hours, rating, feedback
      from public.meq_complaints
     where reporter_mobile = trim(p_mobile) and trim(p_mobile) ~ '^\d{10}$'
     order by opened_at desc limit 100) x;
$$;

create or replace function public.meq_rate_complaint(p_code text, p_mobile text, p_rating int, p_feedback text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.meq_complaints;
begin
  if p_rating is null or p_rating < 1 or p_rating > 5 then raise exception 'INVALID_RATING'; end if;
  select * into c from public.meq_complaints
   where code = upper(trim(p_code)) and reporter_mobile = trim(p_mobile);
  if not found then raise exception 'NOT_FOUND'; end if;
  if c.status <> 'Closed' then raise exception 'NOT_CLOSED'; end if;
  if c.rating is not null then raise exception 'ALREADY_RATED'; end if;
  update public.meq_complaints set rating = p_rating, feedback = left(trim(coalesce(p_feedback,'')), 500),
         rated_at = now() where id = c.id;
  return jsonb_build_object('code', c.code, 'rating', p_rating);
end $$;

create or replace function public.meq_complaint_photo(p_token uuid, p_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare u public.meq_users; v text;
begin
  u := public.meq__auth(p_token);
  select photo into v from public.meq_complaints
   where id = p_id and (u.role = 'admin' or assigned_to = u.id);
  if not found then raise exception 'NOT_FOUND'; end if;
  return v;
end $$;

drop function if exists public.meq_close_complaint(uuid, uuid, text);
create or replace function public.meq_close_complaint(p_token uuid, p_id uuid, p_notes text,
                                                      p_parts jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u public.meq_users; c public.meq_complaints; v_parts jsonb;
begin
  u := public.meq__auth(p_token, 'admin');
  if trim(coalesce(p_notes,'')) = '' then raise exception 'NOTES_REQUIRED'; end if;
  select * into c from public.meq_complaints where id = p_id and status <> 'Closed';
  if not found then raise exception 'NOT_FOUND'; end if;
  v_parts := case when p_parts is null then c.parts else public.meq__clean_parts(p_parts) end;
  update public.meq_complaints
     set status = 'Closed', resolution_notes = trim(p_notes), closed_at = now(), closed_by = u.name,
         parts = v_parts, parts_cost = public.meq__parts_cost(v_parts), updated_at = now()
   where id = p_id returning * into c;
  return public.meq__complaint_json(c);
end $$;

create or replace function public.meq_save_complaint(p_token uuid, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u public.meq_users; c public.meq_complaints; v_status text; v_assign uuid; v_parts jsonb;
begin
  u := public.meq__auth(p_token, 'admin');
  select * into c from public.meq_complaints where id = (p_data->>'id')::uuid;
  if not found then raise exception 'NOT_FOUND'; end if;
  v_status := coalesce(nullif(p_data->>'status',''), c.status);
  v_assign := nullif(p_data->>'assigned_to','')::uuid;
  v_parts  := case when p_data ? 'parts' then public.meq__clean_parts(p_data->'parts') else c.parts end;
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
    parts            = v_parts,
    parts_cost       = public.meq__parts_cost(v_parts),
    status           = v_status,
    closed_at        = case when v_status = 'Closed' then coalesce(closed_at, now()) else null end,
    closed_by        = case when v_status = 'Closed' then coalesce(closed_by, u.name) else null end,
    updated_at       = now(),
    edit_log         = edit_log || jsonb_build_array(jsonb_build_object('at', now(), 'by', u.name))
  where id = c.id returning * into c;
  return public.meq__complaint_json(c);
end $$;

create or replace function public.meq_complaint_escalate(p_token uuid, p_id uuid, p_to text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u public.meq_users; c public.meq_complaints;
begin
  u := public.meq__auth(p_token, 'admin');
  update public.meq_complaints set escalated_at = now(), escalated_to = left(trim(coalesce(p_to,'')), 120),
         updated_at = now()
   where id = p_id and status <> 'Closed' returning * into c;
  if not found then raise exception 'NOT_FOUND'; end if;
  return public.meq__complaint_json(c);
end $$;

drop function if exists public.meq_tech_save_notes(uuid, uuid, text);
create or replace function public.meq_tech_save_notes(p_token uuid, p_id uuid, p_notes text,
                                                      p_parts jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u public.meq_users; c public.meq_complaints; v_parts jsonb;
begin
  u := public.meq__auth(p_token, 'technician');
  select * into c from public.meq_complaints where id = p_id and assigned_to = u.id and status <> 'Closed';
  if not found then raise exception 'NOT_FOUND'; end if;
  v_parts := case when p_parts is null then c.parts else public.meq__clean_parts(p_parts) end;
  update public.meq_complaints
     set resolution_notes = trim(coalesce(p_notes,'')),
         parts = v_parts, parts_cost = public.meq__parts_cost(v_parts),
         status = case when status = 'Open' then 'In Progress' else status end,
         updated_at = now()
   where id = p_id returning * into c;
  return public.meq__complaint_json(c);
end $$;

-- settings: whitelist now includes the new keys
create or replace function public.meq_save_settings(p_token uuid, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare k text; v jsonb;
begin
  perform public.meq__auth(p_token, 'admin');
  for k, v in select * from jsonb_each(p_data) loop
    if k in ('tat_critical','tat_noncritical','remind_days_maint','remind_days_cal',
             'remind_days_contract','public_base_url','popup_on_login','poll_minutes',
             'qr_label_size','qr_per_row','qr_show_location',
             'pm_interval_days','cal_interval_days','escalation_name','escalation_mobile',
             'escalation_after_hours') then
      insert into public.meq_settings(key, value) values (k, v)
      on conflict (key) do update set value = excluded.value;
    end if;
  end loop;
  return (select jsonb_object_agg(key, value) from public.meq_settings);
end $$;

-- ------------------------------------------------------------ PM
create or replace function public.meq_pm_templates(p_token uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public.meq__auth(p_token);
  return coalesce((select jsonb_object_agg(category, items) from public.meq_pm_templates), '{}'::jsonb);
end $$;

create or replace function public.meq_pm_template_save(p_token uuid, p_category text, p_items jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u public.meq_users; v_items jsonb;
begin
  u := public.meq__auth(p_token, 'admin');
  if trim(coalesce(p_category,'')) = '' then raise exception 'NAME_REQUIRED'; end if;
  select coalesce(jsonb_agg(left(trim(x), 300)), '[]'::jsonb) into v_items
    from jsonb_array_elements_text(case when jsonb_typeof(p_items) = 'array' then p_items else '[]'::jsonb end) x
   where trim(x) <> '';
  if jsonb_array_length(v_items) = 0 then raise exception 'CHECKLIST_EMPTY'; end if;
  if jsonb_array_length(v_items) > 60 then raise exception 'CHECKLIST_TOO_LONG'; end if;
  insert into public.meq_pm_templates(category, items, updated_at, updated_by)
  values (trim(p_category), v_items, now(), u.name)
  on conflict (category) do update set items = excluded.items, updated_at = now(), updated_by = u.name;
  return v_items;
end $$;

create or replace function public.meq_pm_save(p_token uuid, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u public.meq_users; e public.meq_equipment; r public.meq_pm_records; v_date date; v_next date;
begin
  u := public.meq__auth(p_token);
  select * into e from public.meq_equipment where id = trim(coalesce(p_data->>'equipment_id',''));
  if not found then raise exception 'EQUIPMENT_NOT_FOUND'; end if;
  if jsonb_typeof(p_data->'results') <> 'array' or jsonb_array_length(p_data->'results') = 0 then
    raise exception 'CHECKLIST_EMPTY'; end if;
  if exists (select 1 from jsonb_array_elements(p_data->'results') x
              where coalesce(x->>'result','') not in ('ok','fail','na')) then
    raise exception 'CHECKLIST_INCOMPLETE'; end if;
  if coalesce(p_data->>'signature','') = '' then raise exception 'SIGNATURE_REQUIRED'; end if;
  perform public.meq__check_image(p_data->>'signature', 300000);
  v_date := coalesce(nullif(p_data->>'pm_date','')::date, current_date);
  if v_date > current_date then raise exception 'FUTURE_DATE'; end if;
  v_next := coalesce(nullif(p_data->>'next_due','')::date,
                     v_date + (public.meq__setting_num('pm_interval_days', 90))::int);
  insert into public.meq_pm_records(equipment_id, pm_date, next_due, results, overall, remarks,
                                    done_by, done_by_role, done_by_id, signature)
  values (e.id, v_date, v_next,
          (select jsonb_agg(jsonb_build_object('item', left(x->>'item', 300), 'result', x->>'result',
                                               'remark', left(coalesce(x->>'remark',''), 300)))
             from jsonb_array_elements(p_data->'results') x),
          coalesce(nullif(p_data->>'overall',''), 'Pass'), left(coalesce(p_data->>'remarks',''), 1000),
          u.name || case when u.post <> '' then ' (' || u.post || ')' else '' end, u.role, u.id, p_data->>'signature')
  returning * into r;
  update public.meq_equipment
     set last_maint = greatest(coalesce(last_maint, v_date), v_date),
         next_maint = case when last_maint is null or v_date >= last_maint then v_next else next_maint end,
         updated_at = now()
   where id = e.id;
  return to_jsonb(r) - 'signature';
end $$;

create or replace function public.meq_pm_list(p_token uuid, p_equipment_id text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u public.meq_users;
begin
  u := public.meq__auth(p_token);
  return coalesce((select jsonb_agg((to_jsonb(r) - 'signature' - 'results')
                     || jsonb_build_object('equipment_name', e.name, 'department', e.department,
                          'fail_count', (select count(*) from jsonb_array_elements(r.results) x where x->>'result' = 'fail'),
                          'item_count', jsonb_array_length(r.results))
                     order by r.pm_date desc, r.created_at desc)
     from (select * from public.meq_pm_records
            where (p_equipment_id is null or equipment_id = p_equipment_id)
              and (u.role = 'admin' or done_by_id = u.id)
            order by pm_date desc, created_at desc limit 3000) r
     join public.meq_equipment e on e.id = r.equipment_id), '[]'::jsonb);
end $$;

create or replace function public.meq_pm_get(p_token uuid, p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u public.meq_users; v jsonb;
begin
  u := public.meq__auth(p_token);
  select to_jsonb(r) || jsonb_build_object('equipment', to_jsonb(e) - 'img_front' - 'img_back' - 'img_label') into v
    from public.meq_pm_records r join public.meq_equipment e on e.id = r.equipment_id
   where r.id = p_id and (u.role = 'admin' or r.done_by_id = u.id);
  if v is null then raise exception 'NOT_FOUND'; end if;
  return v;
end $$;

create or replace function public.meq_pm_delete(p_token uuid, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.meq__auth(p_token, 'admin');
  delete from public.meq_pm_records where id = p_id;
end $$;

-- ------------------------------------------------------------ calibration
create or replace function public.meq_cal_save(p_token uuid, p_data jsonb, p_file_name text,
                                               p_mime text, p_file_data text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u public.meq_users; e public.meq_equipment; v_doc uuid; r public.meq_calibrations;
        v_date date; v_next date; v_size int;
begin
  u := public.meq__auth(p_token, 'admin');
  select * into e from public.meq_equipment where id = trim(coalesce(p_data->>'equipment_id',''));
  if not found then raise exception 'EQUIPMENT_NOT_FOUND'; end if;
  if coalesce(p_file_data,'') = '' then raise exception 'CERTIFICATE_REQUIRED'; end if;
  if p_mime not in ('application/pdf','image/jpeg','image/png','image/webp') then raise exception 'INVALID_FILE_TYPE'; end if;
  if p_file_data !~ '^[A-Za-z0-9+/=]+$' then raise exception 'INVALID_FILE'; end if;
  v_size := (length(p_file_data) * 3 / 4) - (length(p_file_data) - length(rtrim(p_file_data, '=')));
  if v_size > 6291456 then raise exception 'FILE_TOO_LARGE'; end if;
  v_date := nullif(p_data->>'cal_date','')::date;
  if v_date is null then raise exception 'DATE_REQUIRED'; end if;
  if v_date > current_date then raise exception 'FUTURE_DATE'; end if;
  v_next := coalesce(nullif(p_data->>'next_due','')::date,
                     v_date + (public.meq__setting_num('cal_interval_days', 365))::int);
  insert into public.meq_documents(equipment_id, kind, file_name, mime, size_bytes, data, note, uploaded_by)
  values (e.id, 'calibration', left(coalesce(nullif(p_file_name,''),'certificate'), 150), p_mime, v_size, p_file_data,
          left('Calibration ' || to_char(v_date, 'DD Mon YYYY') ||
               case when coalesce(p_data->>'certificate_no','') <> '' then ' · Cert ' || (p_data->>'certificate_no') else '' end, 300),
          u.name)
  returning id into v_doc;
  insert into public.meq_calibrations(equipment_id, cal_date, next_due, agency, certificate_no, result,
                                      doc_id, remarks, created_by)
  values (e.id, v_date, v_next, left(coalesce(p_data->>'agency',''), 150), left(coalesce(p_data->>'certificate_no',''), 80),
          coalesce(nullif(p_data->>'result',''), 'Pass'), v_doc, left(coalesce(p_data->>'remarks',''), 500), u.name)
  returning * into r;
  update public.meq_equipment
     set calibration_done = greatest(coalesce(calibration_done, v_date), v_date),
         next_calibration = case when calibration_done is null or v_date >= calibration_done then v_next else next_calibration end,
         updated_at = now()
   where id = e.id;
  return to_jsonb(r);
end $$;

create or replace function public.meq_cal_delete(p_token uuid, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_doc uuid;
begin
  perform public.meq__auth(p_token, 'admin');
  delete from public.meq_calibrations where id = p_id returning doc_id into v_doc;
  if v_doc is not null then delete from public.meq_documents where id = v_doc; end if;
end $$;

-- ------------------------------------------------------------ condemnation
create or replace function public.meq_condemn_save(p_token uuid, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u public.meq_users; e public.meq_equipment; r public.meq_condemnations; v_id uuid := nullif(p_data->>'id','')::uuid;
        v_status text := coalesce(nullif(p_data->>'status',''), 'Proposed');
begin
  u := public.meq__auth(p_token, 'admin');
  if v_status not in ('Proposed','Approved','Rejected') then raise exception 'INVALID_STATUS'; end if;
  if trim(coalesce(p_data->>'reason','')) = '' then raise exception 'REASON_REQUIRED'; end if;
  if v_id is null then
    select * into e from public.meq_equipment where id = trim(coalesce(p_data->>'equipment_id',''));
    if not found then raise exception 'EQUIPMENT_NOT_FOUND'; end if;
    if exists (select 1 from public.meq_condemnations where equipment_id = e.id and status <> 'Rejected') then
      raise exception 'ALREADY_PROPOSED'; end if;
    insert into public.meq_condemnations(equipment_id, reason, proposed_by, prev_status)
    values (e.id, trim(p_data->>'reason'), u.name, e.status) returning * into r;
  else
    select * into r from public.meq_condemnations where id = v_id;
    if not found then raise exception 'NOT_FOUND'; end if;
    select * into e from public.meq_equipment where id = r.equipment_id;
  end if;
  if v_status = 'Approved' and not exists (
       select 1 from jsonb_array_elements(case when jsonb_typeof(p_data->'committee') = 'array'
                                               then p_data->'committee' else '[]'::jsonb end) x
        where trim(coalesce(x->>'name','')) <> '' and x->>'decision' = 'Approve') then
    raise exception 'COMMITTEE_REQUIRED';
  end if;
  update public.meq_condemnations set
    reason          = left(trim(p_data->>'reason'), 1000),
    condition       = left(coalesce(p_data->>'condition',''), 1000),
    purchase_year   = left(coalesce(p_data->>'purchase_year',''), 10),
    book_value      = nullif(p_data->>'book_value','')::numeric,
    repair_estimate = nullif(p_data->>'repair_estimate','')::numeric,
    committee       = coalesce((select jsonb_agg(jsonb_build_object(
                         'name', left(trim(x->>'name'),100), 'designation', left(coalesce(x->>'designation',''),100),
                         'decision', case when x->>'decision' in ('Approve','Reject') then x->>'decision' else 'Pending' end,
                         'remark', left(coalesce(x->>'remark',''),300)))
                        from jsonb_array_elements(case when jsonb_typeof(p_data->'committee') = 'array'
                                                       then p_data->'committee' else '[]'::jsonb end) x
                        where trim(coalesce(x->>'name','')) <> ''), '[]'::jsonb),
    disposal_method = left(coalesce(p_data->>'disposal_method',''), 200),
    remarks         = left(coalesce(p_data->>'remarks',''), 1000),
    status          = v_status,
    decided_by      = case when v_status = 'Proposed' then '' when r.status = v_status then decided_by else u.name end,
    decided_at      = case when v_status = 'Proposed' then null when r.status = v_status then decided_at else now() end
  where id = r.id returning * into r;
  if v_status = 'Approved' then
    update public.meq_equipment set status = 'Condemned', updated_at = now() where id = r.equipment_id and status <> 'Condemned';
  elsif e.status = 'Condemned' then
    update public.meq_equipment set status = coalesce(nullif(r.prev_status,''), 'Out of Service'), updated_at = now()
     where id = r.equipment_id;
  end if;
  return to_jsonb(r);
end $$;

create or replace function public.meq_condemn_delete(p_token uuid, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r public.meq_condemnations;
begin
  perform public.meq__auth(p_token, 'admin');
  delete from public.meq_condemnations where id = p_id returning * into r;
  if found and r.status = 'Approved' then
    update public.meq_equipment set status = coalesce(nullif(r.prev_status,''), 'Out of Service'), updated_at = now()
     where id = r.equipment_id and status = 'Condemned';
  end if;
end $$;

-- ------------------------------------------------------------ one call for the NABH tab
create or replace function public.meq_nabh_data(p_token uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public.meq__auth(p_token, 'admin');
  return jsonb_build_object(
    'pm', public.meq_pm_list(p_token, null),
    'calibrations', coalesce((select jsonb_agg(to_jsonb(c) || jsonb_build_object('equipment_name', e.name, 'department', e.department)
                                 order by c.cal_date desc, c.created_at desc)
                                from public.meq_calibrations c join public.meq_equipment e on e.id = c.equipment_id), '[]'::jsonb),
    'condemnations', coalesce((select jsonb_agg(to_jsonb(c) || jsonb_build_object('equipment', to_jsonb(e) - 'img_front' - 'img_back' - 'img_label')
                                 order by c.proposed_at desc)
                                from public.meq_condemnations c join public.meq_equipment e on e.id = c.equipment_id), '[]'::jsonb),
    'templates', public.meq_pm_templates(p_token)
  );
end $$;

-- ------------------------------------------------------------ grants
revoke execute on function public.meq__audit_trg() from public, anon, authenticated;
revoke execute on function public.meq__clean_parts(jsonb) from public, anon, authenticated;
revoke execute on function public.meq__parts_cost(jsonb) from public, anon, authenticated;
revoke execute on function public.meq__check_image(text, int) from public, anon, authenticated;
revoke execute on function public.meq__auth(uuid, text) from public, anon, authenticated;
revoke execute on function public.meq__complaint_json(public.meq_complaints) from public, anon, authenticated;

grant execute on function
  public.meq_submit_complaint(text, text, text, text, text), public.meq_track_complaints(text),
  public.meq_rate_complaint(text, text, int, text), public.meq_complaint_photo(uuid, uuid),
  public.meq_close_complaint(uuid, uuid, text, jsonb), public.meq_save_complaint(uuid, jsonb),
  public.meq_complaint_escalate(uuid, uuid, text), public.meq_tech_save_notes(uuid, uuid, text, jsonb),
  public.meq_save_settings(uuid, jsonb), public.meq_audit_list(uuid, bigint, int),
  public.meq_pm_templates(uuid), public.meq_pm_template_save(uuid, text, jsonb), public.meq_pm_save(uuid, jsonb),
  public.meq_pm_list(uuid, text), public.meq_pm_get(uuid, uuid), public.meq_pm_delete(uuid, uuid),
  public.meq_cal_save(uuid, jsonb, text, text, text), public.meq_cal_delete(uuid, uuid),
  public.meq_condemn_save(uuid, jsonb), public.meq_condemn_delete(uuid, uuid), public.meq_nabh_data(uuid)
to anon, authenticated;

notify pgrst, 'reload schema';
