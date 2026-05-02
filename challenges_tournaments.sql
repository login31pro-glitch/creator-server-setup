-- Challenge and Tournament System

-- 1. Challenges
CREATE TABLE IF NOT EXISTS public.challenges (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    challenge_type TEXT NOT NULL CHECK (challenge_type IN ('daily', 'weekly_easy', 'weekly_hard')),
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

-- 2. Tournaments
CREATE TABLE IF NOT EXISTS public.tournaments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    description TEXT,
    tournament_type TEXT NOT NULL CHECK (tournament_type IN ('weekly', 'monthly', 'custom')),
    creator_id UUID REFERENCES auth.users(id),
    status TEXT NOT NULL CHECK (status IN ('signup', 'in_progress', 'completed', 'cancelled')),
    start_time TIMESTAMP WITH TIME ZONE NOT NULL,
    max_players INTEGER NOT NULL,
    current_phase TEXT,
    settings JSONB NOT NULL,
    match_rounds INTEGER NOT NULL DEFAULT 3,
    is_public BOOLEAN DEFAULT true,
    join_code TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

CREATE TABLE IF NOT EXISTS public.tournament_participants (
    tournament_id UUID NOT NULL REFERENCES public.tournaments(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    seed_number INTEGER,
    is_eliminated BOOLEAN DEFAULT false,
    final_placement TEXT,
    joined_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
    PRIMARY KEY(tournament_id, user_id)
);

CREATE TABLE IF NOT EXISTS public.tournament_matches (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tournament_id UUID NOT NULL REFERENCES public.tournaments(id) ON DELETE CASCADE,
    phase TEXT NOT NULL,
    match_number INTEGER NOT NULL,
    player1_id UUID REFERENCES auth.users(id),
    player2_id UUID REFERENCES auth.users(id), -- Null if BYE
    status TEXT NOT NULL CHECK (status IN ('pending', 'active', 'completed')),
    winner_id UUID REFERENCES auth.users(id),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

CREATE TABLE IF NOT EXISTS public.tournament_rounds (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    match_id UUID NOT NULL REFERENCES public.tournament_matches(id) ON DELETE CASCADE,
    round_number INTEGER NOT NULL,
    seed TEXT NOT NULL,
    start_time TIMESTAMP WITH TIME ZONE NOT NULL,
    end_time TIMESTAMP WITH TIME ZONE NOT NULL,
    player1_percent INTEGER,
    player2_percent INTEGER,
    player1_attempts INTEGER,
    player2_attempts INTEGER,
    winner_id UUID REFERENCES auth.users(id),
    status TEXT NOT NULL CHECK (status IN ('pending', 'active', 'completed')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

CREATE TABLE IF NOT EXISTS public.tournament_runs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    round_id UUID NOT NULL REFERENCES public.tournament_rounds(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    percent INTEGER NOT NULL,
    attempts INTEGER NOT NULL,
    run_data JSONB NOT NULL,
    is_valid BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
    UNIQUE(round_id, user_id)
);

CREATE TABLE IF NOT EXISTS public.run_flags (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    run_type TEXT NOT NULL CHECK (run_type IN ('challenge', 'tournament')),
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
ALTER TABLE public.tournaments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tournament_participants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tournament_matches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tournament_rounds ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tournament_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.run_flags ENABLE ROW LEVEL SECURITY;

-- Read policies (Everyone can read public data)
DROP POLICY IF EXISTS "Public read access for challenges" ON public.challenges;
CREATE POLICY "Public read access for challenges" ON public.challenges FOR SELECT USING (true);

DROP POLICY IF EXISTS "Public read access for challenge_runs" ON public.challenge_runs;
CREATE POLICY "Public read access for challenge_runs" ON public.challenge_runs FOR SELECT USING (true);

DROP POLICY IF EXISTS "Public read access for tournaments" ON public.tournaments;
CREATE POLICY "Public read access for tournaments" ON public.tournaments FOR SELECT USING (true);

DROP POLICY IF EXISTS "Public read access for tournament_participants" ON public.tournament_participants;
CREATE POLICY "Public read access for tournament_participants" ON public.tournament_participants FOR SELECT USING (true);

DROP POLICY IF EXISTS "Public read access for tournament_matches" ON public.tournament_matches;
CREATE POLICY "Public read access for tournament_matches" ON public.tournament_matches FOR SELECT USING (true);

DROP POLICY IF EXISTS "Public read access for tournament_rounds" ON public.tournament_rounds;
CREATE POLICY "Public read access for tournament_rounds" ON public.tournament_rounds FOR SELECT USING (true);

DROP POLICY IF EXISTS "Public read access for tournament_runs" ON public.tournament_runs;
CREATE POLICY "Public read access for tournament_runs" ON public.tournament_runs FOR SELECT USING (true);

DROP POLICY IF EXISTS "Public read access for run_flags" ON public.run_flags;
CREATE POLICY "Public read access for run_flags" ON public.run_flags FOR SELECT USING (true);

-- Insert policies
-- Users can insert their own challenge runs
DROP POLICY IF EXISTS "Users can insert own challenge_runs" ON public.challenge_runs;
CREATE POLICY "Users can insert own challenge_runs" ON public.challenge_runs FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);

-- Users can join tournaments (if signup and slots available) - simplistic RLS, typically handled via RPC to enforce logic
DROP POLICY IF EXISTS "Users can join tournaments" ON public.tournament_participants;
CREATE POLICY "Users can join tournaments" ON public.tournament_participants FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);

-- Users can submit tournament runs
DROP POLICY IF EXISTS "Users can insert own tournament_runs" ON public.tournament_runs;
CREATE POLICY "Users can insert own tournament_runs" ON public.tournament_runs FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);

-- Users can flag runs
DROP POLICY IF EXISTS "Users can flag runs" ON public.run_flags;
CREATE POLICY "Users can flag runs" ON public.run_flags FOR INSERT TO authenticated WITH CHECK (auth.uid() = flagger_id);

-- Creator custom tournament creation
DROP POLICY IF EXISTS "Creators can create tournaments" ON public.tournaments;
CREATE POLICY "Creators can create tournaments" ON public.tournaments FOR INSERT TO authenticated WITH CHECK (
    auth.uid() = creator_id AND 
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND (is_content_creator = true OR username = 'Login31'))
);

-- Service role has full access
DROP POLICY IF EXISTS "Service role all access challenges" ON public.challenges;
CREATE POLICY "Service role all access challenges" ON public.challenges FOR ALL TO service_role USING (true);

DROP POLICY IF EXISTS "Service role all access challenge_runs" ON public.challenge_runs;
CREATE POLICY "Service role all access challenge_runs" ON public.challenge_runs FOR ALL TO service_role USING (true);

DROP POLICY IF EXISTS "Service role all access tournaments" ON public.tournaments;
CREATE POLICY "Service role all access tournaments" ON public.tournaments FOR ALL TO service_role USING (true);

DROP POLICY IF EXISTS "Service role all access tournament_participants" ON public.tournament_participants;
CREATE POLICY "Service role all access tournament_participants" ON public.tournament_participants FOR ALL TO service_role USING (true);

DROP POLICY IF EXISTS "Service role all access tournament_matches" ON public.tournament_matches;
CREATE POLICY "Service role all access tournament_matches" ON public.tournament_matches FOR ALL TO service_role USING (true);

DROP POLICY IF EXISTS "Service role all access tournament_rounds" ON public.tournament_rounds;
CREATE POLICY "Service role all access tournament_rounds" ON public.tournament_rounds FOR ALL TO service_role USING (true);

DROP POLICY IF EXISTS "Service role all access tournament_runs" ON public.tournament_runs;
CREATE POLICY "Service role all access tournament_runs" ON public.tournament_runs FOR ALL TO service_role USING (true);

DROP POLICY IF EXISTS "Service role all access run_flags" ON public.run_flags;
CREATE POLICY "Service role all access run_flags" ON public.run_flags FOR ALL TO service_role USING (true);
