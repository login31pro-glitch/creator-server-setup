CREATE OR REPLACE FUNCTION perform_backend_rpc(p_secret text, p_action text, p_data jsonb DEFAULT '{}')
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF p_secret != 'SUPER_SECRET_BACKEND_TOKEN_777' THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  IF p_action = 'insert_tournament' THEN
    INSERT INTO public.tournaments (name, description, tournament_type, status, start_time, max_players, match_rounds, settings, is_public)
    VALUES (
      p_data->>'name',
      p_data->>'description',
      p_data->>'tournament_type',
      p_data->>'status',
      (p_data->>'start_time')::timestamptz,
      (p_data->>'max_players')::integer,
      (p_data->>'match_rounds')::integer,
      p_data->'settings',
      (p_data->>'is_public')::boolean
    );
    RETURN '{"success": true}'::jsonb;
  ELSIF p_action = 'insert_challenge' THEN
    INSERT INTO public.challenges (challenge_type, seed, settings, start_time, end_time, is_active)
    VALUES (
      p_data->>'challenge_type',
      p_data->>'seed',
      p_data->'settings',
      (p_data->>'start_time')::timestamptz,
      (p_data->>'end_time')::timestamptz,
      (p_data->>'is_active')::boolean
    );
    RETURN '{"success": true}'::jsonb;
  ELSIF p_action = 'archive_challenge' THEN
    UPDATE public.challenges SET is_active = false WHERE id = (p_data->>'id')::uuid;
    RETURN '{"success": true}'::jsonb;
  END IF;

  RETURN '{"error": "Unknown action"}'::jsonb;
END;
$$;
