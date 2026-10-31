// Website live chat. No sign in: the visitor gets a private key for their own chat, kept in their browser.
// status:  are we online (chat hours set in the app)
// start:   first message (+ name, + WhatsApp or email). Returns the chat id and key.
// send / contact / poll: need the id and key. Poll returns only this chat's messages.
// Each visitor message sends a notification to desk staff phones that switched notifications on in the app.
// app: a new message in an app chat (the database calls it with the sync token) notifies the other members' phones.
// order: a new food or drink order from the app (the database calls it with the sync token) notifies staff phones; tapping opens the kitchen screen.
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const str = (x: unknown, n: number) => String(x ?? "").slice(0, n);

let keys: { public: string; private: string } | null = null;
async function vapid() {
  if (keys) return keys;
  let { data } = await admin.rpc("web_push_keys");
  if (!data?.public || !data?.private) {
    const k = webpush.generateVAPIDKeys();
    await admin.rpc("web_push_keys_set", { p_public: k.publicKey, p_private: k.privateKey });
    ({ data } = await admin.rpc("web_push_keys"));
  }
  keys = data as { public: string; private: string };
  webpush.setVapidDetails("mailto:hello@phuketking.com", keys.public, keys.private);
  return keys;
}
type Sub = { endpoint: string; p256dh: string; auth: string };
async function notify(p: { title: string; body: string; chat: string }) {
  try {
    const { data } = await admin.rpc("web_push_targets");
    await send((data ?? []) as Sub[], p);
  } catch (_e) { /* notifications are best effort */ }
}
async function send(subs: Sub[], p: { title: string; body: string; chat: string; tag?: string; url?: string }) {
  try {
    await vapid();
    const msg = JSON.stringify({ title: p.title, body: p.body, tag: p.tag ?? "chat-" + p.chat, url: p.url ?? "https://app.phuketking.com/#chat=" + p.chat });
    await Promise.all(subs.map(async (s) => {
      try {
        await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, msg, { TTL: 3600, urgency: "high" });
      } catch (e) {
        const code = (e as { statusCode?: number }).statusCode;
        if (code === 404 || code === 410) await admin.rpc("web_push_gone", { p_endpoint: s.endpoint });
      }
    }));
  } catch (_e) { /* notifications are best effort */ }
}
async function ipHash(req: Request) {
  const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim();
  if (!ip) return "";
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("pk-chat:" + ip));
  return Array.from(new Uint8Array(d)).slice(0, 12).map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  const b = await req.json().catch(() => ({}));
  const mode = str(b.mode, 10);
  if (mode === "keys") { await vapid(); return json({ ok: true }); }
  // a new message in the app (group, staff, coach or desk chat): the database asks, the other members' phones get it
  if (mode === "app") {
    const { data: ok } = await admin.rpc("sync_token_ok", { p_token: req.headers.get("x-sync-token") ?? "" });
    if (ok !== true) return json({ error: "Not allowed." }, 401);
    const { data: t } = await admin.rpc("chat_push_targets", { p_message: str(b.id, 40) });
    const tg = t as { title: string; body: string; chat: string; subs: { endpoint: string; p256dh: string; auth: string }[] } | null;
    if (tg && tg.subs?.length) await send(tg.subs, { title: tg.title, body: tg.body, chat: tg.chat });
    return json({ ok: true, sent: tg?.subs?.length ?? 0 });
  }
  if (mode === "order") {
    const { data: ok } = await admin.rpc("sync_token_ok", { p_token: req.headers.get("x-sync-token") ?? "" });
    if (ok !== true) return json({ error: "Not allowed." }, 401);
    const { data: t } = await admin.rpc("order_push_targets", { p_order: str(b.id, 40) });
    const tg = t as { title: string; body: string; order: string; subs: Sub[] } | null;
    if (tg && tg.subs?.length) await send(tg.subs, { title: tg.title, body: tg.body, chat: "", tag: "order-" + tg.order, url: "https://app.phuketking.com/#kitchen" });
    return json({ ok: true, sent: tg?.subs?.length ?? 0 });
  }
  // other phone notices the database asks for, for example a guest with a food plan checking in (push_targets)
  if (mode === "push") {
    const { data: ok } = await admin.rpc("sync_token_ok", { p_token: req.headers.get("x-sync-token") ?? "" });
    if (ok !== true) return json({ error: "Not allowed." }, 401);
    const { data: t } = await admin.rpc("push_targets", { p_kind: str(b.kind, 20), p_id: str(b.id, 40) });
    const tg = t as { title: string; body: string; tag: string; url: string; subs: Sub[] } | null;
    if (tg && tg.subs?.length) await send(tg.subs, { title: tg.title, body: tg.body, chat: "", tag: tg.tag, url: "https://app.phuketking.com/" + (tg.url || "") });
    return json({ ok: true, sent: tg?.subs?.length ?? 0 });
  }
  if (!["status", "start", "send", "contact", "poll"].includes(mode)) return json({ error: "Unknown request." }, 400);
  const p: Record<string, string> = { mode };
  if (mode === "start") { p.name = str(b.name, 80); p.contact = str(b.contact, 120); p.body = str(b.body, 2000); p.page = str(b.page, 200); p.ip = await ipHash(req); }
  if (mode !== "status" && mode !== "start") { p.id = str(b.id, 40); p.key = str(b.key, 80); }
  if (mode === "send") p.body = str(b.body, 2000);
  if (mode === "contact") { p.contact = str(b.contact, 120); p.name = str(b.name, 80); }
  if (mode === "poll" && b.after) p.after = str(b.after, 40);
  const { data, error } = await admin.rpc("web_chat_api", { p });
  if (error) return json({ error: error.message });
  const out = data as Record<string, unknown>;
  if (out.push) {
    const job = notify(out.push as { title: string; body: string; chat: string });
    // deno-lint-ignore no-explicit-any
    const rt = (globalThis as any).EdgeRuntime; if (rt?.waitUntil) rt.waitUntil(job); else await job;
    delete out.push;
  }
  return json(out);
});
