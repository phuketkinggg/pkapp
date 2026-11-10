# Phone notifications in the store apps (version 1.1)

The store apps show the live web app, so all the notification code is already live. The apps only need the
notifications plugin built in, and the server needs Apple's and Google's keys. Do these once per app.

## iPhone (Apple)
1. developer.apple.com, Certificates, Identifiers and Profiles, Keys, +. Name it "Push", tick
   Apple Push Notifications service (APNs), Continue, Register. Download the .p8 file (only once). Note the Key ID.
   Your Team ID is at the top right of the developer site (Membership details).
2. Identifiers: open the app's ID (com.phuketking.app), tick Push Notifications, Save.
3. Supabase, Edge Functions, Secrets, add:
   - APNS_KEY: the whole text of the .p8 file (open it in TextEdit, copy everything)
   - APNS_KEY_ID: the Key ID
   - APNS_TEAM_ID: the Team ID
   - APNS_TOPIC: com.phuketking.app
   One key works for all your apps; APNS_TOPIC is the bundle ID of the app in that Supabase project.
4. Nothing to build by hand: GitHub builds the apps with notifications switched on (Actions, iOS apps) and uploads them
   to TestFlight. The version is in native/apps/<app>/version (Phuket King 1.1).

## Android (Google Firebase)
1. console.firebase.google.com, Add project, then Add app, Android, once for each app: com.phuketking.app,
   com.pangeaglobalwellness.app, com.muayfriend.muayapp. Download google-services.json after adding the last one
   (it then holds all of them).
2. GitHub, the repo, Settings, Secrets and variables, Actions, New repository secret: GOOGLE_SERVICES_JSON with the
   whole text of that file. The Android builds then include notifications (until then they are built without them).
3. Project settings, Service accounts, Generate new private key. Supabase, Edge Functions, Secrets: add
   FCM_SERVICE_ACCOUNT with the whole text of that JSON file.
4. GitHub, Actions, Android apps, Run workflow. Download the .aab from the run and upload it to Google Play.

## Check it works
Open the new app, sign in, Messages, Turn on notifications on this phone, Allow. The app then shows in the
phone's notification settings. Book a test private from the member app: managers get "New private booked".
