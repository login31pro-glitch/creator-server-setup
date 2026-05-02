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

