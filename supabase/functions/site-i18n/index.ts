// Website languages (feature web_langs): translates the website's English texts with AI and keeps them in public.site_i18n.
// GET  ?lang=ru                      the translations for one language, {english: translation} (public: it is the text of public web pages)
// POST {lang, sha, offset, count}    with the sync token (x-sync-token): translates texts that are not translated yet. It answers at once and works in the background.
// The texts come from pk/lang/strings.json in the repo at that commit (made by tools/site_strings.py). tools/site_lang_pull.py brings them into the website build.
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const KEY = () => (Deno.env.get("ANTHROPIC_API_KEY") ?? "").trim();
const MODEL = "claude-sonnet-5-5";
const NAMES: Record<string, string> = { ru: "Russian", zh: "Simplified Chinese", fr: "French", de: "German", es: "Spanish", ja: "Japanese", nl: "Dutch", it: "Italian", ko: "Korean" };
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "content-type, x-sync-token", "Access-Control-Allow-Methods": "GET, POST, OPTIONS" };
const json = (b: unknown, s = 200, cache = false) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json", ...(cache ? { "Cache-Control": "public, max-age=300" } : {}) } });

async function translate(lang: string, list: string[]): Promise<string[] | null> {
  const name = NAMES[lang];
  const prompt = `You translate the website of Phuket King Muay Thai, a technique first Muay Thai gym in Kathu, Phuket, Thailand, with its own small lakeside resort (Pangea Resort), a healthy cafe and a recovery spa (sauna, steam room, ice bath). Visitors read it to choose a gym, see prices and the timetable, and book training, rooms and the Thai DTV visa through Muay Thai.
Translate each English text below into natural, warm, persuasive ${name}, the way a good local website for travellers would say it. Headings stay short and punchy. Buttons stay short.
${lang === "ru" ? "Use the polite \"вы\" (lowercase). Muay Thai is \"тайский бокс\" in running text and \"Муай Тай\" in names. " : ""}${lang === "zh" ? "Muay Thai is 泰拳. " : ""}${lang === "de" ? "Use \"du\" for a friendly sports tone. " : ""}${lang === "fr" ? "Use \"vous\". " : ""}Keep these exactly as they are: Phuket King, Phuket King Muay Thai, Pangea, Pangea Resort, Pangea Cafe, Kathu, Phuket, THB, DTV, WhatsApp, PromptPay, Stripe, Google, Instagram, Facebook, YouTube, names of people (Coach Tom, Kru Pot, Nikolay and so on), and anything in *stars* keeps its stars around the translated words.
Keep numbers, prices, times and dates as they are. Keep every leading or trailing space and every leading or trailing punctuation mark exactly as in the English (some texts are pieces of longer sentences). Do not add quotes around the text. Never use an em dash.
Answer with only a JSON array of strings, the same length and order as the input array.

${JSON.stringify(list)}`;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const r = await fetch("https://api.anthropic.com/v1/messages", { method: "POST", headers: { "x-api-key": KEY(), "anthropic-version": "2023-06-01", "content-type": "application/json" },
        body: JSON.stringify({ model: MODEL, max_tokens: 16000, messages: [{ role: "user", content: prompt }] }) });
      const j = await r.json();
      if (!r.ok) throw new Error(j?.error?.message ?? String(r.status));
      const t = String(j?.content?.map((c: { text?: string }) => c.text ?? "").join("") ?? "");
      const a = JSON.parse(t.slice(t.indexOf("["), t.lastIndexOf("]") + 1));
      if (Array.isArray(a) && a.length === list.length && a.every((x) => typeof x === "string")) return a;
      throw new Error("wrong length");
    } catch (e) { console.error("translate", lang, attempt, (e as Error).message); }
  }
  return null;
}

async function work(lang: string, sha: string, offset: number, count: number) {
  const r = await fetch(`https://raw.githubusercontent.com/phuketkinggg/pkapp/${sha}/pk/lang/strings.json`);
  const all = ((await r.json()) as unknown[]).filter((k): k is string => typeof k === "string" && /[A-Za-z]/.test(k));
  const part = all.slice(offset, offset + count);
  const done = new Set<string>();
  for (let i = 0; i < part.length; i += 200) {
    const { data } = await admin.from("site_i18n").select("en").eq("lang", lang).in("en", part.slice(i, i + 200));
    (data ?? []).forEach((x: { en: string }) => done.add(x.en));
  }
  const todo = part.filter((k) => !done.has(k));
  const size = 40, jobs: Promise<void>[] = [];
  for (let i = 0; i < todo.length; i += size) {
    const list = todo.slice(i, i + size);
    jobs.push(translate(lang, list).then(async (out) => {
      if (!out) return;
      const rows = list.map((en, j) => ({ lang, en, tr: out[j].replace(/—/g, ", "), at: new Date().toISOString() })).filter((x) => x.tr.trim());
      const { error } = await admin.from("site_i18n").upsert(rows);
      if (error) console.error("save", error.message);
    }));
  }
  await Promise.all(jobs);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method === "GET") {
    const lang = new URL(req.url).searchParams.get("lang") ?? "";
    if (!NAMES[lang]) return json({ error: "That language is not set up." }, 400);
    const out: Record<string, string> = {};
    for (let from = 0; ; from += 1000) {
      const { data, error } = await admin.from("site_i18n").select("en,tr").eq("lang", lang).order("en").range(from, from + 999);
      if (error) return json({ error: error.message }, 500);
      (data ?? []).forEach((x: { en: string; tr: string }) => { out[x.en] = x.tr; });
      if (!data || data.length < 1000) break;
    }
    return json(out, 200, true);
  }
  if (req.method !== "POST") return json({ error: "Use GET or POST." }, 405);
  const { data: ok } = await admin.rpc("sync_token_ok", { p_token: req.headers.get("x-sync-token") ?? "" });
  if (ok !== true) return json({ error: "Not allowed." }, 401);
  if (!KEY()) return json({ error: "ANTHROPIC_API_KEY is missing in Supabase secrets." });
  const b = await req.json().catch(() => ({}));
  const lang = String(b.lang ?? ""), sha = String(b.sha ?? "");
  if (!NAMES[lang]) return json({ error: "That language is not set up." });
  if (!/^([0-9a-f]{40}|main)$/.test(sha)) return json({ error: "Give the commit." });
  const offset = Math.max(0, Math.round(Number(b.offset) || 0)), count = Math.max(1, Math.min(600, Math.round(Number(b.count) || 300)));
  const job = work(lang, sha, offset, count).catch((e) => console.error("work", (e as Error).message));
  // deno-lint-ignore no-explicit-any
  const rt = (globalThis as any).EdgeRuntime;
  if (rt?.waitUntil) rt.waitUntil(job); else await job;
  return json({ ok: true, started: true, offset, count });
});
