-- ClassPoll 3.0 candidate academic workflows. Requires migration 11.
-- All DML through authenticated RPCs with server-side permission checks.
BEGIN;
CREATE OR REPLACE FUNCTION private.cp3_post_notice(p_room uuid,p_title text,p_body text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_id uuid;
BEGIN
 IF NOT private.cp2_owns(p_room) THEN RAISE EXCEPTION '只有教室擁有者可以發布公告' USING errcode='42501'; END IF;
 IF length(trim(coalesce(p_title,''))) NOT BETWEEN 1 AND 160
    OR length(trim(coalesce(p_body,''))) NOT BETWEEN 1 AND 10000
 THEN RAISE EXCEPTION '公告標題或內容格式不合法';END IF;
 INSERT INTO public.cp3_announcements(room_id,title,body,created_by)
 VALUES(p_room,trim(p_title),trim(p_body),auth.uid()) RETURNING id INTO v_id;
 INSERT INTO public.cp2_audit(room_id,actor_uid,event,details)
 VALUES(p_room,auth.uid(),'notice.publish',jsonb_build_object('notice_id',v_id));
 RETURN v_id;
END $$;
CREATE OR REPLACE FUNCTION private.cp3_notice_list(p_room uuid)
RETURNS TABLE(id uuid,title text,body text,published_at timestamptz,is_read boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_student uuid;
BEGIN
 IF NOT private.cp2_owns(p_room) THEN
  SELECT s.id INTO v_student FROM public.cp2_students s
  WHERE s.room_id=p_room AND s.auth_uid=auth.uid() AND s.is_active;
  IF v_student IS NULL THEN RAISE EXCEPTION '沒有查看公告的課堂權限' USING errcode='42501'; END IF;
 END IF;
 RETURN QUERY
 SELECT a.id,a.title,a.body,a.published_at,
   CASE WHEN v_student IS NULL THEN false ELSE EXISTS(
    SELECT 1 FROM public.cp3_notice_reads nr WHERE nr.notice_id=a.id AND nr.student_id=v_student
   ) END
 FROM public.cp3_announcements a
 WHERE a.room_id=p_room AND a.archived_at IS NULL
 ORDER BY a.published_at DESC LIMIT 100;
END $$;
CREATE OR REPLACE FUNCTION private.cp3_notice_read(p_notice uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_room uuid;v_student uuid;
BEGIN
 SELECT a.room_id INTO v_room FROM public.cp3_announcements a
 WHERE a.id=p_notice AND a.archived_at IS NULL;
 IF v_room IS NULL THEN RAISE EXCEPTION '公告不存在'; END IF;
 SELECT s.id INTO v_student FROM public.cp2_students s
 WHERE s.room_id=v_room AND s.auth_uid=auth.uid() AND s.is_active;
 IF v_student IS NULL THEN RAISE EXCEPTION '尚未通過學生名冊驗證' USING errcode='42501'; END IF;
 INSERT INTO public.cp3_notice_reads(notice_id,student_id)
 VALUES(p_notice,v_student) ON CONFLICT DO NOTHING;
END $$;
CREATE OR REPLACE FUNCTION private.cp3_set_grade_weights(p_room uuid,p_attendance numeric,p_quizzes numeric,p_assignments numeric)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_course uuid;
BEGIN
 IF NOT private.cp2_owns(p_room) THEN RAISE EXCEPTION '沒有設定評分規則的權限' USING errcode='42501'; END IF;
 IF p_attendance IS NULL OR p_quizzes IS NULL OR p_assignments IS NULL
   OR p_attendance<0 OR p_quizzes<0 OR p_assignments<0
   OR p_attendance>100 OR p_quizzes>100 OR p_assignments>100
   OR p_attendance+p_quizzes+p_assignments<>100
 THEN RAISE EXCEPTION '成績權重必須介於 0 至 100 並且總和為 100';END IF;
 INSERT INTO public.cp3_courses(room_id) VALUES(p_room)
 ON CONFLICT(room_id) DO NOTHING;
 SELECT id INTO v_course FROM public.cp3_courses WHERE room_id=p_room FOR UPDATE;
 INSERT INTO public.cp3_grade_weights(course_id,attendance,quizzes,assignments)
 VALUES(v_course,p_attendance,p_quizzes,p_assignments)
 ON CONFLICT(course_id) DO UPDATE SET
 attendance=EXCLUDED.attendance,quizzes=EXCLUDED.quizzes,assignments=EXCLUDED.assignments,updated_at=clock_timestamp();
 INSERT INTO public.cp2_audit(room_id,actor_uid,event,details)
 VALUES(p_room,auth.uid(),'grade.weights',jsonb_build_object(
 'attendance',p_attendance,'quizzes',p_quizzes,'assignments',p_assignments));
END $$;
CREATE OR REPLACE FUNCTION private.cp3_get_grade_weights(p_room uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_course uuid;v_value jsonb;
BEGIN
 IF NOT private.cp2_owns(p_room) THEN RAISE EXCEPTION '沒有檢視成績設定的權限' USING errcode='42501';END IF;
 SELECT id INTO v_course FROM public.cp3_courses WHERE room_id=p_room;
 SELECT jsonb_build_object('attendance',w.attendance,'quizzes',w.quizzes,'assignments',w.assignments)
 INTO v_value FROM public.cp3_grade_weights w WHERE w.course_id=v_course;
 RETURN coalesce(v_value,'{"attendance":20,"quizzes":80,"assignments":0}'::jsonb);
END $$;
CREATE OR REPLACE FUNCTION public.cp3_post_notice(p_room uuid,p_title text,p_body text)
RETURNS uuid LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT private.cp3_post_notice(p_room,p_title,p_body);$$;
CREATE OR REPLACE FUNCTION public.cp3_notice_list(p_room uuid)
RETURNS TABLE(id uuid,title text,body text,published_at timestamptz,is_read boolean)
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT * FROM private.cp3_notice_list(p_room);$$;
CREATE OR REPLACE FUNCTION public.cp3_notice_read(p_notice uuid)
RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT private.cp3_notice_read(p_notice);$$;
CREATE OR REPLACE FUNCTION public.cp3_set_grade_weights(p_room uuid,p_attendance numeric,p_quizzes numeric,p_assignments numeric)
RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT private.cp3_set_grade_weights(p_room,p_attendance,p_quizzes,p_assignments);$$;
CREATE OR REPLACE FUNCTION public.cp3_get_grade_weights(p_room uuid)
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT private.cp3_get_grade_weights(p_room);$$;
DO $$ DECLARE f record;BEGIN
 FOR f IN SELECT p.oid::regprocedure signature FROM pg_proc p
 JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname IN ('private','public')
 AND p.proname IN ('cp3_post_notice','cp3_notice_list','cp3_notice_read',
                   'cp3_set_grade_weights','cp3_get_grade_weights') LOOP
  EXECUTE 'REVOKE ALL ON FUNCTION '||f.signature||' FROM PUBLIC,anon';
  EXECUTE 'GRANT EXECUTE ON FUNCTION '||f.signature||' TO authenticated';
 END LOOP;
END $$;
COMMIT;