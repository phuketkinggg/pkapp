// One-off: copies the blog posts from the old WordPress site (phuketking.com) into the app's blog.
// ?mode=list shows what is there. ?mode=import&page=N copies 4 posts per call: text turned into the blog's simple format,
// cover and photos copied into the app's storage. Posts already copied are skipped, so edits made in the app are never overwritten.
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const WP = "https://www.phuketking.com/wp-json/wp/v2/posts";
const STORE = Deno.env.get("SUPABASE_URL") + "/storage/v1/object/public/promos/";
const json = (b: unknown) => new Response(JSON.stringify(b), { headers: { "Content-Type": "application/json" } });

const ENT: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ", hellip: "...", rsquo: "'", lsquo: "'", rdquo: '"', ldquo: '"', ndash: "-", mdash: ", ", "#8217": "'", "#8216": "'", "#8220": '"', "#8221": '"', "#8211": "-", "#8212": ", ", "#038": "&", "#8230": "...", "#039": "'" };
function decode(s: string) {
  return s.replace(/&(#?[a-z0-9]+);/gi, (m, k) => ENT[k.toLowerCase()] ?? (k[0] === "#" ? String.fromCharCode(parseInt(k[1] === "x" ? "0" + k.slice(1) : k.slice(1))) : m));
}
function inline(s: string) {
  return decode(s
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<(strong|b)\b[^>]*>([\s\S]*?)<\/\1>/gi, (_m, _t, x) => x.trim() ? "**" + x.trim() + "**" : "")
    .replace(/<(em|i)\b[^>]*>([\s\S]*?)<\/\1>/gi, (_m, _t, x) => x.trim() ? "*" + x.trim() + "*" : "")
    .replace(/<a\b[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/gi, (_m, h, x) => { const t = x.replace(/<[^>]+>/g, "").trim(); return t ? "[" + t + "](" + h + ")" : ""; })
    .replace(/<[^>]+>/g, ""))
    .replace(/[ \t]+/g, " ").replace(/ *\n */g, "\n").trim();
}
// WordPress HTML to the blog's simple format: ## headings, paragraphs, - lists, **bold**, *italic*, [links](url), ![photos](url)
function toSimple(html: string, imgs: string[]) {
  let s = html.replace(/<!--[\s\S]*?-->/g, "").replace(/<(script|style|iframe|form)\b[\s\S]*?<\/\1>/gi, "");
  s = s.replace(/<img\b[^>]*>/gi, (m) => { const src = (m.match(/\ssrc="([^"]+)"/i) || [])[1]; const alt = (m.match(/\salt="([^"]*)"/i) || [])[1] || ""; if (!src) return ""; imgs.push(src); return "\n\n![" + decode(alt) + "](" + src + ")\n\n"; });
  s = s.replace(/<h1\b[^>]*>([\s\S]*?)<\/h1>/gi, (_m, x) => "\n\n## " + inline(x) + "\n\n")
       .replace(/<h2\b[^>]*>([\s\S]*?)<\/h2>/gi, (_m, x) => "\n\n## " + inline(x) + "\n\n")
       .replace(/<h[3-6]\b[^>]*>([\s\S]*?)<\/h[3-6]>/gi, (_m, x) => "\n\n### " + inline(x) + "\n\n");
  s = s.replace(/<ol\b[^>]*>([\s\S]*?)<\/ol>/gi, (_m, x) => { let n = 0; return "\n\n" + x.replace(/<li\b[^>]*>([\s\S]*?)<\/li>/gi, (_q: string, y: string) => (++n) + ". " + inline(y).replace(/\n/g, " ") + "\n").replace(/<[^>]+>/g, "") + "\n"; });
  s = s.replace(/<ul\b[^>]*>([\s\S]*?)<\/ul>/gi, (_m, x) => "\n\n" + x.replace(/<li\b[^>]*>([\s\S]*?)<\/li>/gi, (_q: string, y: string) => "- " + inline(y).replace(/\n/g, " ") + "\n").replace(/<[^>]+>/g, "") + "\n");
  s = s.replace(/<blockquote\b[^>]*>([\s\S]*?)<\/blockquote>/gi, (_m, x) => "\n\n> " + inline(x).replace(/\n+/g, " ") + "\n\n");
  s = s.replace(/<figcaption\b[^>]*>([\s\S]*?)<\/figcaption>/gi, (_m, x) => "\n\n*" + inline(x) + "*\n\n");
  s = s.replace(/<\/?(p|div|figure|section|article|table|tr|tbody|thead)\b[^>]*>/gi, "\n\n").replace(/<\/?(td|th)\b[^>]*>/gi, " ");
  const blocks = s.split(/\n{2,}/).map((b) => { const t = b.trim(); if (!t) return ""; if (/^(##|###|- |\d+\. |> |!\[)/.test(t)) return t; return inline(t); }).filter(Boolean);
  return blocks.join("\n\n").replace(/\n{3,}/g, "\n\n").trim();
}
async function copyImage(url: string, path: string): Promise<string | null> {
  try {
    if (!/^https:\/\/(www\.)?phuketking\.com\/wp-content\/uploads\//.test(url)) return null;
    const r = await fetch(url); if (!r.ok) return null;
    const type = r.headers.get("content-type") || ""; if (!/^image\/(jpeg|png|webp|gif)/.test(type)) return null;
    const body = new Uint8Array(await r.arrayBuffer()); if (body.length > 5_000_000) return null;
    const up = await admin.storage.from("promos").upload(path, body, { contentType: type.split(";")[0], upsert: true });
    return up.error ? null : STORE + path;
  } catch { return null; }
}
function slugify(s: string) { return s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 110) || "post"; }

Deno.serve(async (req) => {
  const u = new URL(req.url), mode = u.searchParams.get("mode") || "list", page = Math.max(1, Math.min(50, Number(u.searchParams.get("page")) || 1));
  try {
    if (mode === "list") {
      const r = await fetch(WP + "?per_page=100&_fields=id,slug,date,title,link&status=publish");
      const list = await r.json();
      return json({ total: r.headers.get("x-wp-total"), posts: (list || []).map((p: any) => ({ id: p.id, slug: p.slug, date: p.date, title: decode(p.title?.rendered || ""), link: p.link })) });
    }
    const r = await fetch(WP + "?per_page=4&page=" + page + "&_embed=wp:featuredmedia&status=publish");
    if (!r.ok) return json({ done: true, status: r.status });
    const posts = await r.json(); const out: unknown[] = [];
    for (const p of posts) {
      const { data: have } = await admin.from("blog_posts").select("id").eq("wp_id", p.id).maybeSingle();
      if (have) { out.push({ id: p.id, skipped: true }); continue; }
      const slug = slugify(p.slug || p.title?.rendered || String(p.id));
      const imgs: string[] = [];
      let body = toSimple(p.content?.rendered || "", imgs);
      let i = 0;
      for (const src of [...new Set(imgs)].slice(0, 12)) {
        const ext = (src.split("?")[0].split(".").pop() || "jpg").toLowerCase().replace("jpeg", "jpg");
        const nu = await copyImage(src, `blog/${slug}/img-${++i}.${ext}`);
        body = body.split("](" + src + ")").join("](" + (nu || "") + ")");
      }
      body = body.replace(/!\[[^\]]*\]\(\)\n*/g, "");
      const fm = p._embedded?.["wp:featuredmedia"]?.[0];
      const fsrc = fm?.media_details?.sizes?.large?.source_url || fm?.media_details?.sizes?.medium_large?.source_url || fm?.source_url;
      const cover = fsrc ? await copyImage(fsrc, `blog/${slug}/cover.${(fsrc.split(".").pop() || "jpg").toLowerCase().replace("jpeg", "jpg")}`) : null;
      const excerpt = inline(p.excerpt?.rendered || "").replace(/\s*\[(&hellip;|\.\.\.)\]\s*$/, "...").slice(0, 380);
      const ins = await admin.from("blog_posts").insert({ slug, title: decode(p.title?.rendered || "Untitled").slice(0, 200), excerpt: excerpt || null, body: body.slice(0, 99000),
        cover_url: cover, status: "published", published_at: String(p.date || "").slice(0, 10) || null, source: "wordpress", wp_id: p.id });
      out.push({ id: p.id, slug, ok: !ins.error, err: ins.error?.message, imgs: imgs.length, cover: !!cover });
    }
    return json({ page, n: posts.length, out });
  } catch (e) { return json({ error: (e as Error).message }); }
});
