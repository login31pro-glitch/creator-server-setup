-- Run this file in your Supabase SQL Editor to enable Real-Time for notes and votes

-- 1. Enable Full Replica Identity so we can see old values on UPDATE and DELETE
ALTER TABLE public.notes REPLICA IDENTITY FULL;
ALTER TABLE public.note_votes REPLICA IDENTITY FULL;

-- 2. Add the tables to the supabase_realtime publication
-- Note: it might output a warning if they are already in the publication, which is fine
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime' AND tablename = 'notes' AND schemaname = 'public'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.notes;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime' AND tablename = 'note_votes' AND schemaname = 'public'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.note_votes;
    END IF;
END $$;
