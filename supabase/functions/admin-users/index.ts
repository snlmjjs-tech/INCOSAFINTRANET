// Función del servidor: crear, modificar y eliminar usuarios (solo administradores).
// Usa la clave de servicio, que Supabase inyecta como variable de entorno; nunca va en el navegador.
// deno-lint-ignore-all no-explicit-any
import { createClient } from "npm:@supabase/supabase-js@2";

const EMAIL_DOMAIN = "incosaf.local"; // debe coincidir con EMAIL_DOMAIN en index.html
const ID_RE = /^[a-z0-9][a-z0-9._-]{1,31}$/;
const ROLES = ["est", "prof", "apo"];
const MAX_OPS = 100;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

type Result = { id: string; ok: boolean; error?: string; warn?: string };

async function runOp(admin: any, op: any): Promise<Result> {
  const id = String(op?.id ?? "").trim().toLowerCase();
  const fail = (error: string): Result => ({ id, ok: false, error });
  try {
    if (!ID_RE.test(id)) return fail("Usuario no válido.");
    const { data: ex } = await admin.from("profiles").select("id, rol").eq("usuario", id).maybeSingle();
    if (ex?.rol === "adm") return fail("No se puede modificar al administrador desde aquí.");

    if (op.type === "del") {
      if (!ex) return fail("El usuario no existe.");
      const { error } = await admin.auth.admin.deleteUser(ex.id); // borra perfil, notas, anotaciones y vínculos en cascada
      return error ? fail(error.message) : { id, ok: true };
    }
    if (op.type !== "add" && op.type !== "mod") return fail("Acción no válida.");

    const role = String(op.role ?? "");
    const name = String(op.name ?? "").trim();
    const curso = String(op.curso ?? "").trim();
    const pw = op.pw === undefined || op.pw === null || op.pw === "" ? null : String(op.pw);
    if (!ROLES.includes(role)) return fail("Rol no válido.");
    if (name.length < 1 || name.length > 80) return fail("El nombre debe tener entre 1 y 80 caracteres.");
    if (curso.length > 40) return fail("El curso o cargo supera los 40 caracteres.");
    if (pw !== null && (pw.length < 6 || pw.length > 64)) return fail("La contraseña debe tener entre 6 y 64 caracteres.");

    let uid: string;
    if (op.type === "add") {
      if (ex) return fail("El usuario ya existe.");
      if (!pw) return fail("Falta la contraseña.");
      const { data: created, error } = await admin.auth.admin.createUser({
        email: `${id}@${EMAIL_DOMAIN}`, password: pw, email_confirm: true,
      });
      if (error || !created?.user) return fail(error?.message ?? "No se pudo crear la cuenta.");
      uid = created.user.id;
      const { error: pe } = await admin.from("profiles").insert({ id: uid, usuario: id, nombre: name, rol: role, curso });
      if (pe) { await admin.auth.admin.deleteUser(uid); return fail(pe.message); }
    } else {
      if (!ex) return fail("El usuario no existe.");
      uid = ex.id;
      if (pw) {
        const { error } = await admin.auth.admin.updateUserById(uid, { password: pw });
        if (error) return fail(error.message);
      }
      const { error: pe } = await admin.from("profiles").update({ nombre: name, rol: role, curso }).eq("id", uid);
      if (pe) return fail(pe.message);
    }

    // vínculos apoderado ↔ estudiantes
    let warn: string | undefined;
    if (role !== "est") await admin.from("apoderado_estudiante").delete().eq("estudiante_id", uid);
    if (role !== "apo") {
      await admin.from("apoderado_estudiante").delete().eq("apoderado_id", uid);
    } else if (Array.isArray(op.hijos)) {
      const hijos = [...new Set(op.hijos.map((h: unknown) => String(h).trim().toLowerCase()).filter(Boolean))] as string[];
      await admin.from("apoderado_estudiante").delete().eq("apoderado_id", uid);
      if (hijos.length) {
        const { data: ests } = await admin.from("profiles").select("id, usuario").eq("rol", "est").in("usuario", hijos);
        const found = new Set((ests ?? []).map((e: any) => e.usuario));
        const missing = hijos.filter((h) => !found.has(h));
        if (missing.length) warn = `Estudiantes que no existen: ${missing.join(", ")}.`;
        if (ests?.length) {
          const { error } = await admin.from("apoderado_estudiante")
            .insert(ests.map((e: any) => ({ apoderado_id: uid, estudiante_id: e.id })));
          if (error) return fail(error.message);
        }
      }
    }
    return { id, ok: true, warn };
  } catch (e) {
    return fail(e instanceof Error ? e.message : "Error inesperado.");
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Método no permitido." }, 405);

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // 1) quién llama: la sesión debe ser válida
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: { user }, error: ue } = await admin.auth.getUser(token);
  if (ue || !user) return json({ error: "Sesión no válida." }, 401);

  // 2) y debe ser administrador
  const { data: me } = await admin.from("profiles").select("rol").eq("id", user.id).maybeSingle();
  if (me?.rol !== "adm") return json({ error: "Solo el administrador puede hacer esto." }, 403);

  let body: any;
  try { body = await req.json(); } catch { return json({ error: "Solicitud inválida." }, 400); }
  const ops = body?.ops;
  if (!Array.isArray(ops) || ops.length === 0 || ops.length > MAX_OPS)
    return json({ error: `Envía entre 1 y ${MAX_OPS} operaciones por solicitud.` }, 400);

  const results: Result[] = [];
  for (const op of ops) results.push(await runOp(admin, op)); // en orden: una fila puede depender de otra
  return json({ results });
});
