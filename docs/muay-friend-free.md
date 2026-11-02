# Muay Friend free: one shared database, one private section per gym

Supabase project "Muay Friend free" (bnglnfdgptvnmugntiom, Singapore).

## How gyms are kept apart
Each free gym gets its own pair of Postgres schemas in the shared database:
- `g_<slug>`   the gym's tables and app functions (a copy of the app's `public` schema)
- `g_<slug>_p` the gym's private helpers (a copy of the app's `private` schema)

All app functions already use `set search_path to ''` and fully qualified names (`public.x`, `private.y`),
so a gym's copy is the same code with `public.` and `private.` renamed. No gym can read another gym's schema:
row security, grants and the staff table all live inside the gym's own schema.

The API serves a new gym the moment it is made: the list of served schemas is a database setting
(`alter role authenticator set pgrst.db_schemas = ...` then `notify pgrst, 'reload config'`). Tested 2 Nov 2026: works.
The app picks the gym's schema with the supabase-js option `db: { schema: 'g_<slug>' }`.

## Plan
1. Template: generate the full DDL of `public` and `private` from the Muay Friend demo database (tables, defaults,
   constraints, indexes, policies, triggers, functions, views, grants), with placeholders for the schema names.
2. `provision` function (service role): makes the schemas from the template, adds them to the served list,
   sets the gym name, plan 'free' and limits, and makes the owner's staff record.
3. Instant sign-up: muayfriend.com form -> provision -> owner gets a sign-in email and lands in their app.
4. One app build for all free gyms (muayfriend.com/app/?g=<slug>), schema chosen from the address.
5. Free limits in the database: 15 members, 2 staff, basic features only. Upgrade moves the gym to its own project.
6. Shared logins: one auth user can be staff or member in more than one gym (each gym has its own staff and customers tables).

## Progress
- 2 Nov: template made from live with tools/mf_template.sql (5,361 statements: 117 tables, 651 functions, policies,
  triggers, grants) into mf.template. mf.make_schemas('<slug>') builds a gym from it: test gym 'trial' built with
  0 failures, no leftover public./private. references.
