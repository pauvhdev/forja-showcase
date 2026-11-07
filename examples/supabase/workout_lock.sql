-- Extracto de supabase/schema.sql y supabase/policies.sql (Forja).
-- Un entreno cerrado no se puede editar ni borrar: dos capas independientes.

-- 1) Trigger: rechaza cualquier UPDATE tras cerrar la sesión
create or replace function public.lock_completed_workout()
returns trigger language plpgsql as $fn$
declare
  comparar public.workouts;
begin
  if old.status <> 'completed' then
    return new;
  end if;

  -- Una sola excepción: que la sesión se quede sin día de rutina.
  --
  -- Ese UPDATE no lo manda la app, lo genera la clave foránea cuando se borra
  -- la rutina (routine_day_id es "on delete set null"). Sin esta excepción,
  -- borrar una rutina que ya se ha entrenado es imposible: el borrado revienta
  -- con check_violation y la entrada se queda atascada en la cola de subida
  -- para siempre.
  --
  -- Se exige que TODO lo demás sea idéntico, así que esto no abre la puerta a
  -- editar una sesión cerrada: lo único que se pierde es el puntero a un día
  -- que ya no existe. El título, la fecha y las series siguen ahí.
  -- pg_trigger_depth() > 1 significa que este UPDATE lo ha lanzado otro
  -- trigger, y el unico que toca esta tabla es el interno de la clave foranea
  -- al borrar el dia de rutina. Un UPDATE de la app llega siempre a
  -- profundidad 1, asi que por aqui no se cuela nadie editando a mano.
  if pg_trigger_depth() > 1
     and new.routine_day_id is null and old.routine_day_id is not null then
    comparar := new;
    comparar.routine_day_id := old.routine_day_id;
    comparar.updated_at := old.updated_at;
    if comparar is not distinct from old then
      return new;
    end if;
  end if;

  raise exception 'Una sesión completada no se puede modificar (id=%)', old.id
    using errcode = 'check_violation';
end;
$fn$;

create trigger workouts_lock before update on public.workouts
  for each row execute function public.lock_completed_workout();

-- 2) RLS: no existe política de DELETE sobre workouts (lo no concedido se deniega)
-- ── workouts ───────────────────────────────────────────────────────────────
--  OJO: NO hay política de DELETE. En RLS, lo que no se concede se deniega,
--  así que un entreno no lo puede borrar nadie — ni su propio autor.
--  Esta ausencia es intencionada. No añadir una política de delete aquí.
create policy workouts_select on public.workouts
  for select using (
    athlete_id = auth.uid() or public.is_coach_of(athlete_id)
  );

create policy workouts_insert_own on public.workouts
  for insert with check (athlete_id = auth.uid());

-- El trigger workouts_lock corta además cualquier update tras completarla.
create policy workouts_update_own on public.workouts
  for update using (athlete_id = auth.uid()) with check (athlete_id = auth.uid());
