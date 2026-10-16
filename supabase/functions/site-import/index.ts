// One-off: copies the website's starting photos from the old phuketking.com into the app's own storage (promos/site/default/).
// Takes no input and only ever copies this fixed list, so running it again just refreshes the same files.
import { createClient } from "npm:@supabase/supabase-js@2";
import { Image } from "https://deno.land/x/imagescript@1.3.0/mod.ts";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const W = "https://www.phuketking.com/wp-content/uploads/";
const LIST: Record<string, string> = {
  home_hero: "2025/02/DSC0232.webp", home_beginners: "2025/02/DSC0038.webp", home_fitness: "2025/02/IMG_8336.webp",
  home_fighters: "2026/05/IMG_6059-2-scaled.jpg", home_about: "2025/02/DJI_20260502181426_0069_D.webp",
  home_stay: "2026/05/IMG_4883-scaled.jpg", home_location: "2025/02/IMG_8376.webp",
  coach_max: "2025/03/1.png", coach_tom: "2025/03/9.png", coach_mang: "2025/03/6.png", coach_ris: "2025/03/8.png", coach_chi: "2025/03/5.png", coach_phum: "2025/03/2.png",
  prices_hero: "2025/02/DSC0275.webp",
  about_hero: "2025/02/DSC0253.webp", about_why: "2025/02/IMG_5434.webp", about_train: "2025/02/DSC0272.webp", about_recover: "2025/02/IMG_4853.webp",
  about_stay: "2025/02/IMG_5671.webp", about_fuel: "2025/02/PHOTO-2026-03-29-16-17-50-3.webp", about_day: "2025/02/DSC0275.webp",
  about_family: "2025/02/DJI_20260502181426_0069_D.webp", about_strip1: "2025/02/DSC0264.webp", about_strip2: "2025/02/DSC0242.webp",
  about_strip3: "2026/09/DSC0201-scaled.jpg", about_strip4: "2025/02/DSC0094.webp",
  stay_g1: "2026/01/IMG_3103-scaled.jpg", stay_g2: "2025/02/IMG_5671.webp", stay_g3: "2026/01/IMG_3164-2-scaled.jpg",
  stay_g4: "2026/01/IMG_3233-2-scaled.jpg", stay_g5: "2026/05/IMG_4881-scaled.jpg", stay_g6: "2026/05/IMG_4883-scaled.jpg",
};
const TYPE: Record<string, string> = { webp: "image/webp", jpg: "image/jpeg", png: "image/png" };

Deno.serve(async (req) => {
  // ?slot=x copies just one photo (big photos are shrunk one at a time to stay within memory)
  const one = new URL(req.url).searchParams.get("slot");
  const out: Record<string, string> = {};
  for (const [slot, path] of Object.entries(LIST).filter(([k]) => !one || k === one)) {
    try {
      const ext = path.split(".").pop()!.toLowerCase();
      const r = await fetch(W + path);
      if (!r.ok) { out[slot] = "fetch " + r.status; continue; }
      let body = new Uint8Array(await r.arrayBuffer());
      let ext2 = ext;
      // big PNG portraits: shrink to 900px wide JPEG so the page stays fast on phones
      // big JPG photos: shrink to 1800px wide so the gallery stays fast
      if (ext === "jpg" && body.length > 700000) {
        const img = await Image.decode(body);
        if (img.width > 1800) img.resize(1800, Image.RESIZE_AUTO);
        body = await img.encodeJPEG(80);
      }
      if (ext === "png" && body.length > 600000) {
        const img = await Image.decode(body);
        if (img.width > 800) img.resize(800, Image.RESIZE_AUTO);
        body = await img.encodeJPEG(82);
        ext2 = "jpg";
      }
      const up = await admin.storage.from("promos").upload(`site/default/${slot}.${ext2}`, body, { contentType: TYPE[ext2], upsert: true });
      out[slot] = up.error ? "upload " + up.error.message : `ok ${ext2} ${body.length}`;
    } catch (e) { out[slot] = "error " + (e as Error).message; }
  }
  return new Response(JSON.stringify(out), { headers: { "Content-Type": "application/json" } });
});
