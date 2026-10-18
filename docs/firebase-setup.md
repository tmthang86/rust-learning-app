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
     a Services ID and add it in Firebase. So that deleting an account also
     revokes the person's Apple tokens (Apple asks for this), fill in the
     provider's OAuth code flow settings in Firebase: Services ID, Apple
     team ID, key ID and the private key of a "Sign in with Apple" key.
     Without them deletion still works, but the revocation is skipped.
4. **Create the database**: Firestore Database → Create database
   (production mode), then deploy the rules from this repo:
   ```sh
   npm install -g firebase-tools
   firebase login
   firebase deploy --only firestore:rules
   ```
5. **Add your web domain** to Authentication → Settings → Authorized domains
   once the web app has a real address.

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
  sign in again.
- Completed lessons are only ever added, so two devices can't undo each
  other. The track is uploaded only when it was changed on this device;
  otherwise the cloud's choice wins.
- Firestore keeps working offline and sends changes when back online. If
  the first sync after signing in fails, the Progress screen says so and
  offers to try again.

## Deleting an account

Apps that let people create an account must let them delete it from inside
the app (App Store Review Guideline 5.1.1(v)). The Progress screen has
**Delete account**. After confirming, the app:

1. deletes `users/{uid}` (this has to happen while still signed in, since
   the rules then no longer allow it);
2. deletes the Firebase Auth user. If Firebase answers
   `requires-recent-login`, the person signs in again with the same
   provider and the app retries. Apple users always confirm with Apple
   first, which also gives the authorization code used to revoke their
   Apple tokens;
3. clears progress on the device.

If the account can't be deleted (for example the confirmation sign-in is
cancelled), the cloud progress is written back from the device copy and
nothing is lost.
