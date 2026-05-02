DROP POLICY IF EXISTS "Creators can delete their tournaments" ON public.tournaments;
CREATE POLICY "Creators can delete their tournaments" ON public.tournaments FOR DELETE TO authenticated USING (auth.uid() = creator_id);

DROP POLICY IF EXISTS "Creators can delete participants" ON public.tournament_participants;
CREATE POLICY "Creators can delete participants" ON public.tournament_participants FOR DELETE TO authenticated USING (
    EXISTS (SELECT 1 FROM public.tournaments WHERE id = tournament_id AND creator_id = auth.uid())
);
