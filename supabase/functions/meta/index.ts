// Facebook Messenger and Instagram messages in the app.
// GET  (Meta webhook check)       answers the verify challenge (META_VERIFY_TOKEN)
// POST (Meta webhook, signed)     new messages: saved to Messages, desk phones get a notification. Signature checked with META_APP_SECRET.
// POST {mode:'send', id}          x-sync-token (the database, when staff reply): sends the reply through Meta and records the result
// POST {mode:'check'|'subscribe'} x-sync-token: is the token working / switch on webhooks for the page
// Secrets: META_PAGE_TOKEN (system user or page token), META_APP_SECRET. The webhook verify token is kept in the database (private.sync_settings 'meta_verify').
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const env = (k: string) => (Deno.env.get(k) ?? "").trim();
const G = "https://graph.facebook.com/v23.0";
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });

// ---------- Graph ----------
let page: { id: string; name: string; token: string; ig: string | null; ig_name: string | null } | null = null;
async function call(path: string, params: Record<string, string>, method = "GET", token?: string, body?: unknown) {
  const q = new URLSearchParams({ ...params, access_token: token ?? env("META_PAGE_TOKEN") });
  const r = await fetch(`${G}/${path}?${q}`, method === "GET" ? {} : { method, headers: body ? { "Content-Type": "application/json" } : undefined, body: body ? JSON.stringify(body) : undefined });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || j.error) throw new Error(j?.error?.error_user_msg ?? j?.error?.message ?? `Meta said ${r.status}`);
  return j;
}
async function thePage() {
  if (page) return page;
  const me = await call("me", { fields: "id,name" });
  try {
    const p = await call(me.id, { fields: "id,name,instagram_business_account{id,username}" });
    page = { id: p.id, name: p.name, token: env("META_PAGE_TOKEN"), ig: p.instagram_business_account?.id ?? null, ig_name: p.instagram_business_account?.username ?? null };
  } catch {
    const acc = await call("me/accounts", { fields: "id,name,access_token,instagram_business_account{id,username}" });
    const p = (acc.data ?? [])[0];
    if (!p) throw new Error("The token cannot see any Facebook page.");
    page = { id: p.id, name: p.name, token: p.access_token, ig: p.instagram_business_account?.id ?? null, ig_name: p.instagram_business_account?.username ?? null };
  }
  return page;
}

// ---------- phone notifications (same as website chat) ----------
let keys: { public: string; private: string } | null = null;
async function notify(title: string, body: string, chat: string) {
  try {
    if (!keys) {
      const { data } = await admin.rpc("web_push_keys");
      if (!data?.public || !data?.private) return;
      keys = data; webpush.setVapidDetails("mailto:hello@phuketking.com", keys!.public, keys!.private);
    }
    const { data } = await admin.rpc("web_push_targets");
    const msg = JSON.stringify({ title, body: body.slice(0, 140), tag: "chat-" + chat, url: "https://app.phuketking.com/#chat=" + chat });
    await Promise.all(((data ?? []) as { endpoint: string; p256dh: string; auth: string }[]).map(async (s) => {
      try { await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, msg, { TTL: 3600, urgency: "high" }); }
      catch (e) { const c = (e as { statusCode?: number }).statusCode; if (c === 404 || c === 410) await admin.rpc("web_push_gone", { p_endpoint: s.endpoint }); }
    }));
  } catch { /* best effort */ }
}

// ---------- incoming ----------
async function signed(req: Request, raw: string) {
  const secret = env("META_APP_SECRET");
  if (!secret) return false;
  const sig = (req.headers.get("x-hub-signature-256") ?? "").replace(/^sha256=/, "");
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = Array.from(new Uint8Array(await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(raw)))).map((b) => b.toString(16).padStart(2, "0")).join("");
  return sig.length === mac.length && sig === mac;
}
async function who(kind: string, id: string) {
  try {
    const p = await thePage();
    if (kind === "fb") { const u = await call(id, { fields: "first_name,last_name,profile_pic" }, "GET", p.token); return { name: [u.first_name, u.last_name].filter(Boolean).join(" "), pic: u.profile_pic ?? null }; }
    const u = await call(id, { fields: "name,username,profile_pic" }, "GET", p.token);
    return { name: u.name || (u.username ? "@" + u.username : ""), pic: u.profile_pic ?? null };
  } catch { return { name: "", pic: null }; }
}
type Ev = { sender?: { id: string }; recipient?: { id: string }; timestamp?: number; message?: { mid?: string; text?: string; is_echo?: boolean; app_id?: number | string; attachments?: { type?: string; payload?: { url?: string } }[] } };
async function incoming(body: { object?: string; entry?: { id?: string; messaging?: Ev[]; standby?: Ev[] }[] }) {
  const kind = body.object === "instagram" ? "ig" : body.object === "page" ? "fb" : null;
  if (!kind) return;
  for (const en of body.entry ?? []) {
    for (const ev of [...(en.messaging ?? []), ...(en.standby ?? [])]) {
      const m = ev.message; if (!m) continue;
      const echo = !!m.is_echo;
      if (echo && m.app_id && String(m.app_id) === (env("META_APP_ID") || "1116664774235703")) continue; // our own reply coming back
      const sid = echo ? ev.recipient?.id : ev.sender?.id;
      if (!sid || sid === en.id) continue;
      const media = (m.attachments ?? []).map((a) => ({ type: a.type ?? "file", url: a.payload?.url ?? null })).filter((a) => a.url);
      const { data, error } = await admin.rpc("meta_incoming", { p: { kind, social_id: sid, mid: m.mid, text: m.text ?? "", media, echo, at: ev.timestamp ? new Date(ev.timestamp).toISOString() : null } });
      if (error || !data || data.dup) continue;
      let name = "";
      if (data.needs_name) {
        const u = await who(kind, sid);
        if (u.name) { name = u.name; await admin.from("chats").update({ visitor_name: u.name.slice(0, 80), social_pic: u.pic }).eq("id", data.chat_id); }
      } else {
        const { data: c } = await admin.from("chats").select("visitor_name").eq("id", data.chat_id).maybeSingle();
        name = c?.visitor_name ?? "";
      }
      if (!echo) await notify(`${kind === "ig" ? "Instagram" : "Facebook"}: ${name || "new message"}`, m.text || "Sent a photo or file", data.chat_id);
    }
  }
}

// ---------- outgoing ----------
async function send(id: string) {
  const { data: o } = await admin.rpc("meta_out", { p_id: id });
  if (!o || o.status !== "sending") return { skipped: true };
  let err: string | null = null, mid: string | null = null;
  try {
    const p = await thePage();
    const open = o.last_in_at && Date.now() - new Date(o.last_in_at).getTime() < 24 * 3600e3;
    const msg: Record<string, unknown> = { recipient: { id: o.social_id }, message: { text: o.body } };
    if (open) msg.messaging_type = "RESPONSE";
    else { msg.messaging_type = "MESSAGE_TAG"; msg.tag = "HUMAN_AGENT"; }
    const r = await call(`${p.id}/messages`, {}, "POST", p.token, msg);
    mid = r.message_id ?? null;
  } catch (e) {
    err = (e as Error).message;
    if (/outside of allowed window|24 hour|HUMAN_AGENT|tag/i.test(err)) err = "Not delivered: more than 24 hours since their last message. Meta only allows replies inside that time.";
  }
  await admin.from("chat_messages").update(err ? { send_status: "failed", send_error: err.slice(0, 300) } : { send_status: "sent", ext_id: mid, send_error: null }).eq("id", id);
  return { ok: !err, error: err };
}

Deno.serve(async (req) => {
  if (req.method === "GET") {
    const u = new URL(req.url);
    if (u.searchParams.get("hub.mode") === "subscribe") {
      const { data: ok } = await admin.rpc("meta_verify_ok", { p_token: u.searchParams.get("hub.verify_token") ?? "" });
      if (ok === true) return new Response(u.searchParams.get("hub.challenge") ?? "", { status: 200 });
    }
    return new Response("Forbidden", { status: 403 });
  }
  if (req.method !== "POST") return new Response("Use POST", { status: 405 });
  const raw = await req.text();
  // a signed webhook from Meta
  if (req.headers.get("x-hub-signature-256")) {
    if (!(await signed(req, raw))) return new Response("Bad signature", { status: 401 });
    try { await incoming(JSON.parse(raw)); } catch (e) { console.error("webhook", (e as Error).message); }
    return new Response("ok", { status: 200 });
  }
  const b = (() => { try { return JSON.parse(raw); } catch { return {}; } })();
  const { data: ok } = await admin.rpc("sync_token_ok", { p_token: req.headers.get("x-sync-token") ?? "" });
  if (ok !== true) return json({ error: "Not allowed." }, 401);
  try {
    if (b.mode === "send") return json(await send(String(b.id ?? "")));
    if (b.mode === "check") {
      const p = await thePage();
      return json({ ok: true, page: p.name, page_id: p.id, instagram: p.ig_name, instagram_id: p.ig, secret: !!env("META_APP_SECRET"), app_id: (env("META_APP_ID") || "1116664774235703") });
    }
    if (b.mode === "appsubs") {
      const appId = env("META_APP_ID") || "1116664774235703", tok = `${appId}|${env("META_APP_SECRET")}`;
      if (b.set) {
        const { data: v } = await admin.rpc("meta_verify_value");
        const cb = Deno.env.get("SUPABASE_URL") + "/functions/v1/meta";
        for (const [object, fields] of [["page", "messages,message_echoes,standby"], ["instagram", "messages,standby"]]) {
          try { await call(`${appId}/subscriptions`, { object, callback_url: cb, verify_token: String(v ?? ""), fields, include_values: "true" }, "POST", tok); }
          catch (e) { return json({ error: object + ": " + (e as Error).message }); }
        }
      }
      return json(await call(`${appId}/subscriptions`, {}, "GET", tok));
    }
    if (b.mode === "subscribe") {
      const p = await thePage();
      const r = await call(`${p.id}/subscribed_apps`, { subscribed_fields: "messages,message_echoes,standby" }, "POST", p.token);
      const list = await call(`${p.id}/subscribed_apps`, {}, "GET", p.token);
      return json({ ok: true, r, list });
    }
    return json({ error: "Unknown request." }, 400);
  } catch (e) { return json({ error: (e as Error).message }); }
});
