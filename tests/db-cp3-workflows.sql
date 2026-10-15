-- Independent integration test: run only against disposable CI PostgreSQL.
BEGIN;
WITH t AS (INSERT INTO auth.users(email) VALUES('cp3.notice.owner@example.invalid') RETURNING id)
 SELECT set_config('qa.owner',id::text,true) FROM t;
WITH t AS (INSERT INTO auth.users(email) VALUES('cp3.notice.other@example.invalid') RETURNING id)
 SELECT set_config('qa.other',id::text,true) FROM t;
INSERT INTO public.cp2_teachers(user_id,label)
 VALUES(current_setting('qa.owner')::uuid,'Class owner'),(current_setting('qa.other')::uuid,'Other teacher');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',current_setting('qa.owner'),true),
 set_config('request.jwt.claims',jsonb_build_object('sub',current_setting('qa.owner'),'role','authenticated','is_anonymous',false)::text,true);
WITH room AS (INSERT INTO public.cp2_rooms(owner_id,code,title)
 VALUES(auth.uid(),'CP3NOTE001','Notices and grades') RETURNING id)
 SELECT set_config('qa.room',id::text,true) FROM room;
SELECT set_config('qa.secret',access_code,true)
 FROM public.cp2_add_student(current_setting('qa.room')::uuid,'A1','Student');
SELECT set_config('qa.notice',public.cp3_post_notice(current_setting('qa.room')::uuid,'Deadline','Quiz closes at noon')::text,true);
SELECT public.cp3_set_grade_weights(current_setting('qa.room')::uuid,20,50,30);
DO $q$
BEGIN
 IF (SELECT (public.cp3_get_grade_weights(current_setting('qa.room')::uuid)->>'assignments')::numeric)<>30
 THEN RAISE EXCEPTION 'FAIL: grade weights not saved';END IF;
 BEGIN
 PERFORM public.cp3_set_grade_weights(current_setting('qa.room')::uuid,20,50,40);
 RAISE EXCEPTION 'FAIL: grade weights accepted sum not equal 100';
 EXCEPTION WHEN OTHERS THEN
  IF position('總和為 100' in sqlerrm)=0 THEN RAISE;END IF;
 END;
END $q$;
SELECT set_config('request.jwt.claims',jsonb_build_object('sub',current_setting('qa.owner'),'role','authenticated','is_anonymous',true)::text,true);
SELECT * FROM public.cp2_join('CP3NOTE001','A1',current_setting('qa.secret'));
SELECT count(*) AS announcements FROM public.cp3_notice_list(current_setting('qa.room')::uuid);
SELECT public.cp3_notice_read(current_setting('qa.notice')::uuid);
DO $q$
BEGIN
 IF NOT (SELECT is_read FROM public.cp3_notice_list(current_setting('qa.room')::uuid) LIMIT 1)
 THEN RAISE EXCEPTION 'FAIL: student read receipt missing';END IF;
 BEGIN
  PERFORM public.cp3_post_notice(current_setting('qa.room')::uuid,'fake','student is not a teacher');
  RAISE EXCEPTION 'FAIL: student forged announcement';
 EXCEPTION WHEN insufficient_privilege THEN NULL;END;
END $q$;
SELECT set_config('request.jwt.claim.sub',current_setting('qa.other'),true),
 set_config('request.jwt.claims',jsonb_build_object('sub',current_setting('qa.other'),'role','authenticated','is_anonymous',false)::text,true);
DO $q$
BEGIN
 BEGIN
  PERFORM public.cp3_notice_list(current_setting('qa.room')::uuid);
  RAISE EXCEPTION 'FAIL: teacher from another room read notice';
 EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN
  PERFORM public.cp3_set_grade_weights(current_setting('qa.room')::uuid,20,40,40);
  RAISE EXCEPTION 'FAIL: another teacher changed weights';
 EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN
  PERFORM count(*) FROM public.cp3_notice_reads;
  RAISE EXCEPTION 'FAIL: direct read receipt exposure';
 EXCEPTION WHEN insufficient_privilege THEN NULL;END;
END $q$;
SELECT 'PASS: announcement, student read receipt, grading weights and cross-room RLS' AS checks;
ROLLBACK;