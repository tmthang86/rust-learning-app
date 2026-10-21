// Checks firestore.rules: run ./run.sh in this folder.
import { readFileSync } from 'node:fs';
import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} from '@firebase/rules-unit-testing';
import {
  doc,
  setDoc,
  getDoc,
  deleteDoc,
  serverTimestamp,
  arrayUnion,
  Timestamp,
} from 'firebase/firestore';

const env = await initializeTestEnvironment({
  projectId: 'demo-rust-learn',
  firestore: {
    // run.sh copies this file elsewhere and passes the rules path.
    rules: readFileSync(
      process.env.RULES_FILE ?? new URL('../../firestore.rules', import.meta.url),
      'utf8',
    ),
    host: '127.0.0.1',
    port: 8085,
  },
});

const me = env.authenticatedContext('u1').firestore();
const other = env.authenticatedContext('u2').firestore();
const anon = env.unauthenticatedContext().firestore();
const mine = (db = me) => doc(db, 'users', 'u1');
const now = serverTimestamp();
const merge = { merge: true };

/** Writes a document the rules would refuse, as an old build might have. */
const seed = (data) =>
  env.withSecurityRulesDisabled((ctx) => setDoc(doc(ctx.firestore(), 'users', 'u1'), data));

/** Writes the tombstone the Cloud Function leaves when an account is deleted. */
const tombstone = () =>
  env.withSecurityRulesDisabled((ctx) =>
    setDoc(doc(ctx.firestore(), 'deletedUsers', 'u1'), { deletedAt: new Date(), expireAt: new Date() }));
const tomb = (db = me) => doc(db, 'deletedUsers', 'u1');

/** A map of n distinct day-like keys. */
const days = (n) => Object.fromEntries(Array.from({ length: n }, (_, i) => [`d${i}`, 20]));

const cases = [
  ['owner sets track', true, () => setDoc(mine(), { track: 'fast', updatedAt: now }, merge)],
  ['owner adds lessons', true, () =>
    setDoc(mine(), { completedLessons: arrayUnion('u1-l1'), updatedAt: now }, merge)],
  ['owner adds a checkpoint id', true, () =>
    setDoc(mine(), { completedLessons: arrayUnion('u3-check'), updatedAt: now }, merge)],
  ['owner reads', true, () => getDoc(mine())],
  ['other user reads', false, () => getDoc(mine(other))],
  ['other user writes', false, () => setDoc(mine(other), { track: 'fast', updatedAt: now }, merge)],
  ['signed out reads', false, () => getDoc(mine(anon))],
  ['unknown track', false, () => setDoc(mine(), { track: 'pro', updatedAt: now }, merge)],
  ['extra field (entitlement)', false, () =>
    setDoc(mine(), { entitlement: 'premium', updatedAt: now }, merge)],
  ['missing updatedAt', false, () => setDoc(mine(), { track: 'fast' }, merge)],
  ['client-chosen updatedAt', false, () =>
    setDoc(mine(), { track: 'fast', updatedAt: Timestamp.fromMillis(0) }, merge)],
  ['lessons not a list', false, () =>
    setDoc(mine(), { completedLessons: 'x', updatedAt: now }, merge)],
  ['1001 lessons', false, () =>
    setDoc(mine(), {
      completedLessons: Array.from({ length: 1001 }, (_, i) => `l${i}`),
      updatedAt: now,
    }, merge)],
  ['1000 lessons', true, () =>
    setDoc(mine(), {
      completedLessons: Array.from({ length: 1000 }, (_, i) => `l${i}`),
      updatedAt: now,
    }, merge)],
  ['owner sets XP for a day', true, () =>
    setDoc(mine(), { dailyXp: { '2026-03-18': 20 }, updatedAt: now }, merge)],
  ['XP not a map', false, () =>
    setDoc(mine(), { dailyXp: 'lots', updatedAt: now }, merge)],
  ['XP a list', false, () =>
    setDoc(mine(), { dailyXp: [20], updatedAt: now }, merge)],
  ['4001 XP days', false, () =>
    setDoc(mine(), { dailyXp: days(4001), updatedAt: now }, merge)],
  ['4000 XP days', true, () =>
    setDoc(mine(), { dailyXp: days(4000), updatedAt: now }, merge)],
  ['other user writes XP', false, () =>
    setDoc(mine(other), { dailyXp: { '2026-03-18': 20 }, updatedAt: now }, merge)],
  ['XP write without updatedAt', false, () =>
    setDoc(mine(), { dailyXp: { '2026-03-18': 20 } }, merge)],
  // A merge write that names one day changes only that day (Firestore merges
  // maps field by field): this is how the app syncs XP.
  ['a merge write changes only the day it names', true, async () => {
    await seed({ dailyXp: { '2026-03-16': 30, '2026-03-17': 10 } });
    await setDoc(mine(), { dailyXp: { '2026-03-17': 40, '2026-03-18': 5 }, updatedAt: now }, merge);
    const xp = (await getDoc(mine())).data().dailyXp;
    const want = { '2026-03-16': 30, '2026-03-17': 40, '2026-03-18': 5 };
    if (JSON.stringify(xp, Object.keys(xp).sort()) !== JSON.stringify(want, Object.keys(want).sort())) {
      throw new Error(`expected ${JSON.stringify(want)}, got ${JSON.stringify(xp)}`);
    }
  }],
  ['a merge write to other fields keeps the XP', true, async () => {
    await seed({ dailyXp: { '2026-03-16': 30 }, completedLessons: ['a'] });
    await setDoc(mine(), { completedLessons: arrayUnion('b'), updatedAt: now }, merge);
    const data = (await getDoc(mine())).data();
    if (data.dailyXp['2026-03-16'] !== 30) throw new Error('XP lost');
  }],
  ['bad XP type blocks a merge write', false, async () => {
    await seed({ dailyXp: 'oops', completedLessons: ['a'] });
    return setDoc(mine(), { completedLessons: arrayUnion('b'), updatedAt: now }, merge);
  }],
  ['full rewrite repairs a bad XP type', true, async () => {
    await seed({ dailyXp: 'oops', completedLessons: ['a'] });
    return setDoc(mine(), { completedLessons: ['a'], dailyXp: { '2026-03-18': 20 }, updatedAt: now });
  }],
  ['XP inside a map need not be valid (the app ignores bad days)', true, () =>
    setDoc(mine(), { dailyXp: { junk: 'x', '2026-03-18': 20 }, updatedAt: now }, merge)],
  ['other collection', false, () => setDoc(doc(me, 'entitlements', 'u1'), { premium: true })],
  ['other user deletes', false, () => deleteDoc(mine(other))],
  ['owner deletes', true, () => deleteDoc(mine())],

  // A broken document blocks merge writes; the app repairs it with one
  // write without merge (ProgressSync.replace).
  ['bad track blocks a merge write', false, async () => {
    await seed({ track: 42, completedLessons: ['a'] });
    return setDoc(mine(), { completedLessons: arrayUnion('b'), updatedAt: now }, merge);
  }],
  ['full rewrite repairs a bad track', true, async () => {
    await seed({ track: 42, completedLessons: ['a'] });
    return setDoc(mine(), { track: 'fast', completedLessons: ['a', 'b'], updatedAt: now });
  }],
  ['extra stored field blocks a merge write', false, async () => {
    await seed({ legacy: true, completedLessons: ['a'] });
    return setDoc(mine(), { track: 'fast', updatedAt: now }, merge);
  }],
  ['full rewrite removes an extra field', true, async () => {
    await seed({ legacy: true, completedLessons: ['a'] });
    return setDoc(mine(), { completedLessons: ['a'], updatedAt: now });
  }],

  // Tombstone: the account was deleted but a device still holds a token.
  ['tombstone blocks owner create', false, async () => {
    await tombstone();
    return setDoc(mine(), { track: 'fast', updatedAt: now });
  }],
  ['tombstone blocks owner update', false, async () => {
    await seed({ completedLessons: ['a'] });
    await tombstone();
    return setDoc(mine(), { completedLessons: arrayUnion('b'), updatedAt: now }, merge);
  }],
  ['tombstone still lets owner delete', true, async () => {
    await seed({ completedLessons: ['a'] });
    await tombstone();
    return deleteDoc(mine());
  }],
  ['tombstone still lets owner read', true, async () => {
    await seed({ completedLessons: ['a'] });
    await tombstone();
    return getDoc(mine());
  }],
  ["another user's tombstone does not block this one", true, async () => {
    await env.withSecurityRulesDisabled((ctx) =>
      setDoc(doc(ctx.firestore(), 'deletedUsers', 'u2'), { expireAt: new Date() }));
    return setDoc(mine(), { track: 'fast', updatedAt: now });
  }],
  ['client writes a tombstone', false, () => setDoc(tomb(), { deletedAt: now })],
  ['client reads a tombstone', false, async () => {
    await tombstone();
    return getDoc(tomb());
  }],
  ['client deletes a tombstone', false, async () => {
    await tombstone();
    return deleteDoc(tomb());
  }],
];

let failed = 0;
for (const [name, allowed, run] of cases) {
  try {
    // Each case starts from an empty database, so a seeded tombstone or
    // document can't leak into the next one.
    await env.clearFirestore();
    await (allowed ? assertSucceeds(run()) : assertFails(run()));
    console.log(`ok    ${allowed ? 'allows' : 'denies'}: ${name}`);
  } catch (e) {
    failed++;
    console.log(`FAIL  should ${allowed ? 'allow' : 'deny'}: ${name} (${e.message})`);
  }
}
await env.cleanup();
console.log(failed ? `${failed} failed` : `all ${cases.length} passed`);
process.exit(failed ? 1 : 0);
