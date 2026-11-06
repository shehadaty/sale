import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
};
const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: CORS });
const text = (v: unknown, max = 200) => String(v ?? "").trim().slice(0, max);

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return reply({ ok: false, error: "method_not_allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });

  // 1) من المتصل؟ لازم أدمن فعّال (يُفحص على السيرفر، لا نثق بالمتصفح).
  const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "").trim();
  if (!token) return reply({ ok: false, error: "unauthorized" }, 401);
  const { data: authData, error: authError } = await admin.auth.getUser(token);
  if (authError || !authData?.user) return reply({ ok: false, error: "unauthorized" }, 401);
  const { data: caller } = await admin
    .from("user_profiles").select("role,is_active").eq("id", authData.user.id).maybeSingle();
  if (!caller || caller.role !== "admin" || caller.is_active !== true) {
    return reply({ ok: false, error: "forbidden" }, 403);
  }

  // 2) مدخلات
  let body: any;
  try { body = await req.json(); } catch { return reply({ ok: false, error: "bad_json" }, 400); }
  const email = text(body.email, 254).toLowerCase();
  const password = String(body.password ?? "");
  const username = text(body.username, 60);
  const role = text(body.role, 20) || "employee";
  const branch = text(body.branch, 60) || "الكل";
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return reply({ ok: false, error: "invalid_email" }, 400);
  if (password.length < 6) return reply({ ok: false, error: "weak_password" }, 400);
  if (!username) return reply({ ok: false, error: "username_required" }, 400);
  if (!["admin", "employee"].includes(role)) return reply({ ok: false, error: "invalid_role" }, 400);

  // 3) إنشاء حساب Auth (مؤكَّد مباشرة، بدون التأثير على جلسة الأدمن)
  const { data: created, error: createError } = await admin.auth.admin.createUser({
    email, password, email_confirm: true,
    user_metadata: { username, full_name: text(body.full_name, 120) },
  });
  if (createError || !created?.user) {
    const msg = String(createError?.message || "");
    if (/already|registered|exists/i.test(msg)) return reply({ ok: false, error: "already_registered" }, 409);
    return reply({ ok: false, error: "create_failed", detail: msg }, 400);
  }
  const id = created.user.id;

  // 4) ضبط الملف الشخصي بمفتاح الخدمة (الدور/الفرع/التفعيل لا تأتي من المتصفح إلا عبر هذه الدالة)
  const num = (v: unknown) => (v === null || v === undefined || v === "" || Number.isNaN(Number(v)) ? null : Number(v));
  const profile: Record<string, unknown> = {
    id, username, full_name: text(body.full_name, 120) || null, role, branch, is_active: true,
    phone: text(body.phone, 30) || null, qualification: text(body.qualification, 200) || null,
    address: text(body.address, 300) || null, hiring_date: text(body.hiring_date, 10) || null,
    salary: num(body.salary), commission_amount: num(body.commission_amount) ?? 0,
  };
  const { error: profileError } = await admin.from("user_profiles").upsert(profile, { onConflict: "id" });
  if (profileError) {
    await admin.auth.admin.deleteUser(id); // تراجع كامل: لا يبقى حساب بلا ملف
    const code = (profileError as any).code;
    return reply({ ok: false, error: code === "23505" ? "username_taken" : "profile_failed", detail: profileError.message }, code === "23505" ? 409 : 400);
  }
  return reply({ ok: true, id });
});
