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

7. **App Check for the code runner (only if you run your own runner).** The
   production runner accepts requests only from your genuine app, proved with
   Firebase App Check. Register each app and its debug tokens as described in
   [runner/deploy/README.md](../runner/deploy/README.md) (steps 4 to 6).
   Without Firebase the app still works, but it sends no token, so only a
   development runner accepts its code runs.

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
  allowed fields, but only when the read came from the server with no
  writes of its own still pending. A cached or half-written copy is out of
  date, and rewriting from it could remove lessons added on another device.
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
the saved copy with what this device has, but only when it can confirm with
the server that the account still exists. If deleting reports an error but
the account is in fact gone, nothing is written back.

Two cases leave the cloud document missing while the account may still
exist. In both, the device first adds the cloud copy it read before
deleting to its own progress, so nothing that was only in the cloud is
lost, and marks the progress as not saved (the Progress screen shows **Try
syncing again**, and signing out asks "Sign out anyway?" if a sync still
fails).

- **The write putting the document back failed** (the account is known to
  exist). The next successful sync uploads everything again.
- **The app couldn't confirm whether the account was deleted** (for
  example a timeout while offline). The server may have deleted it, and
  the cached sign-in keeps working for up to an hour, so any write could
  recreate `users/{uid}` for a deleted account, and the rules would then
  stop anyone deleting it. The app therefore writes nothing for that
  account until it checks with the server again. Changes made meanwhile
  (finished lessons, a new track) are not sent: they stay on the device and
  show as not saved. The check runs at the next sync (sign-in, app start,
  **Try syncing again**), at sign-out, and when the delete dialog or the
  `/delete-account` page opens. If the account is gone, the device is
  cleared and signed out, and the page shows it as deleted. If it still
  exists, syncing resumes (uploading what was kept) and the person can
  delete it again. If the server still can't be asked, nothing is written
  and the next check asks again. This survives restarting the app.

### Known limitation: other signed-in devices (must be fixed before launch)

Deleting an account removes `users/{uid}` and the Auth user, but another
device that is still signed in to that account keeps a valid ID token for
up to an hour (Firebase ID tokens last that long and the rules only check
the token). If that device syncs in that time (it finishes a lesson, or the
app starts), its write recreates `users/{uid}`. Nobody can delete that
document afterwards from the app, because the account no longer exists, so
it breaks the promise that deletion removes everything.

Before launch, add a server-side cleanup (not built yet):

- A Cloud Function triggered when an Auth user is deleted. Use the stable
  first generation trigger: import it with
  `const functions = require('firebase-functions/v1')` and use
  `functions.auth.user().onDelete(...)`. From firebase-functions v6 on, the
  plain `require('firebase-functions')` gives the second generation API,
  whose `onUserDeleted` (in `firebase-functions/identity`) is still a beta
  preview, not meant for production.
- The function deletes `users/{uid}` with the Admin SDK, then re-checks
  after a delay longer than the token lifetime (for example a Cloud Tasks
  job about 65 minutes later) and deletes the document again if it has
  reappeared.
- Deploying functions needs the Blaze (pay-as-you-go) plan.
- Bulk deletion with the Admin SDK (`admin.auth().deleteUsers()`) doesn't
  fire `onDelete`, so any admin script that deletes users in bulk must also
  delete their `users/{uid}` documents.
- Alternative that blocks recreation outright: `onDelete` writes a
  tombstone `deletedUsers/{uid}` (server-only), and `firestore.rules` refuses
  writes to `users/{uid}` while it exists, e.g.
  `&& !exists(/databases/$(database)/documents/deletedUsers/$(uid))`. This
  costs one extra document read per write.
