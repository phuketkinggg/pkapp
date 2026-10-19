// Live sitemap for Google: every published blog post, online course and page made in the app, on www.phuketking.com.
// Listed in https://www.phuketking.com/robots.txt next to the main sitemap.
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const SITE = "https://www.phuketking.com";
const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;");
const day = (d: unknown) => (d ? String(d).slice(0, 10) : "");

Deno.serve(async () => {
  const [posts, courses, pages] = await Promise.all([
    admin.from("blog_posts").select("slug,published_at,updated_at").eq("status", "published").order("published_at", { ascending: false }).limit(1000),
    admin.from("courses").select("slug,updated_at").eq("status", "published").limit(500),
    admin.from("site_pages").select("slug,updated_at").eq("status", "published").eq("removed", false).limit(500),
  ]);
  const rows: string[] = [];
  const add = (path: string, last: string, pr: string) => rows.push(`  <url><loc>${esc(SITE + path)}</loc>${last ? `<lastmod>${last}</lastmod>` : ""}<priority>${pr}</priority></url>`);
  for (const p of posts.data ?? []) if (/^[a-z0-9-]+$/.test(p.slug)) add("/post?p=" + p.slug, day((p as { updated_at?: string }).updated_at ?? p.published_at), "0.6");
  for (const c of courses.data ?? []) if (/^[a-z0-9-]+$/.test(c.slug)) add("/course?c=" + c.slug, day(c.updated_at), "0.6");
  for (const g of pages.data ?? []) if (/^[a-z0-9-]+$/.test(g.slug)) add("/page?p=" + g.slug, day(g.updated_at), "0.7");
  const xml = `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${rows.join("\n")}\n</urlset>\n`;
  return new Response(xml, { headers: { "Content-Type": "application/xml; charset=utf-8", "Cache-Control": "public, max-age=3600" } });
});
