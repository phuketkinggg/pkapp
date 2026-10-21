// The accounts as CSV for a Google Sheet (=IMPORTDATA(link)). Private link with a token a manager makes in Accounts.
// GET ?t=<token>&kind=entries|departments|checks[&from=YYYY-MM-DD&to=YYYY-MM-DD]   (default: 1 Jan last year to today)
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const today = () => new Date(Date.now() + 7 * 3600e3).toISOString().slice(0, 10);
const isDay = (d: string | null) => !!d && /^\d{4}-\d{2}-\d{2}$/.test(d);
const cell = (v: unknown) => { const s = v == null ? "" : String(v); return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s; };
const csv = (rows: unknown[][]) => rows.map((r) => r.map(cell).join(",")).join("\n") + "\n";
const out = (body: string, s = 200) => new Response(body, { status: s, headers: { "Content-Type": "text/csv; charset=utf-8", "Cache-Control": "no-store" } });
const METHOD: Record<string, string> = { cash: "Cash", card: "Card", transfer: "Bank transfer", qr: "PromptPay", stripe: "Card online", room: "Room bill", staff: "Staff tab", agent: "Agent" };
type Line = { d: string; b: string; dep: string | null; t: string; what: string; cat: string | null; m: string | null; a: number; src: string; to: string | null };

Deno.serve(async (req) => {
  const u = new URL(req.url);
  const t = u.searchParams.get("t") ?? "", kind = u.searchParams.get("kind") ?? "entries";
  const to = isDay(u.searchParams.get("to")) ? u.searchParams.get("to")! : today();
  const from = isDay(u.searchParams.get("from")) ? u.searchParams.get("from")! : `${Number(to.slice(0, 4)) - 1}-01-01`;
  if (!/^[0-9a-f]{20,64}$/.test(t)) return out("Error,This link is not valid\n", 403);
  const { data, error } = await admin.rpc("acc_feed_data", { p_token: t, p_from: from, p_to: to });
  if (error) return out(`Error,${cell(error.message)}\n`, 500);
  if (!data) return out("Error,This link has been replaced. Make a new one in the app: Accounts, Google Sheet.\n", 403);
  const lines = (data.lines ?? []) as Line[];
  if (kind === "entries") {
    const rows: unknown[][] = [["Date", "Business", "Department", "In or out", "What", "Category", "Paid by", "Amount THB", "From", "Signed THB"]];
    for (const l of lines) {
      if (l.t === "move") { // money moved between the businesses shows as out of one and in to the other
        rows.push([l.d, l.b, "Between the businesses", "out", `To ${l.to}: ${l.what}`, l.cat, METHOD[l.m ?? ""] ?? l.m, l.a, "Entry", -l.a]);
        rows.push([l.d, l.to, "Between the businesses", "in", `From ${l.b}: ${l.what}`, l.cat, METHOD[l.m ?? ""] ?? l.m, l.a, "Entry", l.a]);
        continue;
      }
      rows.push([l.d, l.b, l.dep ?? "", l.t, l.what, l.cat ?? "", METHOD[l.m ?? ""] ?? l.m ?? "", Number(l.a), { payment: "App payment", shop: "Till", receipt: "Receipt", commission: "Coach share", entry: "Entry", affiliate: "Affiliate" }[l.src] ?? l.src, l.t === "in" ? Number(l.a) : -Number(l.a)]);
    }
    return out(csv(rows));
  }
  if (kind === "departments") {
    const m = new Map<string, { i: number; o: number }>();
    for (const l of lines) {
      if (l.t === "move") continue;
      const k = [l.d.slice(0, 7), l.b, l.dep || "No department"].join("|");
      const v = m.get(k) ?? { i: 0, o: 0 }; if (l.t === "in") v.i += Number(l.a); else v.o += Number(l.a); m.set(k, v);
    }
    const rows: unknown[][] = [["Month", "Business", "Department", "Money in THB", "Money out THB", "Profit THB"]];
    [...m.entries()].sort((a, b) => a[0] < b[0] ? 1 : -1).forEach(([k, v]) => { const [mo, b, d] = k.split("|"); rows.push([mo, b, d, Math.round(v.i), Math.round(v.o), Math.round(v.i - v.o)]); });
    return out(csv(rows));
  }
  if (kind === "checks") {
    const rows: unknown[][] = [["What to check", "Date", "Business", "Entry", "Amount THB", "Why"]];
    for (const c of (data.checks ?? []) as { level: string; kind: string; d: string; b: string; what: string; a: number | null; why: string }[]) rows.push([c.kind, c.d, c.b ?? "", c.what, c.a ?? "", c.why]);
    if (rows.length === 1) rows.push(["Nothing to check", to, "", "", "", "No duplicates or odd entries found."]);
    return out(csv(rows));
  }
  return out("Error,kind must be entries, departments or checks\n", 400);
});
