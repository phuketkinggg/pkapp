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
4. On the Mac, in this native folder:
   npm install
   npx cap sync ios
   Open the iOS project in Xcode, the app target, Signing and Capabilities, + Capability:
   Push Notifications, and + Capability: Background Modes, tick Remote notifications.
5. Raise the version to 1.1 (build number +1), Product, Archive, upload to App Store Connect.

## Android (Google Firebase)
1. console.firebase.google.com, Add project (or use one you have), then Add app, Android,
   package name com.phuketking.app. Download google-services.json and put it in android/app/.
2. Project settings, Service accounts, Generate new private key. It downloads a JSON file.
3. Supabase, Edge Functions, Secrets, add FCM_SERVICE_ACCOUNT: the whole text of that JSON file.
4. npx cap sync android, raise versionCode and versionName (1.1), build the release bundle, upload to Google Play.

## Check it works
Open the new app, sign in, Messages, Turn on notifications on this phone, Allow. The app then shows in the
phone's notification settings. Book a test private from the member app: managers get "New private booked".
