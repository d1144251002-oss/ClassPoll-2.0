-- ClassPoll 3.0 isolated positive / negative DB integration suite.
-- Run after previous SQL migrations 01,07,08,09,10,11,12 in GitHub Actions PostgreSQL.
BEGIN;
WITH a AS (INSERT INTO auth.users(email) VALUES('admin.cp3@example.invalid') RETURNING id)
 SELECT set_config('qa.admin',id::text,true) FROM a;
WITH a AS (INSERT INTO auth.users(email) VALUES('student.cp3@example.invalid') RETURNING id)
 SELECT set_config('qa.student',id::text,true) FROM a;
WITH a AS (INSERT INTO auth.users(email) VALUES('other.cp3@example.invalid') RETURNING id)
 SELECT set_config('qa.other',id::text,true) FROM a;
INSERT INTO public.cp2_teachers(user_id,label) VALUES(current_setting('qa.admin')::uuid,'Campus admin');
INSERT INTO public.cp3_staff(user_id,role) VALUES(current_setting('qa.admin')::uuid,'admin');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',current_setting('qa.admin'),true),
 set_config('request.jwt.claims',jsonb_build_object('sub',current_setting('qa.admin'),'role','authenticated','is_anonymous',false)::text,true);
SELECT set_config('qa.campus',public.cp3_unit_save(null,null,'campus','LHU','Lunghwa')::text,true);
SELECT set_config('qa.college',public.cp3_unit_save(null,current_setting('qa.campus')::uuid,'college','ENG','Engineering')::text,true);
SELECT set_config('qa.department',public.cp3_unit_save(null,current_setting('qa.college')::uuid,'department','CS','Computing')::text,true);
SELECT set_config('qa.term',public.cp3_term_save(null,115,1,'2026-09-01','2027-01-20')::text,true);
WITH x AS (INSERT INTO public.cp2_rooms(owner_id,code,title)
 VALUES(auth.uid(),'CP3INTEGR01','Course testing') RETURNING id)
 SELECT set_config('qa.room',id::text,true) FROM x;
SELECT set_config('qa.secret',access_code,true)
 FROM public.cp2_add_student(current_setting('qa.room')::uuid,'STU001','Student');
SELECT set_config('qa.course',public.cp3_course_save(null,current_setting('qa.term')::uuid,
 current_setting('qa.department')::uuid,current_setting('qa.room')::uuid,
 'CS101','Algorithms')::text,true);
SELECT public.cp3_course_enroll(current_setting('qa.course')::uuid,
 (SELECT id FROM public.cp2_students WHERE room_id=current_setting('qa.room')::uuid),true);
SELECT public.cp3_weights_set(current_setting('qa.course')::uuid,
 '{"attendance":20,"quiz":40,"assignment":40}'::jsonb);
SELECT set_config('qa.task',public.cp3_assignment_save(null,current_setting('qa.course')::uuid,'Arrays',
 'Describe arrays',clock_timestamp()-interval '10 minutes',clock_timestamp()+interval '1 hour',100,true)::text,true);
SELECT set_config('qa.notice',public.cp3_notice_post(current_setting('qa.course')::uuid,'Class notice','Bring a notebook')::text,true);
SELECT set_config('qa.student_id',(SELECT id::text FROM public.cp2_students
 WHERE room_id=current_setting('qa.room')::uuid),true);
DO $$
BEGIN
 BEGIN PERFORM public.cp3_weights_set(current_setting('qa.course')::uuid,'{"attendance":50,"quiz":40,"assignment":40}'::jsonb);
  RAISE EXCEPTION 'FAIL: invalid 130 percent weights';
 EXCEPTION WHEN OTHERS THEN
  IF position('100' in sqlerrm)=0 THEN RAISE; END IF;
 END;
END $$;
SELECT set_config('request.jwt.claim.sub',current_setting('qa.student'),true),
 set_config('request.jwt.claims',jsonb_build_object('sub',current_setting('qa.student'),'role','authenticated','is_anonymous',true)::text,true);
SELECT * FROM public.cp2_join('CP3INTEGR01','STU001',current_setting('qa.secret'));
SELECT public.cp3_assignment_submit(current_setting('qa.task')::uuid,'Time complexity is O(n).');
SELECT public.cp3_notice_mark_read(current_setting('qa.notice')::uuid);
DO $$
BEGIN
 IF (SELECT count(*) FROM public.cp3_course_list())<>1 THEN RAISE EXCEPTION 'FAIL student course view'; END IF;
 IF (SELECT count(*) FROM public.cp3_notice_list(current_setting('qa.course')::uuid) WHERE read_by_me)=0
 THEN RAISE EXCEPTION 'FAIL student mark-read'; END IF;
 BEGIN PERFORM public.cp3_course_archive(current_setting('qa.course')::uuid,true);
  RAISE EXCEPTION 'FAIL student archived course';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 BEGIN PERFORM public.cp3_grade_review(gen_random_uuid(),50,'not authorized');
  RAISE EXCEPTION 'FAIL student reviewed grades';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 BEGIN PERFORM public.cp3_staff_set('other.cp3@example.invalid','admin');
  RAISE EXCEPTION 'FAIL student elevated campus role';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 BEGIN PERFORM count(*) FROM public.cp3_grade_reviews;
  RAISE EXCEPTION 'FAIL private grade table leaked';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
SELECT set_config('request.jwt.claim.sub',current_setting('qa.admin'),true),
 set_config('request.jwt.claims',jsonb_build_object('sub',current_setting('qa.admin'),'role','authenticated','is_anonymous',false)::text,true);
SELECT set_config('qa.submission',(SELECT id::text FROM public.cp3_submission_list(current_setting('qa.task')::uuid)),true);
SELECT public.cp3_grade_review(current_setting('qa.submission')::uuid,95,'Reviewed');
DO $$
BEGIN
 IF (SELECT assignment_pct FROM public.cp3_gradebook(current_setting('qa.course')::uuid) LIMIT 1)<>95
 THEN RAISE EXCEPTION 'FAIL expected 95 percent homework score'; END IF;
END $$;
SELECT public.cp3_student_set_active(current_setting('qa.student_id')::uuid,false);
DO $$
BEGIN
 IF (SELECT is_active FROM public.cp2_students WHERE id=current_setting('qa.student_id')::uuid)
 THEN RAISE EXCEPTION 'FAIL student suspend'; END IF;
END $$;
SELECT public.cp3_student_set_active(current_setting('qa.student_id')::uuid,true);
SELECT public.cp3_course_archive(current_setting('qa.course')::uuid,true);
DO $$
BEGIN
 IF (SELECT count(*) FROM public.cp3_course_list() WHERE status='archived')<>1
 THEN RAISE EXCEPTION 'FAIL course archive'; END IF;
 IF (SELECT count(*) FROM public.cp3_submission_list(current_setting('qa.task')::uuid))<>1
 THEN RAISE EXCEPTION 'FAIL grade deleted on archive'; END IF;
END $$;
SELECT 'PASS: course, RBAC, student suspension, assignments, notices, grading and archive' AS result;
ROLLBACK;
