-- Add is_content_creator to profiles
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS is_content_creator BOOLEAN DEFAULT FALSE;

-- Creator applications table
CREATE TABLE IF NOT EXISTS public.creator_applications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    reason TEXT NOT NULL,
    links TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
    UNIQUE(user_id) -- only one active per user
);

ALTER TABLE public.creator_applications ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can insert their own application" ON public.creator_applications FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can view their own application" ON public.creator_applications FOR SELECT USING (auth.uid() = user_id OR (SELECT username FROM public.profiles WHERE id = auth.uid()) = 'Login31');
CREATE POLICY "Only Login31 can delete applications" ON public.creator_applications FOR DELETE USING ((SELECT username FROM public.profiles WHERE id = auth.uid()) = 'Login31');
CREATE POLICY "Only Login31 can update applications" ON public.creator_applications FOR UPDATE USING ((SELECT username FROM public.profiles WHERE id = auth.uid()) = 'Login31');

-- Support info table for creators
CREATE TABLE IF NOT EXISTS public.creator_support (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    description TEXT,
    link_1 TEXT,
    link_2 TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
    UNIQUE(user_id)
);
ALTER TABLE public.creator_support ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone can view creator support" ON public.creator_support FOR SELECT USING (true);
CREATE POLICY "Creators can insert their own support info if they are creator" ON public.creator_support FOR INSERT WITH CHECK (auth.uid() = user_id AND ((SELECT is_content_creator FROM public.profiles WHERE id = auth.uid()) = true OR (SELECT username FROM public.profiles WHERE id = auth.uid()) = 'Login31'));
CREATE POLICY "Creators can update their support info" ON public.creator_support FOR UPDATE USING (auth.uid() = user_id AND ((SELECT is_content_creator FROM public.profiles WHERE id = auth.uid()) = true OR (SELECT username FROM public.profiles WHERE id = auth.uid()) = 'Login31'));

-- Featured Roulettes table
CREATE TABLE IF NOT EXISTS public.featured_roulettes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    run_code TEXT NOT NULL,
    theme_color TEXT,
    is_pinned BOOLEAN DEFAULT FALSE,
    plays INTEGER DEFAULT 0,
    total_progress INTEGER DEFAULT 0,
    completions INTEGER DEFAULT 0,
    most_failed_perc INTEGER DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);
ALTER TABLE public.featured_roulettes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone can view featured roulettes" ON public.featured_roulettes FOR SELECT USING (true);
CREATE POLICY "Creators can manage their roulettes" ON public.featured_roulettes FOR ALL USING ((auth.uid() = user_id AND ((SELECT is_content_creator FROM public.profiles WHERE id = auth.uid()) = true)) OR (SELECT username FROM public.profiles WHERE id = auth.uid()) = 'Login31');

CREATE OR REPLACE FUNCTION increment_roulette_play(p_id UUID) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    UPDATE public.featured_roulettes SET plays = plays + 1 WHERE id = p_id;
END;
$$;

CREATE OR REPLACE FUNCTION record_roulette_progress(p_run_code TEXT, p_progress INTEGER) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    UPDATE public.featured_roulettes 
    SET 
      completions = completions + CASE WHEN p_progress >= 100 THEN 1 ELSE 0 END,
      total_progress = total_progress + p_progress
    WHERE run_code = p_run_code;
END;
$$;

-- A function to process application
CREATE OR REPLACE FUNCTION accept_creator_application(p_user_id UUID) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF (SELECT username FROM public.profiles WHERE id = auth.uid()) != 'Login31' THEN
        RAISE EXCEPTION 'Only Login31 can accept applications';
    END IF;
    
    UPDATE public.profiles SET is_content_creator = true WHERE id = p_user_id;
    DELETE FROM public.creator_applications WHERE user_id = p_user_id;
END;
$$;

CREATE OR REPLACE FUNCTION deny_creator_application(p_user_id UUID) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF (SELECT username FROM public.profiles WHERE id = auth.uid()) != 'Login31' THEN
        RAISE EXCEPTION 'Only Login31 can deny applications';
    END IF;
    
    DELETE FROM public.creator_applications WHERE user_id = p_user_id;
END;
$$;

CREATE OR REPLACE FUNCTION set_content_creator(p_user_id UUID, p_status BOOLEAN) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF (SELECT username FROM public.profiles WHERE id = auth.uid()) != 'Login31' THEN
        RAISE EXCEPTION 'Only Login31 can set Content Creator rank';
    END IF;
    UPDATE public.profiles SET is_content_creator = p_status WHERE id = p_user_id;
END;
$$;

