-- Fix information disclosure when joining with an unknown student number.
-- Same error is returned for inactive/unknown student and incorrect access code.
create or replace function private.cp2_join(p_code text,p_number text,p_access text)
returns table(student_id uuid,room_id uuid,display_name text,room_title text)
language plpgsql security definer set search_path='' as $$
declare v_r public.cp2_rooms%rowtype; v_s public.cp2_students%rowtype; v_uid uuid;
begin
 v_uid:=auth.uid();
 if v_uid is null or coalesce(auth.jwt()->>'is_anonymous','false') <> 'true' then
   raise exception '學生端必須使用匿名驗證身分' using errcode='42501'; end if;
 select * into v_r from public.cp2_rooms where code=upper(trim(p_code)) and is_active;
 if not found then raise exception '教室不存在或已關閉'; end if;
 select * into v_s from public.cp2_students s where s.room_id=v_r.id and s.student_no=trim(p_number) for update;
 if not found or not v_s.is_active then raise exception '入班身分驗證失敗，請確認學號與個人入班碼'; end if;
 if v_s.access_hash <> encode(extensions.digest(coalesce(p_access,''),'sha256'),'hex') then
   raise exception '入班身分驗證失敗，請確認學號與個人入班碼'; end if;
 if v_s.auth_uid is not null and v_s.auth_uid <> v_uid then
   raise exception '此學號已綁定另一個裝置，請聯繫教師重設'; end if;
 update public.cp2_students set auth_uid=v_uid,joined_at=coalesce(joined_at,now()),last_seen=now() where id=v_s.id;
 insert into public.cp2_attendance(student_id,room_id,attended_on) values(v_s.id,v_r.id,(now() at time zone 'Asia/Taipei')::date) on conflict do nothing;
 return query select v_s.id,v_r.id,v_s.display_name,v_r.title;
end; $$;
