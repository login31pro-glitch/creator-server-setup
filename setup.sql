-- 0. Profiles Table
CREATE TABLE IF NOT EXISTS public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  username TEXT UNIQUE NOT NULL,
  verified BOOLEAN DEFAULT false,
  is_the_creator BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- Add any new columns that might be missing dynamically safely
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='profiles' AND column_name='banned_until') THEN
        ALTER TABLE public.profiles ADD COLUMN banned_until TIMESTAMP WITH TIME ZONE;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='profiles' AND column_name='restricted_until') THEN
        ALTER TABLE public.profiles ADD COLUMN restricted_until TIMESTAMP WITH TIME ZONE;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='profiles' AND column_name='is_the_creator') THEN
        ALTER TABLE public.profiles ADD COLUMN is_the_creator BOOLEAN DEFAULT false;
    END IF;
    
    -- Assign The Creator role to the initial creator
    UPDATE public.profiles SET is_the_creator = true WHERE username IN ('Login31', 'The Creator', 'The_Creator') AND is_the_creator = false;
END $$;

-- Profiles RLS
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Public profiles are viewable by everyone" ON public.profiles;
DROP POLICY IF EXISTS "Users can insert their own profile" ON public.profiles;
DROP POLICY IF EXISTS "Users can update their own profile" ON public.profiles;
CREATE POLICY "Public profiles are viewable by everyone" ON public.profiles FOR SELECT USING (true);
CREATE POLICY "Users can insert their own profile" ON public.profiles FOR INSERT WITH CHECK (auth.uid() = id);
CREATE POLICY "Users can update their own profile" ON public.profiles FOR UPDATE USING (auth.uid() = id);

CREATE OR REPLACE FUNCTION public.check_pg_net() RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  RETURN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net');
END;
$$;
CREATE OR REPLACE FUNCTION public.handle_new_user() 
RETURNS trigger AS $$
BEGIN
  INSERT INTO public.profiles (id, username, verified, is_the_creator)
  VALUES (new.id, new.raw_user_meta_data->>'username', false, (new.email = 'login31pro@gmail.com'));
  RETURN new;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

BEGIN;
  DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
  CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE PROCEDURE public.handle_new_user();
COMMIT;

-- 1. Create email verification table
CREATE TABLE IF NOT EXISTS public.email_verification_codes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  code TEXT NOT NULL,
  expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- Index for faster lookups
CREATE INDEX IF NOT EXISTS idx_email_verification_codes_user_id ON public.email_verification_codes(user_id);

-- Only service role can access this table directly
ALTER TABLE public.email_verification_codes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Service role can perform all on email_verification_codes" ON public.email_verification_codes;
CREATE POLICY "Service role can perform all on email_verification_codes" ON public.email_verification_codes FOR ALL USING (auth.jwt()->>'role' = 'service_role');

-- Create RPC Functions to replace Edge Functions safely

-- Generate verification code safely via postgres
CREATE OR REPLACE FUNCTION public.generate_verification_code(p_user_id uuid, p_email text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    new_code text;
BEGIN
    -- Delete any existing codes for this user to ensure only 1 active code at a time
    DELETE FROM public.email_verification_codes WHERE user_id = p_user_id;

    -- Generate 6 digit code
    new_code := floor(random() * 900000 + 100000)::text;
    
    -- Insert it behind the scenes
    INSERT INTO public.email_verification_codes (user_id, email, code, expires_at)
    VALUES (p_user_id, p_email, new_code, now() + interval '10 minutes');
    
    -- Return to the client so it can pass it to the Node backend to dispatch the email
    RETURN new_code;
END;
$$;

-- Verify the code safely via postgres
CREATE OR REPLACE FUNCTION public.verify_email_code(p_user_id uuid, user_code text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    valid_record_id uuid;
BEGIN
    -- Also clean up expired codes globally opportunistically just to keep table clean
    DELETE FROM public.email_verification_codes WHERE expires_at < now();

    SELECT id INTO valid_record_id
    FROM public.email_verification_codes
    WHERE user_id = p_user_id
      AND code = user_code
      AND expires_at >= now()
    ORDER BY created_at DESC
    LIMIT 1;
    
    IF valid_record_id IS NOT NULL THEN
        UPDATE public.profiles SET verified = true WHERE id = p_user_id;
        DELETE FROM public.email_verification_codes WHERE user_id = p_user_id;
        RETURN true;
    END IF;
    
    RETURN false;
END;
$$;

-- Cleanup when user aborts setup
CREATE OR REPLACE FUNCTION public.cleanup_verification_codes(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    DELETE FROM public.email_verification_codes WHERE user_id = p_user_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.lookup_email_by_username(p_username text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    found_email text;
BEGIN
    SELECT au.email INTO found_email
    FROM auth.users au
    JOIN public.profiles pp ON au.id = pp.id
    WHERE pp.username = p_username;
    
    RETURN found_email;
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_own_account()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;
    
    DELETE FROM auth.users WHERE id = auth.uid();
END;
$$;

-- Allow cleaning up an unverified user so they can sign up again if they dropped off
CREATE OR REPLACE FUNCTION public.delete_unverified_user(p_email text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    target_user_id uuid;
    is_verified boolean;
BEGIN
    SELECT id INTO target_user_id FROM auth.users WHERE email = p_email;
    IF target_user_id IS NULL THEN
        RETURN true; -- User doesn't exist, we're good
    END IF;
    
    SELECT verified INTO is_verified FROM public.profiles WHERE id = target_user_id;
    IF is_verified = true THEN
        RETURN false; -- User is verified, cannot delete
    END IF;
    
    -- Not verified, delete them to allow fresh signup
    DELETE FROM auth.users WHERE id = target_user_id;
    RETURN true;
END;
$$;

-- 2. Notes Table
CREATE TABLE IF NOT EXISTS public.notes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  demon_id TEXT NOT NULL,
  content TEXT NOT NULL,
  author_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE,
  upvotes INTEGER DEFAULT 0,
  downvotes INTEGER DEFAULT 0
);

-- Add reply feature columns if they don't exist
ALTER TABLE public.notes
  ADD COLUMN IF NOT EXISTS parent_note_id UUID REFERENCES public.notes(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS parent_reply_id UUID REFERENCES public.notes(id) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS idx_notes_demon_id ON public.notes(demon_id);
CREATE INDEX IF NOT EXISTS idx_notes_parent_note_id ON public.notes(parent_note_id);

ALTER TABLE public.notes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Notes are visible to everyone" ON public.notes;
DROP POLICY IF EXISTS "Logged in users can insert notes" ON public.notes;
DROP POLICY IF EXISTS "Users can update their own notes" ON public.notes;
DROP POLICY IF EXISTS "Users can delete their own notes" ON public.notes;
CREATE POLICY "Notes are visible to everyone" ON public.notes FOR SELECT USING (true);
CREATE POLICY "Logged in users can insert notes" ON public.notes FOR INSERT 
WITH CHECK (
  auth.uid() = author_id 
  AND EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND verified = true)
);
CREATE POLICY "Users can update their own notes" ON public.notes FOR UPDATE
USING (auth.uid() = author_id);
CREATE POLICY "Users can delete their own notes" ON public.notes FOR DELETE
USING (auth.uid() = author_id);

CREATE OR REPLACE FUNCTION public.delete_note(target_note_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  note_author_id UUID;
BEGIN
  SELECT author_id INTO note_author_id
  FROM public.notes
  WHERE id = target_note_id;

  IF note_author_id = auth.uid() THEN
    DELETE FROM public.notes WHERE id = target_note_id;
  ELSE
    RAISE EXCEPTION 'Not authorized to delete this note';
  END IF;
END;
$$;

-- 3. Note Votes Table
CREATE TABLE IF NOT EXISTS public.note_votes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  note_id UUID REFERENCES public.notes(id) ON DELETE CASCADE,
  user_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  vote INTEGER NOT NULL CHECK (vote = 1 OR vote = -1),
  UNIQUE(note_id, user_id)
);

-- Fix constraints if tables already existed without ON DELETE CASCADE
ALTER TABLE public.note_votes
  DROP CONSTRAINT IF EXISTS note_votes_note_id_fkey,
  ADD CONSTRAINT note_votes_note_id_fkey FOREIGN KEY (note_id) REFERENCES public.notes(id) ON DELETE CASCADE;

ALTER TABLE public.notes
  DROP CONSTRAINT IF EXISTS notes_parent_note_id_fkey,
  ADD CONSTRAINT notes_parent_note_id_fkey FOREIGN KEY (parent_note_id) REFERENCES public.notes(id) ON DELETE CASCADE,
  DROP CONSTRAINT IF EXISTS notes_parent_reply_id_fkey,
  ADD CONSTRAINT notes_parent_reply_id_fkey FOREIGN KEY (parent_reply_id) REFERENCES public.notes(id) ON DELETE CASCADE;

ALTER TABLE public.note_votes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Note votes visible to everyone" ON public.note_votes;
DROP POLICY IF EXISTS "Users can insert note votes" ON public.note_votes;
DROP POLICY IF EXISTS "Users can update own note votes" ON public.note_votes;
DROP POLICY IF EXISTS "Users can delete own note votes" ON public.note_votes;
CREATE POLICY "Note votes visible to everyone" ON public.note_votes FOR SELECT USING (true);
CREATE POLICY "Users can insert note votes" ON public.note_votes FOR INSERT 
WITH CHECK (auth.uid() = user_id AND EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND verified = true));
CREATE POLICY "Users can update own note votes" ON public.note_votes FOR UPDATE 
USING (auth.uid() = user_id AND EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND verified = true));
CREATE POLICY "Users can delete own note votes" ON public.note_votes FOR DELETE USING (auth.uid() = user_id);

-- 4. Level Votes Table
CREATE TABLE IF NOT EXISTS public.level_votes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  demon_id TEXT NOT NULL,
  user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
  vote INTEGER NOT NULL CHECK (vote = 1 OR vote = -1),
  UNIQUE(demon_id, user_id)
);

ALTER TABLE public.level_votes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Level votes visible to everyone" ON public.level_votes;
DROP POLICY IF EXISTS "Users can insert level votes" ON public.level_votes;
DROP POLICY IF EXISTS "Users can update own level votes" ON public.level_votes;
DROP POLICY IF EXISTS "Users can delete own level votes" ON public.level_votes;
CREATE POLICY "Level votes visible to everyone" ON public.level_votes FOR SELECT USING (true);
CREATE POLICY "Users can insert level votes" ON public.level_votes FOR INSERT 
WITH CHECK (auth.uid() = user_id AND EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND verified = true));
CREATE POLICY "Users can update own level votes" ON public.level_votes FOR UPDATE 
USING (auth.uid() = user_id AND EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND verified = true));
CREATE POLICY "Users can delete own level votes" ON public.level_votes FOR DELETE USING (auth.uid() = user_id);

-- 5. Username Changes
CREATE TABLE IF NOT EXISTS public.pending_username_changes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
  new_username TEXT NOT NULL,
  code TEXT NOT NULL,
  expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
  UNIQUE(user_id)
);

ALTER TABLE public.pending_username_changes ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.username_revert_tokens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
  previous_username TEXT NOT NULL,
  token UUID DEFAULT gen_random_uuid() NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
  UNIQUE(user_id)
);

ALTER TABLE public.username_revert_tokens ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.request_username_change(new_username text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    new_code text;
    v_exists boolean;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    -- Check if username exists
    SELECT EXISTS (
        SELECT 1 FROM public.profiles WHERE lower(username) = lower(new_username)
    ) INTO v_exists;

    IF v_exists THEN
        RAISE EXCEPTION 'Username already taken';
    END IF;

    -- Generate code
    new_code := floor(random() * 900000 + 100000)::text;

    -- Upsert pending change
    INSERT INTO public.pending_username_changes (user_id, new_username, code, expires_at)
    VALUES (auth.uid(), new_username, new_code, now() + interval '10 minutes')
    ON CONFLICT (user_id) DO UPDATE SET
        new_username = EXCLUDED.new_username,
        code = EXCLUDED.code,
        expires_at = EXCLUDED.expires_at,
        created_at = now();

    RETURN new_code;
END;
$$;

CREATE OR REPLACE FUNCTION public.verify_username_change(user_code text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_pending public.pending_username_changes;
    v_old_username text;
    v_revert_token uuid;
    v_user_email text;
BEGIN
    DELETE FROM public.pending_username_changes WHERE expires_at < now();

    SELECT * INTO v_pending
    FROM public.pending_username_changes
    WHERE user_id = auth.uid() AND code = user_code
    LIMIT 1;

    IF v_pending.id IS NULL THEN
        RAISE EXCEPTION 'Invalid or expired code';
    END IF;

    SELECT username INTO v_old_username FROM public.profiles WHERE id = auth.uid();

    DELETE FROM public.username_revert_tokens WHERE user_id = auth.uid();

    INSERT INTO public.username_revert_tokens (user_id, previous_username)
    VALUES (auth.uid(), v_old_username)
    RETURNING token INTO v_revert_token;

    UPDATE public.profiles SET username = v_pending.new_username WHERE id = auth.uid();

    SELECT email INTO v_user_email FROM auth.users WHERE id = auth.uid();

    DELETE FROM public.pending_username_changes WHERE id = v_pending.id;

    RETURN json_build_object(
        'email', v_user_email,
        'revert_token', v_revert_token,
        'old_username', v_old_username,
        'new_username', v_pending.new_username
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.revert_username(revert_token uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_token_record public.username_revert_tokens;
    v_user_email text;
BEGIN
    SELECT * INTO v_token_record
    FROM public.username_revert_tokens
    WHERE token = revert_token
    LIMIT 1;

    IF v_token_record.id IS NULL THEN
        RAISE EXCEPTION 'Invalid or expired token';
    END IF;

    UPDATE public.profiles SET username = v_token_record.previous_username WHERE id = v_token_record.user_id;

    SELECT email INTO v_user_email FROM auth.users WHERE id = v_token_record.user_id;

    DELETE FROM auth.sessions WHERE user_id = v_token_record.user_id;

    DELETE FROM public.username_revert_tokens WHERE id = v_token_record.id;

    RETURN json_build_object(
        'email', v_user_email,
        'username', v_token_record.previous_username
    );
END;
$$;

-- MODERATOR SYSTEM

DO $$ 
BEGIN 
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='profiles' AND column_name='mod_rank') THEN 
    ALTER TABLE public.profiles ADD COLUMN mod_rank INTEGER DEFAULT 0;
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='profiles' AND column_name='is_banned') THEN 
    ALTER TABLE public.profiles ADD COLUMN is_banned BOOLEAN DEFAULT false;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='profiles' AND column_name='warnings_count') THEN 
    ALTER TABLE public.profiles ADD COLUMN warnings_count INTEGER DEFAULT 0;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='notes' AND column_name='is_deleted') THEN 
    ALTER TABLE public.notes ADD COLUMN is_deleted BOOLEAN DEFAULT false;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.get_user_mod_rank(user_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_rank integer;
    v_is_banned boolean;
    v_is_creator boolean;
BEGIN
    IF user_id IS NULL THEN RETURN 0; END IF;
    
    SELECT mod_rank, is_banned, is_the_creator INTO v_rank, v_is_banned, v_is_creator
    FROM public.profiles WHERE id = user_id;
    
    IF v_is_creator = true THEN
        RETURN 4; -- pseudo-rank for Creator
    END IF;

    IF v_is_banned THEN
        RETURN 0;
    END IF;

    RETURN coalesce(v_rank, 0);
END;
$$;

CREATE TABLE IF NOT EXISTS public.mod_audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    action_type TEXT NOT NULL,
    target_user_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    moderator_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    moderator_rank INTEGER NOT NULL,
    details TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

ALTER TABLE public.mod_audit_logs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Rank 3 and Creator can view audit logs" ON public.mod_audit_logs;
CREATE POLICY "Rank 3 and Creator can view audit logs" ON public.mod_audit_logs FOR SELECT USING (
    public.get_user_mod_rank(auth.uid()) >= 3
);

CREATE TABLE IF NOT EXISTS public.mod_promotion_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    target_user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    requester_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

ALTER TABLE public.mod_promotion_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Rank 3 and Creator can view promotion requests" ON public.mod_promotion_requests;
CREATE POLICY "Rank 3 and Creator can view promotion requests" ON public.mod_promotion_requests FOR SELECT USING (
    public.get_user_mod_rank(auth.uid()) >= 3
);

-- RPC for logging mod actions securely
CREATE OR REPLACE FUNCTION public.log_mod_action(p_action_type text, p_target_user_id uuid, p_details text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_mod_rank integer;
BEGIN
    v_mod_rank := public.get_user_mod_rank(auth.uid());
    IF v_mod_rank < 1 THEN
        RAISE EXCEPTION 'Access denied';
    END IF;
    
    INSERT INTO public.mod_audit_logs (action_type, target_user_id, moderator_id, moderator_rank, details)
    VALUES (p_action_type, p_target_user_id, auth.uid(), v_mod_rank, p_details);
END;
$$;

-- Secure moderation RPCs

CREATE TABLE IF NOT EXISTS public.user_warnings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    reason TEXT NOT NULL,
    source TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc', now()) NOT NULL
);
ALTER TABLE public.user_warnings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Mods view warnings" ON public.user_warnings;
CREATE POLICY "Mods view warnings" ON public.user_warnings FOR SELECT USING (
    public.get_user_mod_rank(auth.uid()) >= 1 OR auth.uid() = user_id
);


DROP FUNCTION IF EXISTS public.handle_warning_backend(uuid, text);
DROP FUNCTION IF EXISTS public.handle_warning_backend(uuid, text, text);
CREATE OR REPLACE FUNCTION public.handle_warning_backend(p_target_user_id uuid, p_reason text, p_source text, p_secret text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_wc integer;
    v_punishment text := 'none';
    v_email text;
BEGIN
    IF p_secret != 'gd_demon_notes_internal_secret_9912' THEN
        RAISE EXCEPTION 'Access denied';
    END IF;

    SELECT email INTO v_email FROM auth.users WHERE id = p_target_user_id;

    -- increment warning count
    UPDATE public.profiles
    SET warnings_count = COALESCE(warnings_count, 0) + 1
    WHERE id = p_target_user_id
    RETURNING warnings_count INTO v_wc;

    -- Store warning log
    INSERT INTO public.user_warnings (user_id, reason, source)
    VALUES (p_target_user_id, p_reason, p_source);

    -- Apply punishment
    IF v_wc = 2 OR v_wc = 3 THEN
        UPDATE public.profiles SET restricted_until = now() + interval '15 minutes' WHERE id = p_target_user_id;
        v_punishment := 'restricted_15m';
    ELSIF v_wc = 4 OR v_wc = 5 THEN
        UPDATE public.profiles SET banned_until = now() + interval '24 hours' WHERE id = p_target_user_id;
        v_punishment := 'banned_24h';
    ELSIF v_wc = 6 THEN
        UPDATE public.profiles SET banned_until = now() + interval '1 week' WHERE id = p_target_user_id;
        v_punishment := 'banned_1w';
    ELSIF v_wc = 7 THEN
        UPDATE public.profiles SET banned_until = now() + interval '2 weeks' WHERE id = p_target_user_id;
        v_punishment := 'banned_2w';
    ELSIF v_wc >= 8 THEN
        UPDATE public.profiles SET is_banned = true WHERE id = p_target_user_id;
        v_punishment := 'banned_permanent';
    END IF;
    
    INSERT INTO public.mod_audit_logs (action_type, target_user_id, moderator_id, moderator_rank, details)
    VALUES ('issue_warning', p_target_user_id, p_target_user_id, 0, 'Source: ' || p_source || ' | Reason: ' || p_reason || ' | Set WC to: ' || v_wc);

    RETURN json_build_object('warnings_count', v_wc, 'punishment', v_punishment, 'email', v_email);
END;
$$;

GRANT EXECUTE ON FUNCTION public.handle_warning_backend(uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.handle_warning_backend(uuid, text, text, text) TO anon;
GRANT EXECUTE ON FUNCTION public.handle_warning_backend(uuid, text, text, text) TO service_role;

DROP FUNCTION IF EXISTS public.mod_delete_note(uuid, text);
CREATE OR REPLACE FUNCTION public.mod_delete_note(p_note_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_mod_rank integer;
    v_note_author uuid;
    v_upvotes integer;
BEGIN
    v_mod_rank := public.get_user_mod_rank(auth.uid());
    IF v_mod_rank < 1 THEN RAISE EXCEPTION 'Access denied'; END IF;

    SELECT author_id INTO v_note_author FROM public.notes WHERE id = p_note_id;

    IF v_mod_rank = 1 THEN
        SELECT COUNT(*) INTO v_upvotes FROM public.notes WHERE parent_note_id = p_note_id AND demon_id = 'REPORT';
        IF v_upvotes < 5 THEN
            RAISE EXCEPTION 'Access denied: Rank 1 moderators can only delete notes with 5 or more reports';
        END IF;
    END IF;

    UPDATE public.notes SET is_deleted = true WHERE id = p_note_id;
    
    PERFORM public.log_mod_action('delete_note', v_note_author, 'Note ID: ' || p_note_id);
    
    RETURN json_build_object('author_id', v_note_author);
END;
$$;

CREATE OR REPLACE FUNCTION public.mod_restore_note(p_note_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_mod_rank integer;
    v_note_author uuid;
BEGIN
    v_mod_rank := public.get_user_mod_rank(auth.uid());
    IF v_mod_rank < 2 THEN RAISE EXCEPTION 'Access denied: Requires Rank 2+'; END IF;

    SELECT author_id INTO v_note_author FROM public.notes WHERE id = p_note_id;

    UPDATE public.notes SET is_deleted = false WHERE id = p_note_id;
    
    PERFORM public.log_mod_action('restore_note', v_note_author, 'Note ID: ' || p_note_id);

    -- Clear reports when restoring
    DELETE FROM public.notes WHERE demon_id = 'REPORT' AND parent_note_id = p_note_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.mod_ban_user(p_target_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_mod_rank integer;
    v_target_is_creator boolean;
BEGIN
    v_mod_rank := public.get_user_mod_rank(auth.uid());
    IF v_mod_rank < 3 THEN RAISE EXCEPTION 'Access denied: Requires Rank 3+'; END IF;
    
    IF auth.uid() = p_target_user_id THEN RAISE EXCEPTION 'Cannot ban yourself'; END IF;

    SELECT is_the_creator INTO v_target_is_creator FROM public.profiles WHERE id = p_target_user_id;
    IF v_target_is_creator = true THEN RAISE EXCEPTION 'Cannot ban Creator'; END IF;

    UPDATE public.profiles SET is_banned = true WHERE id = p_target_user_id;
    PERFORM public.log_mod_action('ban_user', p_target_user_id, 'Instantly banned user');
END;
$$;

CREATE OR REPLACE FUNCTION public.mod_unban_user(p_target_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_mod_rank integer;
BEGIN
    v_mod_rank := public.get_user_mod_rank(auth.uid());
    IF v_mod_rank < 3 THEN RAISE EXCEPTION 'Access denied: Requires Rank 3+'; END IF;

    IF auth.uid() = p_target_user_id THEN RAISE EXCEPTION 'Cannot unban yourself'; END IF;

    UPDATE public.profiles SET is_banned = false WHERE id = p_target_user_id;
    PERFORM public.log_mod_action('unban_user', p_target_user_id, 'Instantly unbanned user');
END;
$$;

CREATE OR REPLACE FUNCTION public.mod_set_rank(p_target_user_id uuid, p_new_rank integer)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_mod_rank integer;
    v_target_is_creator boolean;
    v_current_rank integer;
BEGIN
    v_mod_rank := public.get_user_mod_rank(auth.uid());
    IF v_mod_rank < 3 THEN RAISE EXCEPTION 'Access denied: Requires Rank 3+'; END IF;
    
    IF auth.uid() = p_target_user_id THEN RAISE EXCEPTION 'Cannot alter your own rank'; END IF;

    SELECT is_the_creator, mod_rank INTO v_target_is_creator, v_current_rank FROM public.profiles WHERE id = p_target_user_id;
    IF v_target_is_creator = true THEN RAISE EXCEPTION 'Cannot demote/promote Creator'; END IF;
    
    -- Clear pending requests
    DELETE FROM public.mod_promotion_requests WHERE target_user_id = p_target_user_id;

    UPDATE public.profiles SET mod_rank = p_new_rank WHERE id = p_target_user_id;
    PERFORM public.log_mod_action('modify_rank', p_target_user_id, 'Changed rank from ' || COALESCE(v_current_rank, 0) || ' to ' || p_new_rank);
END;
$$;

CREATE OR REPLACE FUNCTION public.mod_issue_warning(p_target_user_id uuid, p_reason text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_mod_rank integer;
    v_warn_count integer;
BEGIN
    v_mod_rank := public.get_user_mod_rank(auth.uid());
    IF v_mod_rank < 2 AND v_mod_rank != -99 THEN RAISE EXCEPTION 'Access denied'; END IF;

    UPDATE public.profiles SET warnings_count = warnings_count + 1 WHERE id = p_target_user_id RETURNING warnings_count INTO v_warn_count;
    PERFORM public.log_mod_action('issue_warning', p_target_user_id, 'Reason: ' || p_reason || ' (Total: ' || v_warn_count || ')');
    
    -- Restrictions and bans
    IF v_warn_count = 2 OR v_warn_count = 3 THEN
        UPDATE public.profiles SET restricted_until = now() + interval '15 minutes' WHERE id = p_target_user_id;
    ELSIF v_warn_count = 4 OR v_warn_count = 5 THEN
        UPDATE public.profiles SET banned_until = now() + interval '24 hours' WHERE id = p_target_user_id;
    ELSIF v_warn_count = 6 THEN
        UPDATE public.profiles SET banned_until = now() + interval '1 week' WHERE id = p_target_user_id;
    ELSIF v_warn_count = 7 THEN
        UPDATE public.profiles SET banned_until = now() + interval '2 weeks' WHERE id = p_target_user_id;
    ELSIF v_warn_count >= 8 THEN
        UPDATE public.profiles SET is_banned = true WHERE id = p_target_user_id;
        PERFORM public.log_mod_action('ban_user', p_target_user_id, 'Permanent ban due to 8+ warnings.');
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.mod_request_promotion(p_target_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_mod_rank integer;
    v_active_requests integer;
BEGIN
    v_mod_rank := public.get_user_mod_rank(auth.uid());
    
    -- Non-mods can only request for themselves
    IF v_mod_rank = 0 AND auth.uid() != p_target_user_id THEN
        RAISE EXCEPTION 'Non-mods can only request promotion for themselves';
    END IF;

    -- Non-mods max active requests = 1
    IF v_mod_rank = 0 THEN
        SELECT COUNT(*) INTO v_active_requests FROM public.mod_promotion_requests WHERE requester_id = auth.uid();
        IF v_active_requests > 0 THEN
            RAISE EXCEPTION 'You already have an active promotion request';
        END IF;
    END IF;

    -- Insert request if it doesn't already exist from this requester
    IF NOT EXISTS (SELECT 1 FROM public.mod_promotion_requests WHERE target_user_id = p_target_user_id AND requester_id = auth.uid()) THEN
        INSERT INTO public.mod_promotion_requests (target_user_id, requester_id) VALUES (p_target_user_id, auth.uid());
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.mod_clear_reports(p_note_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_mod_rank integer;
BEGIN
    v_mod_rank := public.get_user_mod_rank(auth.uid());
    IF v_mod_rank < 1 THEN RAISE EXCEPTION 'Access denied'; END IF;

    DELETE FROM public.notes WHERE demon_id = 'REPORT' AND parent_note_id = p_note_id;
    
    PERFORM public.log_mod_action('clear_reports', NULL, 'Note ID: ' || p_note_id);
END;
$$;

-- RLS changes for soft-deletes in Notes
DROP POLICY IF EXISTS "Notes are visible to everyone" ON public.notes;
CREATE POLICY "Notes are visible to everyone" ON public.notes FOR SELECT USING (
    is_deleted = false OR public.get_user_mod_rank(auth.uid()) >= 1
);

-- RLS to block banned users from making posts/votes
-- We actually just want to enforce this at the app layer, but RLS adds safety.
-- If someone's banned, we can just block inserts:
DROP POLICY IF EXISTS "Logged in users can insert notes" ON public.notes;
CREATE POLICY "Logged in users can insert notes" ON public.notes FOR INSERT 
WITH CHECK (
  auth.uid() = author_id 
  AND EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND verified = true AND is_banned = false)
);

DROP POLICY IF EXISTS "Users can insert note votes" ON public.note_votes;
CREATE POLICY "Users can insert note votes" ON public.note_votes FOR INSERT 
WITH CHECK (auth.uid() = user_id AND EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND verified = true AND is_banned = false));

DROP POLICY IF EXISTS "Users can update own note votes" ON public.note_votes;
CREATE POLICY "Users can update own note votes" ON public.note_votes FOR UPDATE 
USING (auth.uid() = user_id AND EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND verified = true AND is_banned = false));

DROP POLICY IF EXISTS "Users can insert level votes" ON public.level_votes;
CREATE POLICY "Users can insert level votes" ON public.level_votes FOR INSERT 
WITH CHECK (auth.uid() = user_id AND EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND verified = true AND is_banned = false));

DROP POLICY IF EXISTS "Users can update own level votes" ON public.level_votes;
CREATE POLICY "Users can update own level votes" ON public.level_votes FOR UPDATE 
USING (auth.uid() = user_id AND EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND verified = true AND is_banned = false));



CREATE TABLE IF NOT EXISTS public.mod_appeal_requests (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id uuid REFERENCES public.profiles(id) ON DELETE CASCADE,
    reason text NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    UNIQUE(user_id)
);

ALTER TABLE public.mod_appeal_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can request appeals" ON public.mod_appeal_requests;
CREATE POLICY "Users can request appeals"
    ON public.mod_appeal_requests FOR INSERT
    WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can view their own appeal requests" ON public.mod_appeal_requests;
CREATE POLICY "Users can view their own appeal requests"
    ON public.mod_appeal_requests FOR SELECT
    USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Mods can view appeal requests" ON public.mod_appeal_requests;
CREATE POLICY "Mods can view appeal requests"
    ON public.mod_appeal_requests FOR SELECT
    USING (public.get_user_mod_rank(auth.uid()) >= 1);

CREATE OR REPLACE FUNCTION public.mod_request_appeal(p_user_id uuid, p_reason text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    INSERT INTO public.mod_appeal_requests (user_id, reason)
    VALUES (p_user_id, p_reason)
    ON CONFLICT (user_id) DO UPDATE SET reason = p_reason, created_at = now();
END;
$$;

CREATE OR REPLACE FUNCTION public.mod_resolve_appeal(p_user_id uuid, p_approve boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    IF public.get_user_mod_rank(auth.uid()) < 2 THEN
        RAISE EXCEPTION 'Insufficient permissions';
    END IF;

    DELETE FROM public.mod_appeal_requests WHERE user_id = p_user_id;

    IF p_approve THEN
        PERFORM public.mod_unban_user(p_user_id);
    END IF;

    PERFORM public.log_mod_action('resolve_appeal', p_user_id, CASE WHEN p_approve THEN 'Approved appeal and unbanned' ELSE 'Denied appeal' END);
END;
$$;


CREATE OR REPLACE FUNCTION public.mod_reset_warnings(p_target_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_mod_rank integer;
BEGIN
    v_mod_rank := public.get_user_mod_rank(auth.uid());
    IF v_mod_rank < 3 THEN RAISE EXCEPTION 'Access denied'; END IF;
    UPDATE public.profiles SET warnings_count = 0, banned_until = null, restricted_until = null WHERE id = p_target_user_id;
    PERFORM public.log_mod_action('reset_warnings', p_target_user_id, 'Warnings manually reset to 0');
END;
$$;

DROP POLICY IF EXISTS "Users can view own requests" ON public.mod_promotion_requests; CREATE POLICY "Users can view own requests" ON public.mod_promotion_requests FOR SELECT USING (requester_id = auth.uid());


-- setup_auth_rpc.sql
-- Create extension pgcrypto if not exists
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS public.password_reset_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    token UUID DEFAULT gen_random_uuid(),
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    consumed BOOLEAN DEFAULT false,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

CREATE TABLE IF NOT EXISTS public.password_reset_confirmations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    reset_request_id UUID REFERENCES public.password_reset_requests(id) ON DELETE CASCADE,
    new_password_hash TEXT NOT NULL,
    code TEXT NOT NULL,
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    consumed BOOLEAN DEFAULT false,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

CREATE TABLE IF NOT EXISTS public.email_change_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    new_email TEXT NOT NULL,
    code TEXT NOT NULL,
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    consumed BOOLEAN DEFAULT false,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

CREATE TABLE IF NOT EXISTS public.auth_reversal_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    action_type TEXT NOT NULL CHECK (action_type IN ('password', 'email')),
    previous_data TEXT NOT NULL,
    token UUID DEFAULT gen_random_uuid(),
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    consumed BOOLEAN DEFAULT false,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

ALTER TABLE public.password_reset_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.password_reset_confirmations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.email_change_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.auth_reversal_tokens ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.request_password_reset(p_email text, p_username text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_user_id uuid;
    v_token uuid;
BEGIN
    SELECT au.id INTO v_user_id
    FROM auth.users au
    JOIN public.profiles pp ON au.id = pp.id
    WHERE lower(au.email) = lower(p_email) AND lower(pp.username) = lower(p_username);

    IF v_user_id IS NOT NULL THEN
        -- Check rate limit? Delete old
        DELETE FROM public.password_reset_requests WHERE user_id = v_user_id;

        INSERT INTO public.password_reset_requests (user_id, expires_at)
        VALUES (v_user_id, now() + interval '15 minutes')
        RETURNING token INTO v_token;

        RETURN json_build_object('success', true, 'token', v_token, 'user_id', v_user_id);
    END IF;

    RETURN json_build_object('success', false);
END;
$$;

CREATE OR REPLACE FUNCTION public.submit_new_password(p_token uuid, p_new_password text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_request public.password_reset_requests;
    v_code text;
    v_hash text;
BEGIN
    SELECT * INTO v_request
    FROM public.password_reset_requests
    WHERE token = p_token AND consumed = false AND expires_at > now();

    IF v_request.id IS NULL THEN
        RAISE EXCEPTION 'Invalid or expired token';
    END IF;

    v_code := floor(random() * 900000 + 100000)::text;
    v_hash := crypt(p_new_password, gen_salt('bf'));

    DELETE FROM public.password_reset_confirmations WHERE user_id = v_request.user_id;

    INSERT INTO public.password_reset_confirmations (user_id, reset_request_id, new_password_hash, code, expires_at)
    VALUES (v_request.user_id, v_request.id, v_hash, v_code, now() + interval '15 minutes');

    RETURN json_build_object(
        'code', v_code,
        'user_id', v_request.user_id
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.confirm_new_password(p_token uuid, p_code text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_request public.password_reset_requests;
    v_confirm public.password_reset_confirmations;
    v_old_hash text;
    v_reversal_token uuid;
    v_email text;
BEGIN
    SELECT * INTO v_request
    FROM public.password_reset_requests
    WHERE token = p_token AND consumed = false AND expires_at > now();

    IF v_request.id IS NULL THEN
        RAISE EXCEPTION 'Invalid or expired token';
    END IF;

    SELECT * INTO v_confirm
    FROM public.password_reset_confirmations
    WHERE reset_request_id = v_request.id AND code = p_code AND consumed = false AND expires_at > now();

    IF v_confirm.id IS NULL THEN
        RAISE EXCEPTION 'Invalid or expired verification code';
    END IF;

    SELECT encrypted_password, email INTO v_old_hash, v_email
    FROM auth.users
    WHERE id = v_request.user_id;

    -- Create reversal token
    INSERT INTO public.auth_reversal_tokens (user_id, action_type, previous_data, expires_at)
    VALUES (v_request.user_id, 'password', COALESCE(v_old_hash, ''), now() + interval '1 hour')
    RETURNING token INTO v_reversal_token;

    -- Update password
    UPDATE auth.users
    SET encrypted_password = v_confirm.new_password_hash, updated_at = now()
    WHERE id = v_request.user_id;

    -- Log out all sessions
    DELETE FROM auth.sessions WHERE user_id = v_request.user_id;
    DELETE FROM auth.refresh_tokens WHERE session_id IN (SELECT id FROM auth.sessions WHERE user_id = v_request.user_id);

    -- Consume
    UPDATE public.password_reset_requests SET consumed = true WHERE id = v_request.id;
    UPDATE public.password_reset_confirmations SET consumed = true WHERE id = v_confirm.id;

    RETURN json_build_object(
        'email', v_email,
        'reversal_token', v_reversal_token
    );
END;
$$;


CREATE OR REPLACE FUNCTION public.request_email_change(p_new_email text, p_username text, p_password text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_user_id uuid;
    v_valid_pwd boolean;
    v_code text;
    v_exists boolean;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    -- Validate username
    SELECT EXISTS (
        SELECT 1 FROM public.profiles WHERE id = v_user_id AND lower(username) = lower(p_username)
    ) INTO v_exists;

    IF NOT v_exists THEN
        RAISE EXCEPTION 'Invalid username';
    END IF;

    -- check if email taken
    SELECT EXISTS (
        SELECT 1 FROM auth.users WHERE lower(email) = lower(p_new_email)
    ) INTO v_exists;

    IF v_exists THEN
        RAISE EXCEPTION 'Email already in use';
    END IF;

    -- Validate password
    SELECT (encrypted_password = crypt(p_password, encrypted_password)) INTO v_valid_pwd
    FROM auth.users
    WHERE id = v_user_id;

    IF NOT COALESCE(v_valid_pwd, false) THEN
        RAISE EXCEPTION 'Invalid password';
    END IF;

    v_code := floor(random() * 900000 + 100000)::text;

    DELETE FROM public.email_change_requests WHERE user_id = v_user_id;

    INSERT INTO public.email_change_requests (user_id, new_email, code, expires_at)
    VALUES (v_user_id, p_new_email, v_code, now() + interval '15 minutes');

    RETURN v_code;
END;
$$;

CREATE OR REPLACE FUNCTION public.confirm_email_change(p_code text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_req public.email_change_requests;
    v_old_email text;
    v_reversal_token uuid;
    v_user_id uuid;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    SELECT * INTO v_req
    FROM public.email_change_requests
    WHERE user_id = v_user_id AND code = p_code AND consumed = false AND expires_at > now();

    IF v_req.id IS NULL THEN
        RAISE EXCEPTION 'Invalid or expired code';
    END IF;

    SELECT email INTO v_old_email
    FROM auth.users
    WHERE id = v_user_id;

    -- Build reversal token
    INSERT INTO public.auth_reversal_tokens (user_id, action_type, previous_data, expires_at)
    VALUES (v_user_id, 'email', v_old_email, now() + interval '2 hours')
    RETURNING token INTO v_reversal_token;

    -- Update email
    UPDATE auth.users
    SET email = v_req.new_email, email_confirmed_at = now()
    WHERE id = v_user_id;

    -- Log out all sessions
    DELETE FROM auth.sessions WHERE user_id = v_user_id;

    UPDATE public.email_change_requests SET consumed = true WHERE id = v_req.id;

    RETURN json_build_object(
        'old_email', v_old_email,
        'new_email', v_req.new_email,
        'reversal_token', v_reversal_token
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.revert_auth_change(p_reversal_token uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_rev public.auth_reversal_tokens;
    v_email text;
BEGIN
    SELECT * INTO v_rev
    FROM public.auth_reversal_tokens
    WHERE token = p_reversal_token AND consumed = false AND expires_at > now();

    IF v_rev.id IS NULL THEN
        RAISE EXCEPTION 'Invalid or expired token';
    END IF;

    IF v_rev.action_type = 'password' THEN
        UPDATE auth.users SET encrypted_password = v_rev.previous_data, updated_at = now() WHERE id = v_rev.user_id;
    ELSIF v_rev.action_type = 'email' THEN
        UPDATE auth.users SET email = v_rev.previous_data, email_confirmed_at = now() WHERE id = v_rev.user_id;
    END IF;

    -- Invalidate sessions
    DELETE FROM auth.sessions WHERE user_id = v_rev.user_id;

    -- Get user email for info
    SELECT email INTO v_email FROM auth.users WHERE id = v_rev.user_id;

    UPDATE public.auth_reversal_tokens SET consumed = true WHERE id = v_rev.id;

    -- Note: Also invalidate ANY pending username or email change requests for safety
    DELETE FROM public.password_reset_requests WHERE user_id = v_rev.user_id;
    DELETE FROM public.email_change_requests WHERE user_id = v_rev.user_id;
    DELETE FROM public.pending_username_changes WHERE user_id = v_rev.user_id;

    RETURN json_build_object(
        'success', true,
        'action_type', v_rev.action_type,
        'email', v_email
    );
END;
$$;

-- ============================================================================
-- RANKED SYSTEM (PURE CORE LAYER)
-- ============================================================================
-- Independence Principle: NO dependencies on profiles, matches, or tournaments.
-- Only manages ranking data, progression, and structure.

CREATE TABLE IF NOT EXISTS public.ranked_data (
    user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    ranked_points INTEGER NOT NULL DEFAULT 0,
    ranked_level INTEGER NOT NULL DEFAULT 1,
    rank_tier TEXT NOT NULL DEFAULT 'Unranked',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

CREATE TABLE IF NOT EXISTS public.ranked_logs (
    log_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    delta_points INTEGER NOT NULL,
    previous_points INTEGER NOT NULL,
    new_points INTEGER NOT NULL,
    reason TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- RLS for ranked_data
ALTER TABLE public.ranked_data ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Anyone can view ranked data" ON public.ranked_data;
CREATE POLICY "Anyone can view ranked data" ON public.ranked_data FOR SELECT USING (true);

-- Provide trusted updates mechanism (users modifying their own in MVP or trusted backend)
DROP POLICY IF EXISTS "Service role can modify ranked data" ON public.ranked_data;
CREATE POLICY "Service role can modify ranked data" ON public.ranked_data FOR ALL TO service_role USING (true);

DROP POLICY IF EXISTS "Authenticated users can modify their ranked data" ON public.ranked_data;
CREATE POLICY "Authenticated users can modify their ranked data" ON public.ranked_data FOR ALL TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- RLS for ranked_logs
ALTER TABLE public.ranked_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Anyone can view ranked logs" ON public.ranked_logs;
CREATE POLICY "Anyone can view ranked logs" ON public.ranked_logs FOR SELECT USING (true);

DROP POLICY IF EXISTS "Users can insert their own logs" ON public.ranked_logs;
CREATE POLICY "Users can insert their own logs" ON public.ranked_logs FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Service role can modify ranked logs" ON public.ranked_logs;
CREATE POLICY "Service role can modify ranked logs" ON public.ranked_logs FOR ALL TO service_role USING (true);

-- Protect profiles from direct client modifications
CREATE OR REPLACE FUNCTION public.protect_profile_fields() RETURNS trigger AS $$
BEGIN
  -- Prevent privilege escalation from direct client updates
  -- current_role evaluates to 'authenticated' or 'anon' when accessed via PostgREST
  IF current_role IN ('authenticated', 'anon') THEN
    IF NEW.is_the_creator IS DISTINCT FROM OLD.is_the_creator OR
       NEW.mod_rank IS DISTINCT FROM OLD.mod_rank OR
       NEW.is_banned IS DISTINCT FROM OLD.is_banned OR
       NEW.banned_until IS DISTINCT FROM OLD.banned_until OR
       NEW.restricted_until IS DISTINCT FROM OLD.restricted_until OR
       NEW.warnings_count IS DISTINCT FROM OLD.warnings_count OR
       NEW.verified IS DISTINCT FROM OLD.verified THEN
       RAISE EXCEPTION 'You are not allowed to update restricted profile fields directly. Please use the appropriate RPC/API endpoints.';
    END IF;

    IF NEW.username IS DISTINCT FROM OLD.username AND OLD.verified = true THEN
       RAISE EXCEPTION 'You cannot update your username directly once verified. Please use the username change request process.';
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS protect_profile_fields_trigger ON public.profiles;
CREATE TRIGGER protect_profile_fields_trigger
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE PROCEDURE public.protect_profile_fields();
