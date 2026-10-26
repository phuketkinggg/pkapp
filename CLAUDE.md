# Working on this repo

One codebase, many businesses. `index.html` is the app for Phuket King and Pangea, and the same file is built into every other app
(Massage Mate in `massagemate/demo/` by `tools/build_massagemate.py`, Muay Friend in `muayfriend/demo/` by `tools/build_demo.py`).
Tom's standing rule: every change he asks for goes to every app, is written in the changelog, and can be switched on or off by each business.
The apps are built for durability and utility: wherever a business could want it different, make it a setting.

## Every change

1. Change `index.html` (and `pk/` for the website). Never fork the code for one business.
2. Not every business needs it? Put it behind a feature switch: add it to `FEATURES` in `index.html` (key, name, what it does, tabs it controls,
   default on or off, and the default in spa mode). Check it with `featOn('key')`. Server side, check `private.feature('key', default)`.
3. Add an entry at the top of `changelog.js`: date, title, what it does in plain words, and the feature key if it can be switched.
   Write it for any business (say "the gym", "your business"), never Phuket King names.
4. Database changes go in `supabase/sql/<name>.sql` and are applied to all three databases:
   live `jijnshwduhgegacfvpkh`, Muay Friend demo `yojllgjjekitbktzblcc`, Massage Mate demo `phjekupadmjwzrocahiv`.
   Patches that edit an existing function must check that they applied, and skip cleanly where a demo has an older version.
5. New or changed text people read: the app is in English, Thai and Myanmar. Run `python3 tools/build_i18n.py --missing`,
   add Thai and Myanmar for those texts to `i18n/strings.json` (English -> [Thai, Myanmar]), then `python3 tools/build_i18n.py` and bump `I18N_V` in `index.html`.
   Text people write themselves (chat, notes, lessons) is never translated: give its element the class `notr`.
6. Bump the cache name in `sw.js`, then run `python3 tools/build_massagemate.py`, `python3 tools/build_demo.py` and `python3 tools/build_site.py`.
7. The demo builds check their own JavaScript (`tools/check_js.py`) and stop if a word swap broke the code. Check `index.html` the same way
   (`python3 tools/check_js.py index.html`) and test the database functions before telling Tom it is done.

## Never hardcode one business

- Business names come from the database (`app_settings` key `acc_names`, read by `private.biz_main()` and `private.biz_stay()`; in the app `BIZ_MAIN` and `BIZ_STAY`).
- Businesses and departments: `app_settings` key `acc_structure` (Accounts, Businesses and departments).
- Colours: `app_theme`. Features: `features`. Prices, texts, photos and team: settings or tables, never code.
- Massage Mate and Muay Friend never mention Phuket King or Pangea.

## Rules that always apply

- No em dashes and no "&" in any text Tom or customers read.
- Secrets never in chat or in this repo: they live in Supabase secrets.
- Accounting data, customer data and gym contact lists are never committed.
