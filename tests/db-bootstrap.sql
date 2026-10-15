-- Only used inside disposable GitHub Actions PostgreSQL service.
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE SCHEMA auth;
CREATE TABLE auth.users(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 email text UNIQUE,
 is_anonymous boolean NOT NULL DEFAULT false,
 created_at timestamptz DEFAULT now(),
 updated_at timestamptz DEFAULT now()
);
CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid LANGUAGE sql STABLE AS $$
 SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid;
$$;
CREATE OR REPLACE FUNCTION auth.jwt()
RETURNS jsonb LANGUAGE sql STABLE AS $$
 SELECT coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb;
$$;
GRANT USAGE ON SCHEMA auth TO authenticated;
GRANT EXECUTE ON FUNCTION auth.uid(), auth.jwt() TO authenticated;
