-- Approved by Alexander Nov 13 2026: close public access to emails and summaries.
revoke all on table public.emails from anon, authenticated;
revoke all on table public.summaries from anon, authenticated;
alter table public.emails enable row level security;
alter table public.summaries enable row level security;
