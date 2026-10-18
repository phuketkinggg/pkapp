// Retired one-off job. It is switched off so nobody can run it again. The old code is in git history if it is ever needed.
Deno.serve(() => new Response(JSON.stringify({ error: "This one-off job has finished." }), { status: 410, headers: { "Content-Type": "application/json" } }));
