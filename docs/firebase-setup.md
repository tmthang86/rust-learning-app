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
  The rules in `firestore.rules` let each person see only their own document.
- When someone signs in, lessons finished on this device and in the cloud
  are combined, so nobody loses progress by signing in on a new device.
- Completed lessons are only ever added, so two devices can't undo each
  other. Firestore keeps working offline and syncs when back online.
