// Website live chat. No sign in: the visitor gets a private key for their own chat, kept in their browser.
// status:  are we online (chat hours set in the app)
// start:   first message (+ name, + WhatsApp or email). Returns the chat id and key.
// send / contact / poll: need the id and key. Poll returns only this chat's messages.
// Each visitor message sends a notification to desk staff phones that switched notifications on in the app.
// app: a new message in an app chat (the database calls it with the sync token) notifies the other members' phones.
// Phones in the store apps (iPhone and Android) get the same notices through Apple and Google (see nativePush).
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
// ---------- store app notifications: Apple (iPhone) and Google Firebase (Android) ----------
// A phone in the store app is saved in push_subs with endpoint "apns:<token>" or "fcm:<token>".
// Secrets: APNS_KEY (the .p8 file's text), APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC (the app's bundle ID);
//          FCM_SERVICE_ACCOUNT (the Firebase service account JSON). Missing secrets: those phones are skipped.
const nenv = (k: string) => (Deno.env.get(k) ?? "").trim();
const b64url = (b: ArrayBuffer | Uint8Array | string) => {
  const u = typeof b === "string" ? new TextEncoder().encode(b) : b instanceof Uint8Array ? b : new Uint8Array(b);
  let s = ""; for (const x of u) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};
const pemBytes = (pem: string) => Uint8Array.from(atob(pem.replace(/-----[^-]+-----/g, "").replace(/\\n/g, "").replace(/\s+/g, "")), (c) => c.charCodeAt(0));
let apnsJwt: { tok: string; at: number } | null = null;
async function apnsToken() {
  if (apnsJwt && Date.now() - apnsJwt.at < 40 * 60e3) return apnsJwt.tok;
  const key = await crypto.subtle.importKey("pkcs8", pemBytes(nenv("APNS_KEY")), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const head = b64url(JSON.stringify({ alg: "ES256", kid: nenv("APNS_KEY_ID") })), body = b64url(JSON.stringify({ iss: nenv("APNS_TEAM_ID"), iat: Math.floor(Date.now() / 1000) }));
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(head + "." + body));
  apnsJwt = { tok: head + "." + body + "." + b64url(sig), at: Date.now() };
  return apnsJwt.tok;
}
let fcmAuth: { tok: string; exp: number; project: string } | null = null;
async function fcmToken() {
  if (fcmAuth && Date.now() < fcmAuth.exp) return fcmAuth;
  const sa = JSON.parse(nenv("FCM_SERVICE_ACCOUNT")) as { client_email: string; private_key: string; project_id: string };
  const key = await crypto.subtle.importKey("pkcs8", pemBytes(sa.private_key), { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const now = Math.floor(Date.now() / 1000);
  const head = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" })), body = b64url(JSON.stringify({ iss: sa.client_email, scope: "https://www.googleapis.com/auth/firebase.messaging", aud: "https://oauth2.googleapis.com/token", iat: now, exp: now + 3600 }));
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(head + "." + body));
  const r = await fetch("https://oauth2.googleapis.com/token", { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: head + "." + body + "." + b64url(sig) }) });
  const j = await r.json();
  if (!j.access_token) throw new Error("Firebase sign in: " + JSON.stringify(j).slice(0, 200));
  fcmAuth = { tok: j.access_token, exp: Date.now() + 50 * 60e3, project: sa.project_id };
  return fcmAuth;
}
// returns "gone" when the phone no longer has the app (the caller removes it)
async function nativePush(endpoint: string, m: { title: string; body: string; tag?: string; url?: string }): Promise<"ok" | "gone" | "skip" | "fail"> {
  try {
    if (endpoint.startsWith("apns:")) {
      if (!nenv("APNS_KEY") || !nenv("APNS_KEY_ID") || !nenv("APNS_TEAM_ID") || !nenv("APNS_TOPIC")) return "skip";
      const tok = endpoint.slice(5), jwt = await apnsToken();
      const payload = JSON.stringify({ aps: { alert: { title: m.title, body: m.body }, sound: "default", "thread-id": (m.tag ?? "").slice(0, 60) }, url: m.url ?? "" });
      const go = (host: string) => fetch(`https://${host}/3/device/${tok}`, { method: "POST", body: payload,
        headers: { authorization: "bearer " + jwt, "apns-topic": nenv("APNS_TOPIC"), "apns-push-type": "alert", "apns-priority": "10", "apns-expiration": String(Math.floor(Date.now() / 1000) + 3600) } });
      let r = await go("api.push.apple.com");
      // a phone running a build from Xcode uses Apple's test service
      if (r.status === 400 && /BadDeviceToken/.test(await r.clone().text())) r = await go("api.sandbox.push.apple.com");
      if (r.status === 410) return "gone";
      if (!r.ok) { const t = await r.text(); if (/BadDeviceToken|Unregistered|DeviceTokenNotForTopic/.test(t)) return "gone"; console.error("apns", r.status, t.slice(0, 200)); return "fail"; }
      return "ok";
    }
    if (endpoint.startsWith("fcm:")) {
      if (!nenv("FCM_SERVICE_ACCOUNT")) return "skip";
      const a = await fcmToken();
      const r = await fetch(`https://fcm.googleapis.com/v1/projects/${a.project}/messages:send`, { method: "POST", headers: { Authorization: "Bearer " + a.tok, "Content-Type": "application/json" },
        body: JSON.stringify({ message: { token: endpoint.slice(4), notification: { title: m.title, body: m.body }, data: { url: m.url ?? "", tag: m.tag ?? "" },
          android: { priority: "high", ttl: "3600s", notification: { tag: (m.tag ?? "").slice(0, 60) || undefined, sound: "default" } } } }) });
      if (r.ok) return "ok";
      const t = await r.text();
      if (r.status === 404 || /UNREGISTERED|registration-token-not-registered/.test(t)) return "gone";
      console.error("fcm", r.status, t.slice(0, 200)); return "fail";
    }
    return "skip";
  } catch (e) { console.error("native push", (e as Error).message); return "fail"; }
}
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
      if (/^(apns|fcm):/.test(s.endpoint)) {
        const r = await nativePush(s.endpoint, { title: p.title, body: p.body, tag: p.tag ?? "chat-" + p.chat, url: p.url ?? "https://app.phuketking.com/#chat=" + p.chat });
        if (r === "gone") await admin.rpc("web_push_gone", { p_endpoint: s.endpoint });
        return;
      }
      try {
        await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, msg, { TTL: 3600, urgency: "high" });
      } catch (e) {
        const code = (e as { statusCode?: number }).statusCode;
        if (code === 404 || code === 410) await admin.rpc("web_push_gone", { p_endpoint: s.endpoint });
      }
    }));
  } catch (_e) { /* notifications are best effort */ }
}
const RESEND = () => (Deno.env.get("RESEND_API_KEY") ?? "").trim();
const esc = (x: string) => x.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));
async function bookingMail(to: string, from: string | null, title: string, body: string, link: string) {
  if (!RESEND()) return false;
  const subject = title.replace(/^.*\/\s*/, ""), head = subject;
  const text = [body, "", "Open it in the app: " + link].join("\n");
  const html = `<div style="font-family:system-ui,-apple-system,sans-serif;font-size:15px;line-height:1.5;color:#111"><h2 style="margin:0 0 8px">${esc(head)}</h2><p>${esc(body)}</p><p><a href="${esc(link)}">Open it in the app</a></p></div>`;
  try {
    const r = await fetch("https://api.resend.com/emails", { method: "POST", headers: { Authorization: `Bearer ${RESEND()}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: from || "Bookings <hello@app.phuketking.com>", to: [to], subject, html, text }) });
    const j = await r.json().catch(() => ({}));
    await admin.from("sent_emails").insert({ to_email: to, subject, body: text, status: r.ok ? "sent" : "failed", error: r.ok ? null : String(j?.message ?? r.status).slice(0, 300), resend_id: j?.id ?? null, sent_at: r.ok ? new Date().toISOString() : null, campaign: "booking_alert" });
    return r.ok;
  } catch (_e) { return false; }
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
    const tg = t as { title: string; body: string; tag: string; url: string; subs: Sub[]; email?: string | null; from?: string | null } | null;
    if (tg && tg.subs?.length) await send(tg.subs, { title: tg.title, body: tg.body, chat: "", tag: tg.tag, url: "https://app.phuketking.com/" + (tg.url || "") });
    // new bookings are also emailed to the address set in Messages, Booking notifications
    let mailed = false;
    if (tg?.email && /^book_/.test(str(b.kind, 20))) mailed = await bookingMail(tg.email, tg.from ?? null, tg.title, tg.body, "https://app.phuketking.com/" + (tg.url || ""));
    return json({ ok: true, sent: tg?.subs?.length ?? 0, mailed });
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
