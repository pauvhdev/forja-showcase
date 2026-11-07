# Code samples

Real excerpts of Forja's production code (comments in Spanish). They depend on the rest of
the private codebase, so they won't compile on their own.

| File | What it shows |
|---|---|
| [`flutter/sync/outbox.dart`](./flutter/sync/outbox.dart) | The outbox: every local write is queued for upload |
| [`flutter/sync/sync_engine.dart`](./flutter/sync/sync_engine.dart) | The sync engine: push the outbox, then pull changes, with retries |
| [`flutter/formulas.dart`](./flutter/formulas.dart) | 1RM estimation (Epley, RPE/RIR-adjusted) and training formulas |
| [`flutter/barra_discos.dart`](./flutter/barra_discos.dart) | The plate-calculator widget that draws the loaded bar |
| [`supabase/workout_lock.sql`](./supabase/workout_lock.sql) | Trigger + RLS that make a finished workout immutable |
| [`supabase/functions/generate-routine.ts`](./supabase/functions/generate-routine.ts) | Edge Function that generates a routine with AI |
| [`supabase/functions/gemini.ts`](./supabase/functions/gemini.ts) | Server-side Gemini client: secrets, model fallback, structured output |
