// Ask AI: an assistant in the app for the owner and the staff the owner picks (feature ask_ai, Staff, Ask AI).
// POST {messages, files?}  one turn of the chat. The assistant reads data with the person's own rights (read_table),
//                          and anything that would change something comes back as a proposal the person confirms.
// POST {mode:"run", actions}  the person tapped Confirm: the actions run with their own rights.
// Files (PDF, photo, Excel or CSV) go to the AI with the message: PDFs and photos as they are, spreadsheets as text.
import { createClient } from "npm:@supabase/supabase-js@2";
import * as XLSX from "npm:xlsx@0.18.5";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const admin = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const KEY = () => (Deno.env.get("ANTHROPIC_API_KEY") ?? "").trim();
const MODEL = "claude-sonnet-5-5";
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const today = () => new Date(Date.now() + 7 * 3600e3).toISOString().slice(0, 10);
const cut = (s: string, n: number) => (s.length > n ? s.slice(0, n) + "\n[cut, " + (s.length - n) + " more characters]" : s);

// what the assistant may change, only after the person taps Confirm. Each runs with the person's own rights.
const ACTIONS: Record<string, string> = {
  shop_product_save: "Add or change a shop product. args {p: {id (empty for new), name, price (THB), cost (THB), category_id, sku, description, active, in_app, on_web, kitchen, track_stock, low_stock, locations (array of shop_locations ids), grp}}. To change an existing product, read it first and send all its current fields with your changes.",
  shop_stock_set: "Shop stock at a location. args {p_product, p_location, p_kind: delivery (adds) | count (sets the count) | waste (takes off), p_qty, p_note}",
  stock_item_save: "Add or change a store item (housekeeping or supplies store). args {p: {id, name, unit, min_qty, ...}}",
  stock_adjust: "Store item stock. args {p_item, p_mode: delivery | count | waste, p_qty, p_note}",
  send_email: "Send one email from the business to one person. args {to, subject, body, customer_id (optional)}",
};

const TOOLS = [
  { name: "read_table", description: "Read rows from one table of the business database, with the user's own rights. Use the schema in the system prompt. Filters are ANDed.",
    input_schema: { type: "object", properties: {
      table: { type: "string" }, select: { type: "string", description: "Columns, comma separated, or * (default)" },
      filters: { type: "array", items: { type: "object", properties: { column: { type: "string" }, op: { type: "string", enum: ["eq", "neq", "gt", "gte", "lt", "lte", "ilike", "is", "in"] }, value: {} }, required: ["column", "op", "value"] } },
      order: { type: "string", description: "column, or column.desc" }, limit: { type: "integer", description: "max 200, default 50" } }, required: ["table"] } },
  { name: "propose_changes", description: "Prepare changes for the user to confirm. Nothing changes until they tap Confirm. Allowed actions:\n" + Object.entries(ACTIONS).map(([k, v]) => `- ${k}: ${v}`).join("\n") +
      "\nPut related changes in one proposal (for example all stock lines from one delivery note).",
    input_schema: { type: "object", properties: {
      summary: { type: "string", description: "One short line the user sees, in plain words" },
      actions: { type: "array", items: { type: "object", properties: { action: { type: "string", enum: Object.keys(ACTIONS) }, label: { type: "string", description: "What this line does, plain words" }, args: { type: "object" } }, required: ["action", "label", "args"] } } },
      required: ["summary", "actions"] } },
];

async function allowed(auth: string) {
  if (!auth) return null;
  const user = createClient(URL_, ANON, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const { data: u } = await user.auth.getUser(); if (!u?.user) return null;
  const { data: ok } = await user.rpc("ai_access"); if (ok !== true) return null;
  const { data: s } = await admin.from("staff").select("id,name,role").eq("user_id", u.user.id).maybeSingle();
  return { user, staff: s as { id: string; name: string; role: string } | null };
}

async function readTable(user: ReturnType<typeof createClient>, a: Record<string, unknown>) {
  const t = String(a.table ?? ""); if (!/^[a-z_][a-z0-9_]{0,60}$/.test(t)) return "Unknown table.";
  let q = user.from(t).select(String(a.select || "*").slice(0, 500));
  for (const f of (Array.isArray(a.filters) ? a.filters : []).slice(0, 10) as { column: string; op: string; value: unknown }[]) {
    if (!/^[a-z_][a-z0-9_]{0,60}$/.test(String(f.column))) continue;
    if (f.op === "in") q = q.in(f.column, Array.isArray(f.value) ? f.value : [f.value]);
    else if (f.op === "is") q = q.is(f.column, f.value === "null" || f.value === null ? null : f.value as boolean);
    else q = (q as unknown as Record<string, (c: string, v: unknown) => typeof q>)[f.op]?.(f.column, f.value) ?? q;
  }
  if (a.order) { const [c, d] = String(a.order).split("."); if (/^[a-z_][a-z0-9_]{0,60}$/.test(c)) q = q.order(c, { ascending: d !== "desc" }); }
  const { data, error } = await q.limit(Math.max(1, Math.min(200, Number(a.limit) || 50)));
  if (error) return "Error: " + error.message;
  return cut(JSON.stringify(data), 30000);
}

// a file from the app: PDFs and photos go to the AI as they are, spreadsheets as text
function fileBlocks(f: { name: string; type: string; data: string }) {
  const name = String(f.name || "file").slice(0, 120), mt = String(f.type || ""), b64 = String(f.data || "");
  if (mt === "application/pdf" || /\.pdf$/i.test(name)) return [{ type: "text", text: `File: ${name}` }, { type: "document", source: { type: "base64", media_type: "application/pdf", data: b64 } }];
  if (/^image\/(png|jpeg|gif|webp)$/.test(mt)) return [{ type: "text", text: `Photo: ${name}` }, { type: "image", source: { type: "base64", media_type: mt, data: b64 } }];
  if (/\.(xlsx|xls|csv|ods)$/i.test(name) || /sheet|excel|csv/.test(mt)) {
    try {
      const wb = XLSX.read(Uint8Array.from(atob(b64), (c) => c.charCodeAt(0)), { type: "array" });
      const text = wb.SheetNames.map((n) => `Sheet "${n}":\n` + XLSX.utils.sheet_to_csv(wb.Sheets[n])).join("\n\n");
      return [{ type: "text", text: `Spreadsheet ${name}:\n` + cut(text, 60000) }];
    } catch (e) { return [{ type: "text", text: `Spreadsheet ${name} could not be read: ${(e as Error).message}` }]; }
  }
  if (/^text\//.test(mt) || /\.(txt|md|json)$/i.test(name)) { try { return [{ type: "text", text: `File ${name}:\n` + cut(new TextDecoder().decode(Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))), 60000) }]; } catch { /* below */ } }
  return [{ type: "text", text: `File ${name} (${mt}) is a type the assistant cannot read. Ask for a PDF, photo, Excel or CSV.` }];
}

async function system(user: ReturnType<typeof createClient>, who: string) {
  const { data: schema } = await user.rpc("ai_schema");
  const { data: names } = await admin.from("app_settings").select("value").eq("key", "acc_names").maybeSingle();
  let biz = ""; try { const n = JSON.parse(names?.value ?? "{}"); biz = [n.main, n.stay].filter(Boolean).join(" and "); } catch { /* none */ }
  return `You are the assistant inside the business app of ${biz || "the business"}. You are talking with ${who}. Today is ${today()} (Thailand time). Money is in Thai baht (THB).
Help like a capable colleague: answer questions from the real data, prepare stock updates, products and emails, and explain what you did.
Rules:
- Read the data you need with read_table before answering. Never guess numbers, names or ids. Say plainly if something is not in the data.
- To change anything, use propose_changes. The user sees each line and taps Confirm; nothing changes before that. Never claim a change is done until you are told it was confirmed and done.
- For stock from a delivery note, invoice or spreadsheet: read the shop products and locations first, match each line to an existing product by name, and list lines that do not match so the user can decide (you may propose new products).
- Emails: short, friendly and plain, signed with the user's first name, never with dashes as punctuation. Use the customer's email from the data.
- Write in plain short sentences. No em dashes. Do not use the & sign. Keep answers short; use a short list when it helps.
Database tables (name: columns):
${Object.entries((schema ?? {}) as Record<string, string>).map(([t, c]) => `${t}: ${c}`).join("\n").slice(0, 60000)}`;
}

async function claude(sys: string, messages: unknown[], web: boolean) {
  const slot = await admin.rpc("ai_usage_take", { p_fn: "ask-ai" });
  if (slot.error || !slot.data) throw new Error("This month's AI allowance is used up.");
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST", headers: { "x-api-key": KEY(), "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: JSON.stringify({ model: MODEL, max_tokens: 4000, system: sys, tools: web ? [...TOOLS, { type: "web_search_20250305", name: "web_search", max_uses: 5 }] : TOOLS, messages }),
  });
  const j = await res.json().catch(() => ({}));
  await admin.from("ai_usage").update({ in_tokens: j?.usage?.input_tokens ?? null, out_tokens: j?.usage?.output_tokens ?? null, ok: res.ok }).eq("id", slot.data);
  if (!res.ok && web && /web.?search/i.test(String(j?.error?.message ?? ""))) return claude(sys, messages, false);
  if (!res.ok) throw new Error("The AI said: " + (j?.error?.message ?? res.status));
  return j as { content: { type: string; text?: string; id?: string; name?: string; input?: Record<string, unknown> }[]; stop_reason: string };
}

async function runAction(auth: string, user: ReturnType<typeof createClient>, a: { action: string; args: Record<string, unknown> }) {
  if (!(a.action in ACTIONS)) return { ok: false, error: "That action is not allowed." };
  const args = a.args ?? {};
  if (a.action === "send_email") {
    const { data: id, error } = await user.rpc("email_one_save", { p: { to: args.to, subject: args.subject, body: args.body, customer_id: args.customer_id ?? null } });
    if (error) return { ok: false, error: error.message };
    const r = await fetch(URL_ + "/functions/v1/mail-one", { method: "POST", headers: { "Content-Type": "application/json", apikey: ANON, Authorization: auth }, body: JSON.stringify({ id }) });
    const j = await r.json().catch(() => ({}));
    return j?.ok ? { ok: true, result: "Sent to " + args.to } : { ok: false, error: j?.error ?? "Not sent." };
  }
  const { data, error } = await user.rpc(a.action, args);
  return error ? { ok: false, error: error.message } : { ok: true, result: data };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  const auth = req.headers.get("authorization") ?? "";
  const who = await allowed(auth);
  if (!who) return json({ error: "Ask AI is not turned on for you. The owner can turn it on in Staff." }, 403);
  const b = await req.json().catch(() => ({}));
  try {
    if (b.mode === "run") {
      const out = [];
      for (const a of (Array.isArray(b.actions) ? b.actions : []).slice(0, 100)) out.push({ label: String(a.label ?? a.action), ...(await runAction(auth, who.user, a)) });
      return json({ results: out });
    }
    if (!KEY()) return json({ error: "The AI is not set up yet." });
    const messages = (Array.isArray(b.messages) ? b.messages : []).slice(-40);
    // the new message: text plus any files
    const last = messages[messages.length - 1];
    if (last && last.role === "user" && Array.isArray(b.files) && b.files.length) {
      const blocks = (Array.isArray(last.content) ? last.content : [{ type: "text", text: String(last.content ?? "") }]);
      for (const f of b.files.slice(0, 5)) blocks.push(...fileBlocks(f));
      last.content = blocks;
    }
    // web search (feature ask_ai_web, on unless turned off): find places, prices and contacts on the internet
    const { data: feats } = await admin.rpc("app_features");
    const web = (feats as Record<string, unknown> | null)?.ask_ai_web !== false;
    const sys = await system(who.user, who.staff?.name ?? "a team member") + (web ? "\nYou can search the web with web_search, for example to find nearby businesses, their websites and contact emails. Say where facts came from, and never invent an email address: if you cannot find one, say so." : "");
    const proposals: unknown[] = [];
    let reply = "";
    for (let i = 0; i < 8; i++) {
      const r = await claude(sys, messages, web);
      messages.push({ role: "assistant", content: r.content });
      const uses = r.content.filter((c) => c.type === "tool_use");
      reply = r.content.filter((c) => c.type === "text").map((c) => c.text).join("\n").trim() || reply;
      if (r.stop_reason === "pause_turn") continue;
      if (!uses.length || r.stop_reason !== "tool_use") break;
      const results = [];
      for (const u of uses) {
        let out = "";
        if (u.name === "read_table") out = await readTable(who.user, u.input ?? {});
        else if (u.name === "propose_changes") { proposals.push({ id: u.id, summary: u.input?.summary, actions: u.input?.actions }); out = "Shown to the user with a Confirm button. Nothing has changed yet. Tell them briefly what is ready to confirm."; }
        else out = "Unknown tool.";
        results.push({ type: "tool_result", tool_use_id: u.id, content: out });
      }
      messages.push({ role: "user", content: results });
    }
    // stopped in the middle of a tool call: drop it, so the next turn starts clean
    const end = messages[messages.length - 1] as { role: string; content: { type: string }[] };
    if (end?.role === "assistant" && Array.isArray(end.content) && end.content.some((c) => c.type === "tool_use")) messages.pop();
    return json({ reply, proposals, messages });
  } catch (e) {
    return json({ error: (e as Error).message });
  }
});
