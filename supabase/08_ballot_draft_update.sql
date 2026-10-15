-- Formal governance: editable drafts, permanently frozen once activated.
-- No vote data or eligibility is changed.
BEGIN;
CREATE OR REPLACE FUNCTION private.cp2_ballot_update(
 p_ballot uuid,p_title text,p_description text,p_mode text,p_options jsonb,
 p_min integer,p_max integer,p_opens timestamptz,p_closes timestamptz,p_report_min integer
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_b public.cp2_ballots%rowtype;v_n integer;v_distinct integer;
BEGIN
 SELECT * INTO v_b FROM public.cp2_ballots WHERE id=p_ballot FOR UPDATE;
 IF NOT FOUND OR NOT private.cp2_owns(v_b.room_id) THEN RAISE EXCEPTION '無權修改這項表決' USING errcode='42501'; END IF;
 IF v_b.status<>'draft' THEN RAISE EXCEPTION '表決已啟用，選票內容不可修改'; END IF;
 IF p_title IS NULL OR length(trim(p_title)) NOT BETWEEN 1 AND 160 OR length(coalesce(p_description,''))>2000 THEN
   RAISE EXCEPTION '標題或說明不合法'; END IF;
 IF p_mode NOT IN ('single','multiple','yesno') OR p_mode IS NULL THEN RAISE EXCEPTION '投票形式不合法'; END IF;
 IF p_options IS NULL OR jsonb_typeof(p_options)<>'array' THEN RAISE EXCEPTION '選項不合法'; END IF;
 v_n:=jsonb_array_length(p_options);
 IF v_n NOT BETWEEN 2 AND 16 THEN RAISE EXCEPTION '選項數量不合法'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_options) o
 WHERE jsonb_typeof(o.value)<>'string' OR length(trim(o.value #>> '{}')) NOT BETWEEN 1 AND 120)
 THEN RAISE EXCEPTION '選項文字格式不合法'; END IF;
 SELECT count(DISTINCT lower(trim(o.value #>> '{}'))) INTO v_distinct FROM jsonb_array_elements(p_options) o;
 IF v_distinct<>v_n THEN RAISE EXCEPTION '選項不可重複'; END IF;
 IF p_min IS NULL OR p_max IS NULL OR p_min<1 OR p_max<p_min OR p_max>v_n
 THEN RAISE EXCEPTION '選擇數量不合法'; END IF;
 IF p_mode IN ('single','yesno') AND (p_min<>1 OR p_max<>1) THEN RAISE EXCEPTION '單選僅可選一項'; END IF;
 IF p_mode='yesno' AND p_options<>'["贊成","反對","棄權"]'::jsonb THEN RAISE EXCEPTION '表決選項不符合規範'; END IF;
 IF p_report_min IS NULL OR p_report_min NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION '結果公開門檻不合法'; END IF;
 IF p_opens IS NULL OR p_closes IS NULL OR p_closes<=p_opens OR p_closes<=clock_timestamp()
    OR p_closes-p_opens>interval '90 days' OR p_opens>clock_timestamp()+interval '90 days'
 THEN RAISE EXCEPTION '投票時間不合法'; END IF;
 UPDATE public.cp2_ballots SET title=trim(p_title),description=coalesce(p_description,''),
 mode=p_mode,options=p_options,min_choices=p_min,max_choices=p_max,
 opens_at=p_opens,closes_at=p_closes,min_report_votes=p_report_min
 WHERE id=p_ballot;
 INSERT INTO public.cp2_audit(room_id,actor_uid,event,details)
 VALUES(v_b.room_id,auth.uid(),'ballot.update',jsonb_build_object('ballot_id',p_ballot));
END $$;
CREATE OR REPLACE FUNCTION public.cp2_ballot_update(
 p_ballot uuid,p_title text,p_description text,p_mode text,p_options jsonb,
 p_min integer,p_max integer,p_opens timestamptz,p_closes timestamptz,p_report_min integer
) RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT private.cp2_ballot_update(p_ballot,p_title,p_description,p_mode,p_options,p_min,p_max,p_opens,p_closes,p_report_min);
$$;
REVOKE ALL ON FUNCTION private.cp2_ballot_update(uuid,text,text,text,jsonb,integer,integer,timestamptz,timestamptz,integer) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.cp2_ballot_update(uuid,text,text,text,jsonb,integer,integer,timestamptz,timestamptz,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.cp2_ballot_update(uuid,text,text,text,jsonb,integer,integer,timestamptz,timestamptz,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cp2_ballot_update(uuid,text,text,text,jsonb,integer,integer,timestamptz,timestamptz,integer) TO authenticated;
COMMIT;