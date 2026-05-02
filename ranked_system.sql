-- Ranked System (Pure Core Layer)
-- Independence Principle: NO dependencies on profiles, matches, or tournaments.

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

-- Assuming service role / authorized contexts manage this typically. 
-- In pure client-side mode with direct RPC or client modification, we'll allow trusted updates.
-- Realistically, Ranked Data should be updated securely, but for functional MVP without specific server restrictions:
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
