-- ClassPoll 2.0, isolated tables (cp2_*) to avoid overwriting legacy ClassPoll data.
-- Execute ONCE in Supabase SQL Editor (as the project database administrator).
-- Requires pgcrypto (bundled with Supabase Postgres).
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated;

create table if not exists public.cp2_teachers (
  user_id uuid primary key references auth.users(id) on delete cascade,
  label text not null default '教師',
  created_at timestamptz not null default now()
);
create table if not exists public.cp2_rooms (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.cp2_teachers(user_id),
  code text not null unique check (code ~ '^[A-Z0-9]{4,12}$'),
  title text not null check (length(trim(title)) between 1 and 100),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
create table if not exists public.cp2_students (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.cp2_rooms(id) on delete cascade,
  student_no text not null check (length(trim(student_no)) between 1 and 40),
  display_name text not null check (length(trim(display_name)) between 1 and 80),
  access_hash text not null,
  auth_uid uuid references auth.users(id) on delete set null,
  is_active boolean not null default true,
  joined_at timestamptz,
  last_seen timestamptz,
  unique (room_id, student_no)
);
create unique index if not exists cp2_student_uid_room_unique on public.cp2_students(room_id, auth_uid) where auth_uid is not null;
create index if not exists cp2_students_room_idx on public.cp2_students(room_id);
create table if not exists public.cp2_bank (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.cp2_teachers(user_id),
  topic text not null default '未分類',
  prompt text not null check (length(trim(prompt)) between 1 and 500),
  options jsonb not null check(jsonb_typeof(options) = 'array' and jsonb_array_length(options) between 2 and 6),
  correct_index int not null check (correct_index between 0 and 5),
  points int not null default 5 check(points between 0 and 100),
  created_at timestamptz not null default now(),
  check (correct_index < jsonb_array_length(options))
);
create table if not exists public.cp2_questions (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.cp2_rooms(id) on delete cascade,
  prompt text not null check (length(trim(prompt)) between 1 and 500),
  options jsonb not null check(jsonb_typeof(options) = 'array' and jsonb_array_length(options) between 2 and 6),
  points int not null default 5 check(points between 0 and 100),
  allow_changes boolean not null default false,
  status text not null default 'draft' check(status in ('draft','published','closed')),
  created_at timestamptz not null default now(),
  published_at timestamptz,
  ends_at timestamptz
);
create unique index if not exists cp2_one_live_question_per_room on public.cp2_questions(room_id) where status='published';
create index if not exists cp2_questions_room_time_idx on public.cp2_questions(room_id,created_at desc);
create table if not exists public.cp2_answer_keys (
  question_id uuid primary key references public.cp2_questions(id) on delete cascade,
  correct_index int not null check(correct_index between 0 and 5)
);
create table if not exists public.cp2_votes (
  id uuid primary key default gen_random_uuid(),
  question_id uuid not null references public.cp2_questions(id) on delete cascade,
  student_id uuid not null references public.cp2_students(id) on delete cascade,
  choice int not null check(choice between 0 and 5),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(question_id,student_id)
);
create index if not exists cp2_votes_question_idx on public.cp2_votes(question_id);
create table if not exists public.cp2_attendance (
  student_id uuid not null references public.cp2_students(id) on delete cascade,
  room_id uuid not null references public.cp2_rooms(id) on delete cascade,
  attended_on date not null default (now() at time zone 'Asia/Taipei')::date,
  first_seen timestamptz not null default now(),
  primary key(student_id,attended_on)
);
create index if not exists cp2_attendance_room_idx on public.cp2_attendance(room_id,attended_on desc);
create table if not exists public.cp2_audit (
  id bigint generated always as identity primary key,
  room_id uuid references public.cp2_rooms(id) on delete cascade,
  actor_uid uuid,
  event text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists cp2_audit_room_idx on public.cp2_audit(room_id,created_at desc);
create table if not exists public.cp2_errors (
  id bigint generated always as identity primary key,
  room_id uuid references public.cp2_rooms(id) on delete cascade,
  actor_uid uuid not null,
  scope text not null,
  message text not null,
  created_at timestamptz not null default now(),
  check(length(scope) between 1 and 30),
  check(length(message) between 1 and 500)
);
create index if not exists cp2_errors_actor_created_idx on public.cp2_errors(actor_uid,created_at desc);
create index if not exists cp2_errors_room_created_idx on public.cp2_errors(room_id,created_at desc);

-- Safety: no direct write grants for the client to votes, attendance, answer keys or roster credentials.
do $$ declare t text; begin
  foreach t in array array['cp2_teachers','cp2_rooms','cp2_students','cp2_bank','cp2_questions','cp2_answer_keys','cp2_votes','cp2_attendance','cp2_audit','cp2_errors'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('revoke all on table public.%I from anon, authenticated',t);
  end loop;
end $$;
grant select on public.cp2_teachers to authenticated;
grant select,insert,update,delete on public.cp2_rooms to authenticated;
grant select,update on public.cp2_students to authenticated;
grant select,insert,update,delete on public.cp2_bank to authenticated;
grant select on public.cp2_questions to authenticated;
grant select on public.cp2_answer_keys to authenticated;
grant select on public.cp2_votes to authenticated;
grant select on public.cp2_attendance to authenticated;
grant select on public.cp2_audit to authenticated;
grant select on public.cp2_errors to authenticated;

-- Internal checks run with a fixed search_path and no untrusted caller-supplied role flags.
create or replace function private.cp2_is_teacher() returns boolean
language sql security definer stable set search_path = '' as $$
  select exists(select 1 from public.cp2_teachers t where t.user_id=(select auth.uid()))
    and coalesce((select auth.jwt()->>'is_anonymous'),'false') <> 'true';
$$;
create or replace function private.cp2_owns(p_room uuid) returns boolean
language sql security definer stable set search_path = '' as $$
  select private.cp2_is_teacher() and exists (
    select 1 from public.cp2_rooms r where r.id=p_room and r.owner_id=(select auth.uid())
  );
$$;
create or replace function private.cp2_member(p_room uuid) returns boolean
language sql security definer stable set search_path = '' as $$
  select exists(select 1 from public.cp2_students s
    where s.room_id=p_room and s.auth_uid=(select auth.uid()) and s.is_active);
$$;
revoke execute on function private.cp2_is_teacher(),private.cp2_owns(uuid),private.cp2_member(uuid) from public;
grant execute on function private.cp2_is_teacher(),private.cp2_owns(uuid),private.cp2_member(uuid) to authenticated;

-- Drop policies for repeatable setup. Avoid mutually recursive policies via private helpers.
do $$ declare r record; begin
 for r in select schemaname,tablename,policyname from pg_policies where schemaname='public' and tablename like 'cp2_%' loop
   execute format('drop policy if exists %I on %I.%I',r.policyname,r.schemaname,r.tablename);
 end loop;
end $$;
create policy cp2_teachers_self on public.cp2_teachers for select to authenticated using (user_id=(select auth.uid()));
-- Check ownership against the row directly. An INSERT ... RETURNING statement
-- cannot reliably see its just-inserted row through a self-querying STABLE
-- SECURITY DEFINER helper (private.cp2_owns), and may fail the SELECT RLS check.
create policy cp2_rooms_read on public.cp2_rooms for select to authenticated
 using ((owner_id=(select auth.uid()) and (select private.cp2_is_teacher()))
        or private.cp2_member(id));
create policy cp2_rooms_insert on public.cp2_rooms for insert to authenticated
 with check(owner_id=(select auth.uid()) and (select private.cp2_is_teacher()));
create policy cp2_rooms_update on public.cp2_rooms for update to authenticated
 using(private.cp2_owns(id)) with check(owner_id=(select auth.uid()) and (select private.cp2_is_teacher()));
create policy cp2_rooms_delete on public.cp2_rooms for delete to authenticated using(private.cp2_owns(id));
create policy cp2_students_read on public.cp2_students for select to authenticated
 using(private.cp2_owns(room_id) or auth_uid=(select auth.uid()));
create policy cp2_students_teacher_update on public.cp2_students for update to authenticated
 using(private.cp2_owns(room_id)) with check(private.cp2_owns(room_id));
create policy cp2_bank_all on public.cp2_bank for all to authenticated
 using(owner_id=(select auth.uid()) and (select private.cp2_is_teacher()))
 with check(owner_id=(select auth.uid()) and (select private.cp2_is_teacher()));
create policy cp2_questions_read on public.cp2_questions for select to authenticated
 using(private.cp2_owns(room_id) or (private.cp2_member(room_id) and status in ('published','closed')));
create policy cp2_answer_keys_teacher on public.cp2_answer_keys for select to authenticated
 using (exists(select 1 from public.cp2_questions q where q.id=question_id and private.cp2_owns(q.room_id)));
create policy cp2_votes_read on public.cp2_votes for select to authenticated
 using (exists(select 1 from public.cp2_questions q where q.id=question_id and private.cp2_owns(q.room_id))
    or exists(select 1 from public.cp2_students s where s.id=student_id and s.auth_uid=(select auth.uid())));
create policy cp2_attendance_teacher on public.cp2_attendance for select to authenticated using(private.cp2_owns(room_id));
create policy cp2_audit_teacher on public.cp2_audit for select to authenticated using(private.cp2_owns(room_id));
create policy cp2_errors_teacher on public.cp2_errors for select to authenticated using(private.cp2_owns(room_id) or (actor_uid=(select auth.uid()) and (select private.cp2_is_teacher())));

-- Privileged operations are in non-exposed private schema. Public RPC wrappers are SECURITY INVOKER.
create or replace function private.cp2_add_student(p_room uuid,p_number text,p_name text)
returns table(student_id uuid, access_code text)
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_secret text;
begin
 if not private.cp2_owns(p_room) then raise exception '教師權限不足' using errcode='42501'; end if;
 if length(trim(p_number)) not between 1 and 40 or length(trim(p_name)) not between 1 and 80 then
   raise exception '學號或姓名格式不正確'; end if;
 v_secret:=encode(extensions.gen_random_bytes(16),'hex');
 insert into public.cp2_students(room_id,student_no,display_name,access_hash)
 values(p_room,trim(p_number),trim(p_name),encode(extensions.digest(v_secret,'sha256'),'hex')) returning id into v_id;
 insert into public.cp2_audit(room_id,actor_uid,event,details) values(p_room,auth.uid(),'student.add',jsonb_build_object('student_no',trim(p_number)));
 return query select v_id,v_secret;
end; $$;
create or replace function public.cp2_add_student(p_room uuid,p_number text,p_name text)
returns table(student_id uuid,access_code text) language sql security invoker set search_path='' as $$
 select * from private.cp2_add_student(p_room,p_number,p_name); $$;

create or replace function private.cp2_join(p_code text,p_number text,p_access text)
returns table(student_id uuid,room_id uuid,display_name text,room_title text)
language plpgsql security definer set search_path='' as $$
declare v_r public.cp2_rooms%rowtype; v_s public.cp2_students%rowtype; v_uid uuid;
begin
 v_uid:=auth.uid();
 if v_uid is null or coalesce(auth.jwt()->>'is_anonymous','false') <> 'true' then
   raise exception '學生端必須使用匿名驗證身分' using errcode='42501'; end if;
 select * into v_r from public.cp2_rooms where code=upper(trim(p_code)) and is_active;
 if not found then raise exception '教室不存在或已關閉'; end if;
 select * into v_s from public.cp2_students s where s.room_id=v_r.id and s.student_no=trim(p_number) for update;
 if not found or not v_s.is_active then raise exception '入班身分驗證失敗，請確認學號與個人入班碼'; end if;
 if v_s.access_hash <> encode(extensions.digest(coalesce(p_access,''),'sha256'),'hex') then
   raise exception '入班身分驗證失敗，請確認學號與個人入班碼'; end if;
 if v_s.auth_uid is not null and v_s.auth_uid <> v_uid then
   raise exception '此學號已綁定另一個裝置，請聯繫教師重設'; end if;
 update public.cp2_students set auth_uid=v_uid,joined_at=coalesce(joined_at,now()),last_seen=now() where id=v_s.id;
 insert into public.cp2_attendance(student_id,room_id,attended_on) values(v_s.id,v_r.id,(now() at time zone 'Asia/Taipei')::date) on conflict do nothing;
 return query select v_s.id,v_r.id,v_s.display_name,v_r.title;
end; $$;
create or replace function public.cp2_join(p_code text,p_number text,p_access text)
returns table(student_id uuid,room_id uuid,display_name text,room_title text)
language sql security invoker set search_path='' as $$select * from private.cp2_join(p_code,p_number,p_access);$$;

create or replace function private.cp2_resume(p_room uuid)
returns table(student_id uuid,room_id uuid,display_name text,room_title text)
language sql security definer set search_path='' as $$
 select s.id,r.id,s.display_name,r.title from public.cp2_students s
 join public.cp2_rooms r on r.id=s.room_id
 where r.id=p_room and s.auth_uid=auth.uid() and s.is_active and r.is_active limit 1;
$$;
create or replace function public.cp2_resume(p_room uuid)
returns table(student_id uuid,room_id uuid,display_name text,room_title text)
language sql security invoker set search_path='' as $$select * from private.cp2_resume(p_room);$$;

create or replace function private.cp2_heartbeat(p_room uuid) returns void
language plpgsql security definer set search_path='' as $$
declare v_sid uuid;
begin
 update public.cp2_students set last_seen=now() where room_id=p_room and auth_uid=auth.uid() and is_active
 returning id into v_sid;
 if v_sid is null then raise exception '未加入教室' using errcode='42501'; end if;
 insert into public.cp2_attendance(student_id,room_id,attended_on) values(v_sid,p_room,(now() at time zone 'Asia/Taipei')::date) on conflict do nothing;
end; $$;
create or replace function public.cp2_heartbeat(p_room uuid) returns void
language sql security invoker set search_path='' as $$select private.cp2_heartbeat(p_room);$$;

create or replace function private.cp2_publish(p_room uuid,p_prompt text,p_options jsonb,p_correct int,
 p_points int default 5,p_seconds int default 0,p_allow_changes boolean default false)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid; v_r public.cp2_rooms%rowtype;
begin
 if not private.cp2_owns(p_room) then raise exception '教師權限不足' using errcode='42501'; end if;
 if length(trim(p_prompt)) not between 1 and 500 or jsonb_typeof(p_options)<>'array'
    or jsonb_array_length(p_options) not between 2 and 6 then raise exception '題目或選項不符合格式'; end if;
 if p_correct<0 or p_correct>=jsonb_array_length(p_options) then raise exception '正確答案索引錯誤'; end if;
 if p_points not between 0 and 100 or p_seconds not between 0 and 7200 then raise exception '分數或秒數不合法'; end if;
 select * into v_r from public.cp2_rooms where id=p_room for update;
 if not v_r.is_active then raise exception '教室已停用'; end if;
 update public.cp2_questions set status='closed' where room_id=p_room and status='published';
 insert into public.cp2_questions(room_id,prompt,options,points,allow_changes,status,published_at,ends_at)
 values(p_room,trim(p_prompt),p_options,p_points,p_allow_changes,'published',now(),
  case when p_seconds>0 then now()+make_interval(secs => p_seconds) else null end)
 returning id into v_id;
 insert into public.cp2_answer_keys(question_id,correct_index) values(v_id,p_correct);
 insert into public.cp2_audit(room_id,actor_uid,event,details) values(p_room,auth.uid(),'question.publish',jsonb_build_object('question_id',v_id));
 return v_id;
end; $$;
create or replace function public.cp2_publish(p_room uuid,p_prompt text,p_options jsonb,p_correct int,
 p_points int default 5,p_seconds int default 0,p_allow_changes boolean default false)
returns uuid language sql security invoker set search_path='' as $$
 select private.cp2_publish(p_room,p_prompt,p_options,p_correct,p_points,p_seconds,p_allow_changes); $$;

create or replace function private.cp2_close(p_question uuid) returns void
language plpgsql security definer set search_path='' as $$
declare v_room uuid;
begin
 select room_id into v_room from public.cp2_questions where id=p_question;
 if v_room is null or not private.cp2_owns(v_room) then raise exception '教師權限不足' using errcode='42501'; end if;
 update public.cp2_questions set status='closed' where id=p_question and status='published';
 insert into public.cp2_audit(room_id,actor_uid,event,details) values(v_room,auth.uid(),'question.close',jsonb_build_object('question_id',p_question));
end; $$;
create or replace function public.cp2_close(p_question uuid) returns void language sql security invoker set search_path='' as $$select private.cp2_close(p_question);$$;

create or replace function private.cp2_vote(p_question uuid,p_choice int) returns uuid
language plpgsql security definer set search_path='' as $$
declare v_q public.cp2_questions%rowtype; v_sid uuid; v_id uuid;
begin
 if auth.uid() is null or coalesce(auth.jwt()->>'is_anonymous','false') <> 'true' then
   raise exception '學生身分驗證失敗' using errcode='42501'; end if;
 select * into v_q from public.cp2_questions where id=p_question for share;
 if not found or v_q.status <> 'published' or (v_q.ends_at is not null and clock_timestamp()>=v_q.ends_at) then
   raise exception '題目已結束或不存在'; end if;
 if not exists(select 1 from public.cp2_rooms r where r.id=v_q.room_id and r.is_active) then
   raise exception '教室已停用'; end if;
 if p_choice<0 or p_choice>=jsonb_array_length(v_q.options) then raise exception '選項超出範圍'; end if;
 select id into v_sid from public.cp2_students where room_id=v_q.room_id and auth_uid=auth.uid() and is_active;
 if v_sid is null then raise exception '未通過班級名冊驗證' using errcode='42501'; end if;
 -- Atomic unique-vote protection: concurrent requests cannot overwrite when changes are disabled.
 if v_q.allow_changes then
   insert into public.cp2_votes(question_id,student_id,choice) values(p_question,v_sid,p_choice)
   on conflict(question_id,student_id) do update set choice=excluded.choice,updated_at=now()
   returning id into v_id;
 else
   insert into public.cp2_votes(question_id,student_id,choice) values(p_question,v_sid,p_choice)
   on conflict(question_id,student_id) do nothing returning id into v_id;
   if v_id is null then raise exception '此題已作答，不允許再次提交'; end if;
 end if;
 return v_id;
end; $$;
create or replace function public.cp2_vote(p_question uuid,p_choice int) returns uuid
language sql security invoker set search_path='' as $$select private.cp2_vote(p_question,p_choice);$$;


-- Reissue a lost personal admission code WITHOUT deleting votes/attendance.
create or replace function private.cp2_rotate_student(p_student uuid)
returns text language plpgsql security definer set search_path='' as $$
declare v_room uuid; v_secret text;
begin
 select room_id into v_room from public.cp2_students where id=p_student for update;
 if v_room is null or not private.cp2_owns(v_room) then raise exception '教師權限不足' using errcode='42501'; end if;
 v_secret:=encode(extensions.gen_random_bytes(16),'hex');
 update public.cp2_students set access_hash=encode(extensions.digest(v_secret,'sha256'),'hex'),auth_uid=null,last_seen=null where id=p_student;
 insert into public.cp2_audit(room_id,actor_uid,event,details) values(v_room,auth.uid(),'student.rotate_access',jsonb_build_object('student_id',p_student));
 return v_secret;
end; $$;
create or replace function public.cp2_rotate_student(p_student uuid)
returns text language sql security invoker set search_path='' as $$select private.cp2_rotate_student(p_student);$$;


-- Rate-limited sanitized client error telemetry. No stack traces, passwords or access codes.
create or replace function private.cp2_log_error(p_room uuid,p_scope text,p_message text)
returns void language plpgsql security definer set search_path='' as $$
declare v_actor uuid;
begin
 v_actor:=auth.uid();
 if v_actor is null then return; end if;
 if p_room is not null and not (private.cp2_owns(p_room) or private.cp2_member(p_room)) then return; end if;
 if p_room is null and not private.cp2_is_teacher() then return; end if;
 if (select count(*) from public.cp2_errors where actor_uid=v_actor and created_at>now()-interval '1 hour')>=30 then return; end if;
 insert into public.cp2_errors(room_id,actor_uid,scope,message)
 values(p_room,left(coalesce(nullif(trim(p_scope),''),'client'),30),left(coalesce(nullif(trim(p_message),''),'unknown'),500));
end; $$;
create or replace function public.cp2_log_error(p_room uuid,p_scope text,p_message text)
returns void language sql security invoker set search_path='' as $$
 select private.cp2_log_error(p_room,p_scope,p_message);$$;

-- Enforce function-only access for writes, and avoid default EXECUTE on RPC for PUBLIC/anon.
do $$ declare r record; begin
 for r in select p.oid::regprocedure as sig, n.nspname as ns
 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where (n.nspname='private' and p.proname like 'cp2_%')
    or (n.nspname='public' and p.proname in ('cp2_add_student','cp2_join','cp2_resume','cp2_heartbeat','cp2_publish','cp2_close','cp2_vote','cp2_rotate_student','cp2_log_error')) loop
   execute 'revoke all on function '||r.sig||' from public, anon';
   execute 'grant execute on function '||r.sig||' to authenticated';
 end loop;
end $$;

-- Existing Supabase projects normally have a realtime publication. Idempotently add just the 2 needed tables.
do $$ begin
 if exists(select 1 from pg_publication where pubname='supabase_realtime') then
   if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='cp2_questions') then
     alter publication supabase_realtime add table public.cp2_questions;
   end if;
   if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='cp2_votes') then
     alter publication supabase_realtime add table public.cp2_votes;
   end if;
 end if;
end $$;

-- IMPORTANT: No teacher is created automatically. Only a DB admin can execute 02_grant_teacher.sql.

-- Support owner- and student-foreign-key lookups as classes grow.
CREATE INDEX IF NOT EXISTS cp2_bank_owner_id_idx ON public.cp2_bank(owner_id);
CREATE INDEX IF NOT EXISTS cp2_rooms_owner_id_idx ON public.cp2_rooms(owner_id);
CREATE INDEX IF NOT EXISTS cp2_students_auth_uid_idx ON public.cp2_students(auth_uid);
CREATE INDEX IF NOT EXISTS cp2_votes_student_id_idx ON public.cp2_votes(student_id);
