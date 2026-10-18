# Learn Rust

A Rust learning app for iOS, Android, iPad/tablets and the web, built with Flutter.
It serves both people new to programming and developers coming from another
language, lets learners run real Rust code in the app, and is funded by ads
with a one-time "Remove ads" purchase.

## Plan

1. **Foundation and design** (done): Flutter project, course map, main screens.
2. **Code runner backend** (done): sandboxed server in [`runner/`](runner/README.md) that compiles and runs Rust.
3. **Core app and first content** (in progress): Units 0 to 6 written (32 lessons, every example and exercise checked by the compiler); Google/Apple sign-in and progress sync via Firebase, off until a Firebase project is connected ([setup](docs/firebase-setup.md)).
4. **Ads, purchase and launch**: AdMob (mobile), AdSense (web), "Remove ads" purchase, store release.

See [docs/course-map.md](docs/course-map.md) for the course outline and lesson format.

## Project layout

```
lib/
  app/        theme, routing, responsive navigation shell
  data/       models, content loading, app state and progress
  runner/     CodeRunner: talks to the runner service
  features/   onboarding, home, lesson, editor/playground, quiz, progress
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
