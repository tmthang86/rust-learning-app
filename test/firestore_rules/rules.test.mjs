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

const cases = [
  ['owner sets track', true, () => setDoc(mine(), { track: 'fast', updatedAt: now }, merge)],
  ['owner adds lessons', true, () =>
    setDoc(mine(), { completedLessons: arrayUnion('u1-l1'), updatedAt: now }, merge)],
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
];

let failed = 0;
for (const [name, allowed, run] of cases) {
  try {
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
