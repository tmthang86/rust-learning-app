# Turning on accounts (Firebase)

The app works without this: progress is kept on the device and the sign-in
card is hidden. These steps switch on Google and Apple sign-in and progress
sync across devices. Only the project owner can do them, since they need a
Google account and an Apple developer account.

1. **Create a Firebase project** at https://console.firebase.google.com
   (the free Spark plan is enough to start).
2. **Connect the app.** On your computer, in this repository:
   ```sh
   dart pub global activate flutterfire_cli
   flutterfire configure --platforms=android,ios,web
   ```
   This replaces `lib/firebase_options.dart` and adds the Android and iOS
   config files. Commit them; they are not secret.
3. **Turn on sign-in methods** in Firebase console → Authentication →
   Sign-in method:
   - **Google**: enable it. For Android, add your app's SHA-1 and SHA-256
     fingerprints in Project settings.
   - **Apple**: enable it, and in your Apple developer account turn on
     "Sign in with Apple" for the app's bundle ID. For the web, also create
     a Services ID and add it in Firebase.
   - **Apple token revocation (required before release).** Apple asks
     apps that offer Sign in with Apple to revoke the person's tokens when
     they delete their account. In the Apple provider settings in Firebase,
     fill in the OAuth code flow fields: Services ID, Apple team ID, key ID
     and the private key of a "Sign in with Apple" key from your Apple
     developer account. Without them account deletion still works, but the
     revocation silently fails. Revocation only happens in the iOS and
     macOS apps: the web sign-in pop-up doesn't give the app the code it
     needs, so someone who deletes their account on the web can remove the
     app from Settings → Apple ID → Sign in with Apple on their device.
4. **Create the database**: Firestore Database → Create database
   (production mode), then deploy the rules from this repo:
   ```sh
   npm install -g firebase-tools
   firebase login
   firebase deploy --only firestore:rules
   ```
5. **Add your web domain** to Authentication → Settings → Authorized domains
   once the web app has a real address.
6. **Google Play account deletion URL.** Play Console → App content → Data
   safety asks for a web page where people can ask for their account to be
   deleted. Use the web app's deletion page:
   `https://<your web domain>/#/delete-account` (the app uses hash URLs on
   the web). It explains what is deleted and lets a signed-in person delete
   their account with the same steps as the app.

## How sync works

- Data lives in `users/{uid}`: `track`, `completedLessons`, `updatedAt`.
  `firestore.rules` lets each person read, write and delete only their own
  document, and only with these three fields: `track` must be `starter` or
  `fast`, `completedLessons` a list of at most 1000 entries, and
  `updatedAt` the server time of the write. Any other field is refused, so
  nothing that must be trusted (purchases, for example) can be stored here;
  that will go in a document only the server writes.
- The device remembers which account its progress was last synced with.
- When someone signs in, lessons finished on this device while signed out
  are added to their account, so nobody loses progress by signing in.
  Progress left over from a *different* account is never uploaded; the
  device shows the cloud copy instead.
- Signing out clears progress from the device, so the next person on a
  shared phone or tablet starts fresh. Their progress comes back when they
  sign in again. Before signing out, the app makes sure the progress
  reached the account: it retries a first sync that didn't finish, and
  waits up to 5 seconds for queued changes. If that fails (offline, or a
  write was refused), it asks "Sign out anyway?" before clearing.
- A device that has never synced doesn't change the account's track: the
  pick made on first launch counts only when the account has no track yet.
  After that, the track is uploaded only when it was changed on this
  device; otherwise the cloud's choice wins.
- Completed lessons are only ever added, so two devices can't undo each
  other.
- Firestore keeps working offline and sends changes when back online. If a
  sync or a change can't be saved, the Progress screen says so and offers
  to try again.
- The rules check the whole document on every write, so one bad field
  (written by hand, or by an old build) would block all later writes. When
  the app finds such a document it rewrites it in one write with only the
  allowed fields.
- `test/firestore_rules/run.sh` checks the rules against the Firestore
  emulator (needs Node and Java).

## Deleting an account

Apps that let people create an account must let them delete it from inside
the app (App Store Review Guideline 5.1.1(v)), and Google Play also wants a
web page for it (step 6 above). **Delete account** is on the Progress screen
and on `/delete-account`. After the person confirms, the app:

1. asks them to sign in again with the same provider. This starts straight
   from the button press, so the browser lets the pop-up open. For Apple it
   also gives the code used to revoke their Apple tokens;
2. reads `users/{uid}` from the server (offline, it stops here with a
   message and nothing is deleted) and keeps the copy;
3. deletes `users/{uid}` while still signed in (the rules don't allow it
   afterwards);
4. revokes the Apple tokens (best-effort, Apple accounts on iOS/macOS only);
5. deletes the Firebase Auth user;
6. clears progress on the device.

Each server step gives up after 20 seconds with an offline message. If the
account is not deleted, the app writes the cloud document back, combining
the saved copy with what this device has. That write can itself fail (for
example when the connection drops at that moment); then whatever this
device holds is synced again at the next sign-in, but lessons that were
only in the cloud may be lost. If deleting reports an error but the account
is in fact gone, nothing is written back.
