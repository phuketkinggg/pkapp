// Reads a receipt photo with Claude: supplier, date, amount, how it was paid, and the best accounts category. Managers only.
// POST {id}  ->  {supplier, day, amount, method, category, business, department, note}
import { createClient } from "npm:@supabase/supabase-js@2";
import { encodeBase64 } from "jsr:@std/encoding@1/base64";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const admin = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const KEY = () => (Deno.env.get("ANTHROPIC_API_KEY") ?? "").trim();
const MODEL = "claude-sonnet-5-5";
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

const CATS = ["Staff wages", "Rent", "Electricity", "Water", "Internet and phone", "Food and drink stock", "Cafe and drinks supplies", "Shop stock", "Spa supplies",
  "Cleaning and laundry", "Repairs and maintenance", "Equipment", "Marketing and ads", "Software and subscriptions", "Bank and card fees", "Visa and government fees",
  "Transport and fuel", "Office and admin", "Professional fees", "Tax", "Insurance", "Other"];
const DEPTS: Record<string, string[]> = { "Phuket King Gym": ["Gym", "Gym shop", "Spa", "Visa and DTV", "Office", "Marketing", "Maintenance", "Other"],
  "Pangea Resort": ["Pangea Resort", "Pangea Cafe", "Housekeeping", "Maintenance", "Office", "Marketing", "Other"] };

async function manager(req: Request) {
  const user = createClient(URL_, ANON, { global: { headers: { Authorization: req.headers.get("authorization") ?? "" } }, auth: { persistSession: false } });
  const { data } = await user.auth.getUser();
  if (!data?.user) return false;
  const { data: s } = await admin.from("staff").select("role").eq("user_id", data.user.id).eq("active", true).maybeSingle();
  return s?.role === "manager";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  try {
    if (!(await manager(req))) return json({ error: "Only a manager can do this." }, 401);
    if (!KEY()) return json({ error: "The AI is not set up yet. Add ANTHROPIC_API_KEY in Supabase, Edge Functions, Secrets." });
    const b = await req.json().catch(() => ({}));
    if (!/^[0-9a-f-]{36}$/i.test(String(b.id ?? ""))) return json({ error: "Choose a receipt." });
    const { data: r } = await admin.from("expense_receipts").select("id,photo_path,business,department,day,method").eq("id", b.id).maybeSingle();
    if (!r?.photo_path) return json({ error: "That receipt has no photo." });
    const { data: file, error } = await admin.storage.from("receipts").download(r.photo_path);
    if (error || !file) return json({ error: "The photo could not be opened." });
    const type = file.type && /^image\/(jpeg|png|webp|gif)$/.test(file.type) ? file.type : (/\.png$/i.test(r.photo_path) ? "image/png" : "image/jpeg");
    const pdf = file.type === "application/pdf" || /\.pdf$/i.test(r.photo_path);
    const data = encodeBase64(new Uint8Array(await file.arrayBuffer()));
    const doc = pdf ? { type: "document", source: { type: "base64", media_type: "application/pdf", data } } : { type: "image", source: { type: "base64", media_type: type, data } };
    const prompt = `This is a receipt or bill for a business in Phuket, Thailand (a Muay Thai gym "Phuket King Gym", and "Pangea Resort" with bungalows and a cafe). It may be in Thai or English.
The staff member filed it under: business "${r.business}", department "${r.department}", paid by "${r.method}".
Read it and reply with JSON only:
{"supplier": "shop or company name, in English letters if possible", "day": "YYYY-MM-DD or empty if not shown (Thai Buddhist years: subtract 543)", "amount": total paid as a number in Thai baht (the grand total including VAT, not a subtotal), "method": "cash" | "transfer" | "card" | "" if not shown, "category": one of ${JSON.stringify(CATS)}, "business": "Phuket King Gym" or "Pangea Resort" (keep the staff choice unless the receipt clearly belongs to the other), "department": one of the departments for that business ${JSON.stringify(DEPTS)}, "note": "a few words on what was bought, in English"}
If something cannot be read, leave it empty. Never guess an amount.`;
    const slot = await admin.rpc("ai_usage_take", { p_fn: "receipt" });
    if (slot.error) return json({ error: "Could not check the AI allowance. Try again." });
    if (!slot.data) return json({ error: "This month's AI allowance is used up. It starts again on the 1st of next month." });
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST", headers: { "x-api-key": KEY(), "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({ model: MODEL, max_tokens: 800, messages: [{ role: "user", content: [doc, { type: "text", text: prompt }] }] }),
    });
    const j = await res.json().catch(() => ({}));
    await admin.from("ai_usage").update({ in_tokens: j?.usage?.input_tokens ?? null, out_tokens: j?.usage?.output_tokens ?? null, ok: res.ok }).eq("id", slot.data);
    if (!res.ok) return json({ error: "The AI said: " + (j?.error?.message ?? res.status) });
    const out = String((j.content ?? []).filter((c: { type: string }) => c.type === "text").map((c: { text: string }) => c.text).join(""));
    let o: Record<string, unknown> = {};
    try { o = JSON.parse(out.slice(out.indexOf("{"), out.lastIndexOf("}") + 1)); } catch { return json({ error: "The receipt could not be read. Try a clearer photo." }); }
    const biz = o.business === "Pangea Resort" || o.business === "Phuket King Gym" ? String(o.business) : r.business;
    const amt = Number(o.amount);
    return json({
      supplier: String(o.supplier ?? "").slice(0, 120),
      day: /^\d{4}-\d{2}-\d{2}$/.test(String(o.day ?? "")) ? String(o.day) : "",
      amount: isFinite(amt) && amt > 0 && amt < 10000000 ? Math.round(amt * 100) / 100 : null,
      method: ["cash", "transfer", "card"].includes(String(o.method)) ? String(o.method) : "",
      category: CATS.includes(String(o.category)) ? String(o.category) : "",
      business: biz,
      department: (DEPTS[biz] ?? []).includes(String(o.department)) ? String(o.department) : r.department,
      note: String(o.note ?? "").replace(/\s*[—–]\s*/g, ", ").slice(0, 200),
    });
  } catch (e) { return json({ error: (e as Error).message }); }
});
