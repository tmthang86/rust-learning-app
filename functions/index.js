'use strict';

// First generation trigger on purpose: in firebase-functions 7.4.0 the
// second generation `onUserDeleted` (firebase-functions/identity) is still
// marked @beta, while `auth.user().onDelete` in v1 is @public.
const functions = require('firebase-functions/v1');
const { initializeApp } = require('firebase-admin/app');
const { getFirestore, FieldValue, Timestamp } = require('firebase-admin/firestore');

initializeApp();

// How long the tombstone is kept before the optional Firestore TTL policy
// may remove it. A deleted account's ID token lives at most 1 hour, so 24
// hours is a wide margin.
const TOMBSTONE_TTL_MS = 24 * 60 * 60 * 1000;

// When an Auth user is deleted:
// - remove users/{uid}, the person's progress;
// - write deletedUsers/{uid}. firestore.rules refuses writes to users/{uid}
//   while it exists, so another device that is still signed in (its ID
//   token stays valid for up to an hour) can't recreate the document.
//
// One batch, so both happen or neither does. Running it again gives the
// same result, so retries (failurePolicy) are safe. Region: the default is
// us-central1; add `.region('europe-west1')` before `.auth` to change it.
exports.cleanUpDeletedUser = functions
  .runWith({ failurePolicy: true })
  .auth.user()
  .onDelete(async (user) => {
    const db = getFirestore();
    const uid = user.uid;
    const batch = db.batch();
    batch.set(db.doc(`deletedUsers/${uid}`), {
      deletedAt: FieldValue.serverTimestamp(),
      expireAt: Timestamp.fromMillis(Date.now() + TOMBSTONE_TTL_MS),
    });
    batch.delete(db.doc(`users/${uid}`));
    await batch.commit();
    // The uid only: no email or other personal data in logs.
    functions.logger.info('Cleaned up deleted account', { uid });
  });
