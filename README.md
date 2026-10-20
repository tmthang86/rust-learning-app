# Learn Rust

A Rust learning app for iOS, Android, iPad/tablets and the web, built with Flutter.
It serves both people new to programming and developers coming from another
language, lets learners run real Rust code in the app, and is funded by ads
with a one-time "Remove ads" purchase.

## Plan

1. **Foundation and design** (done): Flutter project, course map, main screens.
2. **Code runner backend** (done): sandboxed server in [`runner/`](runner/README.md) that compiles and runs Rust.
3. **Core app and first content** (in progress): Units 0 to 12 written (58 lessons, every example and exercise checked by the compiler); Google/Apple sign-in and progress sync via Firebase, off until a Firebase project is connected ([setup](docs/firebase-setup.md)).
4. **Ads, purchase and launch** (in progress): AdMob banners and a capped interstitial on Android and iOS with Google's consent (UMP), a neutral first-launch age screen (no ads and no accounts for under-13s, child-treated, G-rated ads for 13–17), a "Report an ad" entry for App Store guideline 2.5.18, and a one-time "Remove ads" purchase with Restore, all using Google test ids until real ones are passed ([setup](docs/ads-and-purchases.md)). The web launches ad-free. Still to do: AdMob/store setup, device testing, store release.

Continuous integration (what runs on every push, and how to run it locally): [docs/ci.md](docs/ci.md).

See [docs/course-map.md](docs/course-map.md) for the course outline and lesson format.

## Project layout

```
lib/
  app/        theme, routing, responsive navigation shell
  data/       models, content loading, app state and progress, age band
  runner/     CodeRunner: talks to the runner service
  monetization/ ads, consent (UMP), ad reports, "Remove ads" purchase
  features/   onboarding (age, track), home, lesson, editor/playground, quiz, progress
assets/content/
  course.json         units and lesson list
  lessons/<id>.json   lesson content
tool/check_lessons.py compiles every lesson example and checks exercise solutions
```

## Running

```sh
flutter pub get
flutter run -d chrome --dart-define=RUNNER_URL=http://localhost:8080
flutter test
```

Without `RUNNER_URL` the app works but the Run button explains that running
code isn't set up. See [runner/README.md](runner/README.md) to start the runner.
