-- ClassPoll 2.0 platform hardening: least-privilege room roles, atomic roster import,
-- private executive dashboard, and controlled classroom recovery.
-- Apply only after review and backup. Existing vote, question, and ballot data are not modified.
BEGIN;
CREATE TABLE IF NOT EXISTS public.cp2_room_roles(
 room_id uuid NOT NULL REFERENCES public.cp2_rooms(id) ON DELETE CASCADE,
 teacher_id uuid NOT NULL REFERENCES public.cp2_teachers(user_id) ON DELETE CASCADE,
 role text NOT NULL CHECK(role IN ('assistant','auditor')),
 granted_by uuid NOT NULL REFERENCES public.cp2_teachers(user_id),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(room_id,teacher_id)
);
CREATE INDEX IF NOT EXISTS cp2_room_roles_teacher_idx ON public.cp2_room_roles(teacher_id);
ALTER TABLE public.cp2_room_roles ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.cp2_room_roles FROM PUBLIC,anon,authenticated;
-- No direct policies: all role administration is via server-side authenticated RPC.
CREATE OR REPLACE FUNCTION private.cp2_room_can_view(p_room uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT private.cp2_owns(p_room) OR EXISTS(
  SELECT 1 FROM public.cp2_room_roles a WHERE a.room_id=p_room AND a.teacher_id=auth.uid()
 );
$$;
CREATE OR REPLACE FUNCTION private.cp2_role_list(p_room uuid)
RETURNS TABLE(email text,role text,granted_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT private.cp2_owns(p_room) THEN RAISE EXCEPTION '僅教室擁有者能檢視權限' USING errcode='42501'; END IF;
 RETURN QUERY
 SELECT u.email::text,r.role,r.created_at FROM public.cp2_room_roles r
 JOIN auth.users u ON u.id=r.teacher_id WHERE r.room_id=p_room ORDER BY r.created_at;
END $$;
CREATE OR REPLACE FUNCTION private.cp2_role_set(p_room uuid,p_email text,p_role text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid;v_owner uuid;
BEGIN
 IF NOT private.cp2_owns(p_room) THEN RAISE EXCEPTION '僅教室擁有者能管理權限' USING errcode='42501'; END IF;
 IF p_role IS NULL OR p_role NOT IN ('assistant','auditor','remove') THEN
  RAISE EXCEPTION '角色必須是 assistant、auditor 或 remove'; END IF;
 IF length(trim(coalesce(p_email,''))) NOT BETWEEN 3 AND 254 THEN RAISE EXCEPTION '教師電子郵件格式不正確'; END IF;
 SELECT t.user_id INTO v_uid FROM public.cp2_teachers t JOIN auth.users u ON u.id=t.user_id
 WHERE lower(u.email)=lower(trim(p_email));
 IF v_uid IS NULL THEN RAISE EXCEPTION '找不到已授權的教師帳號'; END IF;
 SELECT owner_id INTO v_owner FROM public.cp2_rooms WHERE id=p_room;
 IF v_uid=v_owner THEN RAISE EXCEPTION '教室擁有者角色不可被覆蓋'; END IF;
 IF p_role='remove' THEN
  DELETE FROM public.cp2_room_roles WHERE room_id=p_room AND teacher_id=v_uid;
 ELSE
  INSERT INTO public.cp2_room_roles(room_id,teacher_id,role,granted_by)
  VALUES(p_room,v_uid,p_role,auth.uid())
  ON CONFLICT(room_id,teacher_id) DO UPDATE SET role=EXCLUDED.role,granted_by=EXCLUDED.granted_by,created_at=clock_timestamp();
 END IF;
 INSERT INTO public.cp2_audit(room_id,actor_uid,event,details) VALUES(
  p_room,auth.uid(),'room.role.update',jsonb_build_object('teacher_id',v_uid,'role',p_role));
END $$;
CREATE OR REPLACE FUNCTION private.cp2_platform_overview()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid;
BEGIN
 v_uid:=auth.uid();
 IF v_uid IS NULL OR coalesce(auth.jwt()->>'is_anonymous','false')='true'
  OR NOT EXISTS(SELECT 1 FROM public.cp2_teachers WHERE user_id=v_uid) THEN
  RAISE EXCEPTION '教師身分驗證失敗' USING errcode='42501';
 END IF;
 RETURN jsonb_build_object(
 'profile',jsonb_build_object('teacher_id',v_uid,'roles',ARRAY['teacher']),
 'rooms',COALESCE((
   SELECT jsonb_agg(row_to_json(t) ORDER BY t.created_at DESC)
   FROM (
    SELECT r.id,r.code,r.title,r.is_active,r.created_at,
     CASE WHEN r.owner_id=v_uid THEN 'owner' ELSE rr.role END AS role,
     (SELECT count(*) FROM public.cp2_students s WHERE s.room_id=r.id) AS students,
     (SELECT count(*) FROM public.cp2_students s WHERE s.room_id=r.id AND s.is_active) AS active_students,
     (SELECT count(*) FROM public.cp2_attendance a WHERE a.room_id=r.id
       AND a.attended_on=(clock_timestamp() AT TIME ZONE 'Asia/Taipei')::date) AS present_today,
     (SELECT count(*) FROM public.cp2_questions q WHERE q.room_id=r.id) AS questions,
     (SELECT count(*) FROM public.cp2_questions q WHERE q.room_id=r.id AND q.status='published') AS live_questions,
     (SELECT count(*) FROM public.cp2_votes v JOIN public.cp2_questions q ON q.id=v.question_id WHERE q.room_id=r.id) AS answers,
     (SELECT count(*) FROM public.cp2_errors e WHERE e.room_id=r.id
       AND e.created_at>clock_timestamp()-interval '24 hours') AS recent_errors
    FROM public.cp2_rooms r LEFT JOIN public.cp2_room_roles rr ON rr.room_id=r.id AND rr.teacher_id=v_uid
    WHERE r.owner_id=v_uid OR rr.teacher_id=v_uid
   ) t
 ),'[]'::jsonb)
 );
END $$;
CREATE OR REPLACE FUNCTION private.cp2_platform_audit(p_room uuid,p_limit int DEFAULT 100)
RETURNS TABLE(created_at timestamptz,event text,details jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT private.cp2_room_can_view(p_room) THEN RAISE EXCEPTION '沒有此教室的稽核查詢權限' USING errcode='42501'; END IF;
 IF p_limit IS NULL OR p_limit<1 OR p_limit>200 THEN RAISE EXCEPTION '筆數須介於 1 至 200'; END IF;
 RETURN QUERY SELECT a.created_at,a.event,a.details FROM public.cp2_audit a
 WHERE a.room_id=p_room ORDER BY a.created_at DESC LIMIT p_limit;
END $$;
CREATE OR REPLACE FUNCTION private.cp2_roster_import(p_room uuid,p_roster jsonb)
RETURNS TABLE(student_id uuid,student_no text,display_name text,access_code text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_line jsonb;v_num text;v_name text;v_secret text;v_id uuid;v_numbers text[]:=ARRAY[]::text[];
BEGIN
 IF NOT private.cp2_owns(p_room) THEN RAISE EXCEPTION '僅教室擁有者能匯入名冊' USING errcode='42501'; END IF;
 IF NOT EXISTS (SELECT 1 FROM public.cp2_rooms WHERE id=p_room AND is_active) THEN RAISE EXCEPTION '教室未開放'; END IF;
 IF p_roster IS NULL OR jsonb_typeof(p_roster)<>'array' OR jsonb_array_length(p_roster) NOT BETWEEN 1 AND 200 THEN
  RAISE EXCEPTION '一次須匯入 1 至 200 名學生'; END IF;
 -- Validate the *entire* import before issuing any credentials.
 FOR v_line IN SELECT value FROM jsonb_array_elements(p_roster) LOOP
  IF jsonb_typeof(v_line)<>'object' THEN RAISE EXCEPTION '名冊格式錯誤'; END IF;
  v_num:=trim(v_line->>'student_no');v_name:=trim(v_line->>'display_name');
  IF v_num IS NULL OR length(v_num) NOT BETWEEN 1 AND 40
   OR v_name IS NULL OR length(v_name) NOT BETWEEN 1 AND 80 THEN
   RAISE EXCEPTION '學號與姓名不得為空且不能超過長度限制'; END IF;
  IF v_num=ANY(v_numbers) THEN RAISE EXCEPTION '匯入名冊內有重複學號：%',v_num; END IF;
  v_numbers:=array_append(v_numbers,v_num);
 END LOOP;
 IF EXISTS(SELECT 1 FROM public.cp2_students s WHERE s.room_id=p_room AND s.student_no=ANY(v_numbers))
 THEN RAISE EXCEPTION '有學號已存在於教室名冊，全部匯入取消'; END IF;
 FOR v_line IN SELECT value FROM jsonb_array_elements(p_roster) LOOP
  v_num:=trim(v_line->>'student_no');v_name:=trim(v_line->>'display_name');
  v_secret:=encode(extensions.gen_random_bytes(16),'hex');
  INSERT INTO public.cp2_students(room_id,student_no,display_name,access_hash)
  VALUES(p_room,v_num,v_name,encode(extensions.digest(v_secret,'sha256'),'hex')) RETURNING id INTO v_id;
  student_id:=v_id;student_no:=v_num;display_name:=v_name;access_code:=v_secret;
  RETURN NEXT;
 END LOOP;
 INSERT INTO public.cp2_audit(room_id,actor_uid,event,details)
 VALUES(p_room,auth.uid(),'roster.import',jsonb_build_object('count',jsonb_array_length(p_roster)));
END $$;
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
     FROM public.cp2_audit a WHERE a.room_id=p_room),'[]'::jsonb)
 );
END $$;
-- Deliberately limited restore: creates a NEW room with a NEW roster; does NOT import votes,
-- attendance or hashed credentials. Historic grading can only be recovered through DBA restore.
CREATE OR REPLACE FUNCTION private.cp2_room_restore_roster(p_backup jsonb,p_new_code text,p_new_title text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_room uuid;v_uid uuid;v_s jsonb;v_codes jsonb;
BEGIN
 v_uid:=auth.uid();
 IF v_uid IS NULL OR NOT EXISTS(SELECT 1 FROM public.cp2_teachers WHERE user_id=v_uid)
   OR coalesce(auth.jwt()->>'is_anonymous','false')='true' THEN
   RAISE EXCEPTION '沒有教室還原權限' USING errcode='42501'; END IF;
 IF p_backup IS NULL OR pg_column_size(p_backup)>5000000 THEN
  RAISE EXCEPTION '備份資料不可超過 5 MB'; END IF;
 IF p_backup->>'format'<>'classpoll-room-backup-v1' THEN RAISE EXCEPTION '備份格式或版本不支援'; END IF;
 v_s:=p_backup->'students';
 IF v_s IS NULL OR jsonb_typeof(v_s)<>'array' OR jsonb_array_length(v_s)>200 THEN
  RAISE EXCEPTION '還原名冊不能超過 200 人'; END IF;
 IF coalesce(p_new_code,'') !~ '^[A-Z0-9]{4,12}$'
 OR length(trim(coalesce(p_new_title,''))) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION '新教室代碼或名稱不合法'; END IF;
 INSERT INTO public.cp2_rooms(owner_id,code,title) VALUES(v_uid,p_new_code,trim(p_new_title)) RETURNING id INTO v_room;
 IF jsonb_array_length(v_s)>0 THEN
   SELECT coalesce(jsonb_agg(jsonb_build_object('student_no',x.student_no,'display_name',x.display_name,'access_code',x.access_code)),'[]'::jsonb)
   INTO v_codes FROM private.cp2_roster_import(v_room,v_s) x;
 ELSE v_codes:='[]'::jsonb; END IF;
 -- Preserve explicit inactive roster entries; restore must not reactivate suspended students.
 UPDATE public.cp2_students s SET is_active=false
 FROM jsonb_array_elements(v_s) AS entry(data)
 WHERE s.room_id=v_room
 AND s.student_no=trim(entry.data->>'student_no')
 AND entry.data->>'active'='false';
 INSERT INTO public.cp2_audit(room_id,actor_uid,event,details)
 VALUES(v_room,v_uid,'room.restore.roster',jsonb_build_object('from_backup',true,'students',jsonb_array_length(v_s)));
 RETURN jsonb_build_object('room_id',v_room,'new_codes',v_codes);
END $$;

-- Public, authenticated RPC wrappers: ordinary clients never receive table-level grants.
CREATE OR REPLACE FUNCTION public.cp2_platform_overview()
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT private.cp2_platform_overview();$$;
CREATE OR REPLACE FUNCTION public.cp2_role_list(p_room uuid)
RETURNS TABLE(email text,role text,granted_at timestamptz)
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT * FROM private.cp2_role_list(p_room);$$;
CREATE OR REPLACE FUNCTION public.cp2_role_set(p_room uuid,p_email text,p_role text)
RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT private.cp2_role_set(p_room,p_email,p_role);$$;
CREATE OR REPLACE FUNCTION public.cp2_platform_audit(p_room uuid,p_limit int DEFAULT 100)
RETURNS TABLE(created_at timestamptz,event text,details jsonb)
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT * FROM private.cp2_platform_audit(p_room,p_limit);$$;
CREATE OR REPLACE FUNCTION public.cp2_roster_import(p_room uuid,p_roster jsonb)
RETURNS TABLE(student_id uuid,student_no text,display_name text,access_code text)
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT * FROM private.cp2_roster_import(p_room,p_roster);$$;
CREATE OR REPLACE FUNCTION public.cp2_room_snapshot(p_room uuid)
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT private.cp2_room_snapshot(p_room);$$;
CREATE OR REPLACE FUNCTION public.cp2_room_restore_roster(p_backup jsonb,p_new_code text,p_new_title text)
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT private.cp2_room_restore_roster(p_backup,p_new_code,p_new_title);$$;
DO $$ DECLARE fn record; BEGIN
 FOR fn IN SELECT p.oid::regprocedure AS signature FROM pg_proc p
 JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname IN('private','public') AND p.proname IN
 ('cp2_room_can_view','cp2_platform_overview','cp2_role_list','cp2_role_set',
 'cp2_platform_audit','cp2_roster_import','cp2_room_snapshot','cp2_room_restore_roster') LOOP
  EXECUTE 'REVOKE ALL ON FUNCTION '||fn.signature||' FROM PUBLIC,anon';
  EXECUTE 'GRANT EXECUTE ON FUNCTION '||fn.signature||' TO authenticated';
 END LOOP;
END $$;
COMMIT;
