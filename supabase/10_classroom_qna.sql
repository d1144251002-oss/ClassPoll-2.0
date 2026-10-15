-- ClassPoll 2.0: moderated classroom Q&A (separate from graded polls and formal ballots).
-- Deploy only after PR review. Content is never directly selectable over PostgREST tables.
BEGIN;
CREATE TABLE IF NOT EXISTS public.cp2_inquiries(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 room_id uuid NOT NULL REFERENCES public.cp2_rooms(id) ON DELETE CASCADE,
 student_id uuid NOT NULL REFERENCES public.cp2_students(id) ON DELETE CASCADE,
 body text NOT NULL CHECK(length(trim(body)) BETWEEN 1 AND 1000),
 answer text CHECK(answer IS NULL OR length(trim(answer)) BETWEEN 1 AND 2000),
 status text NOT NULL DEFAULT 'open' CHECK(status IN ('open','answered','archived')),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 answered_at timestamptz,
 updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX IF NOT EXISTS cp2_inquiries_room_time_idx ON public.cp2_inquiries(room_id,created_at DESC);
CREATE INDEX IF NOT EXISTS cp2_inquiries_student_time_idx ON public.cp2_inquiries(student_id,created_at DESC);
ALTER TABLE public.cp2_inquiries ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.cp2_inquiries FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION private.cp2_qna_post(p_room uuid,p_body text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_student uuid; v_id uuid; v_text text;
BEGIN
 IF auth.uid() IS NULL OR coalesce(auth.jwt()->>'is_anonymous','false')<>'true' THEN
  RAISE EXCEPTION '請使用已入班的學生身分' USING errcode='42501'; END IF;
 v_text:=trim(coalesce(p_body,''));
 IF length(v_text) NOT BETWEEN 1 AND 1000 THEN RAISE EXCEPTION '問題內容需介於 1 至 1000 字'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.cp2_rooms r WHERE r.id=p_room AND r.is_active)
 THEN RAISE EXCEPTION '教室目前不可使用'; END IF;
 SELECT s.id INTO v_student FROM public.cp2_students s
 WHERE s.room_id=p_room AND s.auth_uid=auth.uid() AND s.is_active;
 IF v_student IS NULL THEN RAISE EXCEPTION '尚未通過學生名冊驗證' USING errcode='42501'; END IF;
 -- Serialize submissions per student to make the per-hour limit effective under concurrency.
 PERFORM 1 FROM public.cp2_students s WHERE s.id=v_student FOR UPDATE;
 IF (SELECT count(*) FROM public.cp2_inquiries i WHERE i.student_id=v_student
     AND i.created_at>clock_timestamp()-interval '1 hour')>=10 THEN
  RAISE EXCEPTION '每位學生每小時最多提出 10 個問題'; END IF;
 IF EXISTS(SELECT 1 FROM public.cp2_inquiries i WHERE i.student_id=v_student
       AND i.body=v_text AND i.created_at>clock_timestamp()-interval '30 seconds')
 THEN RAISE EXCEPTION '請勿在 30 秒內重複提交相同問題'; END IF;
 INSERT INTO public.cp2_inquiries(room_id,student_id,body)
 VALUES(p_room,v_student,v_text) RETURNING id INTO v_id;
 RETURN v_id;
END $$;
CREATE OR REPLACE FUNCTION private.cp2_qna_list(p_room uuid,p_limit integer DEFAULT 100)
RETURNS TABLE(id uuid,student_no text,display_name text,body text,answer text,status text,
 created_at timestamptz,answered_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_owner boolean;v_student uuid;
BEGIN
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION '查詢筆數不合法'; END IF;
 v_owner:=private.cp2_owns(p_room);
 IF NOT v_owner THEN
  SELECT s.id INTO v_student FROM public.cp2_students s
  WHERE s.room_id=p_room AND s.auth_uid=auth.uid() AND s.is_active;
  IF v_student IS NULL THEN RAISE EXCEPTION '沒有此教室的問答查詢權限' USING errcode='42501'; END IF;
 END IF;
 RETURN QUERY SELECT q.id,s.student_no,s.display_name,q.body,q.answer,q.status,q.created_at,q.answered_at
 FROM public.cp2_inquiries q JOIN public.cp2_students s ON s.id=q.student_id
 WHERE q.room_id=p_room AND (v_owner OR q.student_id=v_student)
 ORDER BY q.created_at DESC LIMIT p_limit;
END $$;
CREATE OR REPLACE FUNCTION private.cp2_qna_reply(p_question uuid,p_answer text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_room uuid;v_text text;
BEGIN
 v_text:=trim(coalesce(p_answer,''));
 IF length(v_text) NOT BETWEEN 1 AND 2000 THEN RAISE EXCEPTION '回覆需介於 1 至 2000 字'; END IF;
 SELECT q.room_id INTO v_room FROM public.cp2_inquiries q WHERE q.id=p_question FOR UPDATE;
 IF v_room IS NULL OR NOT private.cp2_owns(v_room) THEN RAISE EXCEPTION '只有授課教師能回覆' USING errcode='42501'; END IF;
 IF EXISTS(SELECT 1 FROM public.cp2_inquiries WHERE id=p_question AND status='archived') THEN
  RAISE EXCEPTION '封存問題無法再回覆'; END IF;
 UPDATE public.cp2_inquiries SET answer=v_text,status='answered',
   answered_at=clock_timestamp(),updated_at=clock_timestamp() WHERE id=p_question;
 INSERT INTO public.cp2_audit(room_id,actor_uid,event,details)
 VALUES(v_room,auth.uid(),'qna.reply',jsonb_build_object('question_id',p_question));
END $$;
CREATE OR REPLACE FUNCTION private.cp2_qna_archive(p_question uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_room uuid;
BEGIN
 SELECT q.room_id INTO v_room FROM public.cp2_inquiries q WHERE q.id=p_question FOR UPDATE;
 IF v_room IS NULL OR NOT private.cp2_owns(v_room) THEN RAISE EXCEPTION '只有授課教師能封存' USING errcode='42501'; END IF;
 UPDATE public.cp2_inquiries SET status='archived',updated_at=clock_timestamp() WHERE id=p_question;
 INSERT INTO public.cp2_audit(room_id,actor_uid,event,details)
 VALUES(v_room,auth.uid(),'qna.archive',jsonb_build_object('question_id',p_question));
END $$;
-- Include the Q&A history in encrypted owner-only classroom exports.
CREATE OR REPLACE FUNCTION private.cp2_room_snapshot(p_room uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_r record;
BEGIN
 IF NOT private.cp2_owns(p_room) THEN RAISE EXCEPTION '只有教室擁有者可匯出完整備份' USING errcode='42501'; END IF;
 SELECT r.code,r.title INTO v_r FROM public.cp2_rooms r WHERE r.id=p_room;
 RETURN jsonb_build_object(
   'format','classpoll-room-backup-v1','exported_at',clock_timestamp(),
   'room',jsonb_build_object('code',v_r.code,'title',v_r.title),
   'students',COALESCE((SELECT jsonb_agg(jsonb_build_object('student_no',s.student_no,'display_name',s.display_name,'active',s.is_active))
                    FROM public.cp2_students s WHERE s.room_id=p_room),'[]'::jsonb),
   'attendance',COALESCE((SELECT jsonb_agg(jsonb_build_object('student_no',s.student_no,'date',a.attended_on,'first_seen',a.first_seen))
                    FROM public.cp2_attendance a JOIN public.cp2_students s ON s.id=a.student_id WHERE a.room_id=p_room),'[]'::jsonb),
   'questions',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',q.id,'prompt',q.prompt,'options',q.options,
     'points',q.points,'status',q.status,'created_at',q.created_at,'correct_index',k.correct_index))
     FROM public.cp2_questions q LEFT JOIN public.cp2_answer_keys k ON k.question_id=q.id WHERE q.room_id=p_room),'[]'::jsonb),
   'answers',COALESCE((SELECT jsonb_agg(jsonb_build_object('question_id',v.question_id,'student_no',s.student_no,
     'choice',v.choice,'created_at',v.created_at))
     FROM public.cp2_votes v JOIN public.cp2_students s ON s.id=v.student_id
     JOIN public.cp2_questions q ON q.id=v.question_id WHERE q.room_id=p_room),'[]'::jsonb),
   'audit',COALESCE((SELECT jsonb_agg(jsonb_build_object('at',a.created_at,'event',a.event,'details',a.details))
     FROM public.cp2_audit a WHERE a.room_id=p_room),'[]'::jsonb),
   'inquiries',COALESCE((SELECT jsonb_agg(jsonb_build_object('student_no',s.student_no,
     'question',i.body,'answer',i.answer,'status',i.status,'created_at',i.created_at,
     'answered_at',i.answered_at))
     FROM public.cp2_inquiries i JOIN public.cp2_students s ON s.id=i.student_id
     WHERE i.room_id=p_room),'[]'::jsonb)
 );
END $$;

CREATE OR REPLACE FUNCTION public.cp2_qna_post(p_room uuid,p_body text)
RETURNS uuid LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT private.cp2_qna_post(p_room,p_body);$$;
CREATE OR REPLACE FUNCTION public.cp2_qna_list(p_room uuid,p_limit integer DEFAULT 100)
RETURNS TABLE(id uuid,student_no text,display_name text,body text,answer text,status text,
 created_at timestamptz,answered_at timestamptz)
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT * FROM private.cp2_qna_list(p_room,p_limit);$$;
CREATE OR REPLACE FUNCTION public.cp2_qna_reply(p_question uuid,p_answer text)
RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT private.cp2_qna_reply(p_question,p_answer);$$;
CREATE OR REPLACE FUNCTION public.cp2_qna_archive(p_question uuid)
RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT private.cp2_qna_archive(p_question);$$;
DO $$ DECLARE fn record;BEGIN
 FOR fn IN SELECT p.oid::regprocedure signature FROM pg_proc p
 JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname IN('private','public') AND p.proname IN
  ('cp2_qna_post','cp2_qna_list','cp2_qna_reply','cp2_qna_archive') LOOP
 EXECUTE 'REVOKE ALL ON FUNCTION '||fn.signature||' FROM PUBLIC,anon';
 EXECUTE 'GRANT EXECUTE ON FUNCTION '||fn.signature||' TO authenticated';
 END LOOP;
END $$;
COMMIT;
