#!/bin/sh
# Xcode build phase: fails a Release build that would ship Google's TEST
# AdMob app id or the placeholder ad report address (App Store guideline
# 2.5.18 needs a real way to report ads). Pass the real values (see
# docs/ads-and-purchases.md), or --dart-define=ALLOW_TEST_ADS_IN_RELEASE=true
# for a deliberate test build.
#
# DART_DEFINES comes from Flutter's Generated.xcconfig: comma-separated,
# each entry base64 of KEY=VALUE. ADMOB_APP_ID_IOS comes from AdMob.xcconfig.

[ "$CONFIGURATION" = "Release" ] || exit 0

defines=$(printf '%s\n' "$DART_DEFINES" | tr ',' '\n' | while read -r d; do
  [ -n "$d" ] && printf '%s' "$d" | base64 --decode 2>/dev/null
  echo
done)

value() { printf '%s\n' "$defines" | sed -n "s/^$1=//p" | tail -n 1; }

[ "$(value ALLOW_TEST_ADS_IN_RELEASE)" = "true" ] && exit 0

failed=0
if [ "$ADMOB_APP_ID_IOS" = "ca-app-pub-3940256099942544~1458002511" ]; then
  echo "error: Release build with the AdMob TEST app id. Put the real id in ios/Flutter/AdMob.xcconfig (see docs/ads-and-purchases.md)."
  failed=1
fi
email=$(value AD_REPORT_EMAIL)
if [ -z "$(value AD_REPORT_URL)" ] &&
  { [ -z "$email" ] || [ "$email" = "ads-report@example.com" ]; }; then
  echo "error: Release build without a real ad report address. Pass AD_REPORT_EMAIL or AD_REPORT_URL (see docs/ads-and-purchases.md)."
  failed=1
fi
exit $failed
