-- Run this in your Supabase SQL Editor to add the missing restricted_until column

ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS restricted_until TIMESTAMP WITH TIME ZONE;
