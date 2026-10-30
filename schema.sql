-- =====================================================================
--  Al-Madaris CI — المرحلة 2 : قاعدة البيانات (Supabase / PostgreSQL)
--  انسخ هذا الملف كاملاً في: Supabase > SQL Editor > New query > Run
--  يمكن تشغيله أكثر من مرة دون ضرر.
-- =====================================================================

create extension if not exists pgcrypto;
create sequence if not exists public.institution_seq start 1001;

-- 1) المؤسسات ----------------------------------------------------------
create table if not exists public.institutions (
  id                uuid primary key default gen_random_uuid(),
  code              text unique not null
                    default ('AMC-' || to_char(now(),'YYYY') || '-' || nextval('public.institution_seq')),
  name_ar           text not null,
  name_fr           text not null,
  type              text not null check (type in ('school','quran','univ')),
  country           text not null default 'CI',
  city              text not null,
  cycles            text[] not null default '{}',   -- mat, pri, col, lyc, uni
  tracks            text[] not null default '{}',   -- ar, fr, arfr, quran
  students_estimate int,
  term_system       text not null default 'tri' check (term_system in ('tri','sem')),
  phone             text,
  email             text,
  status            text not null default 'trial' check (status in ('trial','active','suspended')),
  trial_end         date not null default (current_date + 14),
  owner_id          uuid references auth.users(id) on delete set null,
  created_at        timestamptz not null default now()
);

-- 2) المستخدمون (مرتبطون بحسابات الدخول) -------------------------------
create table if not exists public.profiles (
  id             uuid primary key references auth.users(id) on delete cascade,
  institution_id uuid references public.institutions(id) on delete cascade,
  full_name      text,
  phone          text,
  role           text not null default 'admin'
                 check (role in ('superadmin','admin','staff','student','parent')),
  role_title     text,
  created_at     timestamptz not null default now()
);

-- 3) الوثائق الرسمية (للتحقق العلني) -----------------------------------
create table if not exists public.documents (
  code           text primary key,
  institution_id uuid not null references public.institutions(id) on delete cascade,
  doc_type       text not null,
  holder_name    text not null,
  level          text,
  mention        text,
  issued_on      date not null default current_date,
  revoked        boolean not null default false,
  created_at     timestamptz not null default now()
);

-- 4) دوال مساعدة --------------------------------------------------------
create or replace function public.my_institution() returns uuid
language sql stable security definer set search_path = public as $$
  select institution_id from profiles where id = auth.uid()
$$;

create or replace function public.is_superadmin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from profiles where id = auth.uid() and role = 'superadmin')
$$;

-- 5) عند إنشاء حساب جديد: تُنشأ المؤسسة وملف المسؤول تلقائياً ----------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  m    jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  inst uuid;
begin
  if m ? 'name_ar' then
    insert into institutions (name_ar, name_fr, type, country, city, cycles, tracks,
                              students_estimate, term_system, phone, email, owner_id)
    values (m->>'name_ar', m->>'name_fr', m->>'type', coalesce(m->>'country','CI'), m->>'city',
            array(select jsonb_array_elements_text(coalesce(m->'cycles','[]'::jsonb))),
            array(select jsonb_array_elements_text(coalesce(m->'tracks','[]'::jsonb))),
            nullif(m->>'students','')::int, coalesce(m->>'term','tri'),
            m->>'phone', nullif(m->>'email',''), new.id)
    returning id into inst;

    insert into profiles (id, institution_id, full_name, phone, role, role_title)
    values (new.id, inst, m->>'admin_name', m->>'admin_phone', 'admin', m->>'admin_role');
  end if;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 6) التحقق العلني من وثيقة (بدون كشف باقي البيانات) -------------------
create or replace function public.verify_document(p_code text)
returns table (doc_type text, holder_name text, level text, mention text, issued_on date,
               institution_ar text, institution_fr text, city text, revoked boolean)
language sql stable security definer set search_path = public as $$
  select d.doc_type, d.holder_name, d.level, d.mention, d.issued_on,
         i.name_ar, i.name_fr, i.city, d.revoked
  from documents d join institutions i on i.id = d.institution_id
  where d.code = upper(trim(p_code))
$$;
grant execute on function public.verify_document(text) to anon, authenticated;

-- 7) الحماية (Row Level Security) ---------------------------------------
alter table public.institutions enable row level security;
alter table public.profiles     enable row level security;
alter table public.documents    enable row level security;

drop policy if exists inst_read   on public.institutions;
drop policy if exists inst_update on public.institutions;
create policy inst_read   on public.institutions for select
  using (id = public.my_institution() or public.is_superadmin());
create policy inst_update on public.institutions for update
  using (owner_id = auth.uid() or public.is_superadmin());

-- المدير يعدّل بيانات مؤسسته فقط، لا الحالة ولا تاريخ نهاية التجربة
revoke update on public.institutions from authenticated;
grant  update (name_ar, name_fr, city, phone, email, cycles, tracks,
               students_estimate, term_system) on public.institutions to authenticated;

drop policy if exists prof_read   on public.profiles;
drop policy if exists prof_update on public.profiles;
create policy prof_read   on public.profiles for select
  using (id = auth.uid() or institution_id = public.my_institution() or public.is_superadmin());
create policy prof_update on public.profiles for update using (id = auth.uid());
revoke update on public.profiles from authenticated;
grant  update (full_name, phone) on public.profiles to authenticated;

drop policy if exists doc_read on public.documents;
create policy doc_read on public.documents for select
  using (institution_id = public.my_institution() or public.is_superadmin());

-- 8) بيانات تجريبية للتحقق: الرمز AMC-2026-000123 -----------------------
insert into public.institutions (code, name_ar, name_fr, type, city, status)
values ('AMC-DEMO', 'مدرسة تجريبية', 'École de démonstration', 'school', 'بواكي / Bouaké', 'active')
on conflict (code) do nothing;

insert into public.documents (code, institution_id, doc_type, holder_name, level, mention, issued_on)
select 'AMC-2026-000123', id, 'شهادة نهاية المرحلة الابتدائية / CEPE',
       'تلميذ تجريبي — Élève Démo', 'السنة السادسة / CM2', 'جيد جداً / Très bien', '2026-07-15'
from public.institutions where code = 'AMC-DEMO'
on conflict (code) do nothing;

-- 9) (اختياري) اجعل حسابك مشرفاً عاماً على المنصة بعد أن تسجّل:
-- update public.profiles set role = 'superadmin'
--  where id = (select id from auth.users where email = 'konemamoud@gmail.com');
