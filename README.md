# Learn Rust

A Rust learning app for iOS, Android, iPad/tablets and the web, built with Flutter.
It serves both people new to programming and developers coming from another
language, lets learners run real Rust code in the app, and is funded by ads
with a one-time "Remove ads" purchase.

## Plan

1. **Foundation and design** (this step): Flutter project, course map, main screens.
2. **Code runner backend**: a sandboxed server that compiles and runs Rust.
3. **Core app and first content**: editor wired to the runner, accounts and sync, first full module.
4. **Ads, purchase and launch**: AdMob (mobile), AdSense (web), "Remove ads" purchase, store release.

See [docs/course-map.md](docs/course-map.md) for the course outline and lesson format.

## Project layout

```
lib/
  app/        theme, routing, responsive navigation shell
  data/       models, content loading, app state and progress
  runner/     CodeRunner interface (placeholder until step 2)
  features/   onboarding, home, lesson, editor/playground, quiz, progress
assets/content/
  course.json         units and lesson list
  lessons/<id>.json   lesson content
```

## Running

```sh
flutter pub get
flutter run -d chrome     # or an iOS/Android simulator
flutter test
```
