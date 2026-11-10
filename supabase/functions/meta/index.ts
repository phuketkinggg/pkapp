// Facebook Messenger, Instagram and WhatsApp messages in the app, and AI replies to them.
// GET  (Meta webhook check)       answers the verify challenge (META_VERIFY_TOKEN)
// POST (Meta webhook, signed)     new messages: saved to Messages, desk phones get a notification, the AI answers when it is switched on.
//                                 Signature checked with META_APP_SECRET. WhatsApp: object whatsapp_business_account (messages,
//                                 smb_message_echoes for replies sent from the WhatsApp Business app on the phone, history, statuses).
// POST {mode:'send', id}          x-sync-token (the database, when staff reply): sends the reply through Meta and records the result
// POST {mode:'check'|'subscribe'|'appsubs'} x-sync-token: is the token working / switch on webhooks for the page and WhatsApp
// POST {mode:'wa_connect', code, waba_id?, phone_id?, coexist?} a manager, after the Meta sign in in the app: connects the WhatsApp number
// POST {mode:'wa_manual', phone_id, waba_id} a manager: connects a number set up by hand in Meta (token in the WA_TOKEN secret)
// POST {mode:'wa_check'|'wa_disconnect'} a manager: is WhatsApp working / stop using it in the app
// POST {mode:'meta_cfg'} a manager: the Meta app ID and sign in configuration IDs for the app's Connect buttons
// POST {mode:'fb_connect', code} a manager, after the Meta sign in in the app: finds the Facebook pages (and their Instagram);
//      one page is connected at once, more than one comes back as {choose:[...]} for {mode:'fb_pick', page_id}
// POST {mode:'fb_check'|'fb_disconnect'} a manager: which page and Instagram are connected / stop using the page connected in the app
// Secrets: META_PAGE_TOKEN (optional when the page is connected in the app), META_APP_SECRET, META_APP_ID, WA_TOKEN (optional: a system user token with WhatsApp rights),
//          META_FB_CONFIG and META_WA_CONFIG (optional: the sign in configuration IDs, so managers do not type them),
//          ANTHROPIC_API_KEY (AI replies). The webhook verify token is kept in the database (private.sync_settings 'meta_verify').
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const env = (k: string) => (Deno.env.get(k) ?? "").trim();
const G = "https://graph.facebook.com/v23.0";
// the app calls the wa_ modes from the browser
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

// ---------- Graph ----------
// the page connected in the app (private.meta_link) comes first, then the META_PAGE_TOKEN secret
type MetaLink = { page_id?: string; page_name?: string; token?: string; ig_id?: string; ig_name?: string; pages?: { id: string; name: string; access_token: string; ig?: string | null; ig_name?: string | null }[] | null };
let link: MetaLink = {};
async function loadLink() {
  const { data } = await admin.rpc("meta_link_get");
  const l = (data ?? {}) as MetaLink;
  if ((l.token ?? "") !== (link.token ?? "")) page = null; // another page was connected since: forget the old one
  link = l;
}
const pageToken = () => link.token || env("META_PAGE_TOKEN");
let page: { id: string; name: string; token: string; ig: string | null; ig_name: string | null } | null = null;
async function call(path: string, params: Record<string, string>, method = "GET", token?: string, body?: unknown) {
  const q = new URLSearchParams({ ...params, access_token: token ?? pageToken() });
  const r = await fetch(`${G}/${path}?${q}`, method === "GET" ? {} : { method, headers: body ? { "Content-Type": "application/json" } : undefined, body: body ? JSON.stringify(body) : undefined });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || j.error) throw new Error(j?.error?.error_user_msg ?? j?.error?.message ?? `Meta said ${r.status}`);
  return j;
}
async function thePage() {
  if (page) return page;
  if (link.page_id && link.token) { page = { id: link.page_id, name: link.page_name ?? "", token: link.token, ig: link.ig_id ?? null, ig_name: link.ig_name ?? null }; return page; }
  if (!pageToken()) throw new Error("Facebook and Instagram are not connected yet.");
  const me = await call("me", { fields: "id,name" });
  try {
    const p = await call(me.id, { fields: "id,name,instagram_business_account{id,username}" });
    page = { id: p.id, name: p.name, token: pageToken(), ig: p.instagram_business_account?.id ?? null, ig_name: p.instagram_business_account?.username ?? null };
  } catch {
    const acc = await call("me/accounts", { fields: "id,name,access_token,instagram_business_account{id,username}" });
    const p = (acc.data ?? [])[0];
    if (!p) throw new Error("The token cannot see any Facebook page.");
    page = { id: p.id, name: p.name, token: p.access_token, ig: p.instagram_business_account?.id ?? null, ig_name: p.instagram_business_account?.username ?? null };
  }
  return page;
}

// ---------- phone notifications (same as website chat) ----------
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
      if (/^(apns|fcm):/.test(s.endpoint)) {
        if (await nativePush(s.endpoint, { title, body: body.slice(0, 140), tag: "chat-" + chat, url: "https://app.phuketking.com/#chat=" + chat }) === "gone") await admin.rpc("web_push_gone", { p_endpoint: s.endpoint });
        return;
      }
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
async function incoming(body: { object?: string; entry?: { id?: string; messaging?: Ev[]; standby?: Ev[] }[] }, later: (p: Promise<unknown>) => void) {
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
      if (!echo && m.mid) later(aiReply(data.chat_id, m.mid));
    }
  }
}

// ---------- WhatsApp ----------
type WaLink = { phone_id?: string; waba_id?: string; number?: string; name?: string; token?: string; coexist?: boolean; synced?: Record<string, unknown> };
let wa: WaLink | null = null;
async function waLink(fresh = false): Promise<WaLink> { if (wa && !fresh) return wa; const { data } = await admin.rpc("wa_get"); wa = (data ?? {}) as WaLink; return wa; }
const waTok = (l: WaLink) => l.token || env("WA_TOKEN") || pageToken();
type WaMsg = { from?: string; to?: string; id?: string; timestamp?: string; type?: string; text?: { body?: string }; button?: { text?: string };
  interactive?: { button_reply?: { title?: string }; list_reply?: { title?: string } }; image?: { caption?: string }; video?: { caption?: string };
  document?: { caption?: string; filename?: string }; location?: { name?: string; address?: string }; reaction?: unknown };
function waText(m: WaMsg) {
  switch (m.type) {
    case "text": return m.text?.body ?? "";
    case "button": return m.button?.text ?? "";
    case "interactive": return m.interactive?.button_reply?.title ?? m.interactive?.list_reply?.title ?? "";
    case "image": return m.image?.caption ? "[Photo] " + m.image.caption : "[Photo]";
    case "video": return m.video?.caption ? "[Video] " + m.video.caption : "[Video]";
    case "document": return "[File] " + (m.document?.caption ?? m.document?.filename ?? "");
    case "audio": return "[Voice message]";
    case "sticker": return "[Sticker]";
    case "location": return "[Location] " + [m.location?.name, m.location?.address].filter(Boolean).join(", ");
    default: return "[Message]";
  }
}
const waAt = (t?: string) => (t ? new Date(Number(t) * 1000).toISOString() : null);
type WaVal = { metadata?: { phone_number_id?: string; display_phone_number?: string }; contacts?: { wa_id?: string; profile?: { name?: string } }[];
  messages?: WaMsg[]; message_echoes?: WaMsg[]; statuses?: { id?: string; status?: string; errors?: { code?: number; title?: string; message?: string }[] }[];
  history?: { threads?: { id?: string; messages?: WaMsg[] }[] }[] };
async function incomingWa(body: { entry?: { changes?: { field?: string; value?: WaVal }[] }[] }, later: (p: Promise<unknown>) => void) {
  const l = await waLink();
  for (const en of body.entry ?? []) for (const ch of en.changes ?? []) {
    const v = ch.value ?? {};
    if (!l.phone_id || v.metadata?.phone_number_id !== l.phone_id) continue; // not connected, or another number
    const names: Record<string, string> = {};
    for (const c of v.contacts ?? []) if (c.wa_id) names[c.wa_id] = c.profile?.name ?? "";
    // a customer wrote
    for (const m of v.messages ?? []) {
      if (!m.from || !m.id || m.type === "reaction") continue;
      const text = waText(m);
      const { data, error } = await admin.rpc("meta_incoming", { p: { kind: "wa", social_id: m.from, mid: m.id, text, name: names[m.from] ?? "", echo: false, at: waAt(m.timestamp) } });
      if (error || !data || data.dup) continue;
      const { data: c } = await admin.from("chats").select("visitor_name").eq("id", data.chat_id).maybeSingle();
      await notify("WhatsApp: " + (c?.visitor_name || "+" + m.from), text || "New message", data.chat_id);
      later(aiReply(data.chat_id, m.id));
    }
    // the team replied from the WhatsApp Business app on the phone (when the number works in both)
    for (const m of v.message_echoes ?? []) {
      if (!m.to || !m.id) continue;
      await admin.rpc("meta_incoming", { p: { kind: "wa", social_id: m.to, mid: m.id, text: waText(m), echo: true, at: waAt(m.timestamp) } });
    }
    // a message we sent could not be delivered
    for (const st of v.statuses ?? []) {
      if (st.status !== "failed" || !st.id) continue;
      const e = st.errors?.[0];
      const why = e?.code === 131047 ? "Not delivered: more than 24 hours since their last message. WhatsApp only allows replies inside that time." : "Not delivered: " + (e?.message ?? e?.title ?? "WhatsApp did not deliver it");
      await admin.from("chat_messages").update({ send_status: "failed", send_error: why.slice(0, 300) }).eq("ext_id", st.id);
    }
    // past chats shared when the number was connected (last 60 days, no notifications, no AI)
    for (const h of v.history ?? []) for (const t of h.threads ?? []) for (const m of t.messages ?? []) {
      if (!t.id || !m.id || m.type === "reaction") continue;
      const at = waAt(m.timestamp); if (!at || Date.now() - new Date(at).getTime() > 60 * 864e5) continue;
      await admin.rpc("meta_incoming", { p: { kind: "wa", social_id: t.id, mid: m.id, text: waText(m), echo: m.from !== t.id, at } });
    }
  }
}
async function waSend(to: string, text: string) {
  const l = await waLink();
  if (!l.phone_id) throw new Error("WhatsApp is not connected. Connect it in Settings, WhatsApp.");
  const r = await fetch(`${G}/${l.phone_id}/messages`, { method: "POST", headers: { Authorization: `Bearer ${waTok(l)}`, "Content-Type": "application/json" },
    body: JSON.stringify({ messaging_product: "whatsapp", recipient_type: "individual", to, type: "text", text: { preview_url: true, body: text.slice(0, 4096) } }) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || j.error) {
    const code = j?.error?.code;
    if (code === 131047 || /re-engagement|24 hours/i.test(j?.error?.message ?? "")) throw new Error("Not delivered: more than 24 hours since their last message. WhatsApp only allows replies inside that time.");
    throw new Error(j?.error?.error_data?.details ?? j?.error?.message ?? `WhatsApp said ${r.status}`);
  }
  return (j.messages?.[0]?.id ?? null) as string | null;
}
// one reply to any chat, on the platform the chat came from
async function sendTo(kind: string, sid: string, lastIn: string | null, text: string) {
  if (kind === "wa") return await waSend(sid, text);
  const p = await thePage();
  const open = lastIn && Date.now() - new Date(lastIn).getTime() < 24 * 3600e3;
  const msg: Record<string, unknown> = { recipient: { id: sid }, message: { text } };
  if (open) msg.messaging_type = "RESPONSE";
  else { msg.messaging_type = "MESSAGE_TAG"; msg.tag = "HUMAN_AGENT"; }
  try { const r = await call(`${p.id}/messages`, {}, "POST", p.token, msg); return (r.message_id ?? null) as string | null; }
  catch (e) {
    const err = (e as Error).message;
    if (/outside of allowed window|24 hour|HUMAN_AGENT|tag/i.test(err)) throw new Error("Not delivered: more than 24 hours since their last message. Meta only allows replies inside that time.");
    throw e;
  }
}

// connect the number after the Meta sign in in the app (Embedded Signup): swap the code for a token, find the number,
// let the app receive its messages, and (when the number stays on the WhatsApp Business app too) share contacts and past chats
async function waConnect(b: Record<string, unknown>) {
  const appId = env("META_APP_ID") || "1116664774235703", secret = env("META_APP_SECRET");
  if (!secret) return { error: "META_APP_SECRET is missing in Supabase secrets." };
  const code = String(b.code ?? ""); if (!code) return { error: "No sign in code from Meta. Try again." };
  const t = await fetch(`${G}/oauth/access_token?` + new URLSearchParams({ client_id: appId, client_secret: secret, code }));
  const tj = await t.json().catch(() => ({}));
  if (!tj.access_token) return { error: "Meta did not give access: " + (tj?.error?.message ?? t.status) };
  const tok = tj.access_token as string;
  let waba = String(b.waba_id ?? "");
  if (!waba) {
    try { const d = await call("debug_token", { input_token: tok }, "GET", `${appId}|${secret}`);
      const g = (d.data?.granular_scopes ?? []).find((x: { scope: string; target_ids?: string[] }) => x.scope === "whatsapp_business_management");
      waba = g?.target_ids?.[0] ?? ""; } catch { /* asked below */ }
  }
  if (!waba) return { error: "Could not find the WhatsApp business account. Try again and pick it in the Meta window." };
  const nums = await call(`${waba}/phone_numbers`, { fields: "id,display_phone_number,verified_name,platform_type,is_on_biz_app" }, "GET", tok);
  const list = (nums.data ?? []) as { id: string; display_phone_number: string; verified_name: string; is_on_biz_app?: boolean }[];
  const ph = list.find((x) => x.id === String(b.phone_id ?? "")) ?? list[0];
  if (!ph) return { error: "That WhatsApp account has no phone number yet." };
  await call(`${waba}/subscribed_apps`, {}, "POST", tok);
  const coexist = !!b.coexist || !!ph.is_on_biz_app;
  const synced: Record<string, unknown> = {};
  if (coexist) {
    for (const sync_type of ["smb_app_state_sync", "history"]) {
      try { const r = await call(`${ph.id}/smb_app_data`, {}, "POST", tok, { messaging_product: "whatsapp", sync_type }); synced[sync_type] = r.request_id ?? true; }
      catch (e) { synced[sync_type] = "failed: " + (e as Error).message; }
    }
  } else {
    // a number only for the app: register it for sending (a random two step PIN, kept with the link)
    const pin = String(Math.floor(100000 + Math.random() * 900000));
    try { await call(`${ph.id}/register`, {}, "POST", tok, { messaging_product: "whatsapp", pin }); synced.pin = pin; }
    catch (e) { synced.register = "failed: " + (e as Error).message; }
  }
  await admin.rpc("wa_set", { p: { phone_id: ph.id, waba_id: waba, number: ph.display_phone_number, name: ph.verified_name, token: tok, coexist, synced } });
  wa = null;
  await waSubs();
  return { ok: true, number: ph.display_phone_number, name: ph.verified_name, coexist, synced: Object.fromEntries(Object.entries(synced).filter(([k]) => k !== "pin")) };
}
// the app's webhook subscription for WhatsApp (once per app; harmless to repeat)
async function waSubs() {
  const appId = env("META_APP_ID") || "1116664774235703", tok = `${appId}|${env("META_APP_SECRET")}`;
  const { data: v } = await admin.rpc("meta_verify_value");
  try { await call(`${appId}/subscriptions`, { object: "whatsapp_business_account", callback_url: Deno.env.get("SUPABASE_URL") + "/functions/v1/meta", verify_token: String(v ?? ""),
    fields: "messages,smb_message_echoes,history,smb_app_state_sync", include_values: "true" }, "POST", tok); return null; }
  catch (e) { return (e as Error).message; }
}
// ---------- Facebook page and Instagram, connected in the app ----------
async function metaCfg() {
  const { data } = await admin.from("app_settings").select("value").eq("key", "wa_meta").maybeSingle();
  let typed: Record<string, string> = {}; try { typed = JSON.parse(data?.value ?? "{}") ?? {}; } catch { /* nothing typed */ }
  const app = env("META_APP_ID"), fb = env("META_FB_CONFIG"), wa = env("META_WA_CONFIG");
  return { app_id: app || typed.app_id || "", fb_config: fb || typed.fb_config_id || "", wa_config: wa || typed.config_id || "",
    set: { app_id: !!app, fb_config: !!fb, wa_config: !!wa }, ready: !!env("META_APP_SECRET") };
}
type Pg = { id: string; name: string; access_token: string; ig: string | null; ig_name: string | null };
async function fbFinish(p: Pg) {
  await admin.rpc("meta_link_set", { p: { page_id: p.id, page_name: p.name, token: p.access_token, ig_id: p.ig ?? "", ig_name: p.ig_name ?? "", pages: null } });
  await loadLink(); page = null;
  // messages from the page and its Instagram come to the app (best effort: posting works without it)
  const warn: string[] = [];
  try { await call(`${p.id}/subscribed_apps`, { subscribed_fields: "messages,message_echoes,standby" }, "POST", p.access_token); } catch (e) { warn.push("Facebook messages: " + (e as Error).message); }
  const appId = env("META_APP_ID") || (await metaCfg()).app_id, secret = env("META_APP_SECRET");
  if (appId && secret) {
    const { data: v } = await admin.rpc("meta_verify_value");
    for (const [object, fields] of [["page", "messages,message_echoes,standby"], ["instagram", "messages,standby"]]) {
      try { await call(`${appId}/subscriptions`, { object, callback_url: Deno.env.get("SUPABASE_URL") + "/functions/v1/meta", verify_token: String(v ?? ""), fields, include_values: "true" }, "POST", `${appId}|${secret}`); }
      catch (e) { warn.push(object + ": " + (e as Error).message); }
    }
  }
  return { ok: true, page: p.name, instagram: p.ig_name, warn };
}
async function fbConnect(b: Record<string, unknown>) {
  const cfg = await metaCfg(), secret = env("META_APP_SECRET");
  if (!secret || !cfg.app_id) return { error: "The Meta app is not set up yet (META_APP_SECRET and the app ID). Email us and we connect it for you." };
  const code = String(b.code ?? ""); if (!code) return { error: "No sign in code from Meta. Try again." };
  const t = await fetch(`${G}/oauth/access_token?` + new URLSearchParams({ client_id: cfg.app_id, client_secret: secret, code }));
  const tj = await t.json().catch(() => ({}));
  if (!tj.access_token) return { error: "Meta did not give access: " + (tj?.error?.message ?? t.status) };
  // a long lived sign in, so the page tokens from it do not run out
  let user = tj.access_token as string;
  try { const l = await fetch(`${G}/oauth/access_token?` + new URLSearchParams({ grant_type: "fb_exchange_token", client_id: cfg.app_id, client_secret: secret, fb_exchange_token: user })).then((r) => r.json());
    if (l.access_token) user = l.access_token; } catch { /* the short one still works for now */ }
  const acc = await call("me/accounts", { fields: "id,name,access_token,instagram_business_account{id,username}", limit: "100" }, "GET", user);
  const pages: Pg[] = ((acc.data ?? []) as { id: string; name: string; access_token: string; instagram_business_account?: { id: string; username: string } }[])
    .filter((x) => x.access_token).map((x) => ({ id: x.id, name: x.name, access_token: x.access_token, ig: x.instagram_business_account?.id ?? null, ig_name: x.instagram_business_account?.username ?? null }));
  if (!pages.length) return { error: "Meta did not share any Facebook page. Try again and tick your page (and its Instagram) in the Meta window." };
  if (pages.length === 1) return await fbFinish(pages[0]);
  await admin.rpc("meta_link_set", { p: { pages } });
  return { choose: pages.map((x) => ({ id: x.id, name: x.name, instagram: x.ig_name })) };
}
async function manager(req: Request) {
  const tok = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!tok) return false;
  const { data } = await admin.auth.getUser(tok);
  if (!data?.user) return false;
  const { data: s } = await admin.from("staff").select("role").eq("user_id", data.user.id).eq("active", true).maybeSingle();
  return s?.role === "manager";
}

// ---------- AI replies ----------
const AI_KEY = () => env("ANTHROPIC_API_KEY");
const MODEL = "claude-sonnet-5-5";
const DAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
const tidy = (s: string) => String(s ?? "").replace(/\s*[—–]\s*/g, ", ").replace(/\s&\s/g, " and ").trim();
const siteCache: Record<string, string> = {};
async function siteFacts(url: string) {
  if (!url) return "";
  if (siteCache[url] !== undefined) return siteCache[url];
  let t = "";
  try { const r = await fetch(url.replace(/\/+$/, "") + "/llms.txt"); if (r.ok) t = (await r.text()).slice(0, 15000); } catch { /* no site facts */ }
  siteCache[url] = t; return t;
}
type Ctx = { go: boolean; why: string; kind: string; social_id: string; name: string | null; notes: string; site: string; business: string; stay: string;
  messages: { in: boolean; ai: boolean; body: string; at: string }[];
  packages: { name: string; thb: number; local_thb: number | null; thai_thb: number | null; who: string; days: number | null; visits: number | null; covers: string[] | null; notes: string }[];
  classes: { day: number; from: string; to: string | null; title: string; off: string | null }[] };
async function aiReply(chatId: string, trigger: string) {
  try {
    if (!AI_KEY()) return;
    let { data: c } = await admin.rpc("ai_reply_ctx", { p_chat: chatId }) as { data: Ctx | null };
    if (!c?.go) return;
    // wait a moment: people often send two or three messages in a row, and a staff member may already be typing
    await new Promise((r) => setTimeout(r, 12000));
    ({ data: c } = await admin.rpc("ai_reply_ctx", { p_chat: chatId }) as { data: Ctx | null });
    if (!c?.go || !c.messages.length || !c.messages[c.messages.length - 1].in) return;
    const { data: last } = await admin.from("chat_messages").select("ext_id").eq("chat_id", chatId).eq("from_visitor", true).order("created_at", { ascending: false }).limit(1).maybeSingle();
    if (last?.ext_id && last.ext_id !== trigger) return; // a newer message started its own reply
    const slot = await admin.rpc("ai_usage_take", { p_fn: "ai_reply" });
    if (slot.error || !slot.data) return;
    const price = (p: Ctx["packages"][number]) => `${p.name}: ${p.thb} THB` + (p.local_thb ? `, local residents ${p.local_thb} THB` : "") + (p.thai_thb ? `, Thai customers ${p.thai_thb} THB` : "")
      + (p.who && p.who !== "all" ? ` (only for ${p.who === "thai" ? "Thai customers" : "local residents and Thai customers"})` : "")
      + (p.days ? `, valid ${p.days} days` : "") + (p.visits ? `, ${p.visits} visits` : "") + (p.notes ? `. ${p.notes.replace(/\s+/g, " ")}` : "");
    const week = DAYS.map((d, i) => { const k = c!.classes.filter((x) => x.day === i); return k.length ? `${d}: ` + k.map((x) => `${x.from}${x.to ? "-" + x.to : ""} ${x.title}${x.off ? " (paused " + x.off + ")" : ""}`).join(", ") : `${d}: no classes`; }).join("\n");
    const site = await siteFacts(c.site);
    const where = c.kind === "wa" ? "WhatsApp" : c.kind === "ig" ? "Instagram" : "Facebook Messenger";
    const now = new Date(Date.now() + 7 * 3600e3);
    const system = [
      `You answer customer messages on ${where} for ${c.business}${c.stay && c.stay !== c.business ? " (and " + c.stay + ")" : ""}, as the team's assistant. Today is ${DAYS[(now.getUTCDay() + 6) % 7]} ${now.toISOString().slice(0, 10)}, time ${now.toISOString().slice(11, 16)} (Thailand).`,
      "How to answer:",
      "- Reply in the language the customer writes in. Short and friendly, like a helpful person at the front desk on a phone. A few short lines at most.",
      "- Use only the facts below. Never invent prices, times, availability, discounts or promises. If the facts do not answer it, say you will ask the team and someone will reply soon.",
      "- Hand over to the team (handoff true) for: bookings that need a time or a room confirmed, changes, cancellations, refunds, payments, complaints, injuries or health, anything personal, or when the customer asks for a person.",
      "- Never use a long dash and never the & sign. No hashtags. At most one emoji.",
      "- Do not say you are an AI unless they ask. If they ask, say you are the team's assistant and a person can take over.",
      `Reply with JSON only: {"reply":"the message to send","handoff":true or false}`,
      "",
      "FACTS",
      c.notes ? "From the owner:\n" + c.notes : "",
      "Prices (THB):\n" + c.packages.map(price).join("\n"),
      "Weekly class timetable:\n" + week,
      site ? "From the website:\n" + site : "",
    ].filter((x) => x !== "").join("\n");
    // the conversation as turns: the customer is the user, the team and earlier AI replies are the assistant
    const turns: { role: string; content: string }[] = [];
    for (const m of c.messages) {
      const role = m.in ? "user" : "assistant";
      if (turns.length && turns[turns.length - 1].role === role) turns[turns.length - 1].content += "\n" + m.body;
      else turns.push({ role, content: m.body });
    }
    while (turns.length && turns[0].role !== "user") turns.shift();
    if (!turns.length) return;
    const r = await fetch("https://api.anthropic.com/v1/messages", { method: "POST", headers: { "x-api-key": AI_KEY(), "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({ model: MODEL, max_tokens: 700, system, messages: turns }) });
    const j = await r.json().catch(() => ({}));
    await admin.from("ai_usage").update({ in_tokens: j?.usage?.input_tokens ?? null, out_tokens: j?.usage?.output_tokens ?? null, ok: r.ok }).eq("id", slot.data);
    if (!r.ok) return;
    const out = String((j.content ?? []).filter((x: { type: string }) => x.type === "text").map((x: { text: string }) => x.text).join(""));
    let reply = "", handoff = false;
    try { const o = JSON.parse(out.slice(out.indexOf("{"), out.lastIndexOf("}") + 1)); reply = tidy(String(o.reply ?? "")); handoff = !!o.handoff; } catch { reply = tidy(out); }
    if (!reply) return;
    // one last check: a staff member may have answered while the AI was writing
    const { data: again } = await admin.rpc("ai_reply_ctx", { p_chat: chatId }) as { data: Ctx | null };
    if (!again?.go) return;
    let ext: string | null = null, err: string | null = null;
    const { data: ch } = await admin.from("chats").select("last_in_at").eq("id", chatId).maybeSingle();
    try { ext = await sendTo(c.kind, c.social_id, ch?.last_in_at ?? null, reply); } catch (e) { err = (e as Error).message; }
    await admin.rpc("ai_reply_save_msg", { p_chat: chatId, p_body: reply, p_ext: ext ?? "", p_error: err });
    if (handoff || err) await notify(`${where}: ${c.name || "a customer"} needs a person`, err ? "The AI reply was not delivered." : "The AI answered and said the team will reply.", chatId);
  } catch (e) { console.error("ai reply", (e as Error).message); }
}

// ---------- outgoing ----------
async function send(id: string) {
  const { data: o } = await admin.rpc("meta_out", { p_id: id });
  if (!o || o.status !== "sending") return { skipped: true };
  let err: string | null = null, mid: string | null = null;
  try { mid = await sendTo(o.kind, o.social_id, o.last_in_at ?? null, o.body); }
  catch (e) { err = (e as Error).message; }
  await admin.from("chat_messages").update(err ? { send_status: "failed", send_error: err.slice(0, 300) } : { send_status: "sent", ext_id: mid, send_error: null }).eq("id", id);
  return { ok: !err, error: err };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
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
    // answer Meta at once; AI replies finish in the background
    const rt = (globalThis as any).EdgeRuntime; // deno-lint-ignore no-explicit-any
    const later = (p: Promise<unknown>) => { if (rt?.waitUntil) rt.waitUntil(p); };
    try { await loadLink(); } catch { /* the secret still works */ }
    try { const j = JSON.parse(raw); if (j.object === "whatsapp_business_account") await incomingWa(j, later); else await incoming(j, later); }
    catch (e) { console.error("webhook", (e as Error).message); }
    return new Response("ok", { status: 200 });
  }
  const b = (() => { try { return JSON.parse(raw); } catch { return {}; } })();
  // from the app: a manager connects or checks WhatsApp
  if (typeof b.mode === "string" && /^(wa|fb|meta)_/.test(b.mode)) {
    if (!(await manager(req))) return json({ error: "Only a manager can do this." }, 401);
    try {
      await loadLink();
      if (b.mode === "meta_cfg") return json(await metaCfg());
      if (b.mode === "fb_connect") return json(await fbConnect(b));
      if (b.mode === "fb_pick") {
        const p = (link.pages ?? []).find((x) => x.id === String(b.page_id ?? ""));
        if (!p) return json({ error: "That page is no longer in the list. Tap Connect again." });
        return json(await fbFinish({ id: p.id, name: p.name, access_token: p.access_token, ig: p.ig ?? null, ig_name: p.ig_name ?? null }));
      }
      if (b.mode === "fb_check") {
        if (!pageToken()) return json({ connected: false, in_app: false });
        const p = await thePage();
        return json({ connected: true, in_app: !!link.page_id, page: p.name, instagram: p.ig_name });
      }
      if (b.mode === "fb_disconnect") { await admin.rpc("meta_link_set", { p: { page_id: "", page_name: "", token: "", ig_id: "", ig_name: "", pages: null } }); await loadLink(); page = null; return json({ ok: true, still: !!env("META_PAGE_TOKEN") }); }
      if (b.mode === "wa_connect") return json(await waConnect(b));
      if (b.mode === "wa_manual") {
        const phone = String(b.phone_id ?? "").trim(), waba = String(b.waba_id ?? "").trim();
        if (!/^\d{6,}$/.test(phone)) return json({ error: "The phone number ID is the long number in Meta, WhatsApp, API setup." });
        const tok = env("WA_TOKEN") || pageToken();
        const n = await call(phone, { fields: "display_phone_number,verified_name" }, "GET", tok);
        if (/^\d{6,}$/.test(waba)) { try { await call(`${waba}/subscribed_apps`, {}, "POST", tok); } catch (e) { return json({ error: "Could not switch on messages for that account: " + (e as Error).message }); } }
        await admin.rpc("wa_set", { p: { phone_id: phone, waba_id: waba, number: n.display_phone_number, name: n.verified_name, token: "", coexist: false } });
        wa = null;
        return json({ ok: true, number: n.display_phone_number, name: n.verified_name, subs: await waSubs() });
      }
      if (b.mode === "wa_check") {
        const l = await waLink(true);
        if (!l.phone_id) return json({ connected: false });
        const n = await call(l.phone_id, { fields: "display_phone_number,verified_name,quality_rating,platform_type,is_on_biz_app,status" }, "GET", waTok(l));
        return json({ connected: true, number: n.display_phone_number, name: n.verified_name, quality: n.quality_rating, status: n.status, both: !!n.is_on_biz_app });
      }
      if (b.mode === "wa_disconnect") { await admin.rpc("wa_set", { p: { phone_id: "", waba_id: "", number: "", name: "", token: "", coexist: false } }); wa = null; return json({ ok: true }); }
      return json({ error: "Unknown request." }, 400);
    } catch (e) { return json({ error: (e as Error).message }); }
  }
  const { data: ok } = await admin.rpc("sync_token_ok", { p_token: req.headers.get("x-sync-token") ?? "" });
  if (ok !== true) return json({ error: "Not allowed." }, 401);
  try {
    await loadLink();
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
        for (const [object, fields] of [["page", "messages,message_echoes,standby"], ["instagram", "messages,standby"], ["whatsapp_business_account", "messages,smb_message_echoes,history,smb_app_state_sync"]]) {
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
