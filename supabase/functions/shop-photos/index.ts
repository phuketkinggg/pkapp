// Adds product photos to the shop from picture links: downloads each one, makes it a light 800 px JPEG, stores it in the app
// (promos/shop/) and puts it on the products given. Only products with no photo yet are changed.
// POST {mode:'import', items:[{ids:[product id...], url:'https://...'}]}   x-sync-token   (up to 8 pictures a call)
import { createClient } from "npm:@supabase/supabase-js@2";
import { decode, Image } from "https://deno.land/x/imagescript@1.3.0/mod.ts";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });
const isId = (x: unknown) => typeof x === "string" && /^[0-9a-f-]{36}$/i.test(x);

async function one(url: string, ids: string[]) {
  const r = await fetch(url, { headers: { "User-Agent": "Mozilla/5.0 (compatible; PhuketKingShop/1.0)", Accept: "image/*" }, redirect: "follow" });
  if (!r.ok) return { url, error: `download ${r.status}` };
  const buf = new Uint8Array(await r.arrayBuffer());
  if (buf.length < 2000) return { url, error: "too small" };
  const type = (r.headers.get("content-type") || "").split(";")[0].trim().toLowerCase();
  // already a web picture of a sensible size: keep it as it is (decoding big pictures runs out of memory)
  if (["image/jpeg", "image/png", "image/webp"].includes(type) && buf.length <= 1_500_000) return await save(url, ids, buf, type);
  let img = await decode(buf);
  if (!(img instanceof Image)) return { url, error: "not a still image" };
  // a white square background, the photo fitted inside, so every product tile lines up
  const S = 800, k = Math.min(S / img.width, S / img.height, 1);
  img = img.resize(Math.max(1, Math.round(img.width * k)), Math.max(1, Math.round(img.height * k)));
  const box = new Image(S, S).fill(0xffffffff);
  box.composite(img, Math.round((S - img.width) / 2), Math.round((S - img.height) / 2));
  return await save(url, ids, await box.encodeJPEG(82), "image/jpeg");
}

async function save(url: string, ids: string[], bytes: Uint8Array, type: string) {
  const ext = type === "image/png" ? "png" : type === "image/webp" ? "webp" : "jpg";
  const path = `shop/${Date.now()}-${crypto.randomUUID().slice(0, 8)}.${ext}`;
  const up = await admin.storage.from("promos").upload(path, bytes, { contentType: type, upsert: false });
  if (up.error) return { url, error: up.error.message };
  const pub = admin.storage.from("promos").getPublicUrl(path).data.publicUrl;
  const { data, error } = await admin.from("shop_products").update({ image_url: pub, images: [pub] }).in("id", ids).or("image_url.is.null,image_url.eq.").select("id");
  if (error) return { url, error: error.message };
  return { url, photo: pub, set: (data ?? []).length };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  const { data: tok } = await admin.rpc("sync_token_ok", { p_token: req.headers.get("x-sync-token") ?? "" });
  if (tok !== true) return json({ error: "Not allowed." }, 401);
  const b = await req.json().catch(() => ({}));
  if (b.mode !== "import" || !Array.isArray(b.items)) return json({ error: "Unknown request." }, 400);
  const out = [];
  for (const it of b.items.slice(0, 8)) {
    const ids = (Array.isArray(it?.ids) ? it.ids : []).filter(isId);
    const url = String(it?.url ?? "");
    if (!ids.length || !/^https:\/\//.test(url)) { out.push({ url, error: "bad item" }); continue; }
    try { out.push(await one(url, ids)); } catch (e) { out.push({ url, error: (e as Error).message }); }
  }
  return json({ ok: true, results: out });
});
