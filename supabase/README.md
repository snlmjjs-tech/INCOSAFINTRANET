# Configuración de Supabase para la intranet INCOSAF

Haz estos pasos **una sola vez**, en orden. Todo se hace desde el panel de Supabase
(proyecto `INTRANET`). No necesitas instalar nada.

## 1. Crear las tablas y la seguridad
1. En el menú izquierdo abre **SQL Editor** → **New query**.
2. Copia **todo** el contenido de [`schema.sql`](./schema.sql), pégalo y presiona **Run**.
3. Debe terminar con `Success. No rows returned`. Es seguro ejecutarlo más de una vez.

Con esto cada rol queda limitado por la base de datos (no por el navegador):

| Rol | Puede ver | Puede escribir |
|---|---|---|
| Estudiante | Sus notas | Nada |
| Apoderado | Notas y anotaciones de sus hijos | Nada |
| Profesor | Estudiantes, todas las notas y anotaciones | Notas y anotaciones (solo borra las propias) |
| Administrador | Todo | Usuarios, mediante la función `admin-users` |

## 2. Ajustes de autenticación
En **Authentication**:
- **Sign In / Providers → Email**: desactiva **Allow new users to sign up**. Así nadie puede crearse una cuenta por su cuenta; solo el administrador crea usuarios.
- La longitud mínima de contraseña es **6** (valor por defecto). La intranet exige entre 6 y 64.

## 3. Crear la cuenta del administrador
1. **Authentication → Users → Add user → Create new user**.
2. **Email**: `2179@incosaf.local` (el usuario con el que iniciarás sesión es `2179`).
3. **Password**: elige una contraseña **larga y que no sea 2179**. Marca **Auto Confirm User** y crea el usuario.
4. Vuelve a **SQL Editor**, ejecuta esto para darle el rol de administrador:

```sql
insert into public.profiles (id, usuario, nombre, rol, curso)
select id, '2179', 'Administración', 'adm', 'Administrador'
from auth.users where email = '2179@incosaf.local';
```

> Si Supabase rechazara el dominio `incosaf.local`, cámbialo por otro (por ejemplo `intranet-incosaf.app`)
> en **tres** lugares: este paso, `EMAIL_DOMAIN` en `functions/admin-users/index.ts` y `emailDomain` en `index.html`.

## 4. Publicar la función `admin-users`
Es la única parte que usa la clave de servicio; Supabase la inyecta sola, nunca va en el código.
1. **Edge Functions → Deploy a new function → Via Editor**.
2. Nombre: `admin-users`.
3. Pega el contenido de [`functions/admin-users/index.ts`](./functions/admin-users/index.ts) y presiona **Deploy**.
4. En la función, abre **Settings** (o **Details**) y **desactiva "Verify JWT"**: la función ya comprueba por sí misma la sesión y que quien llama sea administrador.

(Con la CLI: `supabase functions deploy admin-users --no-verify-jwt`.)

## 5. Conectar la intranet
1. En **Project Settings → API Keys** copia la **Publishable key** (`sb_publishable_…`).
2. En `index.html`, busca `PEGA_AQUI_LA_PUBLISHABLE_KEY` y reemplázala por esa clave. Es una clave pública: puede estar en el código.
3. **Nunca** pongas la `secret key` ni la `service_role key` en el repositorio.

## 6. Publicar la página web
En GitHub: **Settings → Pages → Build and deployment → Deploy from a branch → `main` / `(root)` → Save**.
La dirección quedará como `https://<usuario>.github.io/INCOSAFINTRANET/`.

## 7. Probar
1. Entra con `2179` y tu contraseña → **Panel de control**.
2. Descarga la **Plantilla**, completa unos usuarios de prueba y súbela; revisa el resumen y presiona **Aplicar**.
3. Entra como profesor, ingresa una nota y una anotación; entra como estudiante y como apoderado para comprobar qué ve cada uno.

## Cómo cargar usuarios con Excel
Hay dos plantillas (botones **Alumnos** y **Profesores** en el panel). Una fila por persona. **La plantilla de alumnos incluye al apoderado en la misma fila** y el sistema crea las dos cuentas.

| Plantilla | Columnas | Usuario | Contraseña inicial |
|---|---|---|---|
| Alumnos | Acción · N° alumno · RUT alumno · Nombre alumno · Curso · RUT apoderado · Nombre apoderado | Alumno: 1000 + N° (234 → `1234`). Apoderado: 3000 + N° (→ `3234`) | 6 primeros dígitos del RUT de cada uno |
| Profesores | Acción · N° profesor · RUT · Nombre · Cargo | 2000 + N° (1 → `2001`) | 6 primeros dígitos de su RUT |

- El RUT solo se usa para calcular la contraseña inicial (que cada persona deberá cambiar al entrar); **no se guarda**. Acepta `12.345.678-9`, `12345678-9` o `12345678`.
- Si no escribes datos de apoderado, se crea solo el alumno. Si escribes uno de los dos datos del apoderado (RUT o nombre) y falta el otro, el alumno se crea y se avisa del error del apoderado.
- **Hermanos:** si dos alumnos tienen el mismo RUT de apoderado dentro del archivo, comparten una sola cuenta de apoderado (su usuario se calcula con el primero de la lista). Si los hermanos se cargan en archivos distintos, quedan con cuentas separadas.
- Si el segundo apoderado de un alumno (mamá y papá) también debe entrar, se crea a mano con **Nuevo usuario** y otro nombre de usuario.
- **Acción**: vacía = crea, o actualiza nombres y curso si ya existe (**las contraseñas no cambian**). `modificar`, `eliminar` y `restablecer` (vuelve las contraseñas a los 6 primeros dígitos del RUT).
- **Eliminar** a un alumno borra también sus notas y anotaciones, y a su apoderado si no tiene otros hijos.
- El curso se ordena solo: `1a`, `1 A` y `1°A` son el mismo curso.
- Antes de aplicar ves un resumen con los usuarios que se crearán y los errores por fila.
- **Exportar usuarios** descarga la lista actual (sin contraseñas) en un formato genérico que también se puede volver a subir.

## Planilla de notas (profesores)
**Notas** abre una planilla del curso: eliges curso y asignatura, escribes la nota de cada alumno en la columna «Nueva» y guardas una sola vez. Enter baja a la fila siguiente, se puede pegar una columna copiada desde Excel y «Agregar columna» permite ingresar varias notas a la vez. Las notas ya guardadas se pueden corregir o borrar (con confirmación) si las registró el mismo profesor.

## Cambio obligatorio de la contraseña inicial
La contraseña inicial (6 primeros dígitos del RUT) es predecible, así que **cada persona debe cambiarla en su primer ingreso**:
- Al entrar por primera vez ve la pantalla «Crea tu contraseña» (mínimo 8 caracteres) y no puede usar la intranet hasta cambiarla.
- No es solo un aviso en pantalla: mientras la contraseña esté pendiente, **la base de datos no entrega notas ni anotaciones**, ni siquiera por la API.
- Al **restablecer** una contraseña desde el panel (acción `restablecer` o «Nueva contraseña» al editar), se vuelve a exigir el cambio en el siguiente ingreso.
- Los usuarios nuevos nacen con el cambio pendiente. El administrador que ya existía queda exento; uno nuevo creado con el comando del paso 3 también tendrá que cambiarla la primera vez.
- Límite: quien conozca el RUT de alguien y entre **antes** que esa persona puede quedarse con la cuenta; la persona lo notará porque su contraseña inicial ya no funciona, y el administrador la restablece. Para reducirlo, entrega las contraseñas iniciales a las familias y pídeles entrar pronto.

### Si ya tenías la base creada (actualizar)
1. **Primero** fusiona el pull request y espera 1 o 2 minutos a que GitHub Pages publique la página nueva.
2. **Después** vuelve a ejecutar [`schema.sql`](./schema.sql) completo en el SQL Editor (es seguro repetirlo). Agrega la columna `cambiar_clave`, deja al administrador exento y **deja con cambio pendiente a todos los demás usuarios que ya existan**.
3. Si lo haces en el orden contrario, los usuarios verían la intranet vacía hasta que se publique la página nueva.

## Notas
- El plan gratuito de Supabase pausa el proyecto tras una semana sin uso; se reactiva desde el panel.
- Activa copias de seguridad o exporta los datos con regularidad si la información es importante.
- Todos los profesores pueden registrar notas y anotaciones a cualquier estudiante; cada profesor solo borra lo que escribió.
