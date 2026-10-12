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

create table if not exists public.noticias (
  id           uuid primary key default gen_random_uuid(),
  titulo       text not null check (char_length(titulo) between 3 and 120),
  mensaje      text not null check (char_length(mensaje) between 3 and 2000),
  autor_id     uuid references public.profiles(id) on delete set null,
  autor_nombre text not null default '',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists noticias_fecha_idx on public.noticias (created_at desc);

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

-- Noticias: el servidor fija el autor al publicar y no deja cambiar autor ni fecha de creación al editar
create or replace function public.fijar_autor() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.autor_id := (select auth.uid());
  new.autor_nombre := coalesce((select nombre from public.profiles where id = (select auth.uid())), '');
  return new;
end $$;

create or replace function public.noticia_editada() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.autor_id := old.autor_id;
  new.autor_nombre := old.autor_nombre;
  new.created_at := old.created_at;
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists noticias_fijar_autor on public.noticias;
create trigger noticias_fijar_autor before insert on public.noticias
  for each row execute function public.fijar_autor();
drop trigger if exists noticias_editada on public.noticias;
create trigger noticias_editada before update on public.noticias
  for each row execute function public.noticia_editada();

revoke all on function public.fijar_autor(), public.noticia_editada() from public, anon;
revoke all on function public.mi_rol(), public.es_apoderado_de(uuid), public.es_estudiante(uuid), public.fijar_profesor() from public, anon;
grant execute on function public.mi_rol(), public.es_apoderado_de(uuid), public.es_estudiante(uuid) to authenticated;

-- ---------- Seguridad por fila ----------
alter table public.profiles             enable row level security;
alter table public.apoderado_estudiante enable row level security;
alter table public.notas                enable row level security;
alter table public.anotaciones          enable row level security;
alter table public.noticias             enable row level security;

-- Permisos de tabla: solo lectura/escritura para usuarios con sesión; el resto lo filtran las políticas
revoke all on public.profiles, public.apoderado_estudiante, public.notas, public.anotaciones, public.noticias from anon, authenticated;
grant select on public.profiles, public.apoderado_estudiante to authenticated;
grant select, insert, update, delete on public.notas, public.anotaciones, public.noticias to authenticated;
-- La función admin-users usa service_role: omite las políticas RLS, pero necesita permisos de tabla
-- (como 'Automatically expose new tables' está desactivado, hay que concederlos aquí).
grant all on public.profiles, public.apoderado_estudiante, public.notas, public.anotaciones, public.noticias to service_role;

-- profiles: cada quien ve el suyo; el admin ve todos; el profesor ve estudiantes; el apoderado ve a sus hijos.
-- Crear, cambiar o borrar usuarios solo ocurre en la función del servidor (admin-users).
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated using (
  id = (select auth.uid())
  or public.mi_rol() = 'adm'
  or (public.mi_rol() = 'prof' and rol = 'est')
  or (rol = 'est' and public.es_apoderado_de(id))
);

-- vínculos apoderado ↔ estudiante
drop policy if exists vinculos_select on public.apoderado_estudiante;
create policy vinculos_select on public.apoderado_estudiante for select to authenticated using (
  apoderado_id = (select auth.uid()) or public.mi_rol() = 'adm'
);

-- notas: el estudiante ve las suyas, el apoderado las de sus hijos, profesores y admin todas
drop policy if exists notas_select on public.notas;
create policy notas_select on public.notas for select to authenticated using (
  public.mi_rol() in ('adm','prof')
  or estudiante_id = (select auth.uid())
  or public.es_apoderado_de(estudiante_id)
);
drop policy if exists notas_insert on public.notas;
create policy notas_insert on public.notas for insert to authenticated with check (
  public.mi_rol() in ('adm','prof') and public.es_estudiante(estudiante_id)
);
drop policy if exists notas_update on public.notas;
create policy notas_update on public.notas for update to authenticated
  using (public.mi_rol() = 'adm' or (public.mi_rol() = 'prof' and profesor_id = (select auth.uid())))
  with check (public.mi_rol() in ('adm','prof') and public.es_estudiante(estudiante_id));
drop policy if exists notas_delete on public.notas;
create policy notas_delete on public.notas for delete to authenticated using (
  public.mi_rol() = 'adm' or (public.mi_rol() = 'prof' and profesor_id = (select auth.uid()))
);

-- anotaciones: los estudiantes NO las ven; apoderados solo las de sus hijos
drop policy if exists anot_select on public.anotaciones;
create policy anot_select on public.anotaciones for select to authenticated using (
  public.mi_rol() in ('adm','prof') or public.es_apoderado_de(estudiante_id)
);
drop policy if exists anot_insert on public.anotaciones;
create policy anot_insert on public.anotaciones for insert to authenticated with check (
  public.mi_rol() in ('adm','prof') and public.es_estudiante(estudiante_id)
);
drop policy if exists anot_update on public.anotaciones;
create policy anot_update on public.anotaciones for update to authenticated
  using (public.mi_rol() = 'adm' or (public.mi_rol() = 'prof' and profesor_id = (select auth.uid())))
  with check (public.mi_rol() in ('adm','prof') and public.es_estudiante(estudiante_id));
drop policy if exists anot_delete on public.anotaciones;
create policy anot_delete on public.anotaciones for delete to authenticated using (
  public.mi_rol() = 'adm' or (public.mi_rol() = 'prof' and profesor_id = (select auth.uid()))
);

-- noticias: todas las personas con perfil las leen; profesores y admin publican;
-- cada profesor edita y elimina solo las suyas (el admin, todas)
drop policy if exists noticias_select on public.noticias;
create policy noticias_select on public.noticias for select to authenticated using (
  public.mi_rol() is not null
);
drop policy if exists noticias_insert on public.noticias;
create policy noticias_insert on public.noticias for insert to authenticated with check (
  public.mi_rol() in ('adm','prof')
);
drop policy if exists noticias_update on public.noticias;
create policy noticias_update on public.noticias for update to authenticated
  using (public.mi_rol() = 'adm' or (public.mi_rol() = 'prof' and autor_id = (select auth.uid())))
  with check (public.mi_rol() = 'adm' or (public.mi_rol() = 'prof' and autor_id = (select auth.uid())));
drop policy if exists noticias_delete on public.noticias;
create policy noticias_delete on public.noticias for delete to authenticated using (
  public.mi_rol() = 'adm' or (public.mi_rol() = 'prof' and autor_id = (select auth.uid()))
);
