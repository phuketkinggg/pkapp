# Pangea: its own database, logins, staff and back office

Agreed with Tom on 12 November 2026. Read this before any Pangea build work.

## What Tom wants
- Pangea Global Wellness holds its own information: every Pangea member and every Pangea staff member worldwide,
  doctors' notes, blood tests, files and memberships. One login per person that works everywhere.
- Regional Pangea businesses (Pangea Phuket first, more later) draw on the Pangea database.
- Phuket King stays separate, as it is now. Pangea may READ what it needs from Phuket King.
  Pangea never WRITES to Phuket King: Pangea writes only to its own database.
- Its own login, own staff, own back office, made for Pangea.
- Members tick to agree that their data is kept privately for professional use only, that it stays theirs
  (Pangea does not own it) and that it is never sold or used to make money. Then make it secure.

## The design
1. One Supabase project for Pangea worldwide (new, about 10 US dollars a month). Not one per region:
   a member's file must not be split across countries.
2. Regions are rows inside it (pangea_regions). Staff belong to one or more regions. A coach or regional manager
   sees only members of their region(s); global staff and the owner see all. Doctors see only the members
   assigned to them, and only the health parts.
3. Same code as every other app (CLAUDE.md: one codebase). The Pangea back office is a build of index.html with
   the Pangea business type, its own name, menus, roles and theme, like Massage Mate. pangea/index.html (the member
   app) points at the new project.
4. Phuket King link, one way: Pangea reads from Phuket King through a narrow server side function (an edge function
   with a key kept in Supabase secrets, never in the app): for a linked person, their check ins, privates and
   training. Phuket King gets nothing from Pangea except, if wanted, "is a Pangea member" and the level.
   No health data ever goes to Phuket King.
5. People in both are linked by email, only with their OK (a tick in the Pangea app).

## Security (build these from the start)
- Row level security on every table. No table readable or writable directly from the app unless its policy
  checks the person and their region; everything else through security definer functions that check the role.
- Health records (member_file, notes, measurements, diary, bloods, documents) only after consent, only for the
  member, their assigned coaches, doctors and region managers, and the owner.
- Files in a private storage bucket, opened with short lived signed links only. Never public URLs.
- Every view and change of a health record is written to an access log (who, what, when). The member can see
  who looked at their file.
- Consent: a tick box with the exact terms (stays theirs, private, professional use only, never sold or used for
  profit). The record keeps which terms version they agreed to and when. Taking it back stops new health data
  being added and hides the file from staff until they agree again. Deleting the account deletes everything.
- Staff need two factor sign in (Supabase MFA) for the back office.
- Backups: Supabase daily backups, point in time recovery when the budget allows.
- No health data in emails, push notifications or logs: notifications say "New note from your coach", nothing more.
- Data stays in one region (Singapore, like the other projects) unless the law of a new country needs otherwise.
- Get a short legal check (Thailand PDPA, EU GDPR) before Pangea opens outside Thailand.

## Moving what exists now
Today Pangea members live in the Phuket King database (customers with tier pangea, member_file, member notes and
documents, Pangea levels, habits, programs, food diary, measurements). Steps:
1. Create the project and the schema (from the template of the live database, Pangea tables only, plus regions,
   doctor role, access log, consent terms version).
2. Copy Pangea members, their files and documents (storage objects too), staff who coach Pangea members.
3. Point the Pangea member app and the Pangea back office at the new project. Members keep their email login
   (they get a "set your password" email once, or a magic link).
4. Check every member's file is complete, then remove the health data from the Phuket King database.
5. Build the Phuket King read link.

## Done so far
- 12 Nov 2026: Supabase project "Pangea Global" made: tqqfhahchjwihwknyiwo, Singapore (ap-southeast-1).
  Publishable key sb_publishable_ei0gMLn3YmXoOO-3O6t_Og_qECOjLb1 (public, fine in the app).
  Whole structure of the live app copied in (6150 statements, 0 errors): 132 tables, 769 functions, defaults, keys, indexes,
  triggers, row security, policies, grants. Supabase's default "anon and authenticated can do everything" grants were
  revoked, so rights are exactly the live app's (checked: function rights identical; table rights identical except mf_leads,
  which is left out on purpose). Project references in functions point at the Pangea project. 7 storage buckets and their
  policies as live. No data yet. The build schema (build.template, build.run) holds the copy log and is not exposed.
  Still to do: app_settings and features for Pangea, sync_settings (functions_url, sync_token), auth settings (site URL,
  email sender, MFA), edge functions deployed to this project, the back office build, regions, doctor role, access log,
  member move, Phuket King read link.
- 12 Nov 2026: the consent tick box with the full terms in the Pangea app; the record keeps the terms version
  (health_consent_terms.sql); the Pangea privacy page says the data stays theirs and is never sold.
