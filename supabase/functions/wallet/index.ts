// Member card in Apple Wallet and Google Wallet (feature wallet_card).
// GET ?t=<card token>&k=apple[&g=<gym>]   the signed .pkpass file (Add to Apple Wallet)
// GET ?t=<card token>&k=google[&g=<gym>]  a Save to Google Wallet link (redirect)
// GET ?t=<card token>&k=info[&g=<gym>]    what the card shows, for the card page (card.html)
// POST ?k=push {token}                    the database (x-sync-token): tell the iPhones that saved this card to update it
// /wallet/apple/v1/...                    Apple Wallet web service: iPhones register for updates and fetch the newest card
// Secrets: APPLE_PASS_P12 (base64 .p12) and APPLE_PASS_P12_PASSWORD, or APPLE_PASS_CERT_PEM and APPLE_PASS_KEY_PEM;
// APPLE_PASS_TYPE_ID, APPLE_TEAM_ID; GOOGLE_WALLET_ISSUER_ID and GOOGLE_WALLET_SA (the service account JSON).
import { createClient } from "npm:@supabase/supabase-js@2";
import forge from "npm:node-forge@1.3.1";
import { zipSync, strToU8 } from "npm:fflate@0.8.2";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const SR = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const PASS_TYPE = (Deno.env.get("APPLE_PASS_TYPE_ID") ?? "").trim();
const TEAM = (Deno.env.get("APPLE_TEAM_ID") ?? "").trim();
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-sync-token", "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const isTok = (s: unknown) => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(String(s ?? ""));
const isGym = (s: unknown) => /^[a-z][a-z0-9_]{1,40}$/.test(String(s ?? ""));
function db(gym?: string | null) {
  return createClient(URL_, SR, { auth: { persistSession: false }, ...(gym && isGym(gym) ? { db: { schema: "g_" + gym } } : {}) });
}

type Card = { name: string; token: string; biz: string; on: boolean; theme: { accent?: string; bg?: string }; settings: Record<string, string>;
  region: { tz?: string; cur?: string }; today: string; updated: string;
  package: { name: string; until: string | null; starts: string | null; left: number | null; week: number | null } | null };

async function card(token: string, gym?: string | null): Promise<Card | null> {
  const { data, error } = await db(gym).rpc("card_data", { p_token: token });
  if (error) throw new Error(error.message);
  return data as Card | null;
}

const longDay = (d: string | null) => d ? new Date(d + "T00:00:00Z").toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" }) : "";
function rgb(hex: string | undefined, fb: string) {
  const m = /^#?([0-9a-f]{6})$/i.exec(hex ?? "") ?? /^#?([0-9a-f]{6})$/i.exec(fb)!;
  const n = parseInt(m[1], 16); return { r: n >> 16, g: (n >> 8) & 255, b: n & 255, css: `rgb(${n >> 16}, ${(n >> 8) & 255}, ${n & 255})`, hex: "#" + m[1] };
}
function lines(c: Card) {
  const p = c.package;
  return {
    pkg: p ? p.name : "No active package",
    left: p ? (p.left == null ? (p.week ? `${p.week} a week` : "Unlimited") : String(p.left)) : "-",
    until: p ? (p.until ? longDay(p.until) : "No end date") : "-",
  };
}

// ---------- Apple ----------
// deno-lint-ignore no-explicit-any
let SIGNER: { key: any; cert: any; wwdr: any } | null = null;
async function signer() {
  if (SIGNER) return SIGNER;
  // deno-lint-ignore no-explicit-any
  let key: any = null, cert: any = null;
  const pem = Deno.env.get("APPLE_PASS_CERT_PEM"), kpem = Deno.env.get("APPLE_PASS_KEY_PEM");
  if (pem && kpem) { cert = forge.pki.certificateFromPem(pem); key = forge.pki.privateKeyFromPem(kpem); }
  else {
    const b64 = (Deno.env.get("APPLE_PASS_P12") ?? "").replace(/\s+/g, "");
    if (!b64) throw new Error("Apple Wallet is not set up yet: add the pass certificate in the secrets.");
    const p12 = forge.pkcs12.pkcs12FromAsn1(forge.asn1.fromDer(forge.util.decode64(b64)), Deno.env.get("APPLE_PASS_P12_PASSWORD") ?? "");
    const kb = p12.getBags({ bagType: forge.pki.oids.pkcs8ShroudedKeyBag })[forge.pki.oids.pkcs8ShroudedKeyBag] ?? [];
    const kb2 = p12.getBags({ bagType: forge.pki.oids.keyBag })[forge.pki.oids.keyBag] ?? [];
    key = (kb[0] ?? kb2[0])?.key ?? null;
    const cb = p12.getBags({ bagType: forge.pki.oids.certBag })[forge.pki.oids.certBag] ?? [];
    cert = (cb.find((b: any) => /Pass Type ID/i.test(String(b.cert?.subject.getField("CN")?.value ?? ""))) ?? cb[0])?.cert ?? null;
  }
  if (!key || !cert) throw new Error("The pass certificate could not be read. Check the password, or add it as PEM.");
  const w = await fetch("https://www.apple.com/certificateauthority/AppleWWDRCAG4.cer");
  if (!w.ok) throw new Error("Could not load the Apple WWDR certificate.");
  const der = new Uint8Array(await w.arrayBuffer()); let s = ""; der.forEach((b) => s += String.fromCharCode(b));
  const wwdr = forge.pki.certificateFromAsn1(forge.asn1.fromDer(s));
  SIGNER = { key, cert, wwdr };
  return SIGNER;
}
async function img(url: string | undefined): Promise<Uint8Array | null> {
  if (!url || !/^https:\/\//.test(url)) return null;
  try { const r = await fetch(url); if (!r.ok) return null; const b = new Uint8Array(await r.arrayBuffer()); return b[0] === 0x89 && b[1] === 0x50 ? b : null; } catch { return null; }
}
function sha1(b: Uint8Array) { const md = forge.md.sha1.create(); let s = ""; b.forEach((x) => s += String.fromCharCode(x)); md.update(s); return md.digest().toHex(); }

async function pkpass(c: Card, gym: string | null) {
  if (!PASS_TYPE || !TEAM) throw new Error("Apple Wallet is not set up yet: add APPLE_PASS_TYPE_ID and APPLE_TEAM_ID in the secrets.");
  const s = c.settings || {}, l = lines(c);
  const bg = rgb(s.bg || c.theme.bg, "#111111"), ac = rgb(s.accent || c.theme.accent, "#D7263D");
  const light = (bg.r * 299 + bg.g * 587 + bg.b * 114) / 1000 > 150;
  const pass = {
    formatVersion: 1, passTypeIdentifier: PASS_TYPE, teamIdentifier: TEAM, serialNumber: c.token,
    organizationName: c.biz, description: `${c.biz} member card`, logoText: s.logo_text ?? c.biz,
    backgroundColor: bg.css, foregroundColor: light ? "rgb(17, 17, 17)" : "rgb(255, 255, 255)", labelColor: ac.css,
    webServiceURL: `${URL_}/functions/v1/wallet/apple${gym ? "/g/" + gym : ""}`, authenticationToken: c.token,
    sharingProhibited: true,
    barcodes: [{ format: "PKBarcodeFormatQR", message: "PKCARD:" + c.token, messageEncoding: "iso-8859-1", altText: c.name }],
    barcode: { format: "PKBarcodeFormatQR", message: "PKCARD:" + c.token, messageEncoding: "iso-8859-1", altText: c.name },
    ...(s.lat && s.lng ? { locations: [{ latitude: Number(s.lat), longitude: Number(s.lng), relevantText: s.near_text || `Welcome to ${c.biz}. Show this card at the desk.` }] } : {}),
    storeCard: {
      headerFields: [{ key: "left", label: c.package?.left == null ? "CLASSES" : "CLASSES LEFT", value: l.left, changeMessage: "Classes left: %@" }],
      primaryFields: [{ key: "pkg", label: "MEMBERSHIP", value: l.pkg, changeMessage: "Your membership: %@" }],
      secondaryFields: [{ key: "name", label: "MEMBER", value: c.name }, { key: "until", label: "VALID UNTIL", value: l.until, changeMessage: "Valid until %@" }],
      backFields: [
        { key: "how", label: "How to use", value: "Show this card at the front desk and we scan it to check you in. It updates by itself when you buy a package or use a class." },
        ...(s.app ? [{ key: "app", label: "App", value: s.app }] : []),
        ...(s.phone ? [{ key: "phone", label: "Phone", value: s.phone }] : []),
        ...(s.address ? [{ key: "addr", label: "Address", value: s.address }] : []),
      ],
    },
  };
  const files: Record<string, Uint8Array> = { "pass.json": strToU8(JSON.stringify(pass)) };
  const icon = await img(s.icon), logo = await img(s.logo || s.icon);
  if (icon) { files["icon.png"] = icon; files["icon@2x.png"] = icon; } else throw new Error("Add a PNG icon for the card in Settings (wallet_card icon).");
  if (logo) { files["logo.png"] = logo; files["logo@2x.png"] = logo; }
  const manifest: Record<string, string> = {}; for (const [k, v] of Object.entries(files)) manifest[k] = sha1(v);
  const ms = JSON.stringify(manifest); files["manifest.json"] = strToU8(ms);
  const sg = await signer();
  const p7 = forge.pkcs7.createSignedData();
  p7.content = forge.util.createBuffer(ms, "utf8");
  p7.addCertificate(sg.cert); p7.addCertificate(sg.wwdr);
  p7.addSigner({ key: sg.key, certificate: sg.cert, digestAlgorithm: forge.pki.oids.sha256,
    authenticatedAttributes: [{ type: forge.pki.oids.contentType, value: forge.pki.oids.data }, { type: forge.pki.oids.messageDigest }, { type: forge.pki.oids.signingTime, value: new Date() as unknown as string }] });
  p7.sign({ detached: true });
  const sig = forge.asn1.toDer(p7.toAsn1()).getBytes(); const sb = new Uint8Array(sig.length); for (let i = 0; i < sig.length; i++) sb[i] = sig.charCodeAt(i);
  files["signature"] = sb;
  return zipSync(files, { level: 0 });
}
function passResponse(z: Uint8Array, c: Card) {
  return new Response(z, { headers: { ...cors, "Content-Type": "application/vnd.apple.pkpass", "Content-Disposition": `attachment; filename="member-card.pkpass"`,
    "Last-Modified": new Date(c.updated).toUTCString(), "Cache-Control": "no-store" } });
}

// tell the iPhones that saved a card to fetch it again (APNs, certificate sign in)
async function push(token: string, gym: string | null) {
  const { data: devs } = await db(gym).from("wallet_devices").select("push_token").eq("card_token", token);
  if (!devs?.length) return { sent: 0 };
  const sg = await signer();
  // deno-lint-ignore no-explicit-any
  const client = (Deno as any).createHttpClient({ cert: forge.pki.certificateToPem(sg.cert), key: forge.pki.privateKeyToPem(sg.key), http2: true, http1: false });
  let sent = 0; const errors: string[] = [];
  for (const d of devs) {
    try {
      const r = await fetch(`https://api.push.apple.com/3/device/${d.push_token}`, { method: "POST", headers: { "apns-topic": PASS_TYPE, "apns-push-type": "background", "apns-priority": "5" }, body: "{}", client } as RequestInit);
      if (r.ok) sent++; else { errors.push(String(r.status)); if (r.status === 410) await db(gym).from("wallet_devices").delete().eq("push_token", d.push_token); }
    } catch (e) { errors.push(String((e as Error).message ?? e)); }
  }
  return { sent, errors };
}

// ---------- Google ----------
function b64url(b: Uint8Array | string) {
  const bytes = typeof b === "string" ? new TextEncoder().encode(b) : b; let s = ""; bytes.forEach((x) => s += String.fromCharCode(x));
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
async function googleLink(c: Card, gym: string | null) {
  const issuer = (Deno.env.get("GOOGLE_WALLET_ISSUER_ID") ?? "").trim(); const raw = Deno.env.get("GOOGLE_WALLET_SA") ?? "";
  if (!issuer || !raw) throw new Error("Google Wallet is not set up yet: add GOOGLE_WALLET_ISSUER_ID and GOOGLE_WALLET_SA in the secrets.");
  const sa = JSON.parse(raw); const s = c.settings || {}, l = lines(c);
  const ref = new URL(URL_).hostname.split(".")[0] + (gym ? "_" + gym : "");
  const classId = `${issuer}.${ref}_member`, objId = `${issuer}.${ref}_${c.token.replace(/-/g, "")}`;
  const bg = rgb(s.bg || c.theme.bg, "#111111");
  const t = (v: string) => ({ defaultValue: { language: "en", value: v } });
  const payload = {
    iss: sa.client_email, aud: "google", typ: "savetowallet", iat: Math.floor(Date.now() / 1000), origins: [],
    payload: {
      genericClasses: [{ id: classId }],
      genericObjects: [{
        id: objId, classId, state: "ACTIVE", cardTitle: t(c.biz), header: t(c.name), subheader: t("Member"),
        hexBackgroundColor: bg.hex, ...(s.icon ? { logo: { sourceUri: { uri: s.icon } } } : {}),
        barcode: { type: "QR_CODE", value: "PKCARD:" + c.token, alternateText: c.name },
        textModulesData: [{ id: "pkg", header: "Membership", body: l.pkg }, { id: "left", header: "Classes left", body: l.left }, { id: "until", header: "Valid until", body: l.until }],
      }],
    },
  };
  const der = Uint8Array.from(atob(String(sa.private_key).replace(/-----[^-]+-----/g, "").replace(/\s+/g, "")), (ch) => ch.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const head = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" })), body = b64url(JSON.stringify(payload));
  const sig = new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(head + "." + body)));
  return "https://pay.google.com/gp/v/save/" + head + "." + body + "." + b64url(sig);
}

// ---------- Apple Wallet web service ----------
async function appleService(req: Request, parts: string[]) {
  // parts after "apple": [g, <gym>,] v1, ...
  let gym: string | null = null;
  if (parts[0] === "g" && isGym(parts[1])) { gym = parts[1]; parts = parts.slice(2); }
  if (parts[0] !== "v1") return new Response(null, { status: 404 });
  const auth = (req.headers.get("authorization") ?? "").replace(/^ApplePass\s+/i, "").trim();
  if (parts[1] === "log") return new Response(null, { status: 200 });
  if (parts[1] === "devices" && parts[3] === "registrations") {
    const device = parts[2], serial = parts[5];
    if (req.method === "GET") {
      const since = new URL(req.url).searchParams.get("passesUpdatedSince");
      const { data: regs } = await db(gym).from("wallet_devices").select("card_token").eq("device_id", device);
      const toks = (regs ?? []).map((r) => r.card_token);
      if (!toks.length) return new Response(null, { status: 204 });
      let q = db(gym).from("wallet_updates").select("card_token,updated_at").in("card_token", toks);
      if (since) q = q.gt("updated_at", new Date(Number(since) * 1000 || since).toISOString());
      const { data: ups } = await q;
      const list = since ? (ups ?? []) : toks.map((t) => ({ card_token: t, updated_at: new Date().toISOString() }));
      if (!list.length) return new Response(null, { status: 204 });
      return json({ serialNumbers: list.map((u) => u.card_token), lastUpdated: String(Math.floor(Date.now() / 1000)) });
    }
    if (!isTok(serial) || auth !== serial) return new Response(null, { status: 401 });
    if (req.method === "POST") {
      const b = await req.json().catch(() => ({}));
      if (!b.pushToken) return new Response(null, { status: 400 });
      const { data: had } = await db(gym).from("wallet_devices").select("device_id").eq("device_id", device).eq("card_token", serial).maybeSingle();
      await db(gym).from("wallet_devices").upsert({ device_id: device, card_token: serial, push_token: b.pushToken });
      await db(gym).from("wallet_updates").upsert({ card_token: serial, updated_at: new Date().toISOString() });
      return new Response(null, { status: had ? 200 : 201 });
    }
    if (req.method === "DELETE") { await db(gym).from("wallet_devices").delete().eq("device_id", device).eq("card_token", serial); return new Response(null, { status: 200 }); }
  }
  if (parts[1] === "passes") {
    const serial = parts[3];
    if (!isTok(serial) || auth !== serial) return new Response(null, { status: 401 });
    const c = await card(serial, gym); if (!c) return new Response(null, { status: 404 });
    const ims = req.headers.get("if-modified-since");
    if (ims && new Date(c.updated).getTime() <= new Date(ims).getTime()) return new Response(null, { status: 304 });
    return passResponse(await pkpass(c, gym), c);
  }
  return new Response(null, { status: 404 });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const u = new URL(req.url);
  const parts = u.pathname.split("/").filter(Boolean); const i = parts.indexOf("apple");
  try {
    if (i >= 0 && parts[i - 1] === "wallet") return await appleService(req, parts.slice(i + 1));
    const k = u.searchParams.get("k"), gym = isGym(u.searchParams.get("g")) ? u.searchParams.get("g") : null;
    if (k === "push" && req.method === "POST") {
      const { data: ok } = await db(gym).rpc("sync_token_ok", { p_token: req.headers.get("x-sync-token") ?? "" });
      if (!ok) return json({ error: "Not allowed." }, 401);
      const b = await req.json().catch(() => ({}));
      if (!isTok(b.token)) return json({ error: "No card." }, 400);
      return json(await push(b.token, gym));
    }
    const t = u.searchParams.get("t");
    if (!isTok(t)) return json({ error: "This card link is not right. Ask the gym for a new one." }, 400);
    const c = await card(t!, gym);
    if (!c || !c.on) return json({ error: "This card was not found." }, 404);
    if (k === "info") { const l = lines(c); return json({ name: c.name, biz: c.biz, theme: c.theme, icon: c.settings?.icon ?? null, pkg: l.pkg, left: l.left, until: l.until, apple: !!(PASS_TYPE && TEAM), google: !!Deno.env.get("GOOGLE_WALLET_ISSUER_ID") }); }
    if (k === "google") return Response.redirect(await googleLink(c, gym), 302);
    return passResponse(await pkpass(c, gym), c);
  } catch (e) {
    return json({ error: String((e as Error).message ?? e) }, 500);
  }
});
