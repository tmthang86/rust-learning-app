# Ads, consent and "Remove ads"

How the app shows ads, asks for consent, handles age, and sells the one-time
"Remove ads" purchase, plus the setup Thang needs to do in AdMob, Play Console
and App Store Connect before release.

Background research: `/mnt/project-files/research/2026-10-18-decisions.md`,
sections 5 to 7.

## What the app does

| | Android / iOS | Web |
|---|---|---|
| Banner ads | Small inline adaptive banner on the course map (after the first unit) and in the reading part of a lesson | None |
| Interstitial | Only after finishing a lesson (passing its quiz, or "Mark as done") | None |
| Rewarded ads | None | None |
| Consent | Google UMP (GDPR, US states, IDFA explainer on iOS) | Not needed (no ads) |
| Age screen | Birth year on first launch | Same (the age is also kept for later features) |
| "Remove ads" | One non-consumable product, `remove_ads`, with Buy and Restore buttons on the Progress screen | No purchase UI |

Lessons, quizzes and code runs never depend on ads. Nothing in the app links to
an outside payment page.

### When ads load

`Monetization.adsEnabled` (lib/monetization/monetization.dart) is true only if
**all** of these hold:

1. the platform has an ad service (Android or iOS);
2. "Remove ads" is not owned on this device;
3. a birth year was given and the person can't be under 13;
4. UMP's `canRequestAds()` is true.

If "Remove ads" is owned, or the person may be under 13, the app never starts
UMP or the ad SDK at all. No consent form appears and no ad request is made.

### Where banners go, and where they never go

`AdPlacement` lists the only two places a banner can appear: `courseMap` and
`lessonReading`. The code editor, the run output, the Playground and the quiz
screens have no banner slot. Tests check this.

In a lesson, the banner goes after the first section, and only when at least
one more reading section follows. Reading text therefore always separates the
ad from the exercise editor further down. A lesson with a single section gets
no banner.

Each banner has 24 px of space above and below and an "Advertisement" label.
It is inline in the scrolling content, not anchored above the navigation bar.
Google warns against placing ads next to navigation or other tappable controls
(https://support.google.com/admob/answer/6275345).

The banner uses `AdSize.getInlineAdaptiveBannerAdSize(width, 100)`, so it is at
most 100 px tall.

### Interstitial rules

- It is shown only at a natural break: just after the learner finishes a lesson
  and leaves it.
- It is never shown for the first lesson of the first session.
- It is shown at most once every `Monetization.interstitialMinInterval` (5
  minutes). The time of the last one is saved, so restarting the app doesn't
  reset the cap.
- It is preloaded after consent, so it never delays navigation. If none is
  ready, nothing is shown and nothing is recorded.
- **Also set an AdMob frequency cap** on the interstitial unit as a second
  limit. See the setup steps below.

### Age (target audience 13+)

On first launch, before the track question, the app asks "What year were you
born?". It is a neutral age screen:
- the field is empty, with no default year;
- it says nothing about age limits or what changes;
- it is not shown again, so a child can't go back and try another year.

These follow the FTC COPPA FAQ and the Google Play Families policy on neutral
age screens.

The year is stored only on the device (key `birthYear`). It is kept on
sign-out.

A birth year can't tell us whether this year's birthday has passed, so the app
uses the youngest age the year allows. Someone born in 2013 counts as under 13
for all of 2026.

| Age band | What happens |
|---|---|
| Possibly under 13 | **No ads at all.** UMP and the ad SDK are never started. |
| 13 to 17 | Ads with the `teen` age treatment and a maximum content rating of PG. UMP gets `tagForUnderAgeOfConsent: true` below 16, since EU countries set the digital age of consent between 13 and 16. |
| 18 and over | Ads with no age treatment and a maximum content rating of PG. |

**Why no ads for under-13s, rather than child-directed ads.** This is the
safer of the two options in the brief:
- **Google Play Families policy.** Ad SDKs that serve children must be
  self-certified, and the advertising ID must not be sent for children
  (https://support.google.com/googleplay/android-developer/answer/9893335).
- **COPPA.** The amended Rule covers "mixed audience" services, with
  compliance due by 22 Apr 2026
  (https://www.federalregister.gov/documents/2025/04/22/2025-05904/childrens-online-privacy-protection-rule).
- **Apple.** Its Kids rules effectively ban third-party ads (guidelines 1.3
  and 5.1.4).

Not starting the SDK means no ad request and no device ID ever leave the device
for these users. The `child` treatment and a G rating are still defined in
`AdAudience.forAge` as a second line of defence. They are not used today.

The age settings use google_mobile_ads 9.1.0's `ageRestrictedTreatment`. It
replaces the deprecated child-directed (TFCD) and under-age-of-consent (TFUA)
tags and adds a teen tier. Sources:
- `RequestConfiguration` in the package source;
- https://support.google.com/admob/answer/6219315;
- https://ppc.land/googles-new-tfat-signal-kills-tfcd-and-tfua-and-finally-adds-a-teen-tier/.

### Consent flow (mobile)

On each launch where ads are allowed (see the conditions above), the app does
the following, without blocking the UI:

1. `ConsentInformation.requestConsentInfoUpdate(...)`;
2. `ConsentForm.loadAndShowConsentFormIfRequired(...)`;
3. `canRequestAds()`. Only when this is true does the app set the age settings
   with `MobileAds.updateRequestConfiguration`, call `MobileAds.initialize()`,
   and load ads.

Progress → **Privacy options** appears when
`getPrivacyOptionsRequirementStatus()` is `required`. It opens
`ConsentForm.showPrivacyOptionsForm`. If the person withdraws consent there,
ads stop.

**iOS ATT.** The app never calls the ATT prompt itself. UMP shows Google's
IDFA explainer message and then Apple's ATT prompt, once the IDFA message is
set up in AdMob (step 3 below). `NSUserTrackingUsageDescription` is in
Info.plist. Ads still work if the person declines tracking.

To test the consent messages on a device in a debug build, run with
`--dart-define=UMP_DEBUG_GEOGRAPHY=eea` (or `us_state`). Add
`--dart-define=UMP_TEST_DEVICE_ID=<hashed id>`, using the hashed id that the
UMP SDK prints in the device log.

### "Remove ads" purchase

The app uses the official `in_app_purchase` package (3.3.1). That is StoreKit 2
on iOS and Play Billing Library 8 on Android. The logic is in
`lib/monetization/purchase_controller.dart`:

- **Granted on purchased or restored.** When the store reports `remove_ads` as
  `purchased` or `restored`, the entitlement is saved on the device (key
  `removeAdsEntitled`) and ads stop at once.
- **Pending purchases are never granted or completed.** Examples are cash
  payments on Play and Ask to Buy on iOS. The card says the purchase is
  pending.
- **Every update that needs it is completed.** `completePurchase` is called
  for every update with `pendingCompletePurchase`, including errors,
  cancellations and unknown products. Without it, Google Play refunds the
  purchase after 3 days and the App Store keeps re-delivering it
  (in_app_purchase README).
- **Errors and cancellations are shown on the card.**
- **Restore purchases is a visible button**, as App Store guideline 3.1.1
  requires. On Android the app also restores quietly at start, because Play's
  purchase query is silent. On iOS restore only runs from the button, because
  it may ask for an Apple ID password. Unfinished App Store transactions are
  re-delivered automatically at launch anyway.
- **A pending Play purchase from restore stays pending.**
  in_app_purchase_android 0.5.4 marks every purchase that
  `restorePurchases()` returns as `restored`, even one still waiting for
  payment (see `restorePurchases` and `GooglePlayPurchaseDetails` in its
  source). The app maps that back to pending and doesn't grant it.

**No server verification at launch: the trade-off.** Verifying receipts on a
server needs a Cloud Function, and Cloud Functions need Firebase's Blaze plan.
For now `TrustDeviceVerifier` accepts the store's on-device result. The risks:
- someone on a tampered or rooted device could fake a purchase and get no ads
  for free;
- a refund isn't noticed, so ads stay off after a refund;
- the entitlement is tied to the device and store account, not to the Firebase
  account, so it doesn't follow a sign-in on the web (the web has no ads
  anyway).

For a one-time "Remove ads" item these risks are small.

**Seam for adding it later.** Implement `PurchaseVerifier`
(lib/monetization/purchase_service.dart). It should send
`StorePurchase.serverVerificationData` to a function that checks it:
- Play: the Play Developer API `purchases.products.get`;
- iOS: the App Store Server API.

Then pass it as `PurchaseController(verifier: ...)` in `lib/main.dart`. That
function can also write `entitlements.removeAds` to the user's Firestore
document, so the purchase follows the account.

### Code map

```
lib/monetization/
  monetization.dart          Monetization: the ads/consent/age rules, interstitial cap, MonetizationScope
  purchase_controller.dart   PurchaseController: buy/restore/pending/error/cancel, entitlement
  ads_service.dart           AdsService interface, AdPlacement, AdAudience, NoAdsService
  consent_service.dart       ConsentService interface, NoConsentService
  purchase_service.dart      PurchaseService interface, StorePurchase, PurchaseVerifier
  ad_banner.dart             AdBannerSlot (placed in screens), AdFrame
  ad_config.dart             ad unit ids (test ids by default, --dart-define for real ones)
  age.dart                   AgeGroup, ageGroupFor
  platform_services.dart     conditional import: _io (Android/iOS) or _stub (web)
  google_ads.dart            google_mobile_ads + UMP implementation (mobile only)
  store_purchases.dart       in_app_purchase implementation (mobile only)
lib/features/onboarding/age_screen.dart
lib/features/progress/monetization_widgets.dart   RemoveAdsCard, PrivacyOptionsTile
test/monetization_test.dart, fakes in test/fakes.dart (FakeAds, FakeConsent, FakeStore)
```

`google_mobile_ads` and `in_app_purchase` both import `dart:io`. They are
reached only through `platform_services.dart`, which uses a conditional import
(`if (dart.library.io)`), so the web build never includes them. `flutter build
web` passes, and the compiled `main.dart.js` contains no reference to either
package.

## Ids to replace before release

Every default is one of Google's public **test** ids. Real ads never show until
you replace them.

| What | Where | Default (test) |
|---|---|---|
| Android AdMob app id | `--dart-define=ADMOB_APP_ID_ANDROID=ca-app-pub-…~…` (read by `android/app/build.gradle.kts` into AndroidManifest.xml) | `ca-app-pub-3940256099942544~3347511713` |
| iOS AdMob app id | `ios/Flutter/AdMob.xcconfig` (`ADMOB_APP_ID_IOS = …`) | `ca-app-pub-3940256099942544~1458002511` |
| Android banner unit | `--dart-define=ADMOB_BANNER_ANDROID=ca-app-pub-…/…` | `ca-app-pub-3940256099942544/9214589741` |
| Android interstitial unit | `--dart-define=ADMOB_INTERSTITIAL_ANDROID=…` | `ca-app-pub-3940256099942544/1033173712` |
| iOS banner unit | `--dart-define=ADMOB_BANNER_IOS=…` | `ca-app-pub-3940256099942544/2435281174` |
| iOS interstitial unit | `--dart-define=ADMOB_INTERSTITIAL_IOS=…` | `ca-app-pub-3940256099942544/4411468910` |
| Product id | both stores: `remove_ads` | — |

The test ids come from the google_mobile_ads 9.1.0 example app in the pub
cache, which matches Google's test-ads page. Release build example:

```sh
flutter build appbundle --release \
  --dart-define=ADMOB_APP_ID_ANDROID=ca-app-pub-1111111111111111~2222222222 \
  --dart-define=ADMOB_BANNER_ANDROID=ca-app-pub-1111111111111111/3333333333 \
  --dart-define=ADMOB_INTERSTITIAL_ANDROID=ca-app-pub-1111111111111111/4444444444

# iOS: first put the real app id in ios/Flutter/AdMob.xcconfig
flutter build ipa --release \
  --dart-define=ADMOB_BANNER_IOS=ca-app-pub-1111111111111111/5555555555 \
  --dart-define=ADMOB_INTERSTITIAL_IOS=ca-app-pub-1111111111111111/6666666666
```

Keep the app id and the unit ids from the same AdMob app. If the app id is
still the test id but the unit ids are real (or the other way round), ads fail
to load. Never tap live ads on your own devices. Add your devices as test
devices in AdMob instead.

## Setup steps for Thang

### 1. AdMob app and ad units
1. AdMob → Apps → Add app. Do this once for Android and once for iOS. Link
   each app to its store listing once the app is published.
2. For each app, create two ad units:
   - **Banner** (adaptive; it is used as an inline adaptive banner), e.g.
     "Reading banner";
   - **Interstitial**, e.g. "Lesson finished". Use only display (image/text)
     ad types if you want to avoid video.
3. Copy the app ids and unit ids into the places in the table above.
4. **Blocking controls** → content rating: set the maximum ad content rating
   to PG as well, to match the code. Block sensitive categories you don't
   want, such as dating and gambling.

### 2. Frequency cap (interstitial)
AdMob → Apps → [app] → Ad units → the interstitial → Advanced settings →
**Frequency capping**: **1 impression per 5 minutes** per user. Optionally add
a daily cap, such as 10 per day.

This matches `Monetization.interstitialMinInterval`. AdMob supports per-unit
frequency caps (https://support.google.com/admob/answer/9341964).

### 3. Privacy & messaging (UMP)
AdMob → **Privacy & messaging**:
1. **European regulations (GDPR)**: create and publish a message for both
   apps. It covers the EEA, the UK and Switzerland. A Google-certified CMP is
   required to serve ads there (https://support.google.com/admob/answer/13554020).
   Add the privacy policy URL, and choose "Close (do not consent)" and "Manage
   options" as you see fit.
2. **US state regulations**: create and publish a message. It covers states
   such as California, Virginia and Colorado. GPC signals trigger restricted
   data processing in some states
   (https://support.google.com/admob/answer/9561022).
3. **IDFA explainer (iOS only)**: create and publish it for the iOS app. UMP
   then shows it, followed by Apple's ATT prompt, during the consent flow
   (https://developers.google.com/admob/flutter/privacy/idfa). The app's
   `NSUserTrackingUsageDescription` text is "This identifier will be used to
   deliver personalized ads to you." Edit it in `ios/Runner/Info.plist` if
   you want.

Messages must be **published** to take effect. Test them with the
`UMP_DEBUG_GEOGRAPHY` dart-define described above.

### 4. app-ads.txt
AdMob verifies that you own the app through an `app-ads.txt` file on your
developer website (https://support.google.com/admob/answer/9363762):
1. Put the developer website URL in the Play listing (Store presence → Store
   listing → Contact details) and in the App Store listing (Marketing URL or
   Support URL).
2. Publish `https://<that domain>/app-ads.txt` containing the line AdMob
   shows you (Apps → app-ads.txt). It looks like this:
   `google.com, pub-XXXXXXXXXXXXXXXX, DIRECT, f08c47fec0942fa0`.
   Firebase Hosting works if your host can't serve a root file.
3. Wait up to 24 hours, then check the status in AdMob.

### 5. The `remove_ads` product
- **Google Play Console**: Monetize with Play → Products → **One-time
  products** → Create product. Use product ID `remove_ads`, name "Remove ads",
  set a price, and activate it. Upload a build with the billing library first
  (an internal testing track is enough). Add license testers under Settings →
  License testing to test without being charged.
- **App Store Connect**: [app] → Monetization → In-App Purchases → **+** →
  type **Non-Consumable**. Use reference name "Remove ads", product ID
  `remove_ads`, a price, and a localized display name and description. Add a
  review screenshot of the Progress screen's "Remove ads" card, then submit it
  with the app version. Accept the Paid Apps agreement first. Test with a
  Sandbox account (Users and Access → Sandbox) or a StoreKit configuration
  file in Xcode.
- The App Store reviewer will look for the **Restore purchases** button on the
  Progress screen.

### 6. Store privacy forms
Fill these in using Google's disclosure pages. The categories below are a
summary from the research notes; check the pages themselves before you submit:
- **App Store privacy labels**
  (https://developers.google.com/admob/ios/privacy/data-disclosure): the
  Google Mobile Ads SDK collects device identifiers, usage data such as
  product interaction and advertising data, diagnostics, and coarse location
  derived from the IP address. These are used for third-party advertising and
  analytics, and are linked to the user where tracking is allowed. Mark
  "Used to track you" for the IDFA, since the app asks for ATT. The SDK
  (11.2.0 and later) ships its own privacy manifest. Firebase sign-in data is
  covered separately in [firebase-setup.md](firebase-setup.md).
- **Google Play Data safety**
  (https://developers.google.com/admob/android/privacy/play-data-disclosure):
  device or other IDs (advertising ID), approximate location from the IP
  address, app interactions, and crash logs and diagnostics. These are
  collected and shared for advertising and analytics, and encrypted in
  transit. The `remove_ads` purchase is handled by Google Play, and the app
  sends no purchase history to its own servers.
- **Target audience** (Play Console → App content → Target audience and
  content): choose **13 and over** only. Don't tick any under-13 age group.
  That would put the app under the Families policy, which needs certified ad
  SDKs and changes the ad rules. In App Store Connect, don't choose the Kids
  category. An age rating around 12+ fits.
- **Ads declaration** (Play Console → App content → Ads): **Yes, my app
  contains ads**.
- **Texas SB 2420**: check its status before launch (see research section 6).

## What was not verified here

This work was done in a Linux container with no Android SDK, no Xcode, no
devices and no store accounts. So:

- **No Android or iOS build was run.** `flutter analyze`, `flutter test` and
  `flutter build web` pass. These are untested:
  - the Gradle change that reads dart-defines into the manifest (its
    decoding code was run on its own with Gradle and gave the right value,
    but not inside a real Android build);
  - the iOS xcconfig and Info.plist entries;
  - plugin registration on device.
- **No real ad was loaded and no consent form was seen.** The google_mobile_ads
  and UMP code (`google_ads.dart`) follows the 9.1.0 package source and its
  example app. Widget tests cover only the rules, through fakes. Not checked
  on a device:
  - inline adaptive sizing and reloading on rotation;
  - interstitial callbacks;
  - UMP's behaviour with `tagForUnderAgeOfConsent` (whether `canRequestAds`
    becomes true without a form).
- **No real purchase was made.** `store_purchases.dart` follows the
  in_app_purchase 3.3.1 source and README. Not tried against Play or App
  Store sandboxes:
  - buying, pending, refund and restore;
  - the Android pending-on-restore mapping.
- **Google's developer sites were blocked from this container**
  (developers.google.com, developers.google.cn), so their pages could not be
  opened. API details come from the package source in `~/.pub-cache` instead.
  The SKAdNetwork list (50 ids) was copied from Google's official iOS sample
  `googleads-mobile-ios-examples` (Swift/admob/BannerExample/Info.plist on
  GitHub). Compare it with
  https://developers.google.com/admob/ios/quick-start#update_your_infoplist
  before release, because Google updates the list over time. Other policy
  points come from search extracts and the earlier research notes, cited
  inline.
- **The privacy-label categories above are not taken from Google's current
  pages**, which couldn't be opened.
- **None of this is legal advice.** The age handling follows public guidance,
  but COPPA, GDPR-K and state laws are legal questions.
