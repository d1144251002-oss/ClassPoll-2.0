-- 1. FIRST create a permanent Email/Password user in Supabase > Authentication > Users.
-- 2. Replace the sample email below with the actual confirmed teacher's email.
-- 3. Execute this SQL as DB administrator. NEVER expose a self-service teacher role grant.
insert into public.cp2_teachers(user_id,label)
select id, '授課教師' from auth.users
where email = 'REPLACE_WITH_TEACHER_EMAIL@example.edu'
  and (is_anonymous is distinct from true)
on conflict(user_id) do update set label=excluded.label;

-- Verify the result (expect 1 row):
select t.user_id,u.email,t.label from public.cp2_teachers t
join auth.users u on u.id=t.user_id
where u.email='REPLACE_WITH_TEACHER_EMAIL@example.edu';
