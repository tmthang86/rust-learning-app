'use strict';
// Runs against the Auth, Firestore and Functions emulators:
// `npm test` (firebase emulators:exec sets the emulator host variables).
const { test, before } = require('node:test');
const assert = require('node:assert/strict');
const { initializeApp } = require('firebase-admin/app');
const { getAuth } = require('firebase-admin/auth');
const { getFirestore, Timestamp } = require('firebase-admin/firestore');

initializeApp({ projectId: 'demo-rust-learn' });
const auth = getAuth();
const db = getFirestore();

before(() => {
  assert.ok(process.env.FIRESTORE_EMULATOR_HOST, 'run with `npm test`, not node directly');
  assert.ok(process.env.FIREBASE_AUTH_EMULATOR_HOST, 'run with `npm test`, not node directly');
});

/** Polls until `check` returns a truthy value, or fails after `ms`. */
async function waitFor(check, what, ms = 20000) {
  const end = Date.now() + ms;
  for (;;) {
    const value = await check();
    if (value) return value;
    if (Date.now() > end) assert.fail(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 250));
  }
}

async function tombstoneOf(uid) {
  const snap = await db.doc(`deletedUsers/${uid}`).get();
  return snap.exists ? snap : null;
}

function assertTombstone(snap, before) {
  const data = snap.data();
  assert.ok(data.deletedAt instanceof Timestamp, 'deletedAt is a timestamp');
  assert.ok(data.expireAt instanceof Timestamp, 'expireAt is a timestamp');
  const hours = (data.expireAt.toMillis() - before) / 3600000;
  assert.ok(hours > 23.9 && hours < 24.1, `expireAt about 24h ahead, got ${hours}h`);
}

test('deleting a user removes users/{uid} and writes a tombstone', async () => {
  const start = Date.now();
  const { uid } = await auth.createUser({ email: 'a@example.com' });
  await db.doc(`users/${uid}`).set({ track: 'fast', completedLessons: ['a'] });

  await auth.deleteUser(uid);

  const snap = await waitFor(() => tombstoneOf(uid), 'the tombstone');
  assertTombstone(snap, start);
  assert.equal((await db.doc(`users/${uid}`).get()).exists, false);
});

test('an existing tombstone is overwritten without failing', async () => {
  const start = Date.now();
  const { uid } = await auth.createUser({ email: 'c@example.com' });
  await db.doc(`deletedUsers/${uid}`).set({ deletedAt: Timestamp.fromMillis(0), expireAt: Timestamp.fromMillis(0) });
  await db.doc(`users/${uid}`).set({ track: 'fast' });

  await auth.deleteUser(uid);

  const snap = await waitFor(async () => {
    const s = await tombstoneOf(uid);
    return s && s.data().expireAt.toMillis() > 0 ? s : null;
  }, 'the tombstone to be rewritten');
  assertTombstone(snap, start);
  assert.equal((await db.doc(`users/${uid}`).get()).exists, false);
});

test('a user who never had a document still gets a tombstone', async () => {
  const start = Date.now();
  const { uid } = await auth.createUser({ email: 'b@example.com' });

  await auth.deleteUser(uid);

  assertTombstone(await waitFor(() => tombstoneOf(uid), 'the tombstone'), start);
  assert.equal((await db.doc(`users/${uid}`).get()).exists, false);
});
