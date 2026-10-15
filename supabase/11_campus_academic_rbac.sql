-- ClassPoll 3.0: additive campus governance, academic structure, safe lifecycle.
-- Requires 01..10. This migration must be verified on an isolated DB before production.
-- No legacy classroom, votes, auth.users or ballot records are modified.
BEGIN;
CREATE TABLE IF NOT EXISTS public.cp3_staff (
 user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
 role text NOT NULL CHECK(role IN ('admin','registrar','teacher','auditor')),
 appointed_by uuid REFERENCES auth.users(id),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE IF NOT EXISTS public.cp3_units (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 parent_id uuid REFERENCES public.cp3_units(id),
 kind text NOT NULL CHECK(kind IN ('campus','college','department')),
 code text NOT NULL UNIQUE CHECK(code ~ '^[A-Z0-9_-]{2,24}$'),
 name text NOT NULL CHECK(length(trim(name)) BETWEEN 1 AND 120),
 is_active boolean NOT NULL DEFAULT true,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE IF NOT EXISTS public.cp3_terms (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 academic_year integer NOT NULL CHECK(academic_year BETWEEN 100 AND 300),
 semester integer NOT NULL CHECK(semester IN (1,2,3)),
 starts_on date NOT NULL,ends_on date NOT NULL,
 is_archived boolean NOT NULL DEFAULT false,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 UNIQUE(academic_year,semester),CHECK(ends_on>starts_on)
);
CREATE TABLE IF NOT EXISTS public.cp3_courses (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 term_id uuid NOT NULL REFERENCES public.cp3_terms(id),
 department_id uuid NOT NULL REFERENCES public.cp3_units(id),
 room_id uuid NOT NULL REFERENCES public.cp2_rooms(id),
 code text NOT NULL CHECK(length(trim(code)) BETWEEN 2 AND 32),
 title text NOT NULL CHECK(length(trim(title)) BETWEEN 1 AND 160),
 owner_id uuid NOT NULL REFERENCES public.cp2_teachers(user_id),
 status text NOT NULL DEFAULT 'active' CHECK(status IN ('active','archived')),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 UNIQUE(term_id,code)
);
CREATE TABLE IF NOT EXISTS public.cp3_course_staff (
 course_id uuid NOT NULL REFERENCES public.cp3_courses(id) ON DELETE CASCADE,
 teacher_id uuid NOT NULL REFERENCES public.cp2_teachers(user_id),
 role text NOT NULL CHECK(role IN ('co_teacher','assistant','auditor')),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(course_id,teacher_id)
);
CREATE TABLE IF NOT EXISTS public.cp3_enrollments (
 course_id uuid NOT NULL REFERENCES public.cp3_courses(id),
 student_id uuid NOT NULL REFERENCES public.cp2_students(id),
 is_active boolean NOT NULL DEFAULT true,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(course_id,student_id)
);
CREATE TABLE IF NOT EXISTS public.cp3_notices (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 course_id uuid NOT NULL REFERENCES public.cp3_courses(id),
 subject text NOT NULL CHECK(length(trim(subject)) BETWEEN 1 AND 160),
 body text NOT NULL CHECK(length(trim(body)) BETWEEN 1 AND 2000),
 author_id uuid NOT NULL REFERENCES auth.users(id),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 archived_at timestamptz
);
CREATE TABLE IF NOT EXISTS public.cp3_notice_reads (
 notice_id uuid NOT NULL REFERENCES public.cp3_notices(id) ON DELETE CASCADE,
 student_id uuid NOT NULL REFERENCES public.cp2_students(id),
 seen_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(notice_id,student_id)
);
CREATE INDEX IF NOT EXISTS cp3_course_term_idx ON public.cp3_courses(term_id,status);
CREATE INDEX IF NOT EXISTS cp3_course_room_idx ON public.cp3_courses(room_id,status);
CREATE INDEX IF NOT EXISTS cp3_course_staff_teacher_idx ON public.cp3_course_staff(teacher_id);
CREATE INDEX IF NOT EXISTS cp3_enrollment_student_idx ON public.cp3_enrollments(student_id,is_active);
CREATE INDEX IF NOT EXISTS cp3_notices_course_idx ON public.cp3_notices(course_id,created_at DESC);
CREATE INDEX IF NOT EXISTS cp3_notice_reads_student_idx ON public.cp3_notice_reads(student_id);
CREATE INDEX IF NOT EXISTS cp3_staff_role_idx ON public.cp3_staff(role);
DO $$ DECLARE tab text;BEGIN
 FOREACH tab IN ARRAY ARRAY[
  'cp3_staff','cp3_units','cp3_terms','cp3_courses','cp3_course_staff',
  'cp3_enrollments','cp3_notices','cp3_notice_reads'
 ] LOOP
  EXECUTE 'ALTER TABLE public.'||tab||' ENABLE ROW LEVEL SECURITY';
  EXECUTE 'REVOKE ALL ON TABLE public.'||tab||' FROM PUBLIC,anon,authenticated';
 END LOOP;
END $$;

CREATE OR REPLACE FUNCTION private.cp3_staff_role()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT role FROM public.cp3_staff
 WHERE user_id=auth.uid() AND coalesce(auth.jwt()->>'is_anonymous','false')<>'true'
$$;
CREATE OR REPLACE FUNCTION private.cp3_is_manager()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(private.cp3_staff_role() IN ('admin','registrar'),false)
$$;
CREATE OR REPLACE FUNCTION private.cp3_can_view_course(p_course uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT private.cp3_is_manager()
 OR EXISTS(SELECT 1 FROM public.cp3_courses c WHERE c.id=p_course AND
   (c.owner_id=auth.uid()
    OR EXISTS(SELECT 1 FROM public.cp3_course_staff cs WHERE cs.course_id=c.id AND cs.teacher_id=auth.uid())
    OR EXISTS(SELECT 1 FROM public.cp3_enrollments e JOIN public.cp2_students s ON s.id=e.student_id
       WHERE e.course_id=c.id AND e.is_active AND s.is_active AND s.auth_uid=auth.uid())))
$$;
CREATE OR REPLACE FUNCTION private.cp3_can_edit_course(p_course uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT private.cp3_is_manager() OR EXISTS(
 SELECT 1 FROM public.cp3_courses c WHERE c.id=p_course AND
 (c.owner_id=auth.uid() OR EXISTS(
  SELECT 1 FROM public.cp3_course_staff cs WHERE cs.course_id=c.id
  AND cs.teacher_id=auth.uid() AND cs.role='co_teacher'))
 )
$$;
CREATE OR REPLACE FUNCTION private.cp3_staff_list()
RETURNS TABLE(email text,role text,appointed_on timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT private.cp3_is_manager() THEN RAISE EXCEPTION '校務人員權限不足' USING errcode='42501'; END IF;
 RETURN QUERY SELECT u.email::text,s.role,s.created_at FROM public.cp3_staff s
 JOIN auth.users u ON u.id=s.user_id ORDER BY s.created_at DESC;
END $$;
CREATE OR REPLACE FUNCTION private.cp3_staff_set(p_email text,p_role text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_user uuid;
BEGIN
 IF private.cp3_staff_role() IS DISTINCT FROM 'admin' THEN
  RAISE EXCEPTION '只有已核准的系統管理員能更改校級角色' USING errcode='42501'; END IF;
 IF p_role IS NULL OR p_role NOT IN ('admin','registrar','teacher','auditor','remove')
 THEN RAISE EXCEPTION '校級角色值不合法'; END IF;
 IF length(trim(coalesce(p_email,''))) NOT BETWEEN 3 AND 254 THEN RAISE EXCEPTION '帳號格式錯誤'; END IF;
 SELECT id INTO v_user FROM auth.users WHERE lower(email)=lower(trim(p_email)) AND is_anonymous=false;
 IF v_user IS NULL THEN RAISE EXCEPTION '找不到已建立的校園 Auth 帳號'; END IF;
 IF v_user=auth.uid() AND p_role IN ('remove','teacher','registrar','auditor')
 THEN RAISE EXCEPTION '不能自行移除系統管理員權限'; END IF;
 IF p_role='remove' THEN DELETE FROM public.cp3_staff WHERE user_id=v_user;
 ELSE
  INSERT INTO public.cp3_staff(user_id,role,appointed_by) VALUES(v_user,p_role,auth.uid())
  ON CONFLICT(user_id) DO UPDATE SET role=excluded.role,appointed_by=excluded.appointed_by;
  IF p_role='teacher' THEN
   INSERT INTO public.cp2_teachers(user_id,label) VALUES(v_user,'教師') ON CONFLICT DO NOTHING;
  END IF;
 END IF;
 INSERT INTO public.cp2_audit(room_id,actor_uid,event,details) VALUES(
 NULL,auth.uid(),'campus.staff.change',jsonb_build_object('subject',v_user,'role',p_role));
END $$;
CREATE OR REPLACE FUNCTION private.cp3_terms_list()
RETURNS TABLE(id uuid,academic_year int,semester int,starts_on date,ends_on date,is_archived boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION '請先登入' USING errcode='42501'; END IF;
 RETURN QUERY SELECT t.id,t.academic_year,t.semester,t.starts_on,t.ends_on,t.is_archived
 FROM public.cp3_terms t ORDER BY t.academic_year DESC,t.semester DESC;
END $$;
CREATE OR REPLACE FUNCTION private.cp3_term_save(
 p_term uuid,p_year int,p_semester int,p_start date,p_end date)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_id uuid;
BEGIN
 IF NOT private.cp3_is_manager() THEN RAISE EXCEPTION '需要校務管理權限' USING errcode='42501'; END IF;
 IF p_year NOT BETWEEN 100 AND 300 OR p_semester NOT IN (1,2,3)
 OR p_start IS NULL OR p_end IS NULL OR p_end<=p_start THEN RAISE EXCEPTION '學期格式不合法'; END IF;
 IF p_term IS NULL THEN
  INSERT INTO public.cp3_terms(academic_year,semester,starts_on,ends_on)
  VALUES(p_year,p_semester,p_start,p_end) RETURNING id INTO v_id;
 ELSE
  UPDATE public.cp3_terms SET academic_year=p_year,semester=p_semester,starts_on=p_start,ends_on=p_end
   WHERE id=p_term AND NOT is_archived RETURNING id INTO v_id;
  IF v_id IS NULL THEN RAISE EXCEPTION '學期不存在或已封存'; END IF;
 END IF;
 RETURN v_id;
END $$;
CREATE OR REPLACE FUNCTION private.cp3_unit_list()
RETURNS TABLE(id uuid,parent_id uuid,kind text,code text,name text,is_active boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION '請先登入' USING errcode='42501'; END IF;
 RETURN QUERY SELECT u.id,u.parent_id,u.kind,u.code,u.name,u.is_active
 FROM public.cp3_units u ORDER BY u.kind,u.code;
END $$;
CREATE OR REPLACE FUNCTION private.cp3_unit_save(
 p_id uuid,p_parent uuid,p_kind text,p_code text,p_name text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_id uuid;
BEGIN
 IF NOT private.cp3_is_manager() THEN RAISE EXCEPTION '需要校務管理權限' USING errcode='42501'; END IF;
 IF p_kind IS NULL OR p_kind NOT IN ('campus','college','department')
 OR coalesce(p_code,'') !~ '^[A-Z0-9_-]{2,24}$'
 OR length(trim(coalesce(p_name,''))) NOT BETWEEN 1 AND 120
 THEN RAISE EXCEPTION '單位格式不合法'; END IF;
 IF (p_kind='campus' AND p_parent IS NOT NULL)
 OR (p_kind<>'campus' AND p_parent IS NULL)
 THEN RAISE EXCEPTION '所屬單位層級不合法'; END IF;
 IF p_parent IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.cp3_units
 WHERE id=p_parent AND is_active AND kind=(CASE WHEN p_kind='college' THEN 'campus' ELSE 'college' END))
 THEN RAISE EXCEPTION '上級單位不存在或層級不符'; END IF;
 IF p_id IS NULL THEN
  INSERT INTO public.cp3_units(parent_id,kind,code,name) VALUES(p_parent,p_kind,p_code,trim(p_name))
  RETURNING id INTO v_id;
 ELSE
  UPDATE public.cp3_units SET parent_id=p_parent,kind=p_kind,code=p_code,name=trim(p_name)
  WHERE id=p_id AND is_active RETURNING id INTO v_id;
  IF v_id IS NULL THEN RAISE EXCEPTION '單位不存在或已停用'; END IF;
 END IF;
 RETURN v_id;
END $$;
CREATE OR REPLACE FUNCTION private.cp3_course_save(
 p_course uuid,p_term uuid,p_department uuid,p_room uuid,p_code text,p_title text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_id uuid;v_owner uuid;
BEGIN
 IF auth.uid() IS NULL OR coalesce(auth.jwt()->>'is_anonymous','false')='true'
 THEN RAISE EXCEPTION '教職員驗證失敗' USING errcode='42501'; END IF;
 IF p_code IS NULL OR length(trim(p_code)) NOT BETWEEN 2 AND 32
 OR p_title IS NULL OR length(trim(p_title)) NOT BETWEEN 1 AND 160 THEN
  RAISE EXCEPTION '課程代碼或名稱不合法'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.cp3_terms WHERE id=p_term AND NOT is_archived)
 OR NOT EXISTS(SELECT 1 FROM public.cp3_units WHERE id=p_department AND kind='department' AND is_active)
 THEN RAISE EXCEPTION '學期或系所設定無效'; END IF;
 SELECT owner_id INTO v_owner FROM public.cp2_rooms WHERE id=p_room AND is_active;
 IF v_owner IS NULL THEN RAISE EXCEPTION '教室不存在或已停用'; END IF;
 IF p_course IS NULL THEN
  IF NOT (private.cp3_is_manager() OR v_owner=auth.uid()) THEN
    RAISE EXCEPTION '無權建立此教室課程' USING errcode='42501'; END IF;
  INSERT INTO public.cp3_courses(term_id,department_id,room_id,code,title,owner_id)
  VALUES(p_term,p_department,p_room,upper(trim(p_code)),trim(p_title),v_owner) RETURNING id INTO v_id;
 ELSE
  IF NOT private.cp3_can_edit_course(p_course) THEN RAISE EXCEPTION '無權更改課程' USING errcode='42501'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.cp3_courses WHERE id=p_course AND room_id=p_room AND status='active')
  THEN RAISE EXCEPTION '此課程已封存或無法移至其他教室'; END IF;
  UPDATE public.cp3_courses SET term_id=p_term,department_id=p_department,code=upper(trim(p_code)),
  title=trim(p_title),updated_at=clock_timestamp() WHERE id=p_course RETURNING id INTO v_id;
 END IF;
 INSERT INTO public.cp2_audit(room_id,actor_uid,event,details)
 VALUES(p_room,auth.uid(),'course.save',jsonb_build_object('course_id',v_id));
 RETURN v_id;
END $$;
CREATE OR REPLACE FUNCTION private.cp3_course_archive(p_course uuid,p_archive boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_room uuid;
BEGIN
 IF NOT private.cp3_can_edit_course(p_course) THEN RAISE EXCEPTION '無權封存課程' USING errcode='42501'; END IF;
 SELECT room_id INTO v_room FROM public.cp3_courses WHERE id=p_course FOR UPDATE;
 IF v_room IS NULL THEN RAISE EXCEPTION '課程不存在'; END IF;
 UPDATE public.cp3_courses SET status=(CASE WHEN p_archive THEN 'archived' ELSE 'active' END),
 updated_at=clock_timestamp() WHERE id=p_course;
 INSERT INTO public.cp2_audit(room_id,actor_uid,event,details)
 VALUES(v_room,auth.uid(),'course.archive',jsonb_build_object('course_id',p_course,'archived',p_archive));
END $$;
CREATE OR REPLACE FUNCTION private.cp3_course_list()
RETURNS TABLE(id uuid,term_id uuid,department_id uuid,room_id uuid,code text,title text,
 status text,owner_id uuid,term_label text,unit_label text,student_count bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION '請先登入' USING errcode='42501'; END IF;
 RETURN QUERY
 SELECT c.id,c.term_id,c.department_id,c.room_id,c.code,c.title,c.status,c.owner_id,
  (t.academic_year::text||'-'||t.semester::text),u.name,
  (SELECT count(*) FROM public.cp3_enrollments e WHERE e.course_id=c.id AND e.is_active)
 FROM public.cp3_courses c JOIN public.cp3_terms t ON t.id=c.term_id
 JOIN public.cp3_units u ON u.id=c.department_id
 WHERE private.cp3_can_view_course(c.id)
 ORDER BY t.academic_year DESC,t.semester DESC,c.code;
END $$;
CREATE OR REPLACE FUNCTION private.cp3_student_set_active(p_student uuid,p_active boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_room uuid;v_count bigint;
BEGIN
 SELECT room_id INTO v_room FROM public.cp2_students WHERE id=p_student FOR UPDATE;
 IF v_room IS NULL OR NOT(private.cp3_is_manager() OR private.cp2_owns(v_room)) THEN
  RAISE EXCEPTION '僅校務管理者或教室擁有者可以停用／恢復學生' USING errcode='42501'; END IF;
 UPDATE public.cp2_students SET is_active=p_active WHERE id=p_student;
 INSERT INTO public.cp2_audit(room_id,actor_uid,event,details)
 VALUES(v_room,auth.uid(),'student.status',jsonb_build_object('student_id',p_student,'active',p_active));
END $$;
CREATE OR REPLACE FUNCTION private.cp3_course_enroll(p_course uuid,p_student uuid,p_active boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_room uuid;v_st_room uuid;
BEGIN
 IF NOT private.cp3_can_edit_course(p_course) THEN RAISE EXCEPTION '無權修改修課名冊' USING errcode='42501'; END IF;
 SELECT room_id INTO v_room FROM public.cp3_courses WHERE id=p_course AND status='active' FOR UPDATE;
 SELECT room_id INTO v_st_room FROM public.cp2_students WHERE id=p_student AND is_active;
 IF v_room IS NULL OR v_st_room IS NULL OR v_room<>v_st_room
 THEN RAISE EXCEPTION '學生須先加入本課程教室並保持啟用'; END IF;
 INSERT INTO public.cp3_enrollments(course_id,student_id,is_active)
 VALUES(p_course,p_student,p_active)
 ON CONFLICT(course_id,student_id) DO UPDATE SET is_active=excluded.is_active;
 INSERT INTO public.cp2_audit(room_id,actor_uid,event,details)
 VALUES(v_room,auth.uid(),'course.enrollment',jsonb_build_object('course_id',p_course,'student_id',p_student,'active',p_active));
END $$;
CREATE OR REPLACE FUNCTION private.cp3_course_staff_set(p_course uuid,p_teacher_email text,p_role text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_room uuid;v_owner uuid;v_teacher uuid;
BEGIN
 SELECT room_id,owner_id INTO v_room,v_owner FROM public.cp3_courses WHERE id=p_course AND status='active' FOR UPDATE;
 IF v_room IS NULL OR NOT(private.cp3_is_manager() OR v_owner=auth.uid()) THEN
  RAISE EXCEPTION '僅課程負責教師或校務管理員可授權教師' USING errcode='42501'; END IF;
 IF p_role NOT IN ('co_teacher','assistant','auditor','remove') OR p_role IS NULL
 THEN RAISE EXCEPTION '角色不合法'; END IF;
 SELECT t.user_id INTO v_teacher FROM public.cp2_teachers t JOIN auth.users u ON u.id=t.user_id
 WHERE lower(u.email)=lower(trim(p_teacher_email));
 IF v_teacher IS NULL OR v_teacher=v_owner THEN RAISE EXCEPTION '教師帳號無效'; END IF;
 IF p_role='remove' THEN DELETE FROM public.cp3_course_staff WHERE course_id=p_course AND teacher_id=v_teacher;
 ELSE
  INSERT INTO public.cp3_course_staff(course_id,teacher_id,role) VALUES(p_course,v_teacher,p_role)
  ON CONFLICT(course_id,teacher_id) DO UPDATE SET role=excluded.role;
 END IF;
 INSERT INTO public.cp2_audit(room_id,actor_uid,event,details)
 VALUES(v_room,auth.uid(),'course.staff',jsonb_build_object('course_id',p_course,'teacher_id',v_teacher,'role',p_role));
END $$;
CREATE OR REPLACE FUNCTION private.cp3_notice_post(p_course uuid,p_subject text,p_body text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_id uuid;v_room uuid;
BEGIN
 IF NOT private.cp3_can_edit_course(p_course) THEN RAISE EXCEPTION '僅授課教師可以公告' USING errcode='42501'; END IF;
 IF length(trim(coalesce(p_subject,''))) NOT BETWEEN 1 AND 160
 OR length(trim(coalesce(p_body,''))) NOT BETWEEN 1 AND 2000 THEN RAISE EXCEPTION '公告字數不合法'; END IF;
 SELECT room_id INTO v_room FROM public.cp3_courses WHERE id=p_course AND status='active';
 IF v_room IS NULL THEN RAISE EXCEPTION '課程已封存'; END IF;
 INSERT INTO public.cp3_notices(course_id,subject,body,author_id)
 VALUES(p_course,trim(p_subject),trim(p_body),auth.uid()) RETURNING id INTO v_id;
 INSERT INTO public.cp2_audit(room_id,actor_uid,event,details)
 VALUES(v_room,auth.uid(),'notice.publish',jsonb_build_object('notice_id',v_id));
 RETURN v_id;
END $$;
CREATE OR REPLACE FUNCTION private.cp3_notice_list(p_course uuid)
RETURNS TABLE(id uuid,subject text,body text,created_at timestamptz,read_by_me boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_student uuid;
BEGIN
 IF NOT private.cp3_can_view_course(p_course) THEN RAISE EXCEPTION '沒有公告讀取權限' USING errcode='42501'; END IF;
 SELECT s.id INTO v_student FROM public.cp2_students s
 JOIN public.cp3_enrollments e ON e.student_id=s.id AND e.course_id=p_course AND e.is_active
 WHERE s.auth_uid=auth.uid() AND s.is_active LIMIT 1;
 RETURN QUERY SELECT n.id,n.subject,n.body,n.created_at,
  EXISTS(SELECT 1 FROM public.cp3_notice_reads nr WHERE nr.notice_id=n.id AND nr.student_id=v_student)
 FROM public.cp3_notices n WHERE n.course_id=p_course AND n.archived_at IS NULL
 ORDER BY n.created_at DESC LIMIT 100;
END $$;
CREATE OR REPLACE FUNCTION private.cp3_notice_mark_read(p_notice uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_course uuid;v_student uuid;
BEGIN
 SELECT course_id INTO v_course FROM public.cp3_notices WHERE id=p_notice AND archived_at IS NULL;
 SELECT s.id INTO v_student FROM public.cp2_students s
 JOIN public.cp3_enrollments e ON e.student_id=s.id AND e.course_id=v_course AND e.is_active
 WHERE s.auth_uid=auth.uid() AND s.is_active LIMIT 1;
 IF v_course IS NULL OR v_student IS NULL THEN
  RAISE EXCEPTION '無權確認公告' USING errcode='42501'; END IF;
 INSERT INTO public.cp3_notice_reads(notice_id,student_id) VALUES(p_notice,v_student)
 ON CONFLICT DO NOTHING;
END $$;
CREATE OR REPLACE FUNCTION private.cp3_dashboard()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_student boolean;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION '請先登入' USING errcode='42501'; END IF;
 v_student:=coalesce(auth.jwt()->>'is_anonymous','false')='true';
 RETURN jsonb_build_object(
  'role',CASE WHEN v_student THEN 'student' ELSE coalesce(private.cp3_staff_role(),'teacher') END,
  'courses',COALESCE((SELECT jsonb_agg(jsonb_build_object(
   'id',c.id,'code',c.code,'title',c.title,'status',c.status,
   'year',t.academic_year,'semester',t.semester,
   'students',(SELECT count(*) FROM public.cp3_enrollments e WHERE e.course_id=c.id AND e.is_active)))
   FROM public.cp3_courses c JOIN public.cp3_terms t ON t.id=c.term_id
   WHERE c.status='active' AND private.cp3_can_view_course(c.id)),'[]'::jsonb),
  'unread',COALESCE((SELECT count(*)
   FROM public.cp3_notices n JOIN public.cp3_enrollments e ON e.course_id=n.course_id AND e.is_active
   JOIN public.cp2_students s ON s.id=e.student_id AND s.is_active AND s.auth_uid=auth.uid()
   LEFT JOIN public.cp3_notice_reads nr ON nr.notice_id=n.id AND nr.student_id=s.id
   WHERE n.archived_at IS NULL AND nr.notice_id IS NULL),0)
 );
END $$;
-- Thin authenticated wrappers; role decisions happen exclusively in private server-side functions.
CREATE OR REPLACE FUNCTION public.cp3_dashboard()
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.cp3_dashboard(); $$;
CREATE OR REPLACE FUNCTION public.cp3_terms_list()
RETURNS TABLE(id uuid,academic_year int,semester int,starts_on date,ends_on date,is_archived boolean)
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT * FROM private.cp3_terms_list(); $$;
CREATE OR REPLACE FUNCTION public.cp3_term_save(p_term uuid,p_year int,p_semester int,p_start date,p_end date)
RETURNS uuid LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.cp3_term_save(p_term,p_year,p_semester,p_start,p_end); $$;
CREATE OR REPLACE FUNCTION public.cp3_unit_list()
RETURNS TABLE(id uuid,parent_id uuid,kind text,code text,name text,is_active boolean)
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT * FROM private.cp3_unit_list(); $$;
CREATE OR REPLACE FUNCTION public.cp3_unit_save(p_id uuid,p_parent uuid,p_kind text,p_code text,p_name text)
RETURNS uuid LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.cp3_unit_save(p_id,p_parent,p_kind,p_code,p_name); $$;
CREATE OR REPLACE FUNCTION public.cp3_course_list()
RETURNS TABLE(id uuid,term_id uuid,department_id uuid,room_id uuid,code text,title text,
 status text,owner_id uuid,term_label text,unit_label text,student_count bigint)
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT * FROM private.cp3_course_list(); $$;
CREATE OR REPLACE FUNCTION public.cp3_course_save(p_course uuid,p_term uuid,p_department uuid,p_room uuid,p_code text,p_title text)
RETURNS uuid LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.cp3_course_save(p_course,p_term,p_department,p_room,p_code,p_title); $$;
CREATE OR REPLACE FUNCTION public.cp3_course_archive(p_course uuid,p_archive boolean)
RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.cp3_course_archive(p_course,p_archive); $$;
CREATE OR REPLACE FUNCTION public.cp3_student_set_active(p_student uuid,p_active boolean)
RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.cp3_student_set_active(p_student,p_active); $$;
CREATE OR REPLACE FUNCTION public.cp3_course_enroll(p_course uuid,p_student uuid,p_active boolean)
RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.cp3_course_enroll(p_course,p_student,p_active); $$;
CREATE OR REPLACE FUNCTION public.cp3_course_staff_set(p_course uuid,p_teacher_email text,p_role text)
RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.cp3_course_staff_set(p_course,p_teacher_email,p_role); $$;
CREATE OR REPLACE FUNCTION public.cp3_staff_list()
RETURNS TABLE(email text,role text,appointed_on timestamptz)
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT * FROM private.cp3_staff_list(); $$;
CREATE OR REPLACE FUNCTION public.cp3_staff_set(p_email text,p_role text)
RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.cp3_staff_set(p_email,p_role); $$;
CREATE OR REPLACE FUNCTION public.cp3_notice_post(p_course uuid,p_subject text,p_body text)
RETURNS uuid LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.cp3_notice_post(p_course,p_subject,p_body); $$;
CREATE OR REPLACE FUNCTION public.cp3_notice_list(p_course uuid)
RETURNS TABLE(id uuid,subject text,body text,created_at timestamptz,read_by_me boolean)
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT * FROM private.cp3_notice_list(p_course); $$;
CREATE OR REPLACE FUNCTION public.cp3_notice_mark_read(p_notice uuid)
RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.cp3_notice_mark_read(p_notice); $$;
DO $$DECLARE f record;BEGIN
 FOR f IN SELECT p.oid::regprocedure AS signature FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname IN ('private','public') AND p.proname IN (
 'cp3_staff_role','cp3_is_manager','cp3_can_view_course','cp3_can_edit_course',
 'cp3_staff_list','cp3_staff_set','cp3_terms_list','cp3_term_save','cp3_unit_list',
 'cp3_unit_save','cp3_course_save','cp3_course_archive','cp3_course_list',
 'cp3_student_set_active','cp3_course_enroll','cp3_course_staff_set',
 'cp3_notice_post','cp3_notice_list','cp3_notice_mark_read','cp3_dashboard'
 ) LOOP
  EXECUTE 'REVOKE ALL ON FUNCTION '||f.signature||' FROM PUBLIC,anon';
  EXECUTE 'GRANT EXECUTE ON FUNCTION '||f.signature||' TO authenticated';
 END LOOP;
END $$;
COMMIT;