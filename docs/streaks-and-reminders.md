# Streaks, XP, daily goal and study reminders

What the learner gets: XP for finishing lessons, a daily goal, a streak that
survives the occasional missed day, and an optional daily reminder. This page
holds the rules, the numbers, how each age group is treated, how it syncs,
and the sources the design rests on.

Deliberately **not** in the app: energy or hearts that block learning,
leaderboards, leagues, betting on a streak, paid streak repair, and any
"your streak is about to die" wording. Nothing here asks for money or
compares learners with each other.

Code: `lib/data/streaks.dart` (all the rules, pure functions),
`lib/data/app_state.dart` (earning and syncing), `lib/reminders/` (settings
and scheduling), `lib/features/streak/` (screens),
`lib/l10n/streak_strings.dart` (every string).

## The numbers

| What | Value |
| --- | --- |
| XP, first time a lesson is finished | 20 |
| XP, finishing a lesson that was already done (review) | 5 |
| XP from the playground | none |
| Daily goal choices | 20 (Casual), 40 (Regular), 60 (Serious) XP; default 20 |
| A freeze is earned | for every 7 active days in a row |
| Freezes held at most | 2 |
| Reminder time | 19:00 local by default, the learner can change it |
| Reminders scheduled ahead | the next 7 days |

All of them are constants at the top of `lib/data/streaks.dart` and
`lib/reminders/reminder_plan.dart`.

### When XP is earned

XP is awarded where a lesson counts as finished: passing the quiz, solving
the exercise, or "Mark as done" (all call `AppState.markCompleted`). Playground
runs earn nothing, so nobody is pushed to hammer the shared code runner.

**A lesson earns XP at most once per local day.** Solving an exercise runs
the same check on every successful Run, and a lesson with an exercise and a
quiz is finished twice in one sitting. Without this, running a solved
exercise again would pay 5 XP a click and one lesson would pay twice. The
list of lessons that already paid today is kept on the device (preference
`xpAwardedToday`). So: the first finish pays 20; a finish of the same lesson
on a later day pays 5; further finishes the same day pay nothing. This is
the one place that narrows the plain "+5 for every review".

Feedback: the quiz summary shows a "+20 XP" chip (a snack bar for lessons
that end the moment they are finished), and a short positive line the first
time that day the goal is reached. Nothing is shown when a finish pays
nothing.

## The activity log and what is derived from it

The only thing stored is a map from a local day (`yyyy-MM-dd`, the device's
calendar date) to the XP earned that day, `dailyXp`. The current streak,
the longest streak, freezes held, total XP and today's XP are all computed
from that map by `summarizeStreak(log, today)`. "Today" is a parameter (the
clock is injected), nothing derived is saved, and two devices that merge
their maps therefore always show the same numbers.

Day arithmetic uses plain dates (converted to a day count in UTC), never
24-hour differences, so a daylight saving change cannot lose or invent a
day.

**Streak.** A day is active when it has more than 0 XP. Walking the active
days from the oldest:

- the next active day follows directly: the streak grows by one;
- days were missed in between: each missed day uses one held freeze; if
  there are enough freezes the streak goes on (the frozen days do not add to
  the count), otherwise it ends, the freezes are gone, and the next active
  day starts a new streak at 1;
- every 7th active day of a streak earns one freeze, at most 2 held.

**Today not being done yet breaks nothing.** The days between the last active
day and today (not counting today) are treated like any other gap: a held
freeze covers them, without one the current streak is 0. This is slightly
wider than "alive when the last active day is today or yesterday" and is a
deliberate choice. Otherwise a learner holding a freeze would see a streak
of 0 after missing a day, and then see it jump back when they return, even
though the history says it never broke. With no freeze the two readings are
the same.

**Longest streak** is the highest count any streak reached, the current one
included. **Total XP** is every valid entry, including days dated after
today (XP earned is XP). Days dated after today (a clock that was set wrong)
and keys that are not real dates never count for a streak; entries with a
bad key, a zero or negative value, a non-number value or an implausible
value (over 100,000) are dropped when the map is read.

## Ages

The birth year from the age screen decides (`AgeGroup`; unknown = none yet).

| | under 13 | 13 to 17 | 18+ | unknown |
| --- | --- | --- | --- | --- |
| XP, goal, streak, freezes on the device | yes | yes | yes | yes |
| Cloud sync of the XP | **no** (same as everything else: no accounts) | yes | yes | yes |
| Reminders on by default | no | no | no | no |
| One-time "Want a daily reminder?" card | **never** | yes | yes | **never** |
| Switch reminders on in Progress | yes, themselves | yes | yes | yes |
| Calm "finish a lesson today" line on Home | no | yes | yes | no |

- Reminders are **off for everyone** until the learner switches them on.
- An under-13 never sees an in-app prompt or card suggesting reminders (the
  card's visibility is computed from the current age every time, so a card
  that was pending disappears if the age becomes under 13, and it is never
  shown while the age is unknown). They can still turn reminders on
  themselves in Progress.
- **No streak-loss pressure for anyone**: no "your streak is about to die",
  no warnings about losing it, no guilt. The reminder text is the same,
  neutral sentence for every age ("Time for a little Rust? Your next lesson
  is ready."). For a possible under-13 there is additionally no hint about
  today at all; the card only shows what they have. A test checks that
  none of the words about loss appear in the Home screen or the
  notification.
- The one-time card appears after the first completed lesson, once. Either
  button ends it for good, and so does switching reminders on another way.
  (If a learner's first lesson was finished on another device, the card
  still appears once on this one; the answer is device-only.)

## Reminders

Settings (on or off, time, whether the card was answered) are stored on the
device only and are never synced. The goal is a device setting too.

**Scheduling.** `planReminders` produces one-shot notifications at the
chosen time on each of the next 7 days, today included. Today is skipped if
today's goal is met or the time has already passed, so there are 7
reminders, or 6 when today is skipped. The plan is made again, cancelling
what was waiting first, whenever:

- the app starts (`main`), and when it comes back to the foreground;
- the learner earns XP (reaching the goal drops today's reminder);
- the goal, the time or the on/off switch changes, or sign-in finishes.

So the schedule always starts from "now" and never doubles up, and
**reminders stop by themselves after about a week without opening the app**:
nothing repeats. Times are built from the calendar date and the wall-clock
time, so they stay at 19:00 across a daylight saving change; each is
converted to an absolute UTC moment for the plugin.

**Permission.** Nothing asks the system for permission until the learner
turns the switch on (or taps "Turn on" on the card), which is their own
action (Android 13+ asks for POST_NOTIFICATIONS at runtime; iOS shows its
prompt). If the system says no, the switch stays off and a sentence explains
that notifications must be allowed in the device settings. If the learner
later blocks notifications there, the next refresh notices, switches
reminders off, cancels them and says why.

**Sign-out.** Signing out (or deleting an adult's account) clears the device
for the next person, so it also resets the reminders: they are switched
off, cancelled and the time goes back to 19:00. Whether the one-time card was
answered is kept: it is never offered again on this device. The goal also
goes back to its default. Clearing the account keys does not wait for the
notification plugin. The system's notification
permission is the system's and stays as it is. A child who deletes their
account keeps their settings, like their progress.

**The web** has no scheduled notifications: the reminder controls are
hidden (`kIsWeb` and `ReminderScheduler.supported`) and the scheduler is a
no-op.

**Text.** `reminderText(StreakStrings)` is the single place a notification's
text is made; the scheduler runs outside any widget, so it is handed the
strings.

### Platform setup

- **Android** (`android/app/build.gradle.kts`, `AndroidManifest.xml`): core
  library desugaring with `desugar_jdk_libs` 2.1.4, `RECEIVE_BOOT_COMPLETED`,
  and the plugin's `ScheduledNotificationReceiver` and
  `ScheduledNotificationBootReceiver`. The plugin adds POST_NOTIFICATIONS
  itself. A `res/raw/keep.xml` stops resource shrinking from removing the
  `ic_stat_reminder` (a white bell on transparent, the notification's small
  icon) that the plugin looks up by name. **No** `SCHEDULE_EXACT_ALARM` or
  `USE_EXACT_ALARM`: reminders use `AndroidScheduleMode.inexactAllowWhileIdle`.
  A study reminder does not need the exact second, Android 14 denies the
  exact-alarm permission to new installs by default, and Google's advice is
  to use inexact timing when exact timing is not needed.
- **iOS** (`AppDelegate.swift`): the notification centre delegate, as the
  plugin README says. The prompt is deferred by turning all Darwin request
  flags off at initialization and calling `requestPermissions` later. At most 7
  notifications are pending, well under iOS's limit of 64. No Info.plist
  entry is needed for local notifications.
- **Why no `flutter_timezone`.** Because every reminder is a one-shot at an
  absolute moment (a local `DateTime` converted to UTC), no time zone database
  or "current zone" lookup is needed, so that dependency is left out. If
  reminders ever repeat (`matchDateTimeComponents`) it will be needed.

Not verified here: an Android or iOS build, and notifications on a real
device (this was developed without an Android SDK or Xcode). The Dart side
is tested with a fake scheduler.

## Sync

For signed-in learners whose age allows accounts only: exactly the same
gates as `completedLessons` (`accountsAllowed`, not during deletion, not for
an unconfirmed deletion). Under-13s keep everything on the device.

- Field `dailyXp` on `users/{uid}`: a map from day to XP.
- A change is written with a merge `set` of **only that day**:
  `{'dailyXp': {'2026-03-18': 40}, 'updatedAt': serverTimestamp}`. Firestore
  merges nested maps field by field, so other days are untouched (the
  emulator test "a merge write changes only the day it names" checks this).
- **Merge rule device + cloud: per day, the larger value. Never a sum**, so
  two devices cannot count the same XP twice. The price: XP earned on the
  same day on two devices that did not sync in between is undercounted (the
  larger device's share is kept). A later write of a lower value for a day
  can lower it in the cloud until the next merge restores the device's
  larger value; this is accepted.
- Days where the device is ahead of the cloud are uploaded by the merge. XP
  earned while a merge runs is remembered (as days still to send) and sent
  when the merge ends, and signing out waits for a merge in progress and for
  those days, so earned XP is not dropped by a slow or failed merge.
  While the device still holds another account's XP, the amounts earned are
  kept apart and added on top of the cloud's days once the merge succeeds
  (also after a failed merge and its retry); nothing of the other account
  is written in the meantime.
- Everything that applies to completed lessons applies to XP: a foreign
  account's XP left on the device is dropped (never uploaded) and the cloud's
  is loaded; XP earned during that merge is this account's and is added on
  top of the cloud's; sign-out and an adult's deletion clear it; a child
  keeps it on the device after the account is deleted; a failed deletion
  puts it back with the rest; a document that needs repair is rewritten in
  one write that includes it.
- Reading never trusts the shape: a `dailyXp` that is not a map makes the
  document "needs repair" (the rules would refuse writes to it until it is
  rewritten); single bad days inside a map are ignored when reading (the
  rules cannot loop over a map, so they only check type and size).
- `firestore.rules`: `dailyXp` is allowed, must be a map, at most 4000
  entries (about 11 years of days). After that, writes would be refused; a
  learner would need to be active for 11 years to get there, and the
  streak and totals on the device keep working.
- **Rollout.** Deploy the rules before a build that writes `dailyXp`. A
  *older* app build that still treats `dailyXp` as an unknown field would
  think the document needs repair and rewrite it without the XP, so release
  this before such a build is in the wild (the app is not published yet).

## Strings

A parallel change adds Flutter gen-l10n, but it was not on `main` when this
was written, so all the new text lives in one class,
`lib/l10n/streak_strings.dart`. Moving it into the ARB files later means
turning each member into a key; the notification text already goes through
one function that takes a `StreakStrings`.

## Tests

- `test/streaks_test.dart`: the pure functions (gaps, freezes, month, leap
  day, year and daylight saving boundaries, empty log, future days,
  malformed keys, merging).
- `test/xp_state_test.dart`: earning, once a day, the goal, sync, merge by
  day maximum, another account's data, sign-out, deletion, children.
- `test/reminders_test.dart`: the plan, the settings with a fake scheduler
  and a fake clock (7 reminders, today skipped, cancel when off, permission
  denied or revoked, serialization), the one-time card for each age group,
  and the screens.
- `test/firestore_rules/rules.test.mjs`: the `dailyXp` rules and the merge
  behaviour, against the emulator (`test/firestore_rules/run.sh`).

## Sources

- Android notification permission (13+, runtime, ask in context after the
  user knows the app, tied to a user action):
  <https://developer.android.com/develop/ui/views/notifications/notification-permission>
- Android 14 exact alarms (denied by default for new installs; use inexact
  when exact timing is not needed):
  <https://developer.android.com/about/versions/14/changes/schedule-exact-alarms>
- flutter_local_notifications (setup, desugaring, receivers, deferring the
  iOS prompt, no scheduled notifications on the web):
  <https://pub.dev/packages/flutter_local_notifications>
- Apple App Store Review Guideline 4.5.4 (push must not be required; opt-in
  and an in-app way to opt out): <https://developer.apple.com/app-store/review/guidelines/#4.5.4>
- UK ICO Children's Code, standard 13 "nudge techniques" (no nudges that
  exploit psychological processes, nudges toward wellbeing are fine; age
  bands up to 17):
  <https://ico.org.uk/for-organisations/uk-gdpr-guidance-and-resources/childrens-information/childrens-code-guidance-and-resources/age-appropriate-design-a-code-of-practice-for-online-services/13-nudge-techniques/>
- Google Play Families policy:
  <https://support.google.com/googleplay/android-developer/answer/9893335>
- Duolingo on streak freezes reducing streak loss (up to 2 held):
  <https://blog.duolingo.com/how-duolingo-streak-builds-habit>
