#!/usr/bin/env sh
# Tests firestore.rules against the Firestore emulator.
# Needs Node 18+ and Java 11+. The first run downloads the emulator.
#
# npm packages are installed in a cache folder outside the repository, so
# node_modules never lands in the Dart project (flutter analyze would scan
# it).
set -e
here="$(cd "$(dirname "$0")" && pwd)"
work="${RULES_TEST_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/rust-learn-rules-test}"
mkdir -p "$work"
cp "$here/package.json" "$here/firebase.json" "$here/rules.test.mjs" "$work/"
cd "$work"
npm install --no-audit --no-fund --silent
RULES_FILE="$here/../../firestore.rules" \
  npx firebase emulators:exec --only firestore --project demo-rust-learn "node rules.test.mjs"
