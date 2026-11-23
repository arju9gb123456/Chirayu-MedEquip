-- =====================================================================
--  Chirayu MedEquip / BioTrack — Equipment documents (v2)
--  Invoice, AMC / CMC contract, warranty card, calibration certificate,
--  service report… uploaded per equipment. Admin-only.
--  Run AFTER setup.sql. Safe to re-run.
-- =====================================================================

create table if not exists public.meq_documents (
  id           uuid primary key default gen_random_uuid(),
  equipment_id text not null references public.meq_equipment(id) on delete cascade,
  kind         text not null check (kind in ('invoice','amc','cmc','warranty','calibration','service','other')),
  file_name    text not null,
  mime         text not null check (mime in ('application/pdf','image/jpeg','image/png','image/webp')),
  size_bytes   int  not null check (size_bytes > 0 and size_bytes <= 6291456),
  data         text not null,               -- base64 (no data: prefix)
  note         text not null default '',
  uploaded_by  text not null default '',
  created_at   timestamptz not null default now()
);
create index if not exists meq_documents_eq_idx on public.meq_documents(equipment_id);

alter table public.meq_documents enable row level security;
revoke all on public.meq_documents from anon, authenticated;

-- list (metadata only, no file data)
create or replace function public.meq_doc_list(p_token uuid, p_equipment_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public.meq__auth(p_token, 'admin');
  return coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'equipment_id', d.equipment_id, 'kind', d.kind,
            'file_name', d.file_name, 'mime', d.mime, 'size_bytes', d.size_bytes, 'note', d.note,
            'uploaded_by', d.uploaded_by, 'created_at', d.created_at) order by d.created_at desc)
          from public.meq_documents d where d.equipment_id = trim(p_equipment_id)), '[]'::jsonb);
end $$;

-- upload
create or replace function public.meq_doc_add(p_token uuid, p_equipment_id text, p_kind text,
                                              p_file_name text, p_mime text, p_data text, p_note text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare u public.meq_users; d public.meq_documents; v_size int;
begin
  u := public.meq__auth(p_token, 'admin');
  if not exists (select 1 from public.meq_equipment where id = trim(p_equipment_id)) then raise exception 'EQUIPMENT_NOT_FOUND'; end if;
  if p_kind not in ('invoice','amc','cmc','warranty','calibration','service','other') then raise exception 'INVALID_DOC_TYPE'; end if;
  if p_mime not in ('application/pdf','image/jpeg','image/png','image/webp') then raise exception 'INVALID_FILE_TYPE'; end if;
  if coalesce(p_data,'') = '' or p_data !~ '^[A-Za-z0-9+/=]+$' then raise exception 'INVALID_FILE'; end if;
  v_size := (length(p_data) * 3) / 4 - (length(p_data) - length(rtrim(p_data, '=')));
  if v_size > 6291456 then raise exception 'FILE_TOO_LARGE'; end if;
  if (select count(*) from public.meq_documents where equipment_id = trim(p_equipment_id)) >= 30 then raise exception 'TOO_MANY_DOCS'; end if;
  insert into public.meq_documents(equipment_id, kind, file_name, mime, size_bytes, data, note, uploaded_by)
  values (trim(p_equipment_id), p_kind, left(coalesce(nullif(trim(p_file_name),''),'document'),150), p_mime, v_size, p_data,
          left(coalesce(p_note,''),300), u.name)
  returning * into d;
  return jsonb_build_object('id', d.id, 'equipment_id', d.equipment_id, 'kind', d.kind, 'file_name', d.file_name,
           'mime', d.mime, 'size_bytes', d.size_bytes, 'note', d.note, 'uploaded_by', d.uploaded_by, 'created_at', d.created_at);
end $$;

-- download
create or replace function public.meq_doc_get(p_token uuid, p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare d public.meq_documents;
begin
  perform public.meq__auth(p_token, 'admin');
  select * into d from public.meq_documents where id = p_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  return jsonb_build_object('file_name', d.file_name, 'mime', d.mime, 'data', d.data);
end $$;

-- delete
create or replace function public.meq_doc_delete(p_token uuid, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.meq__auth(p_token, 'admin');
  delete from public.meq_documents where id = p_id;
end $$;

-- admin_data now also returns a document count per equipment
create or replace function public.meq_admin_data(p_token uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public.meq__auth(p_token, 'admin');
  return jsonb_build_object(
    'equipment', coalesce((select jsonb_agg((to_jsonb(e) - 'img_front' - 'img_back' - 'img_label')
                                            || jsonb_build_object('doc_count',
                                                 (select count(*) from public.meq_documents d where d.equipment_id = e.id))
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

grant execute on function
  public.meq_doc_list(uuid, text), public.meq_doc_add(uuid, text, text, text, text, text, text),
  public.meq_doc_get(uuid, uuid), public.meq_doc_delete(uuid, uuid), public.meq_admin_data(uuid)
to anon, authenticated;

notify pgrst, 'reload schema';
