-- =====================================================================
--  Al-Madaris CI — المرحلة 3 : الفصول والتلاميذ
--  انسخ هذا الملف كاملاً في: SQL Editor > New query > Run
--  (يُشغَّل بعد schema.sql ، ويمكن تشغيله أكثر من مرة)
-- =====================================================================

-- هل المستخدم مدير (مدير مدرسة أو مشرف عام)؟
create or replace function public.is_school_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from profiles where id = auth.uid() and role in ('admin','superadmin'))
$$;

-- 1) الفصول ------------------------------------------------------------
create table if not exists public.classes (
  id             uuid primary key default gen_random_uuid(),
  institution_id uuid not null default public.my_institution()
                 references public.institutions(id) on delete cascade,
  school_year    text not null default '2026-2027',
  cycle          text not null check (cycle in ('mat','pri','col','lyc','uni')),
  level          text not null,
  track          text not null check (track in ('ar','fr','arfr','quran')),
  section        text not null default '',
  capacity       int,
  created_at     timestamptz not null default now(),
  unique (institution_id, school_year, cycle, level, track, section)
);

-- 2) التلاميذ ----------------------------------------------------------
create table if not exists public.students (
  id                uuid primary key default gen_random_uuid(),
  institution_id    uuid not null default public.my_institution()
                    references public.institutions(id) on delete cascade,
  seq               int,
  code              text unique,
  first_name_ar     text not null,
  last_name_ar      text not null,
  full_name_fr      text,
  gender            text check (gender in ('M','F')),
  birth_date        date,
  birth_place       text,
  class_id          uuid references public.classes(id) on delete set null,
  guardian_name     text,
  guardian_relation text,
  guardian_phone    text,
  address           text,
  status            text not null default 'active' check (status in ('active','left')),
  enrolled_on       date not null default current_date,
  created_at        timestamptz not null default now()
);
create index if not exists students_inst_idx  on public.students(institution_id);
create index if not exists students_class_idx on public.students(class_id);

-- الرقم التعريفي التلقائي: AMC-1001-0001
create or replace function public.student_code() returns trigger
language plpgsql security definer set search_path = public as $$
declare ic text; suffix text;
begin
  perform pg_advisory_xact_lock(hashtext(new.institution_id::text));
  select code into ic from institutions where id = new.institution_id;
  suffix := coalesce(nullif(split_part(ic,'-',3),''), split_part(ic,'-',2));
  select coalesce(max(seq),0) + 1 into new.seq from students where institution_id = new.institution_id;
  new.code := 'AMC-' || suffix || '-' || lpad(new.seq::text, 4, '0');
  return new;
end $$;

drop trigger if exists students_code on public.students;
create trigger students_code before insert on public.students
  for each row execute function public.student_code();

-- 3) الحماية -----------------------------------------------------------
alter table public.classes  enable row level security;
alter table public.students enable row level security;
revoke all on public.classes, public.students from anon;

drop policy if exists cls_read   on public.classes;
drop policy if exists cls_insert on public.classes;
drop policy if exists cls_update on public.classes;
drop policy if exists cls_delete on public.classes;
create policy cls_read   on public.classes for select
  using (institution_id = public.my_institution() or public.is_superadmin());
create policy cls_insert on public.classes for insert
  with check (institution_id = public.my_institution() and public.is_school_admin());
create policy cls_update on public.classes for update
  using (institution_id = public.my_institution() and public.is_school_admin());
create policy cls_delete on public.classes for delete
  using (institution_id = public.my_institution() and public.is_school_admin());

drop policy if exists stu_read   on public.students;
drop policy if exists stu_insert on public.students;
drop policy if exists stu_update on public.students;
drop policy if exists stu_delete on public.students;
create policy stu_read   on public.students for select
  using (institution_id = public.my_institution() or public.is_superadmin());
create policy stu_insert on public.students for insert
  with check (institution_id = public.my_institution() and public.is_school_admin()
              and (class_id is null or exists (select 1 from public.classes c
                   where c.id = class_id and c.institution_id = students.institution_id)));
create policy stu_update on public.students for update
  using (institution_id = public.my_institution() and public.is_school_admin())
  with check (class_id is null or exists (select 1 from public.classes c
              where c.id = class_id and c.institution_id = students.institution_id));
create policy stu_delete on public.students for delete
  using (institution_id = public.my_institution() and public.is_school_admin());

-- لا يمكن تغيير المؤسسة ولا الرقم التعريفي بعد الإنشاء
revoke update on public.classes, public.students from authenticated;
grant update (school_year, cycle, level, track, section, capacity) on public.classes to authenticated;
grant update (first_name_ar, last_name_ar, full_name_fr, gender, birth_date, birth_place, class_id,
              guardian_name, guardian_relation, guardian_phone, address, status)
      on public.students to authenticated;
