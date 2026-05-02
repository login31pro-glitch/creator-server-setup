-- Run this in your Supabase SQL Editor to update the promotion request logic to include a reason.

ALTER TABLE public.mod_promotion_requests ADD COLUMN IF NOT EXISTS reason text;

CREATE OR REPLACE FUNCTION public.mod_request_promotion(p_target_user_id uuid, p_reason text)
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
        INSERT INTO public.mod_promotion_requests (target_user_id, requester_id, reason) VALUES (p_target_user_id, auth.uid(), p_reason);
    END IF;
END;
$$;
