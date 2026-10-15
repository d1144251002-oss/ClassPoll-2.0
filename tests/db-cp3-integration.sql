-- Run exclusively in disposable PostgreSQL CI, never against production.
BEGIN;
WITH t AS (INSERT INTO auth.users(email) VALUES('cp3.owner@example.invalid') RETURNING id)
 SELECT set_config('qa.owner',id::text,true) FROM t;
WITH t AS (INSERT INTO auth.users(email) VALUES('cp3.other@example.invalid') RETURNING id)
 SELECT set_config('qa.other',id::text,true) FROM t;
INSERT INTO public.cp2_teachers(user_id,label)
 VALUES(current_setting('qa.owner')::uuid,'Owner'),(current_setting('qa.other')::uuid,'Not owner');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',current_setting('qa.owner'),true),
 set_config('request.jwt.claims',jsonb_build_object('sub',current_setting('qa.owner'),'role','authenticated','is_anonymous',false)::text,true);
WITH room AS (INSERT INTO public.cp2_rooms(owner_id,code,title)
 VALUES(auth.uid(),'CP3TEST123','ClassPoll 3.0 Integration') RETURNING id)
 SELECT set_config('qa.room',id::text,true) FROM room;
SELECT set_config('qa.student',student_id::text,true)
 FROM public.cp2_add_student(current_setting('qa.room')::uuid,'STU11','Student One');
SELECT public.cp3_archive_course(current_setting('qa.room')::uuid,true);
DO $$
BEGIN
 IF (SELECT is_active FROM public.cp2_rooms WHERE id=current_setting('qa.room')::uuid)
 THEN RAISE EXCEPTION 'FAIL: archiving left room active';END IF;
 IF (SELECT archived_at IS NULL FROM public.cp3_courses WHERE room_id=current_setting('qa.room')::uuid)
 THEN RAISE EXCEPTION 'FAIL: course archive timestamp missing';END IF;
END $$;
SELECT public.cp3_archive_course(current_setting('qa.room')::uuid,false);
SELECT public.cp3_manage_student(current_setting('qa.student')::uuid,'disable','Course withdrawal');
DO $$
BEGIN
 IF (SELECT is_active FROM public.cp2_students WHERE id=current_setting('qa.student')::uuid)
 THEN RAISE EXCEPTION 'FAIL: student was not disabled';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.cp3_student_state WHERE student_id=current_setting('qa.student')::uuid AND removed_at IS NOT NULL)
 THEN RAISE EXCEPTION 'FAIL: missing revocation audit state';END IF;
END $$;
SELECT public.cp3_manage_student(current_setting('qa.student')::uuid,'restore','Authorized restore');
DO $$
BEGIN
 IF NOT (SELECT is_active FROM public.cp2_students WHERE id=current_setting('qa.student')::uuid)
 THEN RAISE EXCEPTION 'FAIL: student not restored';END IF;
END $$;
SELECT set_config('request.jwt.claim.sub',current_setting('qa.other'),true),
 set_config('request.jwt.claims',jsonb_build_object('sub',current_setting('qa.other'),'role','authenticated','is_anonymous',false)::text,true);
DO $$
BEGIN
 BEGIN
  PERFORM public.cp3_archive_course(current_setting('qa.room')::uuid,true);
  RAISE EXCEPTION 'FAIL: cross-teacher course archive';
 EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN
  PERFORM public.cp3_manage_student(current_setting('qa.student')::uuid,'disable','unapproved');
  RAISE EXCEPTION 'FAIL: cross-teacher student management';
 EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN
  PERFORM count(*) FROM public.cp3_student_state;
  RAISE EXCEPTION 'FAIL: sensitive state direct access';
 EXCEPTION WHEN insufficient_privilege THEN NULL;END;
END $$;
SELECT 'PASS: archive, restore, student deactivation, RLS cross-teacher isolation' AS regression;
ROLLBACK;