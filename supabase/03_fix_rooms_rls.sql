-- ClassPoll 2.0 production hotfix for existing installations.
-- Fixes "new row violates row-level security policy for table cp2_rooms"
-- when the teacher UI uses INSERT ... RETURNING.
-- Preserve RLS: only a registered teacher can see their own rooms.
BEGIN;
DROP POLICY IF EXISTS cp2_rooms_read ON public.cp2_rooms;
CREATE POLICY cp2_rooms_read ON public.cp2_rooms FOR SELECT TO authenticated
USING (
  (owner_id = (SELECT auth.uid()) AND (SELECT private.cp2_is_teacher()))
  OR private.cp2_member(id)
);
COMMIT;

-- Verify without changing data:
-- SELECT policyname, qual FROM pg_policies
-- WHERE schemaname='public' AND tablename='cp2_rooms';
