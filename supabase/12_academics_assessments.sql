-- ClassPoll 3.0 graded assignments, schedules and explicitly reviewed gradebook.
-- No existing grades, votes, or ballot data are changed.
BEGIN;
CREATE TABLE IF NOT EXISTS public.cp3_class_sessions(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 course_id uuid NOT NULL REFERENCES public.cp3_courses(id),
 session_on date NOT NULL,
 title text NOT NULL CHECK(length(trim(title)) BETWEEN 1 AND 100),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 UNIQUE(course_id,session_on)
);
CREATE TABLE IF NOT EXISTS public.cp3_assignments(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 course_id uuid NOT NULL REFERENCES public.cp3_courses(id),
 title text NOT NULL CHECK(length(trim(title)) BETWEEN 1 AND 160),
 instructions text NOT NULL DEFAULT '' CHECK(length(instructions)<=4000),
 opens_at timestamptz NOT NULL,
 due_at timestamptz NOT NULL,
 max_points numeric(7,2) NOT NULL CHECK(max_points>0 AND max_points<=1000),
 status text NOT NULL DEFAULT 'draft' CHECK(status IN ('draft','published','closed')),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 CHECK(due_at>opens_at)
);
CREATE TABLE IF NOT EXISTS public.cp3_submissions(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 assignment_id uuid NOT NULL REFERENCES public.cp3_assignments(id),
 student_id uuid NOT NULL REFERENCES public.cp2_students(id),
 latest_text text NOT NULL CHECK(length(latest_text) BETWEEN 1 AND 10000),
 revision int NOT NULL CHECK(revision>0),
 updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 UNIQUE(assignment_id,student_id)
);
CREATE TABLE IF NOT EXISTS public.cp3_submission_revisions(
 submission_id uuid NOT NULL REFERENCES public.cp3_submissions(id),
 revision int NOT NULL,
 content text NOT NULL CHECK(length(content) BETWEEN 1 AND 10000),
 submitted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(submission_id,revision)
);
CREATE TABLE IF NOT EXISTS public.cp3_grade_reviews(
 submission_id uuid PRIMARY KEY REFERENCES public.cp3_submissions(id),
 points numeric(7,2) NOT NULL CHECK(points>=0),
 feedback text NOT NULL DEFAULT '' CHECK(length(feedback)<=2000),
 reviewer_id uuid NOT NULL REFERENCES public.cp2_teachers(user_id),
 reviewed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE IF NOT EXISTS public.cp3_grade_weights(
 course_id uuid NOT NULL REFERENCES public.cp3_courses(id),
 category text NOT NULL CHECK(category IN ('attendance','quiz','assignment')),
 weight int NOT NULL CHECK(weight BETWEEN 0 AND 100),
 PRIMARY KEY(course_id,category)
);
-- Each course explicitly owns its own quiz and attendance measurement.
CREATE TABLE IF NOT EXISTS public.cp3_course_questions(
 course_id uuid NOT NULL REFERENCES public.cp3_courses(id),
 question_id uuid NOT NULL UNIQUE REFERENCES public.cp2_questions(id),
 PRIMARY KEY(course_id,question_id)
);
CREATE TABLE IF NOT EXISTS public.cp3_session_attendance(
 session_id uuid NOT NULL REFERENCES public.cp3_class_sessions(id),
 student_id uuid NOT NULL REFERENCES public.cp2_students(id),
 present boolean NOT NULL,
 recorded_by uuid NOT NULL REFERENCES public.cp2_teachers(user_id),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(session_id,student_id)
);
CREATE INDEX IF NOT EXISTS cp3_course_question_question_idx ON public.cp3_course_questions(question_id);
CREATE INDEX IF NOT EXISTS cp3_session_attendance_student_idx ON public.cp3_session_attendance(student_id);
CREATE INDEX IF NOT EXISTS cp3_sessions_course_idx ON public.cp3_class_sessions(course_id,session_on);
CREATE INDEX IF NOT EXISTS cp3_assignments_course_idx ON public.cp3_assignments(course_id,status,due_at);
CREATE INDEX IF NOT EXISTS cp3_submissions_student_idx ON public.cp3_submissions(student_id,assignment_id);
CREATE INDEX IF NOT EXISTS cp3_revisions_submitted_idx ON public.cp3_submission_revisions(submitted_at);
DO $$ DECLARE tab text;BEGIN
 FOREACH tab IN ARRAY ARRAY[
 'cp3_class_sessions','cp3_assignments','cp3_submissions',
 'cp3_submission_revisions','cp3_grade_reviews','cp3_grade_weights',
 'cp3_course_questions','cp3_session_attendance'
 ] LOOP
  EXECUTE 'ALTER TABLE public.'||tab||' ENABLE ROW LEVEL SECURITY';
  EXECUTE 'REVOKE ALL ON TABLE public.'||tab||' FROM PUBLIC,anon,authenticated';
 END LOOP;
END $$;
CREATE OR REPLACE FUNCTION private.cp3_session_save(p_course uuid,p_date date,p_title text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_id uuid;
BEGIN
 IF NOT private.cp3_can_edit_course(p_course) THEN RAISE EXCEPTION '沒有課程管理權限' USING errcode='42501'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.cp3_courses WHERE id=p_course AND status='active') THEN RAISE EXCEPTION '課程已封存'; END IF;
 IF p_date IS NULL OR length(trim(coalesce(p_title,''))) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION '課次日期或名稱不合法'; END IF;
 INSERT INTO public.cp3_class_sessions(course_id,session_on,title) VALUES(p_course,p_date,trim(p_title))
 ON CONFLICT(course_id,session_on) DO UPDATE SET title=excluded.title
 RETURNING id INTO v_id;
 RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION private.cp3_sessions_list(p_course uuid)
RETURNS TABLE(id uuid,session_on date,title text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $
BEGIN
 IF NOT private.cp3_can_view_course(p_course) THEN RAISE EXCEPTION '沒有課程讀取權限' USING errcode='42501'; END IF;
 RETURN QUERY SELECT s.id,s.session_on,s.title FROM public.cp3_class_sessions s
 WHERE s.course_id=p_course ORDER BY s.session_on DESC LIMIT 200;
END $;
CREATE OR REPLACE FUNCTION private.cp3_attendance_set(p_session uuid,p_student uuid,p_present boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $
DECLARE v_course uuid;v_room uuid;
BEGIN
 SELECT course_id INTO v_course FROM public.cp3_class_sessions WHERE id=p_session;
 IF v_course IS NULL OR NOT private.cp3_can_edit_course(v_course) THEN
  RAISE EXCEPTION '課次不存在或教師權限不足' USING errcode='42501'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.cp3_enrollments WHERE course_id=v_course AND student_id=p_student AND is_active)
 THEN RAISE EXCEPTION '學生不是此課程的有效修課者'; END IF;
 INSERT INTO public.cp3_session_attendance(session_id,student_id,present,recorded_by)
 VALUES(p_session,p_student,p_present,auth.uid())
 ON CONFLICT(session_id,student_id) DO UPDATE SET present=excluded.present,recorded_by=excluded.recorded_by;
 SELECT room_id INTO v_room FROM public.cp3_courses WHERE id=v_course;
 INSERT INTO public.cp2_audit(room_id,actor_uid,event,details)
 VALUES(v_room,auth.uid(),'course.attendance',jsonb_build_object('session_id',p_session,'student_id',p_student,'present',p_present));
END $;
CREATE OR REPLACE FUNCTION private.cp3_course_question_link(p_course uuid,p_question uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $
DECLARE v_room uuid;v_question_room uuid;
BEGIN
 IF NOT private.cp3_can_edit_course(p_course) THEN RAISE EXCEPTION '無權將試題加入課程' USING errcode='42501'; END IF;
 SELECT room_id INTO v_room FROM public.cp3_courses WHERE id=p_course AND status='active';
 SELECT room_id INTO v_question_room FROM public.cp2_questions WHERE id=p_question;
 IF v_room IS NULL OR v_question_room IS NULL OR v_room<>v_question_room
 THEN RAISE EXCEPTION '題目和課程必須屬於同一教室'; END IF;
 INSERT INTO public.cp3_course_questions(course_id,question_id) VALUES(p_course,p_question)
 ON CONFLICT DO NOTHING;
END $;
CREATE OR REPLACE FUNCTION private.cp3_assignment_save(
 p_id uuid,p_course uuid,p_title text,p_instructions text,p_opens timestamptz,
 p_due timestamptz,p_points numeric,p_publish boolean)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_id uuid;v_status text;v_existing boolean;
BEGIN
 IF NOT private.cp3_can_edit_course(p_course) THEN RAISE EXCEPTION '課程寫入權限不足' USING errcode='42501'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.cp3_courses WHERE id=p_course AND status='active') THEN RAISE EXCEPTION '課程已封存'; END IF;
 IF length(trim(coalesce(p_title,''))) NOT BETWEEN 1 AND 160 OR length(coalesce(p_instructions,''))>4000
 OR p_opens IS NULL OR p_due IS NULL OR p_due<=p_opens
 OR p_points IS NULL OR p_points<=0 OR p_points>1000 THEN RAISE EXCEPTION '作業資料不合法'; END IF;
 IF p_id IS NULL THEN
  INSERT INTO public.cp3_assignments(course_id,title,instructions,opens_at,due_at,max_points,status)
  VALUES(p_course,trim(p_title),coalesce(p_instructions,''),p_opens,p_due,p_points,
   CASE WHEN p_publish THEN 'published' ELSE 'draft' END) RETURNING id INTO v_id;
 ELSE
  SELECT status INTO v_status FROM public.cp3_assignments
  WHERE id=p_id AND course_id=p_course FOR UPDATE;
  IF v_status IS NULL OR v_status='closed' THEN RAISE EXCEPTION '找不到可編輯的作業'; END IF;
  SELECT EXISTS(SELECT 1 FROM public.cp3_submissions WHERE assignment_id=p_id) INTO v_existing;
  IF v_existing AND (SELECT title<>trim(p_title) OR instructions<>coalesce(p_instructions,'')
                    OR opens_at<>p_opens OR due_at<>p_due OR max_points<>p_points
                   FROM public.cp3_assignments WHERE id=p_id) THEN
    RAISE EXCEPTION '已收到繳交的作業不能修改內容與評分規則'; END IF;
  UPDATE public.cp3_assignments SET title=trim(p_title),instructions=coalesce(p_instructions,''),
   opens_at=p_opens,due_at=p_due,max_points=p_points,
   status=CASE WHEN p_publish THEN 'published' ELSE status END WHERE id=p_id
  RETURNING id INTO v_id;
 END IF;
 INSERT INTO public.cp2_audit(room_id,actor_uid,event,details)
 SELECT room_id,auth.uid(),'assignment.save',jsonb_build_object('assignment_id',v_id)
 FROM public.cp3_courses WHERE id=p_course;
 RETURN v_id;
END $$;
CREATE OR REPLACE FUNCTION private.cp3_assignment_list(p_course uuid)
RETURNS TABLE(id uuid,title text,instructions text,opens_at timestamptz,due_at timestamptz,
 max_points numeric,status text,submitted boolean,reviewed_points numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_is_staff boolean;
BEGIN
 IF NOT private.cp3_can_view_course(p_course) THEN RAISE EXCEPTION '無權閱讀課程作業' USING errcode='42501'; END IF;
 v_is_staff:=private.cp3_can_edit_course(p_course) OR EXISTS(
  SELECT 1 FROM public.cp3_course_staff cs WHERE cs.course_id=p_course AND cs.teacher_id=auth.uid());
 RETURN QUERY SELECT a.id,a.title,a.instructions,a.opens_at,a.due_at,a.max_points,a.status,
   EXISTS(SELECT 1 FROM public.cp3_submissions s JOIN public.cp2_students st ON st.id=s.student_id
          WHERE s.assignment_id=a.id AND st.auth_uid=auth.uid()),
   (SELECT g.points FROM public.cp3_grade_reviews g
    JOIN public.cp3_submissions s ON s.id=g.submission_id
    JOIN public.cp2_students st ON st.id=s.student_id
    WHERE s.assignment_id=a.id AND st.auth_uid=auth.uid())
 FROM public.cp3_assignments a
 WHERE a.course_id=p_course AND (v_is_staff OR a.status<>'draft')
 ORDER BY a.due_at DESC LIMIT 200;
END $$;
CREATE OR REPLACE FUNCTION private.cp3_assignment_submit(p_assignment uuid,p_text text)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_a public.cp3_assignments%rowtype;v_st uuid;v_sid uuid;v_revision int;v_reviewed boolean;
BEGIN
 IF coalesce(auth.jwt()->>'is_anonymous','false')<>'true' THEN RAISE EXCEPTION '需已入班的學生身分' USING errcode='42501'; END IF;
 SELECT * INTO v_a FROM public.cp3_assignments WHERE id=p_assignment FOR UPDATE;
 IF NOT FOUND OR v_a.status<>'published' OR clock_timestamp() NOT BETWEEN v_a.opens_at AND v_a.due_at
 THEN RAISE EXCEPTION '作業未開放或已截止'; END IF;
 IF length(trim(coalesce(p_text,''))) NOT BETWEEN 1 AND 10000 THEN RAISE EXCEPTION '繳交內容需介於 1 至 10000 字'; END IF;
 SELECT s.id INTO v_st FROM public.cp2_students s JOIN public.cp3_enrollments e
 ON e.student_id=s.id AND e.course_id=v_a.course_id AND e.is_active
 WHERE s.auth_uid=auth.uid() AND s.is_active LIMIT 1;
 IF v_st IS NULL THEN RAISE EXCEPTION '你不在本課程名冊' USING errcode='42501'; END IF;
 SELECT s.id,s.revision INTO v_sid,v_revision FROM public.cp3_submissions s
 WHERE s.assignment_id=p_assignment AND s.student_id=v_st FOR UPDATE;
 v_reviewed:=v_sid IS NOT NULL AND EXISTS(SELECT 1 FROM public.cp3_grade_reviews WHERE submission_id=v_sid);
 IF v_reviewed THEN RAISE EXCEPTION '已完成教師批改，禁止重新繳交'; END IF;
 IF v_sid IS NULL THEN
  v_revision:=1;
  INSERT INTO public.cp3_submissions(assignment_id,student_id,latest_text,revision)
  VALUES(p_assignment,v_st,trim(p_text),v_revision) RETURNING id INTO v_sid;
 ELSE
  v_revision:=v_revision+1;
  UPDATE public.cp3_submissions SET latest_text=trim(p_text),revision=v_revision,updated_at=clock_timestamp()
  WHERE id=v_sid;
 END IF;
 INSERT INTO public.cp3_submission_revisions(submission_id,revision,content)
 VALUES(v_sid,v_revision,trim(p_text));
 RETURN v_revision;
END $$;
CREATE OR REPLACE FUNCTION private.cp3_submission_list(p_assignment uuid)
RETURNS TABLE(id uuid,student_no text,display_name text,latest_text text,revision int,
 submitted_at timestamptz,points numeric,feedback text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_course uuid;
BEGIN
 SELECT a.course_id INTO v_course FROM public.cp3_assignments a WHERE a.id=p_assignment;
 IF v_course IS NULL OR NOT private.cp3_can_edit_course(v_course)
 THEN RAISE EXCEPTION '沒有閱卷權限' USING errcode='42501'; END IF;
 RETURN QUERY SELECT s.id,st.student_no,st.display_name,s.latest_text,s.revision,
 s.updated_at,g.points,g.feedback FROM public.cp3_submissions s
 JOIN public.cp2_students st ON st.id=s.student_id
 LEFT JOIN public.cp3_grade_reviews g ON g.submission_id=s.id
 WHERE s.assignment_id=p_assignment ORDER BY st.student_no;
END $$;
CREATE OR REPLACE FUNCTION private.cp3_grade_review(p_submission uuid,p_points numeric,p_feedback text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_course uuid;v_max numeric;v_room uuid;
BEGIN
 SELECT a.course_id,a.max_points INTO v_course,v_max FROM public.cp3_submissions s
 JOIN public.cp3_assignments a ON a.id=s.assignment_id WHERE s.id=p_submission FOR UPDATE OF s;
 IF v_course IS NULL OR NOT private.cp3_can_edit_course(v_course)
 THEN RAISE EXCEPTION '沒有評分權限' USING errcode='42501'; END IF;
 IF p_points IS NULL OR p_points<0 OR p_points>v_max OR length(coalesce(p_feedback,''))>2000
 THEN RAISE EXCEPTION '評分超過此作業滿分或回饋過長'; END IF;
 INSERT INTO public.cp3_grade_reviews(submission_id,points,feedback,reviewer_id)
 VALUES(p_submission,p_points,coalesce(p_feedback,''),auth.uid())
 ON CONFLICT(submission_id) DO UPDATE SET points=excluded.points,feedback=excluded.feedback,
 reviewer_id=excluded.reviewer_id,reviewed_at=clock_timestamp();
 SELECT room_id INTO v_room FROM public.cp3_courses WHERE id=v_course;
 INSERT INTO public.cp2_audit(room_id,actor_uid,event,details)
 VALUES(v_room,auth.uid(),'grade.review',jsonb_build_object('submission_id',p_submission,'points',p_points));
END $$;
CREATE OR REPLACE FUNCTION private.cp3_weights_set(p_course uuid,p_weights jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_count int;v_total int;
BEGIN
 IF NOT private.cp3_can_edit_course(p_course) THEN RAISE EXCEPTION '沒有評分設定權限' USING errcode='42501'; END IF;
 IF p_weights IS NULL OR jsonb_typeof(p_weights)<>'object'
  OR (SELECT count(*) FROM jsonb_object_keys(p_weights))<>3
  OR NOT p_weights ?& ARRAY['attendance','quiz','assignment'] THEN
  RAISE EXCEPTION '成績比例必須包含出席、測驗、作業'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_each_text(p_weights) e
 WHERE e.key NOT IN ('attendance','quiz','assignment')
 OR e.value !~ '^[0-9]{1,3}$' OR e.value::integer>100) THEN
  RAISE EXCEPTION '權重必須是 0 至 100 的整數'; END IF;
 SELECT sum(value::integer) INTO v_total FROM jsonb_each_text(p_weights);
 IF v_total<>100 THEN RAISE EXCEPTION '成績權重加總必須等於 100'; END IF;
 INSERT INTO public.cp3_grade_weights(course_id,category,weight)
 SELECT p_course,key,value::integer FROM jsonb_each_text(p_weights)
 ON CONFLICT(course_id,category) DO UPDATE SET weight=excluded.weight;
 INSERT INTO public.cp2_audit(room_id,actor_uid,event,details)
 SELECT room_id,auth.uid(),'grade.weights.update',p_weights FROM public.cp3_courses WHERE id=p_course;
END $$;
CREATE OR REPLACE FUNCTION private.cp3_gradebook(p_course uuid)
RETURNS TABLE(student_no text,display_name text,attendance_pct numeric,
 quiz_pct numeric,assignment_pct numeric,final_pct numeric,
 reviewed_assignments bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE wa int;wq int;wh int;
BEGIN
 IF NOT private.cp3_can_edit_course(p_course) THEN RAISE EXCEPTION '沒有讀取成績簿權限' USING errcode='42501'; END IF;
 SELECT COALESCE((SELECT weight FROM public.cp3_grade_weights WHERE course_id=p_course AND category='attendance'),20),
 COALESCE((SELECT weight FROM public.cp3_grade_weights WHERE course_id=p_course AND category='quiz'),40),
 COALESCE((SELECT weight FROM public.cp3_grade_weights WHERE course_id=p_course AND category='assignment'),40)
 INTO wa,wq,wh;
 RETURN QUERY
 WITH base AS (SELECT st.id,st.student_no,st.display_name,c.room_id
  FROM public.cp3_enrollments e JOIN public.cp2_students st ON st.id=e.student_id
  JOIN public.cp3_courses c ON c.id=e.course_id
  WHERE e.course_id=p_course AND e.is_active),
 computed AS(
 SELECT b.id,b.student_no,b.display_name,
  CASE WHEN (SELECT count(*) FROM public.cp3_class_sessions x WHERE x.course_id=p_course)=0
  THEN NULL::numeric ELSE
   round(100.0*(SELECT count(*) FROM public.cp3_class_sessions x
   JOIN public.cp3_session_attendance att ON att.session_id=x.id AND att.student_id=b.id AND att.present
   WHERE x.course_id=p_course)/
   (SELECT count(*) FROM public.cp3_class_sessions x WHERE x.course_id=p_course),2) END AS ap,
  CASE WHEN (SELECT COALESCE(sum(q.points),0) FROM public.cp3_course_questions link
      JOIN public.cp2_questions q ON q.id=link.question_id WHERE link.course_id=p_course AND q.status='closed')=0 THEN NULL::numeric
  ELSE round(100.0*(SELECT COALESCE(sum(CASE WHEN v.choice=k.correct_index THEN q.points ELSE 0 END),0)
    FROM public.cp2_votes v JOIN public.cp2_questions q ON q.id=v.question_id
    JOIN public.cp3_course_questions link ON link.question_id=q.id AND link.course_id=p_course
    JOIN public.cp2_answer_keys k ON k.question_id=q.id WHERE v.student_id=b.id
    AND q.status='closed')/
    (SELECT sum(q.points) FROM public.cp3_course_questions link
      JOIN public.cp2_questions q ON q.id=link.question_id
      WHERE link.course_id=p_course AND q.status='closed'),2) END AS qp,
  CASE WHEN (SELECT COALESCE(sum(a.max_points),0) FROM public.cp3_assignments a
    WHERE a.course_id=p_course AND a.status<>'draft')=0 THEN NULL::numeric
  ELSE round(100.0*(SELECT COALESCE(sum(g.points),0) FROM public.cp3_submissions s
     JOIN public.cp3_grade_reviews g ON g.submission_id=s.id
     JOIN public.cp3_assignments a ON a.id=s.assignment_id
     WHERE s.student_id=b.id AND a.course_id=p_course AND a.status<>'draft')/
    (SELECT sum(a.max_points) FROM public.cp3_assignments a
     WHERE a.course_id=p_course AND a.status<>'draft'),2) END AS hp,
  (SELECT count(*) FROM public.cp3_submissions s JOIN public.cp3_grade_reviews g ON g.submission_id=s.id
   JOIN public.cp3_assignments a ON a.id=s.assignment_id
   WHERE s.student_id=b.id AND a.course_id=p_course) AS review_count
 FROM base b
 )
 SELECT c.student_no,c.display_name,c.ap,c.qp,c.hp,
 CASE WHEN (wa>0 AND c.ap IS NULL) OR (wq>0 AND c.qp IS NULL) OR (wh>0 AND c.hp IS NULL)
 THEN NULL::numeric ELSE round((coalesce(c.ap,0)*wa+coalesce(c.qp,0)*wq+coalesce(c.hp,0)*wh)/100.0,2) END,
 c.review_count FROM computed c ORDER BY c.student_no;
END $$;
-- Publication of grades outside ClassPoll is manual, never automated by these APIs.
CREATE OR REPLACE FUNCTION public.cp3_session_save(p_course uuid,p_date date,p_title text)
RETURNS uuid LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.cp3_session_save(p_course,p_date,p_title); $$;
CREATE OR REPLACE FUNCTION public.cp3_sessions_list(p_course uuid)
RETURNS TABLE(id uuid,session_on date,title text)
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $ SELECT * FROM private.cp3_sessions_list(p_course); $;
CREATE OR REPLACE FUNCTION public.cp3_attendance_set(p_session uuid,p_student uuid,p_present boolean)
RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $
 SELECT private.cp3_attendance_set(p_session,p_student,p_present); $;
CREATE OR REPLACE FUNCTION public.cp3_course_question_link(p_course uuid,p_question uuid)
RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $
 SELECT private.cp3_course_question_link(p_course,p_question); $;
CREATE OR REPLACE FUNCTION public.cp3_assignment_save(p_id uuid,p_course uuid,p_title text,p_instructions text,
 p_opens timestamptz,p_due timestamptz,p_points numeric,p_publish boolean)
RETURNS uuid LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT private.cp3_assignment_save(p_id,p_course,p_title,p_instructions,p_opens,p_due,p_points,p_publish); $$;
CREATE OR REPLACE FUNCTION public.cp3_assignment_list(p_course uuid)
RETURNS TABLE(id uuid,title text,instructions text,opens_at timestamptz,due_at timestamptz,
 max_points numeric,status text,submitted boolean,reviewed_points numeric)
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT * FROM private.cp3_assignment_list(p_course); $$;
CREATE OR REPLACE FUNCTION public.cp3_assignment_submit(p_assignment uuid,p_text text)
RETURNS int LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT private.cp3_assignment_submit(p_assignment,p_text); $$;
CREATE OR REPLACE FUNCTION public.cp3_submission_list(p_assignment uuid)
RETURNS TABLE(id uuid,student_no text,display_name text,latest_text text,revision int,
 submitted_at timestamptz,points numeric,feedback text)
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT * FROM private.cp3_submission_list(p_assignment); $$;
CREATE OR REPLACE FUNCTION public.cp3_grade_review(p_submission uuid,p_points numeric,p_feedback text)
RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT private.cp3_grade_review(p_submission,p_points,p_feedback); $$;
CREATE OR REPLACE FUNCTION public.cp3_weights_set(p_course uuid,p_weights jsonb)
RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT private.cp3_weights_set(p_course,p_weights); $$;
CREATE OR REPLACE FUNCTION public.cp3_gradebook(p_course uuid)
RETURNS TABLE(student_no text,display_name text,attendance_pct numeric,
 quiz_pct numeric,assignment_pct numeric,final_pct numeric,reviewed_assignments bigint)
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT * FROM private.cp3_gradebook(p_course); $$;
DO $$DECLARE f record;BEGIN
 FOR f IN SELECT p.oid::regprocedure AS signature FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname IN('private','public') AND p.proname IN (
 'cp3_session_save','cp3_assignment_save','cp3_assignment_list','cp3_assignment_submit',
 'cp3_submission_list','cp3_grade_review','cp3_weights_set','cp3_gradebook',
 'cp3_sessions_list','cp3_attendance_set','cp3_course_question_link') LOOP
  EXECUTE 'REVOKE ALL ON FUNCTION '||f.signature||' FROM PUBLIC,anon';
  EXECUTE 'GRANT EXECUTE ON FUNCTION '||f.signature||' TO authenticated';
 END LOOP;
END $$;
COMMIT;