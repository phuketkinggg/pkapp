# Phuket King app

One app for Phuket King Muay Thai and Pangea: the customer app, the coach, housekeeping, maintenance and kitchen apps, and the back office (till, stays, privates, staff hours, receipts, contacts, investor view).

## How it is built

- `index.html` is the whole app: one page, plain JavaScript, no build step. GitHub Pages serves it.
- `vendor/` holds the three libraries the app uses (Supabase, QR codes, QR scanning), pinned to exact versions and served from this site, not from a CDN.
- `sw.js` keeps the app installable and opens the last copy with no signal. Data is never cached.
- `supabase/functions/` are the server functions: MotoPress sync, Stripe card payments and webhook, app access for staff and customers, and the stay welcome email.
- Database: Supabase project `jijnshwduhgegacfvpkh` (Singapore).

## Security rules

- Every table has row level security. The app reads and writes through rules or through database functions that check who is calling (manager, front desk, resort, coach, housekeeping, maintenance, kitchen, investor, customer).
- Nothing in the database can be called without signing in. New functions are not callable by visitors by default.
- The staff PIN hash can not be read by the app at all.
- Only the publishable Supabase key is in this repo. Stripe, MotoPress, Resend and the sync token live only in Supabase secrets.
- Customer and staff personal data never goes into this repo.
- The page has a content security policy: scripts only from this site, data only from the Supabase project.
- Removing a mistake from the till or a bill needs a manager's PIN every time. Payments of deleted sales are voided, never left counting.
- Refunds (packages and privates) need a manager's PIN. Money given back is a negative payment, so every report sees it. Deleting a package needs a manager's PIN and removes its check ins and the privates booked on it; the database refuses a package delete without that PIN step.
- The stay is the master for who the guest is: change the guest on a stay and its training, till sales and payments follow.
