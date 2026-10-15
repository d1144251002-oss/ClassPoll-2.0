-- ClassPoll 2.0 | Formal ballots module v1
-- Classroom / campus governance. Not certified for public governmental elections.
-- Existing cp2_* classroom/test tables and votes are untouched.
-- Blind aggregate access: the teacher NEVER receives per-person choice rows.
-- Database administrators can still inspect data or correlate events: NOT cryptographic E2E secrecy.
BEGIN;

CREATE TABLE IF NOT EXISTS public.cp2_ballots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id uuid NOT NULL REFERENCES public.cp2_rooms(id) ON DELETE RESTRICT,
  title text NOT NULL CHECK (length(trim(title)) BETWEEN 1 AND 160),
  description text NOT NULL DEFAULT '' CHECK (length(description)<=2000),
  mode text NOT NULL CHECK(mode IN ('single','multiple','yesno')),
  options jsonb NOT NULL CHECK(jsonb_typeof(options)='array' AND jsonb_array_length(options) BETWEEN 2 AND 16),
  min_choices integer NOT NULL DEFAULT 1 CHECK(min_choices BETWEEN 1 AND 16),
  max_choices integer NOT NULL DEFAULT 1 CHECK(max_choices BETWEEN 1 AND 16 AND max_choices>=min_choices),
  opens_at timestamptz NOT NULL,
  closes_at timestamptz NOT NULL CHECK(closes_at>opens_at),
  status text NOT NULL DEFAULT 'draft' CHECK(status IN ('draft','active','closed')),
  activated_at timestamptz,
  closed_at timestamptz,
  min_report_votes integer NOT NULL DEFAULT 3 CHECK(min_report_votes BETWEEN 1 AND 100),
  eligible_count integer NOT NULL DEFAULT 0 CHECK(eligible_count>=0),
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK(max_choices <= jsonb_array_length(options)),
  CHECK((mode='single' AND min_choices=1 AND max_choices=1)
     OR (mode='yesno' AND min_choices=1 AND max_choices=1 AND options='["贊成","反對","棄權"]'::jsonb)
     OR mode='multiple')
);
CREATE INDEX IF NOT EXISTS cp2_ballots_room_idx ON public.cp2_ballots(room_id,created_at DESC);

CREATE TABLE IF NOT EXISTS public.cp2_ballot_eligible (
  ballot_id uuid NOT NULL REFERENCES public.cp2_ballots(id) ON DELETE RESTRICT,
  student_id uuid NOT NULL REFERENCES public.cp2_students(id) ON DELETE RESTRICT,
  PRIMARY KEY(ballot_id,student_id)
);
CREATE INDEX IF NOT EXISTS cp2_ballot_eligible_student_idx ON public.cp2_ballot_eligible(student_id);

-- Participation is separate from vote contents; receipt only proves acceptance.
CREATE TABLE IF NOT EXISTS public.cp2_ballot_participation (
  ballot_id uuid NOT NULL REFERENCES public.cp2_ballots(id) ON DELETE RESTRICT,
  student_id uuid NOT NULL REFERENCES public.cp2_students(id) ON DELETE RESTRICT,
  receipt uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  PRIMARY KEY(ballot_id,student_id)
);
CREATE INDEX IF NOT EXISTS cp2_ballot_participation_student_idx ON public.cp2_ballot_participation(student_id);

-- No voter identity or participation-receipt foreign key in vote contents table.
CREATE TABLE IF NOT EXISTS public.cp2_ballot_choices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ballot_id uuid NOT NULL REFERENCES public.cp2_ballots(id) ON DELETE RESTRICT,
  choice_indices smallint[] NOT NULL CHECK(cardinality(choice_indices) BETWEEN 1 AND 16)
);
CREATE INDEX IF NOT EXISTS cp2_ballot_choices_ballot_idx ON public.cp2_ballot_choices(ballot_id);

ALTER TABLE public.cp2_ballots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cp2_ballot_eligible ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cp2_ballot_participation ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cp2_ballot_choices ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.cp2_ballots,public.cp2_ballot_eligible,
  public.cp2_ballot_participation,public.cp2_ballot_choices FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.cp2_ballots TO authenticated;
DROP POLICY IF EXISTS cp2_ballots_visible ON public.cp2_ballots;
CREATE POLICY cp2_ballots_visible ON public.cp2_ballots FOR SELECT TO authenticated
USING (
  private.cp2_owns(room_id)
  OR (status<>'draft' AND private.cp2_member(room_id))
);
-- No direct write policy, and no SELECT policies on eligibility/participation/choices.
-- Only audited SECURITY DEFINER functions below may access those tables.

CREATE OR REPLACE FUNCTION private.cp2_ballot_create(
 p_room uuid,p_title text,p_description text,p_mode text,p_options jsonb,
 p_min integer,p_max integer,p_opens timestamptz,p_closes timestamptz,p_report_min integer DEFAULT 3
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_id uuid; v_n integer; v_distinct integer;
BEGIN
 IF NOT private.cp2_owns(p_room) THEN RAISE EXCEPTION '無權管理教室' USING errcode='42501'; END IF;
 IF NOT EXISTS (SELECT 1 FROM public.cp2_rooms WHERE id=p_room AND is_active) THEN RAISE EXCEPTION '教室已停用'; END IF;
 IF p_title IS NULL OR length(trim(p_title)) NOT BETWEEN 1 AND 160
    OR length(coalesce(p_description,''))>2000 THEN RAISE EXCEPTION '標題或說明過長'; END IF;
 IF p_mode NOT IN ('single','multiple','yesno') OR p_mode IS NULL THEN RAISE EXCEPTION '投票方式無效'; END IF;
 IF p_options IS NULL OR jsonb_typeof(p_options)<>'array' THEN RAISE EXCEPTION '選項必須是陣列'; END IF;
 v_n:=jsonb_array_length(p_options);
 IF v_n NOT BETWEEN 2 AND 16 THEN RAISE EXCEPTION '選項數量需要 2 至 16 項'; END IF;
 IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_options) x
            WHERE jsonb_typeof(x.value)<>'string' OR length(trim(x.value #>> '{}')) NOT BETWEEN 1 AND 120) THEN
   RAISE EXCEPTION '選項必須是 1 至 120 字的文字'; END IF;
 SELECT count(DISTINCT lower(trim(x.value #>> '{}'))) INTO v_distinct FROM jsonb_array_elements(p_options) x;
 IF v_distinct<>v_n THEN RAISE EXCEPTION '投票選項不能重複'; END IF;
 IF p_mode IN ('single','yesno') AND (p_min<>1 OR p_max<>1) THEN RAISE EXCEPTION '單選必須選取一項'; END IF;
 IF p_mode='yesno' AND p_options<>'["贊成","反對","棄權"]'::jsonb THEN RAISE EXCEPTION '表決選項必須是贊成／反對／棄權'; END IF;
 IF p_min IS NULL OR p_max IS NULL OR p_min<1 OR p_max<p_min OR p_max>v_n THEN RAISE EXCEPTION '最低或最高可選數不合法'; END IF;
 IF p_report_min IS NULL OR p_report_min NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION '最低公開票數介於 1 至 100'; END IF;
 IF p_opens IS NULL OR p_closes IS NULL OR p_closes<=p_opens
    OR p_closes<=clock_timestamp() OR p_closes-p_opens>interval '90 days'
    OR p_opens>clock_timestamp()+interval '90 days' THEN
    RAISE EXCEPTION '投票時間必須正確，期限不得超過 90 天'; END IF;
 INSERT INTO public.cp2_ballots(room_id,title,description,mode,options,min_choices,max_choices,opens_at,closes_at,min_report_votes)
 VALUES (p_room,trim(p_title),coalesce(p_description,''),p_mode,p_options,p_min,p_max,p_opens,p_closes,p_report_min)
 RETURNING id INTO v_id;
 INSERT INTO public.cp2_audit(room_id,actor_uid,event,details)
 VALUES (p_room,auth.uid(),'ballot.create',jsonb_build_object('ballot_id',v_id));
 RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION private.cp2_ballot_activate(p_ballot uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_b public.cp2_ballots%rowtype; v_n integer;
BEGIN
 SELECT * INTO v_b FROM public.cp2_ballots WHERE id=p_ballot FOR UPDATE;
 IF NOT FOUND OR NOT private.cp2_owns(v_b.room_id) THEN RAISE EXCEPTION '無權啟用投票' USING errcode='42501'; END IF;
 IF v_b.status<>'draft' OR v_b.closes_at<=clock_timestamp() THEN RAISE EXCEPTION '無法啟用已開始、結束或失效的投票'; END IF;
 IF NOT EXISTS (SELECT 1 FROM public.cp2_rooms WHERE id=v_b.room_id AND is_active) THEN RAISE EXCEPTION '教室已停用'; END IF;
 INSERT INTO public.cp2_ballot_eligible(ballot_id,student_id)
 SELECT p_ballot,s.id FROM public.cp2_students s WHERE s.room_id=v_b.room_id AND s.is_active
 ON CONFLICT DO NOTHING;
 GET DIAGNOSTICS v_n=ROW_COUNT;
 IF v_n=0 THEN RAISE EXCEPTION '沒有符合資格的學生，請先建立學生名冊'; END IF;
 IF v_n<v_b.min_report_votes THEN
   RAISE EXCEPTION '目前名冊僅有 % 人，低於結果公開門檻 % 票。請先增加學生或編輯草稿的公開門檻。',v_n,v_b.min_report_votes;
 END IF;
 UPDATE public.cp2_ballots SET eligible_count=v_n,status='active',activated_at=clock_timestamp() WHERE id=p_ballot;
 INSERT INTO public.cp2_audit(room_id,actor_uid,event,details)
 VALUES(v_b.room_id,auth.uid(),'ballot.activate',jsonb_build_object('ballot_id',p_ballot,'eligible',v_n));
 RETURN v_n;
END $$;

CREATE OR REPLACE FUNCTION private.cp2_ballot_close(p_ballot uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_b public.cp2_ballots%rowtype;
BEGIN
 SELECT * INTO v_b FROM public.cp2_ballots WHERE id=p_ballot FOR UPDATE;
 IF NOT FOUND OR NOT private.cp2_owns(v_b.room_id) THEN RAISE EXCEPTION '無權結束投票' USING errcode='42501'; END IF;
 IF v_b.status<>'active' THEN RAISE EXCEPTION '僅可結束已啟用的投票'; END IF;
 UPDATE public.cp2_ballots SET status='closed',closed_at=clock_timestamp() WHERE id=p_ballot;
 INSERT INTO public.cp2_audit(room_id,actor_uid,event,details)
 VALUES(v_b.room_id,auth.uid(),'ballot.close',jsonb_build_object('ballot_id',p_ballot));
END $$;

CREATE OR REPLACE FUNCTION private.cp2_ballot_cast(p_ballot uuid,p_choices integer[])
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_b public.cp2_ballots%rowtype; v_sid uuid; v_receipt uuid;
  v_choice integer; v_len integer;
BEGIN
 IF auth.uid() IS NULL OR coalesce(auth.jwt()->>'is_anonymous','false')<>'true' THEN
    RAISE EXCEPTION '請使用學生身分入班' USING errcode='42501'; END IF;
 SELECT * INTO v_b FROM public.cp2_ballots WHERE id=p_ballot FOR SHARE;
 IF NOT FOUND OR v_b.status<>'active'
    OR clock_timestamp()<v_b.opens_at OR clock_timestamp()>=v_b.closes_at THEN
    RAISE EXCEPTION '投票尚未開放或已結束'; END IF;
 IF NOT EXISTS (SELECT 1 FROM public.cp2_rooms WHERE id=v_b.room_id AND is_active) THEN RAISE EXCEPTION '教室已停用'; END IF;
 SELECT id INTO v_sid FROM public.cp2_students
 WHERE room_id=v_b.room_id AND auth_uid=auth.uid() AND is_active;
 IF v_sid IS NULL OR NOT EXISTS(SELECT 1 FROM public.cp2_ballot_eligible
                  WHERE ballot_id=p_ballot AND student_id=v_sid) THEN
    RAISE EXCEPTION '您不在本次投票資格名冊中' USING errcode='42501'; END IF;
 v_len:=cardinality(p_choices);
 IF v_len IS NULL OR v_len<v_b.min_choices OR v_len>v_b.max_choices THEN
    RAISE EXCEPTION '選擇數量不符合規則'; END IF;
 IF EXISTS(SELECT 1 FROM unnest(p_choices) x WHERE x IS NULL OR x<0 OR x>=jsonb_array_length(v_b.options))
    OR (SELECT count(DISTINCT x) FROM unnest(p_choices) x)<>v_len THEN
    RAISE EXCEPTION '選項不合法或重複'; END IF;
 -- Uniqueness of (ballot_id,student_id) blocks double voting across devices and requests.
 INSERT INTO public.cp2_ballot_participation(ballot_id,student_id)
 VALUES(p_ballot,v_sid) RETURNING receipt INTO v_receipt;
 INSERT INTO public.cp2_ballot_choices(ballot_id,choice_indices)
 VALUES(p_ballot,p_choices::smallint[]);
 -- Do not write individual choices / receipt to an audit event.
 RETURN v_receipt;
END $$;

CREATE OR REPLACE FUNCTION private.cp2_ballot_list(p_room uuid)
RETURNS TABLE(
 id uuid,title text,description text,mode text,options jsonb,
 min_choices integer,max_choices integer,opens_at timestamptz,closes_at timestamptz,
 status text,eligible_count integer,cast_count bigint,
 has_voted boolean,receipt uuid,min_report_votes integer,results_available boolean
) LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path='' AS $$
DECLARE v_owner boolean; v_member boolean;
BEGIN
 v_owner:=private.cp2_owns(p_room);
 v_member:=private.cp2_member(p_room);
 IF NOT v_owner AND NOT v_member THEN RAISE EXCEPTION '無權查看這個教室的投票' USING errcode='42501'; END IF;
 RETURN QUERY SELECT b.id,b.title,b.description,b.mode,b.options,b.min_choices,b.max_choices,
 b.opens_at,b.closes_at,b.status,b.eligible_count,
 CASE WHEN v_owner OR (b.status='closed' OR clock_timestamp()>=b.closes_at)
      THEN (SELECT count(*) FROM public.cp2_ballot_participation p WHERE p.ballot_id=b.id)
      ELSE -1::bigint END AS cast_count,
 EXISTS(SELECT 1 FROM public.cp2_ballot_participation p
   JOIN public.cp2_students s ON s.id=p.student_id
   WHERE p.ballot_id=b.id AND s.auth_uid=auth.uid()) AS has_voted,
 (SELECT p.receipt FROM public.cp2_ballot_participation p
   JOIN public.cp2_students s ON s.id=p.student_id
   WHERE p.ballot_id=b.id AND s.auth_uid=auth.uid() LIMIT 1) AS receipt,
 b.min_report_votes,
 ((b.status='closed' OR clock_timestamp()>=b.closes_at)
  AND (SELECT count(*) FROM public.cp2_ballot_participation p WHERE p.ballot_id=b.id)>=b.min_report_votes) AS results_available
 FROM public.cp2_ballots b
 WHERE b.room_id=p_room AND (v_owner OR b.status<>'draft') ORDER BY b.created_at DESC;
END $$;

CREATE OR REPLACE FUNCTION private.cp2_ballot_results(p_ballot uuid)
RETURNS TABLE(choice_index integer,choice_label text,votes bigint,total_ballots bigint,eligible_count integer)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path='' AS $$
DECLARE v_b public.cp2_ballots%rowtype;v_total bigint;
BEGIN
 SELECT * INTO v_b FROM public.cp2_ballots WHERE id=p_ballot;
 IF NOT FOUND OR NOT (private.cp2_owns(v_b.room_id) OR private.cp2_member(v_b.room_id))
 THEN RAISE EXCEPTION '無權查看投票結果' USING errcode='42501'; END IF;
 IF v_b.status='draft' OR (v_b.status<>'closed' AND clock_timestamp()<v_b.closes_at)
 THEN RAISE EXCEPTION '投票尚未結束，結果尚未公開'; END IF;
 SELECT count(*) INTO v_total FROM public.cp2_ballot_participation WHERE ballot_id=p_ballot;
 IF v_total<v_b.min_report_votes THEN RAISE EXCEPTION '未達最低公開票數，為保障隱私不顯示結果'; END IF;
 RETURN QUERY SELECT ix.n::integer,v_b.options->>ix.n,
 (SELECT count(*) FROM public.cp2_ballot_choices c WHERE c.ballot_id=p_ballot
  AND ix.n::smallint=ANY(c.choice_indices)) AS votes,
 v_total,v_b.eligible_count
 FROM generate_series(0,jsonb_array_length(v_b.options)-1) AS ix(n) ORDER BY ix.n;
END $$;

-- Only tightly-scoped, authenticated invoker wrappers are exposed via PostgREST.
CREATE OR REPLACE FUNCTION public.cp2_ballot_create(p_room uuid,p_title text,p_description text,
 p_mode text,p_options jsonb,p_min integer,p_max integer,p_opens timestamptz,p_closes timestamptz,
 p_report_min integer DEFAULT 3) RETURNS uuid LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT private.cp2_ballot_create(p_room,p_title,p_description,p_mode,p_options,p_min,p_max,p_opens,p_closes,p_report_min); $$;
CREATE OR REPLACE FUNCTION public.cp2_ballot_activate(p_ballot uuid)
 RETURNS integer LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT private.cp2_ballot_activate(p_ballot); $$;
CREATE OR REPLACE FUNCTION public.cp2_ballot_close(p_ballot uuid)
 RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT private.cp2_ballot_close(p_ballot); $$;
CREATE OR REPLACE FUNCTION public.cp2_ballot_cast(p_ballot uuid,p_choices integer[])
 RETURNS uuid LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT private.cp2_ballot_cast(p_ballot,p_choices); $$;
CREATE OR REPLACE FUNCTION public.cp2_ballot_list(p_room uuid)
 RETURNS TABLE(id uuid,title text,description text,mode text,options jsonb,min_choices integer,
 max_choices integer,opens_at timestamptz,closes_at timestamptz,status text,
 eligible_count integer,cast_count bigint,has_voted boolean,receipt uuid,
 min_report_votes integer,results_available boolean)
 LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT * FROM private.cp2_ballot_list(p_room); $$;
CREATE OR REPLACE FUNCTION public.cp2_ballot_results(p_ballot uuid)
 RETURNS TABLE(choice_index integer,choice_label text,votes bigint,total_ballots bigint,eligible_count integer)
 LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT * FROM private.cp2_ballot_results(p_ballot); $$;

-- Revoke PostgreSQL's default PUBLIC function execution (includes anonymous callers).
DO $$ DECLARE fn record; BEGIN
 FOR fn IN SELECT p.oid::regprocedure AS signature
 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname IN ('private','public') AND p.proname IN
 ('cp2_ballot_create','cp2_ballot_activate','cp2_ballot_close',
  'cp2_ballot_cast','cp2_ballot_list','cp2_ballot_results')
 LOOP
   EXECUTE 'REVOKE ALL ON FUNCTION '||fn.signature||' FROM PUBLIC,anon';
   EXECUTE 'GRANT EXECUTE ON FUNCTION '||fn.signature||' TO authenticated';
 END LOOP;
END $$;
COMMIT;
