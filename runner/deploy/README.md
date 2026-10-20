# Deploying the code runner

This guide gets the runner online, step by step. It is written for the
project owner. Follow the steps in order.

What you will end up with:

- One small virtual machine (VM) that runs learners' Rust code inside
  gVisor. The main path uses an **Oracle Cloud Always Free** VM. A **Google
  Cloud** VM is the fallback ([Appendix](#appendix-google-cloud-as-the-host-fallback)).
- Caddy in front of it, with a free HTTPS certificate.
- A runner that only accepts requests from your genuine app, checked with
  Firebase App Check.
- A new app build that points at it.

Cost:

- **Oracle Always Free: US$0** while you stay inside the free limits (one
  Ampere A1 VM with 2 CPUs and 12 GB of memory, at most 200 GB of disks).
  You must still give Oracle a credit card, and you upgrade the account to
  Pay As You Go (step 4) so that a quiet VM is not switched off. Upgrading
  costs nothing by itself.
- **Google Cloud fallback: about US$36–40 per month** (an estimate; check the
  [pricing calculator](https://cloud.google.com/products/calculator)).

Abuse can make the runner slow. It cannot make the VM bigger, so the VM's own
price does not grow. Network traffic out of the VM is the one cost that
follows use. Oracle's free allowance for it is large (the Always Free page
lists 10 TB a month; I could not check that page myself). Google bills
it, so there the budget alert is the safety net. The runner caps the size of
its answers.

How it works: the design is in [../docs/production-design.md](../docs/production-design.md)
(see its section 2 addendum for the Oracle decision). This guide only covers
what you must do.

Steps marked **by hand** need your accounts. Everything else is a script in
this folder.

| Part | What |
|---|---|
| A | Accounts, the VM and the consoles, by hand (steps 1–11) |
| B | First deploy (steps 12–14) |
| C | Check it end to end (steps 15–16) |
| D | Release builds of the app (step 17) |
| E | Every day after that |
| Appendix | Google Cloud as the host (the fallback) |

---

## Part A. Set up the accounts and the VM (by hand)

### Step 1. Install the tools on your laptop

You need:

- `git`
- [Docker](https://docs.docker.com/get-docker/) with `buildx` (Docker Desktop
  has it)
- `ssh` (every Mac and Linux has it)
- the Oracle command line tool `oci`, from step 6. It is optional: the
  console can do the same by hand.
- Flutter, as for the rest of the app
- `jq` and `dig` for a few checks (`brew install jq bind` on a Mac)

### Step 2. Find your Firebase project (it is also a Google Cloud project)

If you did the steps in [../../docs/firebase-setup.md](../../docs/firebase-setup.md),
you already have a Firebase project. Use it.

1. Open <https://console.firebase.google.com>. Create the project if you
   have none.
2. Open **Project settings → General**. Write down:
   - **Project ID**, for example `rust-learn-12345`
   - **Project number**, for example `123456789012`

Choose the address of the runner. It is a name in a domain you own:

```sh
export DOMAIN=runner.example.com
```

Later commands use `$DOMAIN`.

### Step 3. Create the Oracle Cloud account

1. Open <https://www.oracle.com/cloud/free/> and choose **Start for free**.
2. Fill in your name, email and country. Confirm the email.
3. Choose the **home region** (read the box below first).
4. Enter a **regular credit card**. Oracle uses it to check you are a real
   person. Prepaid and virtual cards are often refused.
5. Wait until Oracle says the account is ready. It sends an email. This can
   take a few minutes, sometimes longer.
6. Sign in at <https://cloud.oracle.com>.

> **The home region is permanent.** You pick it once and can never change
> it. Always Free VMs can only be created in the home region.
>
> **Recommended: Singapore (`ap-singapore-1`).** It is the closest region to
> Vietnam. The price is availability: Singapore has only one availability
> domain, and free Ampere A1 machines there are often "Out of capacity". You
> may have to retry for hours or days (step 6 does the retrying for you).
>
> Another region may have more availability domains, which gives more
> chances, but it is farther away. A run takes 1–3 seconds, so some extra
> milliseconds of distance matter little. The console shows how many
> availability domains a region has. I could not check that from here.
>
> If you cannot get a VM at all, use the Google Cloud fallback.

### Step 4. Upgrade to Pay As You Go and set a budget alert

**Why upgrade.** Oracle may stop an Always Free VM that looks idle. "Idle"
means: over 7 days, the 95th-percentile CPU use is under 20 %, and so is the
network use and (on A1) the memory use. A quiet runner looks idle. Oracle
emails a warning first. A Pay As You Go account is not subject to that rule.
The VM still costs **$0** while you stay inside the Always Free limits:

- one A1 VM with at most 2 CPUs and 12 GB of memory,
- at most 200 GB of disks in total (this guide uses 50 GB),
- no other paid resources.

Oracle has cut the free limits before without announcing it (it halved the A1
quota in 2026). That is why the Google Cloud fallback exists.

1. In the console open the menu, then **Billing & Cost Management → Upgrade
   and Manage Payment**, and choose **Upgrade**. (Oracle renames menus. If you
   do not find it, search the console for "Upgrade".)
2. Use a regular credit card. Oracle may refuse prepaid cards.

**Budget alert (required).** It does not stop spending. It tells you early.

1. Open **Billing & Cost Management → Budgets → Create budget**.
2. Scope: the whole tenancy (the root compartment). Monthly budget amount:
   **1 US dollar**.
3. Add an alert rule: type **Actual spend**, threshold **1 percent**, send it
   to your email. Add a second rule at **100 percent**.

With these rules, any charge at all (one cent) sends you an email.

### Step 5. Create the network

Do this in the Oracle console, in your home region.

1. Open the menu, **Networking → Virtual cloud networks → Start VCN
   Wizard**, choose **Create VCN with Internet Connectivity**.
2. Name: `rust-runner-vcn`. Leave the address ranges as they are. Create it.
   This makes a public subnet, a private subnet, an internet gateway and a
   security list.
3. Open the VCN, **Security → Default Security List for rust-runner-vcn →
   Add/Edit Ingress Rules**.
4. Find your own IP address (`curl -4 -s https://ifconfig.me`). Make the
   ingress rules exactly these:

   | Source CIDR | Protocol | Destination port | Why |
   |---|---|---|---|
   | `YOUR.IP.ADDRESS/32` | TCP | 22 | SSH, only from you. The wizard's default rule says `0.0.0.0/0`: **change it**. |
   | `0.0.0.0/0` | TCP | 80 | Caddy asks Let's Encrypt for the certificate here |
   | `0.0.0.0/0` | TCP | 443 | The runner's address |

   You may keep the wizard's ICMP rules. Delete anything else that is open to
   the world.

If your home IP changes (many home connections do), SSH times out. Open this
security list in the console and edit the port 22 rule to your new IP.

> **Why plain SSH and not the OCI Bastion service?** Oracle has no
> equivalent of Google's IAP tunnel. The Bastion service opens short-lived
> sessions that you would have to create before every deploy, which is more
> moving parts. Key-only SSH from one IP address is simple and safe enough:
> passwords are switched off on the VM (setup does it) and the port is closed
> to everybody else. Bastion is a possible later upgrade. The scripts do not
> use it.

Also open the **public subnet** (Networking → VCN → Subnets) and copy its
**OCID** (the long id that starts with `ocid1.subnet`). Step 6 needs it.

### Step 6. Create the VM

You can do this by script (a) or by hand in the console (b).

First make an SSH key. This is the only way into the VM. Choose a passphrase
when it asks, and load the key into your agent so you type the passphrase once:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/rust-runner -C rust-runner
ssh-add ~/.ssh/rust-runner        # on a Mac: ssh-add --apple-use-keychain ~/.ssh/rust-runner
```

Make a short name for the VM. Put this in `~/.ssh/config`, using your
`$DOMAIN`:

```
Host rust-runner
  HostName runner.example.com
  User ubuntu
  IdentityFile ~/.ssh/rust-runner
  IdentitiesOnly yes
```

#### a) With the script

1. Install the Oracle command line tool and sign it in:
   ```sh
   brew install oci-cli          # Mac. Elsewhere: see below
   oci setup config              # asks for the OCIDs and makes an API key
   ```
   Elsewhere: <https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm>
   (the install script is
   `https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh`).
   `oci setup config` asks for your tenancy OCID, your user OCID and your
   region (`ap-singapore-1`). Both OCIDs are on your profile page in the
   console. At the end it prints a public key: in the console open **your
   profile → My profile → API keys → Add API key → Paste a public key** and
   paste it.
2. Check that it works: `oci iam region-subscription list` must print your
   region.
3. Create the VM:
   ```sh
   runner/deploy/oracle-launch.sh \
     --subnet-id ocid1.subnet.oc1.ap-singapore-1.PASTE-THE-ID \
     --ssh-key-file ~/.ssh/rust-runner.pub
   ```
   It creates an Ampere A1 VM (2 CPUs, 12 GB), Ubuntu 24.04, 50 GB disk, with
   a public IP address, the old metadata endpoint switched off, and your key.
   At the end it prints the **public IP address**.

**If it says "Out of capacity".** That means Oracle has no free A1 machines
in your region right now. The script waits 90 seconds and tries again, for up
to 12 hours. Leave the terminal open (on a Mac run it as
`caffeinate -i runner/deploy/oracle-launch.sh ...`, so the laptop does not
sleep). Other things that help:

- Run it again later. Capacity comes and goes.
- You can change how long it keeps trying: `--retry-minutes 2880 --interval 60`.
- If after a few days there is still nothing, use the Google Cloud fallback.

#### b) By hand in the console

1. **Compute → Instances → Create instance.**
2. Name: `rust-runner`.
3. **Image:** change it to **Canonical Ubuntu 24.04** (the Arm / aarch64 one).
4. **Shape:** change it to **Ampere → VM.Standard.A1.Flex**, **2 OCPUs**,
   **12 GB** memory.
5. **Networking:** your `rust-runner-vcn`, the **public subnet**, and
   **Automatically assign public IPv4 address**.
6. **SSH keys:** choose **Paste public keys** and paste the contents of
   `~/.ssh/rust-runner.pub`.
7. **Boot volume:** tick **Specify a custom boot volume size** and enter
   **50** GB.
8. **Show advanced options → Management → Instance metadata service:**
   choose **Version 2 only**. (This switches off the old metadata endpoint.)
9. Create. If it says "Out of capacity", try again later.

Note the public IP address that the instance page shows.

#### Check that you can log in

```sh
ssh rust-runner true && echo "ssh works"
```

(Step 7 must be done first for the name to work. Until then use
`ssh -i ~/.ssh/rust-runner ubuntu@PUBLIC-IP true`. The first time, SSH asks
to trust the VM's key: answer `yes`.)

The IP address stays with the VM while it exists, also across a stop and a
start. If you ever delete and recreate the VM, you get another address and
must change the DNS record.

### Step 7. Point the domain at the VM

At the company that manages your domain, add a DNS record:

| Type | Name | Value |
|---|---|---|
| `A` | `runner` (so the full name is `runner.example.com`) | the public IP from step 6 |

A short TTL, like 300 seconds, helps while you test. Wait a few minutes,
then check:

```sh
dig +short "$DOMAIN"
```

It must print the IP. Do not go on until it does. Without it, the free
certificate in step 13 cannot be issued.

### Step 8. Register the apps in Firebase

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

### Step 9. Turn on App Check for each platform

App Check is how the runner knows a request comes from your real app. Open
**Firebase console → App Check → Apps**. Do the part for each platform you
ship.

**Do not click "Enforce" for Firestore, Authentication or any other Firebase
product.** That is a separate decision. The runner does its own checking.

Leave the token lifetime at **1 hour** for every provider.

Firebase's screens change from time to time. If a button has another name,
search the Firebase docs for "App Check" and the platform.

#### Android: Play Integrity

The Play app signing key exists only after you have uploaded a first build
to Google Play. So this part has two halves:

**Now:**

1. Enable the API (Google Cloud console → APIs & Services → Library →
   "Play Integrity API" → Enable), or with `gcloud`:
   ```sh
   gcloud services enable playintegrity.googleapis.com --project rust-learn-12345
   ```

**After the first upload to Google Play** (step 17; the internal testing track
is enough):

2. In **Play Console → your app → Test and release → App integrity → App
   signing**, copy the **SHA-256 fingerprint** of the "App signing key
   certificate". Add it in **Firebase console → Project settings → Your apps →
   Android → Add fingerprint**.
3. In the **Play Console**, open **App integrity → Play Integrity API** and
   link this Google Cloud project to the app.
4. In **Firebase console → App Check → Apps**, open the Android app, choose
   **Play Integrity** and save.

Until then, test Android with a debug token (step 11). Only a build installed
from Google Play (even the internal testing track) passes Play Integrity. A
release APK you install by hand will not.

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

Enable the **App Attest** capability for the app (step 10).

#### Web: reCAPTCHA Enterprise

1. Enable the API:
   ```sh
   gcloud services enable recaptchaenterprise.googleapis.com --project rust-learn-12345
   ```
2. Open **Google Cloud console → Security → reCAPTCHA Enterprise → Create
   key**.
   - Display name: `Rust Learn web`.
   - Platform: **Website**.
   - Domains: every host name your web app is served on, for example
     `learn.example.com`, `rust-learn-12345.web.app` and
     `rust-learn-12345.firebaseapp.com` (no `https://`). Do not add
     `localhost`; use a debug token for that.
   - Type: **score-based** (no checkbox).
3. Copy the **site key** the console shows.
4. In **Firebase console → App Check → Apps**, open the web app, choose
   **reCAPTCHA Enterprise**, paste the site key and save. Keep the default
   minimum score. Raise it later only if the logs show abuse from the web.

You will use the site key again when you build the web app (step 17).

### Step 10. Turn on the App Attest capability (Apple)

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

### Step 11. Register debug tokens (for your own testing)

Debug builds do not use Play Integrity or App Attest. They send a **debug
token** instead. You make the token up and register it.

1. Make a token:
   ```sh
   uuidgen
   ```
2. In **Firebase console → App Check → Apps**, open each app you test with
   (Android, iOS, web), open the **⋮** menu, choose **Manage debug tokens**,
   and add the token.
3. Keep the token out of git. You pass it on the command line (step 15).
   If it leaks, delete it in the console. A debug token works against the
   production runner.

---

## Part B. First deploy

### Step 12. Fill in the settings and commit them

Open `runner/deploy/production.env`. Replace every `REPLACE` value. None of
these values is secret.

**Change only the part after the `=`.** Do not add comments, spaces or quotes
on these lines: everything after the `=` is part of the value.

| Setting | What to put |
|---|---|
| `RUNNER_ALLOWED_ORIGINS` | Every address the web app is opened on, separated by commas, with no spaces and no trailing slash. With Firebase Hosting that is both `https://PROJECT_ID.web.app` and `https://PROJECT_ID.firebaseapp.com`, plus your own domain if you added one. Example below. |
| `RUNNER_FIREBASE_PROJECT_NUMBER` | The project number from step 2 |
| `RUNNER_FIREBASE_PROJECT_ID` | The project ID from step 2 |
| `RUNNER_APP_CHECK_APP_IDS` | The three App IDs from step 8, separated by commas, no spaces |
| `RUNNER_DOMAIN` | The runner's address from step 7, for example `runner.example.com` |

For example:

```
RUNNER_ALLOWED_ORIGINS=https://learn.example.com,https://rust-learn-12345.web.app,https://rust-learn-12345.firebaseapp.com
RUNNER_FIREBASE_PROJECT_NUMBER=123456789012
RUNNER_FIREBASE_PROJECT_ID=rust-learn-12345
RUNNER_APP_CHECK_APP_IDS=1:123456789012:android:0a1b2c3d4e5f,1:123456789012:ios:0a1b2c3d4e5f,1:123456789012:web:0a1b2c3d4e5f
RUNNER_DOMAIN=runner.example.com
```

Leave the other lines as they are. If you ship no web app, still use a real
address for `RUNNER_ALLOWED_ORIGINS` (for example your site's address).

`runner/deploy/vars.sh` already says `PROVIDER=oracle`. Nothing to change.

Now make your personal settings file. Git ignores it, so it is never
committed:

```sh
echo 'SSH_HOST=rust-runner' > runner/deploy/local.env
```

`rust-runner` is the short name from `~/.ssh/config` (step 6). Without
`SSH_HOST`, `push.sh` uses `RUNNER_DOMAIN` as the address and your normal SSH
key.

Commit the settings. The deploy scripts build from the last commit and refuse
to run with uncommitted changes:

```sh
git add runner/deploy/production.env
git commit -m "Runner: production settings"
```

### Step 13. Set up the VM, then deploy

Run these from the repository root, one at a time. Each one prints what it
does and stops at the first problem.

**a) Set up the VM (about 5–10 minutes).**

```sh
runner/deploy/push.sh --setup
```

On the very first connection the script remembers the VM's SSH key. If SSH
ever warns later that the key has changed, it is either a new VM (remove the
old line from `~/.ssh/known_hosts`) or something is wrong: find out which
before you go on.

This installs Docker, gVisor and Caddy on the VM, opens ports 80 and 443 in
the VM's own firewall (Oracle's Ubuntu image blocks them), blocks the
instance metadata service for the runner's user, and switches off SSH
passwords. It finishes with a list of checks. Every line should say `PASS`
(a `NOTE` is information):

```
PASS  runsc is exactly 20261012.0 ...
PASS  docker's default runtime is runsc
...
PASS  iptables accepts new connections on port 443 (file and live)
PASS  the rust-runner user cannot reach the metadata service (169.254.169.254)
All host checks passed (the runner was not checked).
```

The VM keeps the firewall file as it was before in
`/etc/iptables/rules.v4.before-rust-runner`.

**b) Deploy with a test certificate.** This builds the runner on your laptop
(the first build takes a few minutes), uploads it, starts it and runs the
full checks. Let's Encrypt has strict limits on real certificates, so the
first run uses their *staging* service:

```sh
runner/deploy/push.sh --acme-staging
```

At the end you should see `Release <id> is live`. The VM runs the whole
sandbox test suite under gVisor. This takes a few minutes. If a check says
`FAIL`, the script goes back to the old release by itself. On the first
deploy there is no old release: the runner is stopped and nothing broken
stays running. See "When something fails" below.

**c) Deploy for real.** Same release, real certificate:

```sh
runner/deploy/push.sh
```

Check from your laptop:

```sh
curl -s "https://$DOMAIN/health"
```

You should see JSON that starts with `{"status":"ok"`.

### Step 14. Test that the runner refuses strangers

```sh
curl -i -X POST "https://$DOMAIN/run" \
  -H 'content-type: application/json' -d '{"code":"fn main() {}"}'
```

The answer must be `401` with `"code":"app_check_missing"`. A runner that
runs code for anyone is a bug.

Also check that Caddy updates itself (it faces the internet, so security
releases matter). This lists the update sources the VM will use; Caddy's must
be among them:

```sh
ssh rust-runner 'sudo unattended-upgrade --dry-run -d 2>&1 | grep -i -e "allowed origins" -e cloudsmith | head'
```

If nothing mentions `cloudsmith`, tell the developer. Until it is fixed, run
`ssh rust-runner 'sudo apt-get install --only-upgrade caddy'` once a month.

---

## Part C. Check it end to end

### Step 15. Run a debug build against the real runner

Use the debug token from step 11.

```sh
export APP_CHECK_DEBUG_TOKEN=paste-your-uuid-here    # do not commit this

flutter run \
  --dart-define=RUNNER_URL=https://$DOMAIN \
  --dart-define=APP_CHECK_DEBUG_TOKEN=$APP_CHECK_DEBUG_TOKEN
```

For Chrome add `-d chrome`. Open a lesson, press **Run** on the hello world
code, and the output should appear.

If Run says "This copy of the app couldn't be verified": a debug build adds
"add its App Check debug token in the Firebase console" (step 11). A release
build says to update the app, or on the web to reload the page. Look at the
runner's log (the `auth_error` field says why):

```sh
ssh rust-runner 'sudo journalctl -u rust-runner -n 30 -o cat'
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

### Step 16. Add an uptime check

The Firebase project is a Google Cloud project, and Google's uptime checks
can watch any public address. In the Google Cloud console open **Monitoring →
Uptime checks → Create uptime check**:

- Protocol: **HTTPS**
- Hostname: `runner.example.com` (your domain)
- Path: `/health`
- Check every: **5 minutes**
- Response validation: **Content matches**, `"status":"ok"`
- Notification: create an **email** channel with your address

(Any other uptime service that can match text in the answer works as well.)

The runner says `"status":"unhealthy"` (HTTP 503) when no job has succeeded
for 30 minutes, when its keys are not loaded, or when the disk is nearly
full. A quiet runner stays healthy: after 10 minutes without traffic it runs
a small test job of its own (the self-check), and that counts.

---

## Part D. Release builds of the app

### Step 17. Build with the runner address

Always build with `RUNNER_URL`. A release build **without** it cannot run
code.

```sh
# Android (upload the .aab to Play, for example the internal testing track)
flutter build appbundle --release --dart-define=RUNNER_URL=https://$DOMAIN

# iOS (then upload with Xcode or Transporter)
flutter build ipa --release --dart-define=RUNNER_URL=https://$DOMAIN

# Web (needs the reCAPTCHA site key from step 9)
flutter build web --release \
  --dart-define=RUNNER_URL=https://$DOMAIN \
  --dart-define=APP_CHECK_WEB_SITE_KEY=your-recaptcha-site-key
```

Never pass `APP_CHECK_DEBUG_TOKEN` to a release build.

**After the first upload to Google Play, finish the Android part of step 9**
(items 2–4: the signing fingerprint, the Play Integrity link, and choosing
Play Integrity in App Check). Until then the Play build gets 401.

Things to know:

- Without Firebase set up, the app still starts. It just sends no App Check
  token, and the production runner then answers 401.
- A web build without `APP_CHECK_WEB_SITE_KEY` sends no token either.
- The web app's address must be in `RUNNER_ALLOWED_ORIGINS` (step 12).
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
`/opt/rust-runner/releases/<commit>` on the VM, together with the systemd unit
and the Caddy template it was tested with. The last three are kept. A release
that failed its checks is never kept as something to roll back to.

If the real-certificate deploy fails only because Caddy has not got its
certificate yet, the old release keeps running. Wait two or three minutes
(`ssh rust-runner 'sudo journalctl -u caddy -n 30 --no-pager'`), then run
`runner/deploy/push.sh` again.

### Roll back by hand

```sh
runner/deploy/push.sh --rollback
```

This goes to the previous release. Binary, settings, sandbox image, systemd
unit and Caddy settings all go back together. Run it again to go forward.

### Open a shell on the VM

```sh
ssh rust-runner
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
ssh rust-runner \
  'sudo journalctl -u rust-runner --since -7d -o cat | jq -c "select(.event==\"summary\")" | tail -50'
```

Look at the counts of 429, 401 and `internal`, the longest queue wait and the
free disk. Then skim the warnings:

```sh
ssh rust-runner 'sudo journalctl -p warning --since -7d --no-pager | tail -50'
```

A `mem_limit_rate_high` warning means abuse, or a host problem.

Also read any email from Oracle. It sends warnings about idle VMs and about
changes to the free limits.

If runs are often slow (`queue_wait_max_ms` above 2000) or you see many
`busy` answers: the Oracle free VM cannot be made bigger for free. Either live
with slower runs, pay Oracle for more CPUs, or move to the Google Cloud
fallback and its larger machine (Appendix).

### Monthly: upgrade gVisor, Docker and the sandbox image

Docker, containerd and gVisor are pinned and held, so they never upgrade by
themselves. Once a month:

1. Find the newest versions. Update both CPU types, even though you run only
   one, so that the fallback stays ready.
   ```sh
   # gVisor: version and sha256, for arm64 (Oracle) and amd64 (Google Cloud)
   curl -s https://storage.googleapis.com/gvisor/releases/dists/release/main/binary-arm64/Packages | grep -E '^(Version|SHA256):'
   curl -s https://storage.googleapis.com/gvisor/releases/dists/release/main/binary-amd64/Packages | grep -E '^(Version|SHA256):'

   # Docker and containerd (the same version string exists for both CPUs)
   curl -s https://download.docker.com/linux/ubuntu/dists/noble/stable/binary-arm64/Packages \
     | awk '/^Package: /{p=$2} /^Version: /{print p, $2}' \
     | grep -E '^(docker-ce|docker-ce-cli|containerd.io) ' | sort -V | tail -n 12

   # Sandbox image: the line "Digest:" at the top
   docker buildx imagetools inspect mirror.gcr.io/library/rust:<new tag>-slim-bookworm | head -3
   ```
2. Edit `runner/deploy/vars.sh`: `RUNSC_VERSION`, `RUNSC_DEB_SHA256_arm64`,
   `RUNSC_DEB_SHA256_amd64` (the download address follows the version),
   `DOCKER_VERSION`, `DOCKER_SEMVER`, `CONTAINERD_VERSION`.
3. To use a new Rust toolchain, change the image digest in **three** places,
   to the same value: the `FROM` line in `runner/deploy/Dockerfile.build`, the
   `FROM` line in `runner/sandbox.Dockerfile`, and `RUNNER_IMAGE` in
   `runner/deploy/production.env`. `push.sh` stops with a message if they
   differ.
4. Commit, then:
   ```sh
   runner/deploy/push.sh --upgrade-packages    # installs the versions, runs the checks
   runner/deploy/push.sh                       # deploys the new settings and image
   ```
   If anything goes wrong during `--upgrade-packages` (a failed download, a
   failed check), the old versions are installed again by itself.

   **Then you must undo the version bump in git.** `vars.sh` still names the
   new versions, but the VM has the old ones, so every normal deploy would
   fail its checks and roll itself back. Run `git revert <the commit that
   changed vars.sh>`, and look at the error before you try again.

Ubuntu security updates and Caddy updates install by themselves (Caddy is
included because it faces the internet; the update restarts it for about a
second). The VM reboots at 03:00 Vietnam time when an update needs it, and
comes back in about a minute.

### Stop paying for it

Oracle: **Compute → Instances → rust-runner → More actions → Terminate**, and
tick **Permanently delete the attached boot volume**. The account stays.
Then remove the DNS record. For Google Cloud see the Appendix.

---

## When something fails

| What you see | What to do |
|---|---|
| `push.sh`: "there are uncommitted changes" | Commit (or stash) first. The build uses the last commit. |
| `push.sh`: "still has REPLACE values" | Finish step 12 and commit. |
| `push.sh`: "the Rust image digest differs" | Make the three digests the same (Monthly, item 3). |
| `ssh` or `push.sh` hangs and times out | Your IP address changed. Edit the port 22 rule of the security list (step 5). |
| `Permission denied (publickey)` | The key is not loaded (`ssh-add ~/.ssh/rust-runner`) or `~/.ssh/config` names another key (step 6). |
| `oracle-launch.sh` keeps saying "no free A1 capacity" | See "Out of capacity" in step 6. Be patient, or use the Google Cloud fallback. |
| `setup-host.sh` fails on a download | Run `runner/deploy/push.sh --setup` again. It is safe to repeat. |
| `FAIL runsc is exactly ...` or other host checks | The VM does not match `vars.sh`. Run `push.sh --setup` again. |
| `FAIL iptables does not accept port ...` | Run `push.sh --setup` again. The original firewall file is in `/etc/iptables/rules.v4.before-rust-runner`. |
| Caddy cannot get a certificate | Check `dig +short $DOMAIN` (step 7), that the security list allows ports 80 and 443 (step 5), that the VM firewall does (`ssh rust-runner 'sudo iptables -S INPUT'` shows `--dport 80` and `--dport 443`), and `sudo journalctl -u caddy -n 50`. |
| The checks fail on the TLS certificate after the real deploy (step 13c), "the previous release is running again" | Caddy is fetching the real certificate. Wait two or three minutes, check `sudo journalctl -u caddy -n 30`, then run `runner/deploy/push.sh` again. |
| The certificate is still the test one after a few minutes | On the VM run `sudo systemctl restart caddy`. If that is not enough, run `sudo rm -r /var/lib/caddy/.local/share/caddy/certificates`, restart Caddy again, and then run `runner/deploy/push.sh` again. |
| `FAIL POST https://.../run without an App Check header ...` | The runner is up but answered something else. Run `curl -i` as in step 14 and read the answer. |
| `/health did not report ok` | `sudo journalctl -u rust-runner -n 100 -o cat`. A bad setting is listed there, all problems at once. |
| The first deploy failed and the runner is stopped | That is on purpose. Fix the problem (the log tells you), then run `push.sh` again. |
| `another setup, deploy, rollback or upgrade is running` | Two scripts ran at once. Wait for the first to end, then run yours again. The lock is released when a script ends, even if it failed. |
| After `--upgrade-packages` failed: normal deploys fail on "runsc version" or "docker server" | Undo the bump in git (`git revert`, see Monthly item 4), then deploy. |
| Runner says `app_not_allowed` (403) | The app's ID is missing in `RUNNER_APP_CHECK_APP_IDS`. Fix, commit, deploy. |
| The app says "couldn't be verified" | Step 9 is not complete for that platform (Android: after the first Play upload), or the build has no token (step 15 has the log command). In a debug build the debug token is not registered (step 11). |
| The browser shows a CORS error | The web address is missing in `RUNNER_ALLOWED_ORIGINS` (both the `.web.app` and the `.firebaseapp.com` one if you use Firebase Hosting). |
| The app says "You're running code very quickly" | A rate limit. Wait the number of seconds it shows. |
| A release made things worse | `runner/deploy/push.sh --rollback`. |

---

## Appendix. Google Cloud as the host (the fallback)

Use this when Oracle has no capacity, or if Oracle ever withdraws the free
tier. It costs about US$36–40 per month. The scripts need only a setting to
switch: `PROVIDER=gce`.

The VM is an `e2-medium` (x86_64). The kit builds an x86_64 binary for it and
the VM picks the right gVisor and Docker packages by itself. Steps 1, 2 and 7
to 17 are the same, with these changes:

- In step 12 the local settings file says:
  ```sh
  printf 'PROVIDER=gce\nPROJECT=rust-learn-12345\n' > runner/deploy/local.env
  ```
  (use your project ID). `REGION`, `ZONE` and `VM` in `vars.sh` default to
  `asia-southeast1`, `asia-southeast1-b` and `rust-runner`.
- Instead of `ssh rust-runner ...`, commands on the VM go through Google's
  IAP tunnel:
  ```sh
  gcloud compute ssh rust-runner --zone "$ZONE" --tunnel-through-iap -- 'sudo journalctl -u rust-runner -n 30 -o cat'
  ```
- `push.sh` runs `gcloud compute ssh` with `--quiet`. If `gcloud` has to
  create an SSH key, it makes one **without** a passphrase. To use a
  passphrase, open a shell once yourself before the first `push.sh`
  (`gcloud compute ssh rust-runner --zone "$ZONE" --tunnel-through-iap`) and
  choose one there.
- Instead of steps 3 to 6 do the following.

**G1. Tools and project.**

```sh
# also install the gcloud CLI: https://cloud.google.com/sdk/docs/install
gcloud auth login
export PROJECT_ID=rust-learn-12345        # your project ID (step 2)
export REGION=asia-southeast1             # Singapore
export ZONE=asia-southeast1-b
gcloud config set project "$PROJECT_ID"
```

**G2. Billing and a budget alert (required).** The VM needs billing. Linking
billing moves the Firebase project to the Blaze (pay as you go) plan. The free
quotas stay the same.

1. Open <https://console.cloud.google.com/billing>. Link a billing account
   to the project.
2. Create a budget: **Billing → Budgets & alerts → Create budget**. Scope:
   this project. Amount: **US$60** per month. Alerts at 50 %, 90 % and
   100 %, by email. A budget alert does not stop spending. It tells you
   early.

Command line version (find your billing account ID with
`gcloud billing accounts list`):

```sh
gcloud services enable billingbudgets.googleapis.com
gcloud billing budgets create --billing-account=XXXXXX-XXXXXX-XXXXXX \
  --display-name="Runner budget" --budget-amount=60USD \
  --filter-projects="projects/$PROJECT_ID" \
  --threshold-rule=percent=0.5 --threshold-rule=percent=0.9 \
  --threshold-rule=percent=1.0
```

Without `--filter-projects` the budget counts every project in the billing
account. If `gcloud` says the project is not valid, use the project number
instead of the ID (`projects/123456789012`).

**G3. Create the VM.** Turn on the services and give yourself access. You are
the project owner, so the role commands may say nothing changed.

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

**G4. Firewall.** Open the web ports to the world, and SSH only to Google's
IAP range. Then delete the default rules that would leave SSH and RDP open.

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

**G5. The address.**

```sh
gcloud compute addresses describe rust-runner-ip --region "$REGION" --format='value(address)'
```

Use that IP in the DNS record of step 7.

**Make it bigger.** If runs are often slow, stop the VM, change the machine
type to `e2-standard-2`, start it, and raise `RUNNER_MAX_JOBS` in
`production.env`.

**Stop paying for it.**

```sh
gcloud compute instances delete rust-runner --zone "$ZONE"
gcloud compute addresses delete rust-runner-ip --region "$REGION"
```

**Switching between Oracle and Google.** Create the other VM, point the DNS
record at it, set `PROVIDER` in `runner/deploy/local.env`, then run
`runner/deploy/push.sh --setup` and `runner/deploy/push.sh`. Both VMs run the
same code. `push.sh` builds the right binary for the provider you chose.

---

## What is in this folder

| File | What it is |
|---|---|
| `push.sh` | Runs on your laptop. Builds, uploads, installs. |
| `oracle-launch.sh` | Runs on your laptop. Creates the Oracle VM and retries when Oracle has no capacity. |
| `local.env` | Yours, not in git. `SSH_HOST`, `SSH_KEY`, `PROVIDER`, ... |
| `Dockerfile.build` | The cross-build recipe (aarch64 or x86_64 Linux, no QEMU, glibc 2.36). |
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
