-- ClassPoll 2.0: enforce voting deadlines with wall clock, not transaction start.
-- Safe for existing installations; no data is changed.
create or replace function private.cp2_vote(p_question uuid,p_choice int) returns uuid
language plpgsql security definer set search_path='' as $$
declare v_q public.cp2_questions%rowtype; v_sid uuid; v_id uuid;
begin
 if auth.uid() is null or coalesce(auth.jwt()->>'is_anonymous','false') <> 'true' then
   raise exception '學生身分驗證失敗' using errcode='42501'; end if;
 select * into v_q from public.cp2_questions where id=p_question for share;
 if not found or v_q.status <> 'published' or (v_q.ends_at is not null and clock_timestamp()>=v_q.ends_at) then
   raise exception '題目已結束或不存在'; end if;
 if not exists(select 1 from public.cp2_rooms r where r.id=v_q.room_id and r.is_active) then
   raise exception '教室已停用'; end if;
 if p_choice<0 or p_choice>=jsonb_array_length(v_q.options) then raise exception '選項超出範圍'; end if;
 select id into v_sid from public.cp2_students where room_id=v_q.room_id and auth_uid=auth.uid() and is_active;
 if v_sid is null then raise exception '未通過班級名冊驗證' using errcode='42501'; end if;
 -- Atomic unique-vote protection: concurrent requests cannot overwrite when changes are disabled.
 if v_q.allow_changes then
   insert into public.cp2_votes(question_id,student_id,choice) values(p_question,v_sid,p_choice)
   on conflict(question_id,student_id) do update set choice=excluded.choice,updated_at=now()
   returning id into v_id;
 else
   insert into public.cp2_votes(question_id,student_id,choice) values(p_question,v_sid,p_choice)
   on conflict(question_id,student_id) do nothing returning id into v_id;
   if v_id is null then raise exception '此題已作答，不允許再次提交'; end if;
 end if;
 return v_id;
end; $$;
