CREATE TABLE IF NOT EXISTS public.challenges (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    challenge_type TEXT NOT NULL CHECK (challenge_type IN ('daily', 'weekly_easy', 'weekly_hard', 'custom')),
    name TEXT,
    description TEXT,
    creator_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    is_public BOOLEAN DEFAULT true,
    seed TEXT NOT NULL,
    settings JSONB NOT NULL,
    start_time TIMESTAMP WITH TIME ZONE NOT NULL,
    end_time TIMESTAMP WITH TIME ZONE NOT NULL,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

CREATE TABLE IF NOT EXISTS public.challenge_runs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    challenge_id UUID NOT NULL REFERENCES public.challenges(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    highest_percent INTEGER NOT NULL DEFAULT 0,
    attempts INTEGER NOT NULL DEFAULT 0,
    avg_percent NUMERIC NOT NULL DEFAULT 0,
    best_run_time TIMESTAMP WITH TIME ZONE,
    is_valid BOOLEAN DEFAULT true,
    run_data JSONB NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
    UNIQUE(challenge_id, user_id)
);

CREATE TABLE IF NOT EXISTS public.run_flags (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    run_type TEXT NOT NULL CHECK (run_type IN ('challenge')),
    run_id UUID NOT NULL,
    flagger_id UUID NOT NULL REFERENCES auth.users(id),
    reason TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
    UNIQUE(run_type, run_id, flagger_id)
);

-- Profile Additions
DO $$ 
BEGIN 
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='profiles' AND column_name='receive_tournament_emails') THEN 
    ALTER TABLE public.profiles ADD COLUMN receive_tournament_emails BOOLEAN DEFAULT true;
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='profiles' AND column_name='is_content_creator') THEN 
    ALTER TABLE public.profiles ADD COLUMN is_content_creator BOOLEAN DEFAULT false;
  END IF;
END $$;

-- RLS
ALTER TABLE public.challenges ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.challenge_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.run_flags ENABLE ROW LEVEL SECURITY;

-- Read policies (Everyone can read public data)
DROP POLICY IF EXISTS "Public read access for challenges" ON public.challenges;
CREATE POLICY "Public read access for challenges" ON public.challenges FOR SELECT USING (true);

DROP POLICY IF EXISTS "Public read access for challenge_runs" ON public.challenge_runs;
CREATE POLICY "Public read access for challenge_runs" ON public.challenge_runs FOR SELECT USING (true);

DROP POLICY IF EXISTS "Public read access for run_flags" ON public.run_flags;
CREATE POLICY "Public read access for run_flags" ON public.run_flags FOR SELECT USING (true);

-- Insert policies
-- Users can insert their own challenge runs
DROP POLICY IF EXISTS "Users can insert own challenge_runs" ON public.challenge_runs;
CREATE POLICY "Users can insert own challenge_runs" ON public.challenge_runs FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);

-- Users can flag runs
DROP POLICY IF EXISTS "Users can flag runs" ON public.run_flags;
CREATE POLICY "Users can flag runs" ON public.run_flags FOR INSERT TO authenticated WITH CHECK (auth.uid() = flagger_id);

-- Creators can update challenges
DROP POLICY IF EXISTS "Creators can update challenges" ON public.challenges;
CREATE POLICY "Creators can update challenges" ON public.challenges FOR UPDATE TO authenticated USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND (is_content_creator = true OR is_the_creator = true))
);

-- Creators can delete challenges
DROP POLICY IF EXISTS "Creators can delete challenges" ON public.challenges;
CREATE POLICY "Creators can delete challenges" ON public.challenges FOR DELETE TO authenticated USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND (is_content_creator = true OR is_the_creator = true))
);

-- Service role has full access
DROP POLICY IF EXISTS "Service role all access challenges" ON public.challenges;
CREATE POLICY "Service role all access challenges" ON public.challenges FOR ALL TO service_role USING (true);

DROP POLICY IF EXISTS "Service role all access challenge_runs" ON public.challenge_runs;
CREATE POLICY "Service role all access challenge_runs" ON public.challenge_runs FOR ALL TO service_role USING (true);

DROP POLICY IF EXISTS "Service role all access run_flags" ON public.run_flags;
CREATE POLICY "Service role all access run_flags" ON public.run_flags FOR ALL TO service_role USING (true);
