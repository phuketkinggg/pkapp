// Translates the app's own words into a language with AI and keeps them in public.i18n_auto (the app loads them with i18n_pack).
// POST {lang:'ru', sha:'<commit>', offset, count} with the sync token (x-sync-token). It answers at once and works in the background.
// Only words that are not translated yet are sent. The words come from i18n/strings.json in the repo at that commit.
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const KEY = () => (Deno.env.get("ANTHROPIC_API_KEY") ?? "").trim();
const MODEL = "claude-sonnet-5-5";
const NAMES: Record<string, string> = { ru: "Russian", zh: "Simplified Chinese", de: "German", fr: "French", es: "Spanish", ja: "Japanese", ko: "Korean", ar: "Arabic", he: "Hebrew", it: "Italian", nl: "Dutch", pl: "Polish", sv: "Swedish", uk: "Ukrainian", kk: "Kazakh" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });

async function translate(lang: string, list: string[]): Promise<string[] | null> {
  const name = NAMES[lang];
  const prompt = `You translate the screens of an app used by a Muay Thai gym with a small resort, cafe and spa in Phuket, Thailand. Customers book classes, packages, rooms and food in it; staff run the gym with it.
Translate each English text below into natural, friendly ${name}, the way a good local app would say it. Short buttons and labels stay short.
${lang === "ru" ? "Use the polite \"вы\" (lowercase). Muay Thai is \"тайский бокс\" in running text and \"Муай Тай\" in names. " : ""}Keep these exactly as they are: Phuket King, Pangea, Muay Friend, Massage Mate, THB, Stripe, PromptPay, WhatsApp, LINE, DTV, numbers, times, email addresses and links.
Keep every leading or trailing space and every leading or trailing punctuation mark exactly as in the English (some texts are pieces of longer sentences). Do not add quotes around the text.
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
  const r = await fetch(`https://raw.githubusercontent.com/phuketkinggg/pkapp/${sha}/i18n/strings.json`);
  const all = Object.keys(await r.json()).filter((k) => /[A-Za-z]/.test(k));
  const part = all.slice(offset, offset + count);
  const { data: have } = await admin.from("i18n_auto").select("en").eq("lang", lang).in("en", part);
  const done = new Set((have ?? []).map((x: { en: string }) => x.en));
  const todo = part.filter((k) => !done.has(k));
  const size = 60, jobs: Promise<void>[] = [];
  for (let i = 0; i < todo.length; i += size) {
    const list = todo.slice(i, i + size);
    jobs.push(translate(lang, list).then(async (out) => {
      if (!out) return;
      const rows = list.map((en, j) => ({ lang, en, tr: out[j], at: new Date().toISOString() })).filter((x) => x.tr.trim());
      const { error } = await admin.from("i18n_auto").upsert(rows);
      if (error) console.error("save", error.message);
    }));
  }
  await Promise.all(jobs);
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  const { data: ok } = await admin.rpc("sync_token_ok", { p_token: req.headers.get("x-sync-token") ?? "" });
  if (ok !== true) return json({ error: "Not allowed." }, 401);
  if (!KEY()) return json({ error: "ANTHROPIC_API_KEY is missing in Supabase secrets." });
  const b = await req.json().catch(() => ({}));
  const lang = String(b.lang ?? ""), sha = String(b.sha ?? "");
  if (!NAMES[lang]) return json({ error: "That language is not set up." });
  if (!/^[0-9a-f]{40}$/.test(sha)) return json({ error: "Give the commit." });
  const offset = Math.max(0, Math.round(Number(b.offset) || 0)), count = Math.max(1, Math.min(400, Math.round(Number(b.count) || 180)));
  const job = work(lang, sha, offset, count).catch((e) => console.error("work", (e as Error).message));
  // deno-lint-ignore no-explicit-any
  const rt = (globalThis as any).EdgeRuntime;
  if (rt?.waitUntil) rt.waitUntil(job); else await job;
  return json({ ok: true, started: true, offset, count });
});
