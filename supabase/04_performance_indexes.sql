-- ClassPoll 2.0: foreign-key supporting indexes for growing rosters and votes.
-- Safe to run more than once; no application data is changed.
CREATE INDEX IF NOT EXISTS cp2_bank_owner_id_idx
  ON public.cp2_bank(owner_id);
CREATE INDEX IF NOT EXISTS cp2_rooms_owner_id_idx
  ON public.cp2_rooms(owner_id);
CREATE INDEX IF NOT EXISTS cp2_students_auth_uid_idx
  ON public.cp2_students(auth_uid);
CREATE INDEX IF NOT EXISTS cp2_votes_student_id_idx
  ON public.cp2_votes(student_id);
