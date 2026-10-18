# Ads, consent and "Remove ads"

How the app shows ads, asks for consent, handles age, and sells the one-time
"Remove ads" purchase, plus the setup Thang needs to do in AdMob, Play Console
and App Store Connect before release.

Background research: `/mnt/project-files/research/2026-10-18-decisions.md`,
sections 5 to 7.

## What the app does

| | Android / iOS | Web |
|---|---|---|
| Banner ads | Small inline adaptive banner on the course map (after the last unit) and in the reading part of a lesson | None |
| Interstitial | Only after the first finish of a lesson (its first quiz pass, or "Mark as done") | None |
| Rewarded ads | None | None |
| Consent | Google UMP (GDPR, US states, IDFA explainer on iOS); the form is shown to adults only | Not needed (no ads) |
| Age screen | Birth year on first launch | Same: it also decides whether accounts are allowed (no accounts under 13) |
| Report an ad | "Report an ad" on Progress while ads are on | None |
| "Remove ads" | One non-consumable product, `remove_ads`, with Buy and Restore buttons on the Progress screen | No purchase UI |

Lessons, quizzes and code runs never depend on ads. Nothing in the app links to
an outside payment page.

### When ads load

`Monetization.adsEnabled` (lib/monetization/monetization.dart) is true only if
**all** of these hold:

1. the platform has an ad service (Android or iOS);
2. "Remove ads" is not owned on this device;
3. a birth year was given and the person can't be under 13;
4. UMP's `canRequestAds()` is true;
5. `MobileAds.initialize()` has finished (eligibility is checked again
   afterwards, in case "Remove ads" was bought meanwhile).

If "Remove ads" is owned, or the person may be under 13, the app never starts
UMP or the ad SDK at all. No consent form appears and no ad request is made.

At start the app first waits, for at most 3 seconds
(`PurchaseController.quietRestoreWait`), for a silent restore of "Remove
ads" (see below). Someone who already paid on a new phone then never sees
the consent form or an ad. If the store is slow, ads start after the wait and
stop as soon as the restore arrives.

The Progress screen shows the "Remove ads" card only when the person would
see ads (Android or iOS, and old enough for ads), or as "Ads removed" when
they already own it. Under-13s and web users never see the offer.

### Where banners go, and where they never go

`AdPlacement` lists the only two places a banner can appear: `courseMap` and
`lessonReading`. The code editor, the run output, the Playground and the quiz
screens have no banner slot. Tests check this.

In a lesson, the banner goes after the first section, and only when at least
one more reading section follows. Reading text therefore always separates the
ad from the exercise editor further down. A lesson with a single section gets
no banner.

On the course map the banner goes after the last unit, so it never sits
between units the learner is scrolling through.

Each banner has 24 px of space above and below and an "Advertisement" label,
with nothing tappable next to it. It is inline in the scrolling content, not
anchored above the navigation bar. Google warns against placing ads next to
navigation or other tappable controls
(https://support.google.com/admob/answer/6275345). If the real size of a loaded
banner can't be read, it is shown at the slot's full 60 px.

The slot always reserves a fixed 60 px (`AdBannerSlot.adHeight`) before the ad
loads, and keeps it if the ad fails, so the text never jumps. The banner uses
`AdSize.getInlineAdaptiveBannerAdSize(width, 60)` and is clamped to that
height. The slot is kept alive while scrolled off screen, so scrolling a
lesson doesn't request a new banner.

### Interstitial rules

- It is shown only at a natural break: just after the learner passes a
  lesson's quiz (or taps "Mark as done" in a lesson without quiz or exercise)
  and leaves it.
- Only the first such finish of each lesson counts. The lessons that already
  counted are saved (key `interstitialLessons`), so passing a quiz again,
  even after a restart, shows nothing. Solving a lesson's exercise
  completes the lesson but doesn't use up its finish, so the usual path
  (exercise, then quiz) still gets its break.
- It is never shown for the first lesson of the first session.
- It is shown at most once every `Monetization.interstitialMinInterval` (5
  minutes). The time is recorded only when an interstitial was actually
  shown (on `onAdShowedFullScreenContent` or the impression) and is saved,
  so restarting the app doesn't reset the cap.
- It is preloaded after consent, so it never delays navigation. If none is
  ready, nothing is shown and nothing is recorded. The app stops waiting for
  it after 10 seconds (`Monetization.interstitialShowTimeout`).
- If "Remove ads" is bought while one is loading, it is dropped when it
  arrives.
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

The year is stored only on the device (key `birthYear`, in `AgeStore`,
lib/data/age.dart). It is kept on sign-out. The age screen is also shown on
the web, because it decides whether accounts are allowed.

A birth year can't tell us whether this year's birthday has passed, so the app
uses the youngest age the year allows. Someone born in 2013 counts as under 13
for all of 2026.

| Age band | What happens |
|---|---|
| Possibly under 13 | **No ads at all**: UMP and the ad SDK are never started. **No account**: no sign-in and no cloud sync (see below). |
| 13 to 17 | Restricted ads: the `child` age treatment (no personalisation, child ad policies) and a maximum content rating of G. UMP gets `tagForUnderAgeOfConsent: true` and no consent form is shown. In the EEA they are expected to get Google's Limited Ads on top (see below). |
| 18 and over | Ads with no age treatment and a maximum content rating of PG. The UMP consent form is shown where required. |

`AdAudience.forAge` (lib/monetization/ads_service.dart) holds this mapping,
and `requestConfigurationFor` (lib/monetization/google_ads.dart) turns it into
the SDK's `RequestConfiguration`. Both are pure functions with tests.

**Why the child treatment for all under-18s.** Several rules treat 13 to 17
as minors whose data needs extra care:
- **New York Child Data Protection Act** (N.Y. Gen. Bus. Law art. 45-A, in
  force 20 Jun 2025) limits processing the personal data of users under 18
  without informed consent. Non-personalised child-treated ads avoid that
  processing.
- **EU digital age of consent** is 13 to 16 depending on the country, and the
  app can't tell which applies.
- **UMP.** The under-age-of-consent tag maps to the child treatment under
  the new age setting, so this keeps the two consistent.

Two different things are both called "limited" here:
- the **child treatment** is a per-request signal from the app
  (`RequestConfiguration`): no personalised ads, and Google's ad policies
  for children apply, everywhere;
- **Limited Ads** is Google's name for the serving mode used in the EEA, UK
  and Switzerland when there is no consent to store or read data on the
  device: no personal data, no device storage, fewer ad types
  (https://support.google.com/admob/answer/10105530).

**Expected for 13 to 17 in the EEA (not verified on a device).** With
`tagForUnderAgeOfConsent` set, UMP is expected to report the consent status
as `NOT_REQUIRED` without showing anything, so `canRequestAds()` is true,
and those users get Limited Ads with the child treatment and a G rating. If
it reports `REQUIRED` instead, `canRequestAds()` stays false and they simply
get no ads there; the app retries on each resume.

Device check before launch, in a debug build on Android and on iOS:
1. run with `--dart-define=UMP_DEBUG_GEOGRAPHY=eea` and
   `--dart-define=UMP_TEST_DEVICE_ID=<hashed id from the log>`;
2. answer the age screen with **2010** (a teen);
3. read the `UMP: underAgeOfConsent=true showForm=false status=…
   canRequestAds=…` line the app logs after the consent update. Expected:
   `status=ConsentStatus.notRequired canRequestAds=true`, and banners load;
4. repeat with 1990 to see the adult form for comparison.

Open question for iOS: if the IDFA explainer message is published in AdMob
but never shown (minors get no form), does UMP keep the status at
`REQUIRED`, which would mean no ads for minors on iOS in the EEA? Step 3
answers this on an iPhone.

**No accounts under 13.** Signing in would send the child's progress to a
cloud account, so `AppState.accountsAllowed` is false for the under-13 band:
- Progress shows "Your progress is saved on this device" instead of the
  account card, with no sign-in buttons.
- `AppState.signIn` refuses (`AccountErrorKind.ageRestricted`), and the
  cloud merge and background writes refuse too, all in AppState.
- The only exception is `/delete-account`: a child may sign in there only to
  delete an account. Nothing is synced or merged, and leaving the page
  without deleting signs them out again. Deleting keeps the progress on
  the device.
- Someone already signed in who answers under 13 (for example an install
  from before the age screen) is signed out on this device at once, keeping
  their progress on the device. Syncing stops. The account stays until they
  delete it, and Progress offers "Delete your account" prominently.
- If a child's sign-in on `/delete-account` creates a new account (Firebase
  `isNewUser`: there was no account for that sign-in), the app deletes that
  new account at once and says there was nothing to delete. If that fails,
  it signs out on the device and Progress offers deletion.

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

Not starting the SDK means no ad request and no device ID ever leave the
device for under-13s. `AdAudience.forAge` still maps under-13 to the child
treatment and G, as a second line of defence.

The age settings use google_mobile_ads 9.1.0's `ageRestrictedTreatment`. It
replaces the deprecated child-directed (TFCD) and under-age-of-consent (TFUA)
tags and adds a teen tier (not used: teens get the child treatment, see
above). Sources:
- `RequestConfiguration` in the package source;
- https://support.google.com/admob/answer/6219315;
- https://ppc.land/googles-new-tfat-signal-kills-tfcd-and-tfua-and-finally-adds-a-teen-tier/.

### Consent flow (mobile)

On each launch where ads are allowed (see the conditions above), the app does
the following, without blocking the UI:

1. `ConsentInformation.requestConsentInfoUpdate(...)`;
2. `ConsentForm.loadAndShowConsentFormIfRequired(...)`, for adults only;
3. `canRequestAds()`. Only when this is true does the app set the age settings
   with `MobileAds.updateRequestConfiguration`, call `MobileAds.initialize()`,
   and load ads.

Consent counts as gathered only when the update and the form succeeded and
`canRequestAds()` is true. Otherwise (offline, a form error, or no consent
yet) it is tried again when the app comes back to the foreground.

Consent and the ad SDK also wait for the start-up purchase check, even when
the age screen is answered while it runs, so someone who already paid never
sees either.

Progress → **Privacy options** appears when
`getPrivacyOptionsRequirementStatus()` is `required`. It opens
`ConsentForm.showPrivacyOptionsForm`. If the person withdraws consent there,
they get limited ads (non-personalised, served without the consented
identifiers), not none: in UMP, withdrawing GDPR consent still lets
`canRequestAds()` be true, and Google then serves limited ads
(https://support.google.com/admob/answer/10105530). Ads stop only if
`canRequestAds()` turns false.

**iOS ATT.** The app never calls the ATT prompt itself. UMP shows Google's
IDFA explainer message and then Apple's ATT prompt, once the IDFA message is
set up in AdMob (step 3 below), as part of its consent form.
`NSUserTrackingUsageDescription` is in Info.plist. Ads still work if the
person declines tracking.

Under-18s never get the UMP form (`showForm: false`), so the app never
leads them to the IDFA message or the ATT prompt. Whether UMP would also
suppress it on its own for `tagForUnderAgeOfConsent` users wasn't checked.

**App measurement waits.** The Google Mobile Ads SDK may bundle Google
Analytics for Firebase measurement (on Android it does; on iOS it may, since
GMA SDK 11 changed how it is linked). It is told to wait until the app
initializes the SDK, which happens only after consent and only for people old
enough for ads:
- Android: `<meta-data android:name="com.google.android.gms.ads.DELAY_APP_MEASUREMENT_INIT" android:value="true"/>`
  in AndroidManifest.xml;
- iOS: `GADDelayAppMeasurementInit` = YES in Info.plist.

The key names were checked against Google's own Unity plugin source
(googleads-mobile-unity on GitHub: `ManifestProcessor.cs` writes the Android
key and `PListProcessor.cs` writes the iOS key), because Google's developer
pages couldn't be opened from here.

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
  `removeAdsEntitled`) and ads stop at once. A purchase the verifier rejects
  is neither granted nor completed, so the store can refund it.
- **Pending purchases are never granted or completed.** Examples are cash
  payments on Play and Ask to Buy on iOS. The card says the purchase is
  pending.
- **Every update that needs it is completed.** `completePurchase` is called
  for every update with `pendingCompletePurchase`, including errors,
  cancellations and unknown products. Without it, Google Play refunds the
  purchase after 3 days and the App Store keeps re-delivering it
  (in_app_purchase README).
- **Android cancellations and billing errors arrive without a product id.**
  in_app_purchase_android 0.5.4 reports a cancelled purchase, and a billing
  error that came with no purchase, as an update with product id `''`
  (`_getPurchaseDetailsFromResult`). The app applies these to the purchase in
  progress. "Item already owned" runs a restore instead of showing an error.
- **Errors and cancellations are shown on the card in plain words**, such as
  "Purchase cancelled." or "Couldn't reach the store. Check your connection
  and try again." Billing codes are logged, not shown.
- **Restore purchases is a visible button**, as App Store guideline 3.1.1
  requires.
- **A silent restore runs at every start and every return to the
  foreground**, on Android and on iOS with StoreKit 2. Neither prompts:
  Play's purchase query is silent, and in_app_purchase_storekit 0.4.14's
  StoreKit 2 restore reads `Transaction.currentEntitlements` without a
  sign-in prompt. On Android this also runs when "Remove ads" is already
  owned, so a purchase that wasn't acknowledged yet (Play refunds those after
  3 days) is completed on the next start.
- **The Restore button** restores, and if nothing is found it calls
  `AppStore.sync()` (`InAppPurchaseStoreKitPlatformAddition().sync()`, which
  may ask for the Apple ID password) and restores once more. A restore waits
  only for updates that arrive after its own request, so an earlier update
  still being handled can't make it look empty (which would cause a second
  restore and a needless password prompt). A failed restore says "Couldn't
  check for earlier purchases", not that a purchase failed.
- **Store availability is checked again** when Progress opens and when the app
  returns to the foreground, so a store that was unreachable at start
  doesn't leave the card empty.
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

### Reporting an ad (App Store guideline 2.5.18)

Apple requires apps with ads to let people report inappropriate ones. While
ads are on, Progress has a **Report an ad** entry. It opens an e-mail (or a
web form) with the time, the screen of the last banner seen and the ad unit
ids filled in. There is no link next to the banners themselves, to keep
tappable controls away from live ads.

- `--dart-define=AD_REPORT_EMAIL=you@your-domain.example` sets the address. The
  default, `ads-report@example.com`, is a placeholder: **replace it before
  release.** Release builds refuse it (see the guards below).
- `--dart-define=AD_REPORT_URL=https://…` sends people to a web form instead;
  the details are added as query parameters.

If no mail app can open the link, the app shows the address so it can be
copied. When a report comes in, block the ad in AdMob (Blocking controls →
Ad review center).

### Code map

```
lib/monetization/
  monetization.dart          Monetization: the ads/consent/age rules, interstitial cap, MonetizationScope
  purchase_controller.dart   PurchaseController: buy/restore/pending/error/cancel, entitlement
  ads_service.dart           AdsService interface, AdPlacement, AdAudience, NoAdsService
  consent_service.dart       ConsentService interface, NoConsentService
  purchase_service.dart      PurchaseService interface, StorePurchase, PurchaseVerifier
  ad_banner.dart             AdBannerSlot (placed in screens), reportAdFrom
  ad_report.dart             the ad report e-mail or URL (AD_REPORT_EMAIL / AD_REPORT_URL)
  ad_config.dart             ad unit ids (test ids by default, --dart-define for real ones)
  platform_services.dart     conditional import: _io (Android/iOS) or _stub (web)
  google_ads.dart            google_mobile_ads + UMP implementation (mobile only)
  store_purchases.dart       in_app_purchase implementation (mobile only)
lib/data/age.dart                                  AgeGroup, ageGroupFor, AgeStore (shared by AppState and Monetization)
lib/features/onboarding/age_screen.dart
lib/features/progress/monetization_widgets.dart   RemoveAdsCard, PrivacyOptionsTile, ReportAdTile
test/monetization_test.dart, test/child_accounts_test.dart,
fakes in test/fakes.dart (FakeAds, FakeConsent, FakeStore)
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

| Ad report address | `--dart-define=AD_REPORT_EMAIL=…` (or `AD_REPORT_URL`) | `ads-report@example.com` (placeholder) |

The test ids come from the google_mobile_ads 9.1.0 example app in the pub
cache, which matches Google's test-ads page.

Keep the ids in one file outside git, for example `admob.json`:

```json
{
  "ADMOB_APP_ID_ANDROID": "ca-app-pub-1111111111111111~2222222222",
  "ADMOB_BANNER_ANDROID": "ca-app-pub-1111111111111111/3333333333",
  "ADMOB_INTERSTITIAL_ANDROID": "ca-app-pub-1111111111111111/4444444444",
  "ADMOB_BANNER_IOS": "ca-app-pub-1111111111111111/5555555555",
  "ADMOB_INTERSTITIAL_IOS": "ca-app-pub-1111111111111111/6666666666",
  "AD_REPORT_EMAIL": "ads@your-domain.example"
}
```

Replace every value, including the example address: it is refused in
release builds.

and build with it:

```sh
flutter build appbundle --release --dart-define-from-file=admob.json

# iOS: first put the real app id in ios/Flutter/AdMob.xcconfig
flutter build ipa --release --dart-define-from-file=admob.json
```

`--dart-define-from-file` values reach Gradle the same way as
`--dart-define` ones, so the Android app id is read from the file too.

**Guards against shipping test ids or the placeholder report address.**
- An Android release build (`preReleaseBuild` in
  `android/app/build.gradle.kts`) fails if the app id is still the test id,
  if `ADMOB_BANNER_ANDROID` or `ADMOB_INTERSTITIAL_ANDROID` is missing or
  one of Google's test ids, or if there is no real `AD_REPORT_EMAIL` or
  `AD_REPORT_URL`.
- An iOS release build fails in the "Check Release Ads Config" build phase
  (`ios/scripts/check_release_ads.sh`) for the same reasons, with
  `ADMOB_BANNER_IOS` and `ADMOB_INTERSTITIAL_IOS` as the unit ids, reading
  the app id from `AdMob.xcconfig`. Each platform checks only its own ids.
- A report address ending in `.example` (such as the placeholder
  `ads@your-domain.example` in the file above) counts as a placeholder too,
  in all three guards, unless `AD_REPORT_URL` is set. Replace it with your
  real address.
- A release build of the app that still has **any** test unit id, or the
  placeholder report address, shows no ads at all and logs a loud warning
  (`releaseAdsProblem` in `ad_config.dart`). "Remove ads" still works.
- For a deliberate release-mode test build, add
  `--dart-define=ALLOW_TEST_ADS_IN_RELEASE=true` to switch all of these off.

Keep the app id and the unit ids from the same AdMob app. If the app id is
still the test id but the unit ids are real, ads fail to load. Never tap live ads on your own devices. Add your devices as test
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
   to PG as well, to match the code for adults (the code asks for G for
   under-18s on each request). Block sensitive categories you don't
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
  category. Apple's age ratings are now 4+, 9+, 13+, 16+ and 18+; answer the
  questionnaire honestly, and with ads aimed at a 13+ audience **13+** is the
  expected result.
- **Ads declaration** (Play Console → App content → Ads): **Yes, my app
  contains ads**.
- **Texas SB 2420** (App Store Accountability Act) makes app stores verify
  ages and pass age signals to apps. Timeline as reported by the review (not
  checked against court records here): a federal court enjoined it on
  23 Dec 2025, before its 1 Jan 2026 start; the Fifth Circuit stayed that
  injunction on 28 May 2026; CCIA filed with the Supreme Court in June 2026.
  **Re-check its status before launch** (see research section 6).
- **Store age signals.** Before launch, read Apple's **Declared Age Range**
  API and Google Play's **Age Signals** API. Where available they give an
  age range from the store, which could replace or back up the birth-year
  screen.

## What was not verified here

This work was done in a Linux container with no Android SDK, no Xcode, no
devices and no store accounts. So:

- **No Android or iOS build was run.** `flutter analyze`, `flutter test` and
  `flutter build web` pass. These are untested:
  - the Gradle change that reads dart-defines into the manifest, and the
    release check (both were run on their own with Gradle, including with
    the configuration cache, and behaved correctly, but not inside a real
    Android build);
  - the iOS xcconfig and Info.plist entries, including the delayed app
    measurement keys, and the release check build phase (its script was run
    with `sh`/`dash` on Linux for each case, not in Xcode or with macOS's
    `base64`);
  - plugin registration on device.
- **No real ad was loaded and no consent form was seen.** The google_mobile_ads
  and UMP code (`google_ads.dart`) follows the 9.1.0 package source and its
  example app. Widget tests cover only the rules, through fakes. Not checked
  on a device:
  - inline adaptive sizing and reloading on rotation;
  - interstitial callbacks;
  - UMP's behaviour with `tagForUnderAgeOfConsent` and no form: the expected
    `NOT_REQUIRED` status and `canRequestAds` true for under-18s in the EEA,
    and on iOS whether an unshown IDFA message keeps the status at
    `REQUIRED` (see the device check under "Age");
  - "Report an ad" opening a mail app;
  - deleting a brand-new account right after a child's sign-in (Firebase
    `isNewUser`).
- **No real purchase was made.** `store_purchases.dart` follows the
  in_app_purchase 3.3.1 source and README. Not tried against Play or App
  Store sandboxes:
  - buying, pending, refund and restore;
  - the Android pending-on-restore mapping, and cancellations and errors with
    an empty product id (the tests feed the plugin's own
    `GooglePlayPurchaseDetails.fromPurchase` objects, but no real store);
  - `AppStore.sync()` from the Restore button.
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
