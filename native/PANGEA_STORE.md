# Pangea in the App Store and Google Play

The Pangea app is built in the cloud with the other apps (GitHub, Actions): every change under native/ makes a new
iPhone build in TestFlight and an Android file (.aab) to upload to Google Play. The app shows the live Pangea app
(app.phuketking.com/pangea, the same as app.pangeaglobalwellness.com), so updates need no new store release.

- Bundle ID / package name: com.pangeaglobalwellness.app
- Version: native/apps/pangea/version (1.0)
- Privacy policy: https://www.pangeaglobalwellness.com/privacy
- Support: https://www.pangeaglobalwellness.com/ (hello@phuketking.com, WhatsApp +66 96 907 6150)
- Members delete their account in the app: Me, Delete my account.

## App Store (iPhone)
The app record (com.pangeaglobalwellness.app) already exists in App Store Connect.
1. App Store Connect, Apps, Pangea, iOS App 1.0. Under Build, pick the newest build from TestFlight.
2. Fill in the listing below, screenshots (iPhone 6.9 inch and iPad 13 inch), and App Privacy (below).
3. App Review Information: a test login (a member account made for Apple, with a little in it), and the notes below.
4. Add for Review, Submit.

## Google Play (Android)
1. Play Console, Create app: name Pangea Global Wellness, App, Free.
2. GitHub, Actions, Android apps, the newest run, Artifacts: download android-pangea, upload pangea.aab
   to Testing, Internal testing first, then Production.
3. Fill in the store listing below, Data safety (below), Content rating (questionnaire: no violence, no user to user
   content in public), Target audience 18 and over, and App access: the same test login as for Apple.

## Listing
Name: Pangea Global Wellness
Subtitle (Apple, 30 characters): Your wellness, kept together
Short description (Google, 80 characters): Your habits, health file, coach and yearly service in one place.
Category: Health and Fitness
Keywords (Apple): wellness,longevity,coach,habits,health,blood test,nutrition,recovery,retreat,muay thai

Description:
Pangea brings every part of your wellness back together: mind, body, nutrition, bloods and genetics. It is not a
retreat you leave behind. It is a lifestyle looked after for life, by people who know you.

In the Pangea app:
- Today: the habits and steps your coach set for you, one tap to tick them off.
- Health: your own health file. Add measurements, a diary and photos, and upload blood tests, doctor's letters and scans.
- Journey: where you are, your level and your yearly service.
- Coach: talk to your coach and our team any time.
- Me: your membership, and your account at Pangea Phuket (Phuket King Muay Thai, Pangea Resort and Pangea Cafe).

Your health details are only kept after you agree, only you and your coaches can see them, and you can delete
your account and everything in it from the app at any time.

## Notes for Apple's reviewer
Pangea is the member app for Pangea Global Wellness, a wellness membership with in person coaching at our centre in
Phuket, Thailand. Members sign in with the account they get when they join. Use the test login above. The Health tab
holds the member's own health file (consent asked first), Coach is chat with their coach. Account deletion: Me,
Delete my account.

## App Privacy (Apple) and Data safety (Google)
Collected and linked to the person, not used for tracking or advertising:
- Contact info: name, email, phone (account, app functionality)
- Health and fitness: health records, measurements, diary (app functionality, with consent)
- Photos and files: uploaded by the member (app functionality)
- User content: messages with the coach (app functionality)
- Purchases: membership and bookings (app functionality)
- Identifiers: user ID (app functionality)
Data is encrypted in transit. Members can ask for deletion and can delete the account in the app.
No data is sold or shared with third parties for advertising.
