-- Integration contract: run after 01_install, 07, 08, 09, 10 on disposable PostgreSQL.
-- All test records are rolled back even on a successful run.
BEGIN;
WITH t AS (
 INSERT INTO auth.users(email) VALUES('ci.owner@example.invalid') RETURNING id
) SELECT set_config('qa.teacher',id::text,true) FROM t;
WITH t AS (
 INSERT INTO auth.users(email) VALUES('ci.delegate@example.invalid') RETURNING id
) SELECT set_config('qa.delegate',id::text,true) FROM t;
WITH t AS (
 INSERT INTO auth.users(email,is_anonymous) VALUES('ci.student@example.invalid',true) RETURNING id
) SELECT set_config('qa.student',id::text,true) FROM t;
INSERT INTO public.cp2_teachers(user_id,label)
 VALUES(current_setting('qa.teacher')::uuid,'CI owner'),(current_setting('qa.delegate')::uuid,'CI audit');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',current_setting('qa.teacher'),true),
 set_config('request.jwt.claims',jsonb_build_object('sub',current_setting('qa.teacher'),'role','authenticated','is_anonymous',false)::text,true);
WITH room AS (
 INSERT INTO public.cp2_rooms(owner_id,code,title) VALUES(auth.uid(),'CIROOM2026','Database Integration') RETURNING id
) SELECT set_config('qa.room',id::text,true) FROM room;
SELECT set_config('qa.code',access_code,true) FROM public.cp2_add_student(
 current_setting('qa.room')::uuid,'STU1','CI Student');
SELECT count(*) AS imported FROM public.cp2_roster_import(current_setting('qa.room')::uuid,
 '[{"student_no":"STU2","display_name":"CI Student Two"},{"student_no":"STU3","display_name":"CI Inactive"}]'::jsonb);
DO $$
BEGIN
 BEGIN
  PERFORM public.cp2_roster_import(current_setting('qa.room')::uuid,
   '[{"student_no":"NEW1","display_name":"A"},{"student_no":"STU1","display_name":"Duplicate"}]'::jsonb);
  RAISE EXCEPTION 'FAIL: partial roster import';
 EXCEPTION WHEN OTHERS THEN
  IF position('已存在' in sqlerrm)=0 THEN RAISE; END IF;
 END;
 IF (SELECT count(*) FROM public.cp2_students WHERE room_id=current_setting('qa.room')::uuid)<>3 THEN
  RAISE EXCEPTION 'FAIL: roster import was not atomic'; END IF;
END $$;
SELECT set_config('qa.question',public.cp2_publish(current_setting('qa.room')::uuid,
 'What is 2+2?','["3","4"]'::jsonb,1,5,120,false)::text,true);
SELECT public.cp2_role_set(current_setting('qa.room')::uuid,'ci.delegate@example.invalid','auditor');
SELECT count(*) AS roles FROM public.cp2_role_list(current_setting('qa.room')::uuid);
SELECT set_config('request.jwt.claim.sub',current_setting('qa.student'),true),
 set_config('request.jwt.claims',jsonb_build_object('sub',current_setting('qa.student'),'role','authenticated','is_anonymous',true)::text,true);
SELECT * FROM public.cp2_join('CIROOM2026','STU1',current_setting('qa.code'));
SELECT public.cp2_vote(current_setting('qa.question')::uuid,1);
SELECT set_config('qa.qna',public.cp2_qna_post(current_setting('qa.room')::uuid,'Please explain arrays.')::text,true);
DO $$
BEGIN
 BEGIN
  PERFORM public.cp2_vote(current_setting('qa.question')::uuid,0);
  RAISE EXCEPTION 'FAIL: duplicate graded vote';
 EXCEPTION WHEN OTHERS THEN IF position('此題已作答' in sqlerrm)=0 THEN RAISE; END IF; END;
 BEGIN
  PERFORM public.cp2_qna_reply(current_setting('qa.qna')::uuid,'Student cannot answer');
  RAISE EXCEPTION 'FAIL: student replied';
 EXCEPTION WHEN OTHERS THEN IF sqlstate<>'42501' THEN RAISE; END IF; END;
 IF (SELECT count(*) FROM public.cp2_answer_keys)<>0 THEN RAISE EXCEPTION 'FAIL: answer key leaked'; END IF;
END $$;
SELECT set_config('request.jwt.claim.sub',current_setting('qa.teacher'),true),
 set_config('request.jwt.claims',jsonb_build_object('sub',current_setting('qa.teacher'),'role','authenticated','is_anonymous',false)::text,true);
SELECT public.cp2_qna_reply(current_setting('qa.qna')::uuid,'Arrays store indexed items.');
SELECT public.cp2_close(current_setting('qa.question')::uuid);
SELECT count(*) AS answered_questions FROM public.cp2_qna_list(current_setting('qa.room')::uuid,100) WHERE status='answered';
SELECT set_config('request.jwt.claim.sub',current_setting('qa.delegate'),true),
 set_config('request.jwt.claims',jsonb_build_object('sub',current_setting('qa.delegate'),'role','authenticated','is_anonymous',false)::text,true);
DO $$
BEGIN
 IF (SELECT count(*) FROM jsonb_array_elements(public.cp2_platform_overview()->'rooms'))<>1 THEN
  RAISE EXCEPTION 'FAIL: delegated room absent'; END IF;
 BEGIN PERFORM public.cp2_roster_import(current_setting('qa.room')::uuid,'[{"student_no":"E","display_name":"Escalate"}]'::jsonb);
  RAISE EXCEPTION 'FAIL: auditor modified roster';
 EXCEPTION WHEN OTHERS THEN IF sqlstate<>'42501' THEN RAISE; END IF; END;
 BEGIN PERFORM public.cp2_role_set(current_setting('qa.room')::uuid,'ci.delegate@example.invalid','assistant');
  RAISE EXCEPTION 'FAIL: auditor modified roles';
 EXCEPTION WHEN OTHERS THEN IF sqlstate<>'42501' THEN RAISE; END IF; END;
 BEGIN PERFORM count(*) FROM public.cp2_room_roles;
  RAISE EXCEPTION 'FAIL: direct access to role table';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
SELECT set_config('request.jwt.claim.sub',current_setting('qa.teacher'),true),
 set_config('request.jwt.claims',jsonb_build_object('sub',current_setting('qa.teacher'),'role','authenticated','is_anonymous',false)::text,true);
UPDATE public.cp2_students SET is_active=false WHERE room_id=current_setting('qa.room')::uuid AND student_no='STU3';
SELECT set_config('qa.clone',
 (public.cp2_room_restore_roster(public.cp2_room_snapshot(current_setting('qa.room')::uuid),
 'CICLONE2026','New test room'))->>'room_id',true);
DO $$
BEGIN
 IF (SELECT count(*) FROM public.cp2_students WHERE room_id=current_setting('qa.clone')::uuid)<>3
 THEN RAISE EXCEPTION 'FAIL: roster restore count'; END IF;
 IF (SELECT is_active FROM public.cp2_students WHERE room_id=current_setting('qa.clone')::uuid AND student_no='STU3')
 THEN RAISE EXCEPTION 'FAIL: disabled student reactivated'; END IF;
 IF (SELECT count(*) FROM public.cp2_votes v JOIN public.cp2_questions q ON q.id=v.question_id
     WHERE q.room_id=current_setting('qa.clone')::uuid)<>0
 THEN RAISE EXCEPTION 'FAIL: grades imported into new room'; END IF;
END $$;
SELECT 'PASS: RLS, roster, graded quiz, moderated Q&A, delegation and safe recovery' AS regression;
ROLLBACK;
