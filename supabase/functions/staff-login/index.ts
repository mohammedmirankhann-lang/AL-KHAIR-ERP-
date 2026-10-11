import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

function tempPassword() {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789";
  const buf = new Uint32Array(10);
  crypto.getRandomValues(buf);
  return Array.from(buf, (n) => chars[n % chars.length]).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
    const svc = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const auth = req.headers.get("Authorization") || "";

    // Only the signed-in owner may call this.
    const caller = createClient(url, anon, { global: { headers: { Authorization: auth } } });
    const { data: u } = await caller.auth.getUser();
    if (!u?.user) return json({ error: "Not signed in" }, 401);
    const { data: isOwner } = await caller.rpc("is_owner");
    if (isOwner !== true) return json({ error: "Only the owner can do this" }, 403);

    const { action, staff_id, role } = await req.json();
    const newRole = ["teacher", "coordinator", "accountant"].includes(role) ? role : "teacher";
    if (!staff_id || !/^(create|reset|disable|enable|role)$/.test(action)) return json({ error: "Bad request" }, 400);

    const admin = createClient(url, svc, { auth: { persistSession: false } });
    const { data: st, error: se } = await admin.from("staff").select("*").eq("id", staff_id).maybeSingle();
    if (se || !st) return json({ error: "Staff member not found" }, 404);

    if (action === "role") {
      if (!st.user_id) return json({ error: "This staff member has no login yet" }, 400);
      const { error: re } = await admin.from("profiles").update({ role: newRole }).eq("id", st.user_id);
      if (re) return json({ error: re.message }, 400);
      return json({ ok: true, role: newRole });
    }

    // Login on/off. A disabled login cannot sign in, but all records the person created are kept.
    if (action === "disable" || action === "enable") {
      if (!st.user_id) return json({ ok: true, note: "No login to change" });
      const off = action === "disable";
      const { error: be } = await admin.auth.admin.updateUserById(st.user_id, { ban_duration: off ? "876000h" : "none" });
      if (be) return json({ error: be.message }, 400);
      await admin.from("profiles").update({ is_active: !off }).eq("id", st.user_id);
      return json({ ok: true, disabled: off });
    }

    const pwd = tempPassword();
    const code = String(st.staff_code || "").trim().toUpperCase();

    if (action === "create") {
      if (st.user_id) return json({ error: "This staff member already has a login" }, 409);
      if (!/^[A-Z]{2,6}\d{1,5}$/.test(code)) return json({ error: "Set a staff code (like AKA1) for this staff member first" }, 400);
      const loginId = `${code.toLowerCase()}@staff.alkhair.in`;
      const { data: cu, error: ce } = await admin.auth.admin.createUser({
        email: loginId, password: pwd, email_confirm: true,
        user_metadata: { temp_password: true, full_name: st.full_name },
      });
      if (ce || !cu?.user) return json({ error: ce?.message || "Could not create login" }, 400);
      const { error: pe } = await admin.from("profiles").upsert({ id: cu.user.id, full_name: st.full_name, role: newRole, is_active: true });
      if (pe) { await admin.auth.admin.deleteUser(cu.user.id); return json({ error: pe.message }, 400); }
      await admin.from("staff").update({ user_id: cu.user.id, login_id: loginId }).eq("id", st.id);
      return json({ ok: true, login_id: loginId, login_hint: code, temp_password: pwd });
    }

    // reset
    if (!st.user_id) return json({ error: "This staff member has no login yet" }, 400);
    const { error: ue } = await admin.auth.admin.updateUserById(st.user_id, { password: pwd, ban_duration: "none", user_metadata: { temp_password: true, full_name: st.full_name } });
    if (ue) return json({ error: ue.message }, 400);
    await admin.from("profiles").update({ is_active: true }).eq("id", st.user_id);
    const hint = st.login_id && String(st.login_id).endsWith("@staff.alkhair.in") ? String(st.login_id).split("@")[0].toUpperCase() : st.login_id;
    return json({ ok: true, login_id: st.login_id, login_hint: hint, temp_password: pwd });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
