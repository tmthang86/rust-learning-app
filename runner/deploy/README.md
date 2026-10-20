# Deploying the code runner

This guide gets the runner online, step by step. It is written for the
project owner. Follow the steps in order.

What you will end up with:

- One small Google Cloud VM that runs learners' Rust code inside gVisor.
- Caddy in front of it, with a free HTTPS certificate.
- A runner that only accepts requests from your genuine app, checked with
  Firebase App Check.
- A new app build that points at it.

Cost: about **US$36–40 per month** (one `e2-medium` VM, a disk and a static
IP). The Singapore price is an estimate. Check the
[pricing calculator](https://cloud.google.com/products/calculator) before
you start. Abuse can make the runner slow, but it cannot raise the bill,
because the VM has a fixed price.

How it works: the design is in [../docs/production-design.md](../docs/production-design.md).
This guide only covers what you must do.

Steps marked **by hand** need your accounts. Everything else is a script in
this folder.

| Part | What |
|---|---|
| A | Accounts and consoles, by hand (steps 1–8) |
| B | First deploy (steps 9–11) |
| C | Check it end to end (steps 12–13) |
| D | Release builds of the app (step 14) |
| E | Every day after that |

---

## Part A. Set up the accounts and the VM (by hand)

### Step 1. Install the tools on your laptop

You need:

- `git`
- [Docker](https://docs.docker.com/get-docker/) with `buildx` (Docker Desktop
  has it)
- the [`gcloud` CLI](https://cloud.google.com/sdk/docs/install)
- Flutter, as for the rest of the app
- `jq` and `dig` for a few checks (`brew install jq bind` on a Mac)

Sign in to Google Cloud:

```sh
gcloud auth login
```

### Step 2. Make one Google Cloud project (it is also the Firebase project)

If you did the steps in [../../docs/firebase-setup.md](../../docs/firebase-setup.md),
you already have a Firebase project. It is a Google Cloud project too. Use
the same one.

1. Open <https://console.firebase.google.com>. Create the project if you
   have none.
2. Open **Project settings → General**. Write down:
   - **Project ID**, for example `rust-learn-12345`
   - **Project number**, for example `123456789012`

Set these in your terminal. Later commands use them.

```sh
export PROJECT_ID=rust-learn-12345        # your project ID
export REGION=asia-southeast1             # Singapore
export ZONE=asia-southeast1-b
export DOMAIN=runner.example.com          # the address you will use for the runner
gcloud config set project "$PROJECT_ID"
```

### Step 3. Turn on billing and create a budget alert (required)

The VM needs billing. Linking billing moves the Firebase project to the
Blaze (pay as you go) plan. The free quotas stay the same.

1. Open <https://console.cloud.google.com/billing>. Link a billing account
   to the project.
2. **Create a budget alert now.** Go to **Billing → Budgets & alerts →
   Create budget**.
   - Scope: this project.
   - Amount: **US$60** per month.
   - Alerts: 50 %, 90 % and 100 %, by email.

   A budget alert does not stop spending. It tells you early.

Command line version, if you prefer it (find your billing account ID with
`gcloud billing accounts list`):

```sh
gcloud services enable billingbudgets.googleapis.com
gcloud billing budgets create --billing-account=XXXXXX-XXXXXX-XXXXXX \
  --display-name="Runner budget" --budget-amount=60USD \
  --threshold-rule=percent=0.5 --threshold-rule=percent=0.9 \
  --threshold-rule=percent=1.0
```

### Step 4. Register the apps in Firebase

Skip what you already did.

```sh
dart pub global activate flutterfire_cli
flutterfire configure --platforms=android,ios,web
```

This registers the Android, iOS and web apps. The names it uses:

- Android package: `com.rustlearn.rust_learn`
- iOS bundle ID: `com.rustlearn.rustLearn`

Now collect the three **App IDs**. Open **Project settings → General → Your
apps**. Each app shows an App ID, like these:

```
1:123456789012:android:0a1b2c3d4e5f
1:123456789012:ios:0a1b2c3d4e5f
1:123456789012:web:0a1b2c3d4e5f
```

Write all three down. The runner only accepts tokens from these apps.

### Step 5. Turn on App Check for each platform

App Check is how the runner knows a request comes from your real app. Open
**Firebase console → App Check → Apps**. Do the part for each platform you
ship.

**Do not click "Enforce" for Firestore, Authentication or any other Firebase
product.** That is a separate decision. The runner does its own checking.

Leave the token lifetime at **1 hour** for every provider.

Firebase's screens change from time to time. If a button has another name,
search the Firebase docs for "App Check" and the platform.

#### Android: Play Integrity

1. Enable the API:
   ```sh
   gcloud services enable playintegrity.googleapis.com
   ```
2. In **Firebase console → Project settings → Your apps → Android**, add the
   **SHA-256 fingerprint of the Play app signing key**. Find it in **Play
   Console → your app → Test and release → App integrity → App signing**
   (the "App signing key certificate").
3. In the **Play Console**, open **App integrity → Play Integrity API** and
   link this Google Cloud project to the app.
4. In **Firebase console → App Check → Apps**, open the Android app, choose
   **Play Integrity** and save.

Note: only a build installed from Google Play (even the internal testing
track) passes Play Integrity. A release APK you install by hand will not.
Use a debug token for those (step 6).

#### iOS: App Attest, with DeviceCheck as the fallback

1. Open **Project settings → Your apps → iOS** and make sure the Apple
   **Team ID** is filled in.
2. In **App Check → Apps**, open the iOS app, choose **App Attest** and save.
3. For the DeviceCheck fallback, create a key at
   <https://developer.apple.com/account/resources/authkeys/list>:
   - Click **+**, give it a name, tick **DeviceCheck**, continue, register.
   - Download the `.p8` file. **Apple lets you download it once.** Keep it
     safe, and out of git.
   - Write down the **Key ID**.
4. In **App Check → Apps**, open the iOS app again, choose **DeviceCheck**,
   upload the `.p8` file, enter the Key ID and save.

Enable the **App Attest** capability for the app (this is step 5b below).

#### Web: reCAPTCHA Enterprise

1. Enable the API:
   ```sh
   gcloud services enable recaptchaenterprise.googleapis.com
   ```
2. Open **Google Cloud console → Security → reCAPTCHA Enterprise → Create
   key**.
   - Display name: `Rust Learn web`.
   - Platform: **Website**.
   - Domain: the host name of your web app, for example `learn.example.com`
     (no `https://`). Do not add `localhost`; use a debug token for that.
   - Type: **score-based** (no checkbox).
3. Copy the **site key** the console shows.
4. In **Firebase console → App Check → Apps**, open the web app, choose
   **reCAPTCHA Enterprise**, paste the site key and save. Keep the default
   minimum score. Raise it later only if the logs show abuse from the web.

You will use the site key again when you build the web app (step 14).

### Step 5b. Turn on the App Attest capability (Apple)

The repo already contains `ios/Runner/Runner.entitlements` and the Xcode
settings that use it. You still need to switch the capability on for your
App ID.

Easy way:

1. Open `ios/Runner.xcworkspace` in Xcode.
2. Select the **Runner** target, then **Signing & Capabilities**.
3. You should see **App Attest** in the list. With automatic signing, Xcode
   turns it on for the App ID by itself.

By hand, if Xcode complains: open
<https://developer.apple.com/account/resources/identifiers/list>, choose the
App ID `com.rustlearn.rustLearn`, tick **App Attest** under Capabilities and
save.

### Step 6. Register debug tokens (for your own testing)

Debug builds do not use Play Integrity or App Attest. They send a **debug
token** instead. You make the token up and register it.

1. Make a token:
   ```sh
   uuidgen
   ```
2. In **Firebase console → App Check → Apps**, open each app you test with
   (Android, iOS, web), open the **⋮** menu, choose **Manage debug tokens**,
   and add the token.
3. Keep the token out of git. You pass it on the command line (step 12).
   If it leaks, delete it in the console. A debug token works against the
   production runner.

### Step 7. Create the VM

Turn on the services and give yourself access. You are the project owner, so
the role commands may say nothing changed. That is fine.

```sh
gcloud services enable compute.googleapis.com iap.googleapis.com oslogin.googleapis.com

ME=$(gcloud config get-value account)
gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="user:$ME" --role=roles/iap.tunnelResourceAccessor
gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="user:$ME" --role=roles/compute.osAdminLogin
```

Reserve a fixed IP address, then create the VM. The VM has **no service
account**, so nothing on it can reach your Google Cloud resources.

```sh
gcloud compute addresses create rust-runner-ip --region "$REGION"

gcloud compute instances create rust-runner \
  --zone "$ZONE" \
  --machine-type e2-medium \
  --image-family ubuntu-2404-lts-amd64 --image-project ubuntu-os-cloud \
  --boot-disk-size 20GB --boot-disk-type pd-balanced \
  --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring \
  --no-service-account --no-scopes \
  --tags rust-runner \
  --address rust-runner-ip \
  --metadata enable-oslogin=TRUE
```

Firewall: open the web ports to the world, and SSH only to Google's IAP
range. Then delete the default rules that would leave SSH and RDP open.

```sh
gcloud compute firewall-rules create rust-runner-web \
  --network default --direction INGRESS --allow tcp:80,tcp:443 \
  --target-tags rust-runner --source-ranges 0.0.0.0/0

gcloud compute firewall-rules create rust-runner-iap-ssh \
  --network default --direction INGRESS --allow tcp:22 \
  --target-tags rust-runner --source-ranges 35.235.240.0/20

gcloud compute firewall-rules delete default-allow-ssh default-allow-rdp
```

(If a rule does not exist in your project, skip it.)

Write down the IP address:

```sh
gcloud compute addresses describe rust-runner-ip --region "$REGION" --format='value(address)'
```

### Step 8. Point the domain at the VM

At the company that manages your domain, add a DNS record:

| Type | Name | Value |
|---|---|---|
| `A` | `runner` (so the full name is `runner.example.com`) | the IP from step 7 |

A short TTL, like 300 seconds, helps while you test. Wait a few minutes,
then check:

```sh
dig +short "$DOMAIN"
```

It must print the IP. Do not go on until it does. Without it, the free
certificate in step 10 cannot be issued.

---

## Part B. First deploy

### Step 9. Fill in the settings and commit them

Open `runner/deploy/production.env`. Replace every `REPLACE` value. None of
these values is secret.

```
RUNNER_ALLOWED_ORIGINS=https://learn.example.com         # your web app's address, no trailing slash
RUNNER_FIREBASE_PROJECT_NUMBER=123456789012              # step 2
RUNNER_FIREBASE_PROJECT_ID=rust-learn-12345              # step 2
RUNNER_APP_CHECK_APP_IDS=1:123...:android:...,1:123...:ios:...,1:123...:web:...   # step 4, no spaces
RUNNER_DOMAIN=runner.example.com                         # step 8
```

Leave the other lines as they are. If you ship no web app, still use a real
address for `RUNNER_ALLOWED_ORIGINS` (for example your site's address).

Also open `runner/deploy/vars.sh` and look at the top. The defaults
(`asia-southeast1`, VM name `rust-runner`) match steps 2 and 7. If you
changed them, change them here too. The project comes from your `gcloud`
settings.

Commit the file. The deploy scripts build from the last commit and refuse to
run with uncommitted changes:

```sh
git add runner/deploy/production.env runner/deploy/vars.sh
git commit -m "Runner: production settings"
```

### Step 10. Set up the VM, then deploy

Run these from the repository root, one at a time. Each one prints what it
does and stops at the first problem.

**a) Set up the VM (about 5–10 minutes).**

```sh
runner/deploy/push.sh --setup
```

The first time, `gcloud` makes an SSH key for you. Press Enter when it asks
for a passphrase, or choose one.

This installs Docker, gVisor, Caddy and the service on the VM. It finishes
with a list of checks. Every line should say `PASS`:

```
PASS  runsc is exactly 20261012.0 ...
PASS  docker's default runtime is runsc
...
All host checks passed (the runner was not checked).
```

**b) Deploy with a test certificate.** This builds the runner on your laptop
(the first build takes a few minutes), uploads it, starts it and runs the
full checks. Let's Encrypt has strict limits on real certificates, so the
first run uses their *staging* service:

```sh
runner/deploy/push.sh --acme-staging
```

At the end you should see `Release <id> is live`. The VM runs the whole
sandbox test suite under gVisor. This takes a few minutes. If a check says
`FAIL`, the script goes back to the old release by itself (on the first
deploy there is none, so it stays as it is). See "When something fails"
below.

**c) Deploy for real.** Same release, real certificate:

```sh
runner/deploy/push.sh
```

Check from your laptop:

```sh
curl -s "https://$DOMAIN/health"
```

You should see JSON that starts with `{"status":"ok"`.

### Step 11. Test that the runner refuses strangers

```sh
curl -i -X POST "https://$DOMAIN/run" \
  -H 'content-type: application/json' -d '{"code":"fn main() {}"}'
```

The answer must be `401` with `"code":"app_check_missing"`. A runner that
runs code for anyone is a bug.

---

## Part C. Check it end to end

### Step 12. Run a debug build against the real runner

Use the debug token from step 6.

```sh
export APP_CHECK_DEBUG_TOKEN=paste-your-uuid-here    # do not commit this

flutter run \
  --dart-define=RUNNER_URL=https://$DOMAIN \
  --dart-define=APP_CHECK_DEBUG_TOKEN=$APP_CHECK_DEBUG_TOKEN
```

For Chrome add `-d chrome`. Open a lesson, press **Run** on the hello world
code, and the output should appear.

If Run says "This copy of the app couldn't be verified", look at the runner's
log (the `auth_error` field says why):

```sh
gcloud compute ssh rust-runner --zone "$ZONE" --tunnel-through-iap -- \
  'sudo journalctl -u rust-runner -n 30 -o cat'
```

Also check these once, to be sure the settings match what Google really
sends:

1. In a debug session, print one App Check token. Add this line to
   `lib/main.dart` after `runApp`, run once, then **delete the line** (never
   commit it):
   ```dart
   debugPrint('TOKEN ' + (await FirebaseAppCheck.instance.getToken() ?? 'none'));
   ```
2. Decode it **on your laptop only**. Do not paste it into a website.
   ```sh
   TOKEN=paste-it-here
   echo "$TOKEN" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq .
   ```
   If `base64` complains, add `=` characters at the end of the middle part
   until its length is a multiple of 4.
3. Look at the result:
   - `iss` must be `https://firebaseappcheck.googleapis.com/<your project number>`
   - `aud` must contain `projects/<your project number>` or
     `projects/<your project ID>`
   - `sub` must be one of your App IDs

If `iss` or `aud` look different, tell the developer: the runner's checks
need a one-line change.

### Step 13. Add an uptime check

In the Google Cloud console open **Monitoring → Uptime checks → Create
uptime check**:

- Protocol: **HTTPS**
- Hostname: `runner.example.com` (your domain)
- Path: `/health`
- Check every: **5 minutes**
- Response validation: **Content matches**, `"status":"ok"`
- Notification: create an **email** channel with your address

The runner says `"status":"unhealthy"` (HTTP 503) when it has not run a job
for 30 minutes, when its keys are not loaded, or when the disk is nearly
full.

---

## Part D. Release builds of the app

### Step 14. Build with the runner address

Always build with `RUNNER_URL`. A release build **without** it cannot run
code.

```sh
# Android (upload the .aab to Play, for example the internal testing track)
flutter build appbundle --release --dart-define=RUNNER_URL=https://$DOMAIN

# iOS (then upload with Xcode or Transporter)
flutter build ipa --release --dart-define=RUNNER_URL=https://$DOMAIN

# Web (needs the reCAPTCHA site key from step 5)
flutter build web --release \
  --dart-define=RUNNER_URL=https://$DOMAIN \
  --dart-define=APP_CHECK_WEB_SITE_KEY=your-recaptcha-site-key
```

Never pass `APP_CHECK_DEBUG_TOKEN` to a release build.

Things to know:

- Without Firebase set up, the app still starts. It just sends no App Check
  token, and the production runner then answers 401.
- A web build without `APP_CHECK_WEB_SITE_KEY` sends no token either.
- The web app's address must be in `RUNNER_ALLOWED_ORIGINS` (step 9).
  Otherwise the browser blocks the answers. To add one, edit the file,
  commit, and run `runner/deploy/push.sh`.
- Check the App Store and Play Console privacy forms. App Check and Play
  Integrity read device signals. Check what each store asks you to declare.
- If App Attest fails on a *release* build that you install straight from
  Xcode, open `ios/Runner/Runner.entitlements` and change `production` to
  `development` for that test build only. Change it back before you upload.
  Builds from TestFlight and the App Store use `production`.

---

## Part E. Every day after that

All commands run from the repository root, after committing your changes.

### Deploy a new version of the runner

```sh
runner/deploy/push.sh
```

It builds from the last commit, checks the binary, switches over, runs the
checks and goes back by itself if they fail. Each release lives in
`/opt/rust-runner/releases/<commit>` on the VM. The last three are kept.

### Roll back by hand

```sh
runner/deploy/push.sh --rollback
```

This goes to the previous release. Binary, settings and sandbox image go
back together. Run it again to go forward.

### Open a shell on the VM

```sh
gcloud compute ssh rust-runner --zone "$ZONE" --tunnel-through-iap
```

Useful commands there:

```sh
sudo journalctl -u rust-runner -n 100 -o cat      # runner log (JSON lines)
sudo journalctl -u caddy -n 50 --no-pager         # certificate and proxy log
sudo /opt/rust-runner/deploy/smoke.sh             # run all the checks again
curl -s http://127.0.0.1:8080/health | jq .       # health and counters
```

### Weekly: read the logs (10 minutes)

```sh
gcloud compute ssh rust-runner --zone "$ZONE" --tunnel-through-iap -- \
  'journalctl -u rust-runner --since -7d -o cat | jq -c "select(.event==\"summary\")" | tail -50'
```

Look at the counts of 429, 401 and `internal`, the longest queue wait and the
free disk. Then skim the warnings:

```sh
gcloud compute ssh rust-runner --zone "$ZONE" --tunnel-through-iap -- \
  'journalctl -p warning --since -7d --no-pager | tail -50'
```

A `mem_limit_rate_high` warning means abuse, or a host problem.

If runs are often slow (`queue_wait_max_ms` above 2000) or you see many
`busy` answers, make the VM bigger: stop it, change the machine type to
`e2-standard-2`, start it, and raise `RUNNER_MAX_JOBS` in `production.env`.

### Monthly: upgrade gVisor, Docker and the sandbox image

Docker, containerd and gVisor are pinned and held, so they never upgrade by
themselves. Once a month:

1. Find the newest versions.
   ```sh
   # gVisor: version and sha256
   curl -s https://storage.googleapis.com/gvisor/releases/dists/release/main/binary-amd64/Packages | grep -E '^(Version|SHA256):'

   # Docker and containerd
   curl -s https://download.docker.com/linux/ubuntu/dists/noble/stable/binary-amd64/Packages \
     | awk '/^Package: /{p=$2} /^Version: /{print p, $2}' \
     | grep -E '^(docker-ce|docker-ce-cli|containerd.io) ' | sort -V | tail -n 12

   # Sandbox image: the line "Digest:" at the top
   docker buildx imagetools inspect mirror.gcr.io/library/rust:<new tag>-slim-bookworm | head -3
   ```
2. Edit `runner/deploy/vars.sh`: `RUNSC_VERSION`, `RUNSC_DEB_SHA256`
   (`RUNSC_DEB_URL` follows the version), `DOCKER_VERSION`, `DOCKER_SEMVER`,
   `CONTAINERD_VERSION`.
3. Edit `RUNNER_IMAGE` in `runner/deploy/production.env` if you want a new
   Rust toolchain for learners.
4. Commit, then:
   ```sh
   runner/deploy/push.sh --upgrade-packages    # installs the versions, runs the checks
   runner/deploy/push.sh                       # deploys the new settings and image
   ```
   If the checks fail after `--upgrade-packages`, the old versions are
   installed again by itself.

Ubuntu security updates install by themselves. The VM reboots at 03:00
Vietnam time when an update needs it, and comes back in about a minute.

### Stop paying for it

```sh
gcloud compute instances delete rust-runner --zone "$ZONE"
gcloud compute addresses delete rust-runner-ip --region "$REGION"
```

---

## When something fails

| What you see | What to do |
|---|---|
| `push.sh`: "there are uncommitted changes" | Commit (or stash) first. The build uses the last commit. |
| `push.sh`: "still has REPLACE values" | Finish step 9 and commit. |
| `gcloud compute ssh` says permission denied or error 4033 / 4003 | Check the two roles in step 7. Wait a minute after adding them. Try again. |
| `setup-host.sh` fails on a download | Run `runner/deploy/push.sh --setup` again. It is safe to repeat. |
| `FAIL runsc is exactly ...` or other host checks | The VM does not match `vars.sh`. Run `push.sh --setup` again. |
| Caddy cannot get a certificate | Check `dig +short $DOMAIN` (step 8), that the firewall allows ports 80 and 443 (step 7), and `sudo journalctl -u caddy -n 50`. |
| The checks fail on the TLS certificate after the real deploy (step 10c) | Caddy may still hold the test certificate. On the VM run `sudo systemctl restart caddy`. If that is not enough, run `sudo rm -r /var/lib/caddy/.local/share/caddy/certificates` and restart Caddy again. |
| `FAIL POST https://.../run without an App Check header ...` | The runner is up but answered something else. Run `curl -i` as in step 11 and read the answer. |
| `/health did not report ok` | `sudo journalctl -u rust-runner -n 100 -o cat`. A bad setting is listed there, all problems at once. |
| Runner says `app_not_allowed` (403) | The app's ID is missing in `RUNNER_APP_CHECK_APP_IDS`. Fix, commit, deploy. |
| The app says "couldn't be verified" | Step 5 is not complete for that platform, or the build has no token (step 12 has the log command). |
| The browser shows a CORS error | The web address is missing in `RUNNER_ALLOWED_ORIGINS`. |
| The app says "You're running code very quickly" | A rate limit. Wait the number of seconds it shows. |
| A release made things worse | `runner/deploy/push.sh --rollback`. |

---

## What is in this folder

| File | What it is |
|---|---|
| `push.sh` | Runs on your laptop. Builds, uploads, installs. |
| `Dockerfile.build` | The cross-build recipe (x86_64 Linux, no QEMU, glibc 2.36). |
| `setup-host.sh` | One-time VM setup. Safe to repeat. |
| `install.sh` | Installs a release on the VM. Also rollback and package upgrades. |
| `smoke.sh` | The checks. Runs after every deploy. |
| `lib.sh`, `vars.sh` | Shared code and the pinned versions. |
| `production.env` | The runner's settings. Not secret. |
| `daemon.json` | Docker settings (gVisor as the default runtime). |
| `Caddyfile.template` | Caddy settings. |
| `rust-runner.service` | The systemd service. |
| `journald-runner.conf`, `52unattended-upgrades-runner` | Log and automatic update settings. |

Do not edit `daemon.json` by hand. It is written in the exact format that
`runsc install` writes, so the byte-for-byte check keeps passing.
