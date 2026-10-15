-- ClassPoll 3.0 candidate; DO NOT install on production before staging approval.
-- Non-destructive academic structure with school / department / academic year / term / course.
BEGIN;
CREATE TABLE IF NOT EXISTS public.cp3_departments (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 code text NOT NULL UNIQUE CHECK(length(code) BETWEEN 2 AND 32),
 title text NOT NULL CHECK(length(trim(title)) BETWEEN 1 AND 120),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE IF NOT EXISTS public.cp3_terms (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 academic_year text NOT NULL CHECK(academic_year ~ '^[0-9]{3,4}$'),
 term smallint NOT NULL CHECK(term IN (1,2,3)),
 starts_on date NOT NULL, ends_on date NOT NULL,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 UNIQUE(academic_year,term),CHECK(ends_on>starts_on)
);
CREATE TABLE IF NOT EXISTS public.cp3_courses (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 room_id uuid NOT NULL UNIQUE REFERENCES public.cp2_rooms(id) ON DELETE RESTRICT,
 department_id uuid REFERENCES public.cp3_departments(id) ON DELETE RESTRICT,
 term_id uuid REFERENCES public.cp3_terms(id) ON DELETE RESTRICT,
 course_code text CHECK(course_code IS NULL OR length(course_code) BETWEEN 2 AND 40),
 archived_at timestamptz,
 archived_by uuid REFERENCES public.cp2_teachers(user_id),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX IF NOT EXISTS cp3_courses_dept_term_idx ON public.cp3_courses(department_id,term_id);
CREATE TABLE IF NOT EXISTS public.cp3_course_staff (
 course_id uuid NOT NULL REFERENCES public.cp3_courses(id) ON DELETE RESTRICT,
 teacher_id uuid NOT NULL REFERENCES public.cp2_teachers(user_id) ON DELETE RESTRICT,
 role text NOT NULL CHECK(role IN ('co_teacher','assistant','auditor')),
 granted_by uuid NOT NULL REFERENCES public.cp2_teachers(user_id),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(course_id,teacher_id)
);
CREATE TABLE IF NOT EXISTS public.cp3_grade_weights (
 course_id uuid PRIMARY KEY REFERENCES public.cp3_courses(id) ON DELETE RESTRICT,
 attendance numeric(5,2) NOT NULL DEFAULT 20 CHECK(attendance>=0 AND attendance<=100),
 quizzes numeric(5,2) NOT NULL DEFAULT 80 CHECK(quizzes>=0 AND quizzes<=100),
 assignments numeric(5,2) NOT NULL DEFAULT 0 CHECK(assignments>=0 AND assignments<=100),
 updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 CHECK(attendance+quizzes+assignments=100)
);
CREATE TABLE IF NOT EXISTS public.cp3_assignments (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 course_id uuid NOT NULL REFERENCES public.cp3_courses(id) ON DELETE RESTRICT,
 title text NOT NULL CHECK(length(trim(title)) BETWEEN 1 AND 160),
 instructions text NOT NULL DEFAULT '',
 due_at timestamptz,
 published_at timestamptz,
 archived_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX IF NOT EXISTS cp3_assignments_course_due_idx ON public.cp3_assignments(course_id,due_at);
CREATE TABLE IF NOT EXISTS public.cp3_announcements (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 room_id uuid NOT NULL REFERENCES public.cp2_rooms(id) ON DELETE RESTRICT,
 title text NOT NULL CHECK(length(trim(title)) BETWEEN 1 AND 160),
 body text NOT NULL CHECK(length(body) BETWEEN 1 AND 10000),
 created_by uuid NOT NULL REFERENCES public.cp2_teachers(user_id),
 published_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 archived_at timestamptz
);
CREATE INDEX IF NOT EXISTS cp3_announcement_recent_idx ON public.cp3_announcements(room_id,published_at DESC);
CREATE TABLE IF NOT EXISTS public.cp3_notice_reads (
 notice_id uuid NOT NULL REFERENCES public.cp3_announcements(id) ON DELETE RESTRICT,
 student_id uuid NOT NULL REFERENCES public.cp2_students(id) ON DELETE RESTRICT,
 read_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(notice_id,student_id)
);
CREATE TABLE IF NOT EXISTS public.cp3_student_state (
 student_id uuid PRIMARY KEY REFERENCES public.cp2_students(id) ON DELETE RESTRICT,
 removed_at timestamptz,
 removed_by uuid REFERENCES public.cp2_teachers(user_id),
 removal_reason text CHECK(removal_reason IS NULL OR length(removal_reason)<=500)
);
DO $$ DECLARE v text;BEGIN
 FOREACH v IN ARRAY ARRAY['cp3_departments','cp3_terms','cp3_courses','cp3_course_staff',
 'cp3_grade_weights','cp3_assignments','cp3_announcements','cp3_notice_reads','cp3_student_state']
 LOOP
  EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',v);
  EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC,anon,authenticated',v);
 END LOOP;
END $$;
-- All operations run through narrowly scoped RPCs, no direct client DML.
CREATE OR REPLACE FUNCTION private.cp3_manage_student(p_student uuid,p_action text,p_reason text DEFAULT '')
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_room uuid;
BEGIN
 SELECT room_id INTO v_room FROM public.cp2_students WHERE id=p_student FOR UPDATE;
 IF v_room IS NULL OR NOT private.cp2_owns(v_room) THEN
  RAISE EXCEPTION '教室擁有者權限不足' USING errcode='42501'; END IF;
 IF p_action NOT IN ('disable','restore') OR p_action IS NULL THEN RAISE EXCEPTION '不支援的學生管理操作';END IF;
 IF p_action='disable' THEN
  UPDATE public.cp2_students SET is_active=false WHERE id=p_student;
  INSERT INTO public.cp3_student_state(student_id,removed_at,removed_by,removal_reason)
   VALUES(p_student,clock_timestamp(),auth.uid(),left(coalesce(p_reason,''),500))
   ON CONFLICT(student_id) DO UPDATE SET
    removed_at=EXCLUDED.removed_at,removed_by=EXCLUDED.removed_by,removal_reason=EXCLUDED.removal_reason;
 ELSE
  UPDATE public.cp2_students SET is_active=true WHERE id=p_student;
  UPDATE public.cp3_student_state SET removed_at=NULL,removed_by=NULL,removal_reason=NULL WHERE student_id=p_student;
 END IF;
 INSERT INTO public.cp2_audit(room_id,actor_uid,event,details)
 VALUES(v_room,auth.uid(),'student.'||p_action,jsonb_build_object('student_id',p_student,'reason',left(coalesce(p_reason,''),500)));
END $$;
CREATE OR REPLACE FUNCTION private.cp3_archive_course(p_room uuid,p_archived boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_id uuid;
BEGIN
 IF NOT private.cp2_owns(p_room) THEN RAISE EXCEPTION '僅教室擁有者能封存課程' USING errcode='42501';END IF;
 IF p_archived IS NULL THEN RAISE EXCEPTION '封存狀態不得為空';END IF;
 INSERT INTO public.cp3_courses(room_id) VALUES(p_room)
 ON CONFLICT(room_id) DO NOTHING;
 SELECT id INTO v_id FROM public.cp3_courses WHERE room_id=p_room FOR UPDATE;
 UPDATE public.cp3_courses SET archived_at=CASE WHEN p_archived THEN clock_timestamp() ELSE NULL END,
  archived_by=CASE WHEN p_archived THEN auth.uid() ELSE NULL END WHERE id=v_id;
 UPDATE public.cp2_rooms SET is_active=NOT p_archived WHERE id=p_room;
 INSERT INTO public.cp2_audit(room_id,actor_uid,event,details)
 VALUES(p_room,auth.uid(),CASE WHEN p_archived THEN 'course.archive' ELSE 'course.restore' END,
  jsonb_build_object('course_id',v_id));
END $$;
CREATE OR REPLACE FUNCTION private.cp3_course_list()
RETURNS TABLE(room_id uuid,room_code text,room_title text,course_id uuid,archived_at timestamptz,
 students bigint,department_code text,academic_year text,term smallint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT private.cp2_is_teacher() THEN RAISE EXCEPTION '請先登入授權教師帳號' USING errcode='42501';END IF;
 RETURN QUERY SELECT r.id,r.code,r.title,c.id,c.archived_at,
 (SELECT count(*) FROM public.cp2_students s WHERE s.room_id=r.id),
 d.code,t.academic_year,t.term
 FROM public.cp2_rooms r LEFT JOIN public.cp3_courses c ON c.room_id=r.id
 LEFT JOIN public.cp3_departments d ON d.id=c.department_id
 LEFT JOIN public.cp3_terms t ON t.id=c.term_id
 WHERE private.cp2_owns(r.id)
 ORDER BY r.created_at DESC;
END $$;
CREATE OR REPLACE FUNCTION public.cp3_manage_student(p_student uuid,p_action text,p_reason text DEFAULT '')
RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT private.cp3_manage_student(p_student,p_action,p_reason);$$;
CREATE OR REPLACE FUNCTION public.cp3_archive_course(p_room uuid,p_archived boolean)
RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT private.cp3_archive_course(p_room,p_archived);$$;
CREATE OR REPLACE FUNCTION public.cp3_course_list()
RETURNS TABLE(room_id uuid,room_code text,room_title text,course_id uuid,archived_at timestamptz,
 students bigint,department_code text,academic_year text,term smallint)
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT * FROM private.cp3_course_list();$$;
DO $$ DECLARE f record;BEGIN
 FOR f IN SELECT p.oid::regprocedure signature FROM pg_proc p
 JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname IN('private','public') AND p.proname IN
 ('cp3_manage_student','cp3_archive_course','cp3_course_list') LOOP
  EXECUTE 'REVOKE ALL ON FUNCTION '||f.signature||' FROM PUBLIC,anon';
  EXECUTE 'GRANT EXECUTE ON FUNCTION '||f.signature||' TO authenticated';
 END LOOP;
END $$;
COMMIT;