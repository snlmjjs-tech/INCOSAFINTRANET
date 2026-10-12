-- =====================================================================
-- INCOSAF · Intranet · esquema de base de datos y seguridad por rol
-- Pégalo completo en Supabase → SQL Editor → New query → Run.
-- Es seguro ejecutarlo más de una vez.
-- Roles: adm (administrador), prof (profesor), est (estudiante), apo (apoderado)
-- =====================================================================

-- ---------- Tablas ----------
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  usuario    text not null unique check (usuario ~ '^[a-z0-9][a-z0-9._-]{1,31}$'),
  nombre     text not null check (char_length(nombre) between 1 and 80),
  rol        text not null check (rol in ('adm','prof','est','apo')),
  curso      text not null default '' check (char_length(curso) <= 40),
  created_at timestamptz not null default now()
);

-- Contraseña inicial (RUT) → hay que cambiarla en el primer ingreso. Mientras esté pendiente, la base de datos no
-- entrega notas ni anotaciones. Al añadir la columna a una base existente, el administrador queda exento.
do $$ begin
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'profiles' and column_name = 'cambiar_clave') then
    alter table public.profiles add column cambiar_clave boolean not null default true;
    update public.profiles set cambiar_clave = false where rol = 'adm';
  end if;
end $$;

create table if not exists public.apoderado_estudiante (
  apoderado_id  uuid not null references public.profiles(id) on delete cascade,
  estudiante_id uuid not null references public.profiles(id) on delete cascade,
  primary key (apoderado_id, estudiante_id)
);
create index if not exists apoderado_estudiante_est_idx on public.apoderado_estudiante (estudiante_id);

create table if not exists public.notas (
  id              uuid primary key default gen_random_uuid(),
  estudiante_id   uuid not null references public.profiles(id) on delete cascade,
  asignatura      text not null check (char_length(asignatura) between 1 and 60),
  nota            numeric(2,1) not null check (nota >= 1.0 and nota <= 7.0),
  profesor_id     uuid references public.profiles(id) on delete set null,
  profesor_nombre text not null default '',
  created_at      timestamptz not null default now()
);
create index if not exists notas_est_idx on public.notas (estudiante_id, created_at);

create table if not exists public.anotaciones (
  id              uuid primary key default gen_random_uuid(),
  estudiante_id   uuid not null references public.profiles(id) on delete cascade,
  tipo            text not null check (tipo in ('positiva','negativa','observacion')),
  asignatura      text check (asignatura is null or char_length(asignatura) <= 60),
  detalle         text not null check (char_length(detalle) between 3 and 1000),
  fecha           date not null default current_date,
  profesor_id     uuid references public.profiles(id) on delete set null,
  profesor_nombre text not null default '',
  created_at      timestamptz not null default now()
);
create index if not exists anotaciones_est_idx on public.anotaciones (estudiante_id, created_at);

-- ---------- Funciones de apoyo (security definer: evitan recursión en las políticas) ----------
create or replace function public.mi_rol() returns text
language sql stable security definer set search_path = '' as $$
  select rol from public.profiles where id = (select auth.uid())
$$;

create or replace function public.es_apoderado_de(est uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.apoderado_estudiante
    where apoderado_id = (select auth.uid()) and estudiante_id = est)
$$;

create or replace function public.es_estudiante(p uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles where id = p and rol = 'est')
$$;

-- ¿La persona ya cambió su contraseña inicial? (si no tiene perfil, no)
create or replace function public.clave_ok() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select not cambiar_clave from public.profiles where id = (select auth.uid())), false)
$$;

-- Al insertar, el servidor fija quién escribe (el cliente no puede falsearlo)
create or replace function public.fijar_profesor() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.profesor_id := (select auth.uid());
  new.profesor_nombre := coalesce((select nombre from public.profiles where id = (select auth.uid())), '');
  return new;
end $$;

drop trigger if exists notas_fijar_profesor on public.notas;
create trigger notas_fijar_profesor before insert on public.notas
  for each row execute function public.fijar_profesor();
drop trigger if exists anotaciones_fijar_profesor on public.anotaciones;
create trigger anotaciones_fijar_profesor before insert on public.anotaciones
  for each row execute function public.fijar_profesor();

revoke all on function public.mi_rol(), public.clave_ok(), public.es_apoderado_de(uuid), public.es_estudiante(uuid), public.fijar_profesor() from public, anon;
grant execute on function public.mi_rol(), public.clave_ok(), public.es_apoderado_de(uuid), public.es_estudiante(uuid) to authenticated;

-- ---------- Seguridad por fila ----------
alter table public.profiles             enable row level security;
alter table public.apoderado_estudiante enable row level security;
alter table public.notas                enable row level security;
alter table public.anotaciones          enable row level security;

-- Permisos de tabla: solo lectura/escritura para usuarios con sesión; el resto lo filtran las políticas
revoke all on public.profiles, public.apoderado_estudiante, public.notas, public.anotaciones from anon, authenticated;
grant select on public.profiles, public.apoderado_estudiante to authenticated;
grant select, insert, update, delete on public.notas, public.anotaciones to authenticated;
-- La función admin-users usa service_role: omite las políticas RLS, pero necesita permisos de tabla
-- (como 'Automatically expose new tables' está desactivado, hay que concederlos aquí).
grant all on public.profiles, public.apoderado_estudiante, public.notas, public.anotaciones to service_role;

-- profiles: cada quien ve el suyo (aunque tenga la clave pendiente, para saberlo); el admin ve todos;
-- el profesor ve estudiantes; el apoderado ve a sus hijos. Crear, cambiar o borrar usuarios solo ocurre
-- en la función del servidor (admin-users).
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated using (
  id = (select auth.uid())
  or (public.clave_ok() and (
    public.mi_rol() = 'adm'
    or (public.mi_rol() = 'prof' and rol = 'est')
    or (rol = 'est' and public.es_apoderado_de(id))))
);

-- vínculos apoderado ↔ estudiante
drop policy if exists vinculos_select on public.apoderado_estudiante;
create policy vinculos_select on public.apoderado_estudiante for select to authenticated using (
  public.clave_ok() and (apoderado_id = (select auth.uid()) or public.mi_rol() = 'adm')
);

-- notas: el estudiante ve las suyas, el apoderado las de sus hijos, profesores y admin todas
drop policy if exists notas_select on public.notas;
create policy notas_select on public.notas for select to authenticated using (
  public.clave_ok() and (
    public.mi_rol() in ('adm','prof')
    or estudiante_id = (select auth.uid())
    or public.es_apoderado_de(estudiante_id))
);
drop policy if exists notas_insert on public.notas;
create policy notas_insert on public.notas for insert to authenticated with check (
  public.clave_ok() and public.mi_rol() in ('adm','prof') and public.es_estudiante(estudiante_id)
);
drop policy if exists notas_update on public.notas;
create policy notas_update on public.notas for update to authenticated
  using (public.clave_ok() and (public.mi_rol() = 'adm' or (public.mi_rol() = 'prof' and profesor_id = (select auth.uid()))))
  with check (public.clave_ok() and public.mi_rol() in ('adm','prof') and public.es_estudiante(estudiante_id));
drop policy if exists notas_delete on public.notas;
create policy notas_delete on public.notas for delete to authenticated using (
  public.clave_ok() and (public.mi_rol() = 'adm' or (public.mi_rol() = 'prof' and profesor_id = (select auth.uid())))
);

-- anotaciones: los estudiantes NO las ven; apoderados solo las de sus hijos
drop policy if exists anot_select on public.anotaciones;
create policy anot_select on public.anotaciones for select to authenticated using (
  public.clave_ok() and (public.mi_rol() in ('adm','prof') or public.es_apoderado_de(estudiante_id))
);
drop policy if exists anot_insert on public.anotaciones;
create policy anot_insert on public.anotaciones for insert to authenticated with check (
  public.clave_ok() and public.mi_rol() in ('adm','prof') and public.es_estudiante(estudiante_id)
);
drop policy if exists anot_update on public.anotaciones;
create policy anot_update on public.anotaciones for update to authenticated
  using (public.clave_ok() and (public.mi_rol() = 'adm' or (public.mi_rol() = 'prof' and profesor_id = (select auth.uid()))))
  with check (public.clave_ok() and public.mi_rol() in ('adm','prof') and public.es_estudiante(estudiante_id));
drop policy if exists anot_delete on public.anotaciones;
create policy anot_delete on public.anotaciones for delete to authenticated using (
  public.clave_ok() and (public.mi_rol() = 'adm' or (public.mi_rol() = 'prof' and profesor_id = (select auth.uid())))
);

-- ---------- Cambio de contraseña inicial ----------
-- La persona marca su propia clave como cambiada (después de cambiarla con auth.updateUser).
create or replace function public.clave_cambiada() returns void
language sql security definer set search_path = '' as $$
  update public.profiles set cambiar_clave = false where id = (select auth.uid())
$$;

-- El administrador obliga a cambiar la clave de ciertos usuarios (por ejemplo, tras restablecerla).
create or replace function public.forzar_cambio_clave(p_usuarios text[]) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not (public.clave_ok() and public.mi_rol() = 'adm') then
    raise exception 'Solo el administrador puede hacer esto';
  end if;
  update public.profiles set cambiar_clave = true where usuario = any (p_usuarios) and rol <> 'adm';
end $$;

revoke all on function public.clave_cambiada(), public.forzar_cambio_clave(text[]) from public, anon;
grant execute on function public.clave_cambiada(), public.forzar_cambio_clave(text[]) to authenticated;
