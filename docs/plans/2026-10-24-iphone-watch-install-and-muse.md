# NOOP on iPhone + Apple Watch Ultra, always connected, plus Muse

- **Plan revision:** r2, 2026-10-24. r1 was approved by the user on 2026-10-24 with D1 = (a), D2 = (a), D3 = (a).
- **Status:** approved, implementing. r2 records the decisions and the concrete R6 design (see "Revision r2").
- **Repo:** `~/noop`, `main` at `37b660a` (v2.8.6), upstream `NoopApp/noop`, plus uncommitted watch work from 2026-06-17.

## Problem statement

The user wants to stop paying for a WHOOP membership. To do that, NOOP has to cover what the official app covers day to day:

1. Running on their own iPhone 17 Pro and Apple Watch Ultra 2, not only the Mac.
2. Staying connected to their WHOOP 4.0 strap all the time, so history keeps building without them opening the app.
3. Being glanceable from the wrist.
4. Connecting to "Muse". What that means is not settled yet (see D1).

**Facts found (verified):**

- The strap on record is a **WHOOP 4.0**. The Mac NOOP database lists one device, "WHOOP 4.0", with about 40k HR samples and 11k R-R intervals.
- The working tree already has an **uncommitted watch app**: a watch target, a complication, iPhone-to-watch snapshot sync, and a "Start Live" direct-to-strap mode. It is about 1,360 lines plus project changes.
- That work **builds**. With signing disabled, `xcodebuild -scheme NOOPiOS` succeeded and embedded `NOOPWatch.app` inside `NOOP.app/Watch`.
- The iPhone app already declares `bluetooth-central` background mode and uses Core Bluetooth state restoration, so the phone can keep the strap connected in the background.
- The WHOOP 4.0 exposes the standard heart-rate characteristic (0x2A37). NOOP's code notes it "works unbonded". So the watch can read live HR and R-R from it directly.
- The strap holds **one Bluetooth connection at a time**, per the repo's protocol docs. Phone and watch cannot both be connected at once.
- Xcode on this Mac has two signing teams: a **paid company team** ("RevitalizedAI LLC", whose profiles last 365 days) and a **free Personal Team**. The iPhone 17 Pro is paired and available. The Watch Ultra 2 shows as "unavailable" right now; it must be unlocked, on the charger, and near the Mac or phone to install.
- The app installed as `/Applications/Muse.app` is **Meta's "Muse" agent app** (`com.meta.endo`, an internal Meta build). It is **not** the Interaxon Muse EEG headband app. It supports MCP servers.

**Gaps in the existing watch work (found in review):**

- Watch direct mode stops whenever the watch app leaves the foreground. Wrist-down kills it, so it is not "always connected".
- HR collected by the watch is shown but never sent back to the phone. Workouts recorded by the watch leave a hole in history.
- The watch UI says "Recovery". The app renamed that score to **Charge** in v2.6.0.
- Bundle IDs are `com.noopapp.*`. Signing under either of the user's teams needs a team-unique prefix.

**Assumptions:** watchOS limits background Bluetooth for third-party apps. A running `HKWorkoutSession` is the supported way to keep a watch app (and its Bluetooth link) alive with the wrist down. This comes from Apple docs and forum answers but has not been tested on this watch. It also needs the HealthKit entitlement, which free Personal Teams are widely reported not to get. The R4 spike verifies this first.

## Proposed solution overview

Make the **iPhone the always-on collector** and the **watch the window**. The phone holds the strap connection 24/7 in the background, stores everything, and computes scores. The watch shows Charge, live HR, battery, and data freshness from the phone, with a watch-face complication. For workouts away from the phone, the watch takes over the strap through a workout session that survives wrist-down. It hands the samples back to the phone afterwards, so history has no gap. Then sign everything under one team and install it on both devices, with a runbook so re-installs are repeatable.

Muse integration is designed only after D1 is answered.

### Visual overview

```mermaid
flowchart LR
    strap["WHOOP 4.0 strap<br/>(one connection at a time)"]
    subgraph phone["iPhone 17 Pro: always-on collector"]
        ble["BLEManager<br/>background + state restoration"]
        db[("Local SQLite<br/>history + scores")]
        pub["WatchSnapshotPublisher"]
    end
    subgraph watch["Watch Ultra 2: window + workout fallback"]
        glance["Glance: Charge, HR,<br/>battery, freshness"]
        comp["Complication"]
        wk["Workout mode (NEW)<br/>HKWorkoutSession keeps BLE alive"]
        buf["Sample buffer (NEW)"]
    end
    muse["Muse (D1: Meta agent app<br/>OR EEG headband)"]

    strap -- "default: 24/7" --> ble --> db --> pub
    pub -- "WatchConnectivity snapshot" --> glance
    glance --> comp
    strap -. "workout only: handoff" .-> wk --> buf
    buf -- "transferUserInfo after workout (NEW)" --> db
    db -. "D1 decides direction" .- muse
```

![Rendered overview](assets/2026-10-24-watch-overview.png)

*Solid lines: the normal path, mostly existing code. Dotted lines: the workout handoff and Muse, which are new. "NEW" marks what this plan adds.*

## Decisions (resolved at G1)

| ID | Question | Options | Recommendation |
|---|---|---|---|
| D1 | Which "Muse"? | **(a)** Meta's Muse agent app on this Mac. NOOP would expose read-only summaries to it through a local MCP server. **(b)** The Interaxon Muse EEG headband. NOOP would pair to it over Bluetooth and record meditation/EEG sessions next to HRV. | Ask. These are unrelated projects. (a) sends health summaries into a Meta prototype app, which breaks NOOP's "nothing leaves the device" promise. (b) reverse-engineers a second device protocol, which is bigger. |
| D2 | Which signing team? | **(a)** Paid "RevitalizedAI LLC" team: 1-year profiles, HealthKit, App Groups. **(b)** Free Personal Team: re-sign every 7 days, likely no HealthKit, so no workout mode and no Apple Health. | (a), if it is acceptable to put a personal app under the company account. (b) breaks "always connected" every 7 days and blocks R4. |
| D3 | Where does the code go? | **(a)** A private fork under `vnguyendc`, with a PR inside that fork. **(b)** A PR to upstream `NoopApp/noop`. **(c)** A local branch only. | (a). The bundle-ID and team changes are personal and do not belong upstream. A clean watch PR can go upstream later. |

## Revision r2 (2026-10-24, after approval)

- **D1 = (a):** Meta's Muse agent app. **D2 = (a):** the RevitalizedAI LLC team. **D3 = (a):** a private repo under `vnguyendc`. GitHub does not allow a fork of a public repo to be private, so this is a private copy of upstream, not a GitHub "fork".
- **R6 mechanism changed from a local MCP server to Apple Health.** Inspecting Muse 9.0 (`com.meta.endo`) showed no way to register a local stdio MCP server. Its "custom connectors" are API-key or OAuth cloud services, and its local connectors are built in. It does ship an **Apple Health connector**, and its own UI text says: "Apple Health is only on iPhone. Open the app on your iPhone to connect or manage it." NOOP's iPhone app already writes daily resting HR, HRV (SDNN), SpO₂ and respiratory rate into Apple Health, deduplicated per day. So R6 becomes: sign with HealthKit (D2), turn on NOOP's Apple Health write-back, connect Muse's Apple Health connector on the iPhone, and confirm Muse answers from NOOP-written data. No new server code. This narrows scope and adds no new data path beyond the one the user chose in D1.
- **R6 limitation:** Charge, Effort and Rest have no Apple Health type, so Muse will not see those scores directly. It sees the underlying vitals plus the Apple Watch's own data.

## Revision r3 (2026-10-27, approved)

Approved by the user on 2026-10-27: "approved, go ahead with r3".


Two facts from the real devices change the plan. The strap is a **WHOOP 5.0** ("VINHS WHOOP"), not the 4.0 from the Mac database. The watch is a new **Apple Watch Ultra 4** (Watch8,1), not the Ultra 2. Both items listed as out of scope, WHOOP 5.0 specifics and TestFlight, are now in scope.

**Install route: TestFlight.** The user approved it on 2026-10-27 ("yes test flight please"). The Ultra 4 can't run development builds: it was never seen by Xcode, so Developer Mode can't be enabled, and it isn't in the team's profiles. Build 2.8.6 (50) is uploaded and installed on both devices through TestFlight. To pass App Store validation it needed opaque full-bleed iOS and watch icons (`Tools/make_icon.py` now writes `noop_icon_ios_1024.png`), a single 1024 watch icon, and matching widget build numbers. TestFlight builds expire after 90 days, so a refresh means bumping `CURRENT_PROJECT_VERSION`, archiving and uploading again.

**Defect found during R4: the watch workout ends a few seconds after it starts.**
- *Symptom:* tap Start workout on the watch. It connects briefly, then shows "Your iPhone took the strap back after the watch lost it."
- *Evidence from the phone strap log:* this happened four times (13:54:05, 13:54:12, 13:57:03, 13:57:07). Each time the phone let go ("Disconnected (intentional)"). 1 to 3 s later it set up its pending connect, and that connect completed in the same second.
- *Evidence from a second central:* a read-only CoreBluetooth probe on the Mac (14:00:13 to 14:00:53) found the strap advertising as connectable. It connected as a second central and received 35 standard HR notifications, with R-R intervals. The phone was almost certainly still connected at the time; the log copied at 13:57 shows it connected.
- *Root cause:* `WatchDirectHandoffCoordinator` assumes the strap accepts one connection at a time. So when the phone's pending connect completes, it reads that as "the watch let go" (`phoneReconnected()`), tells the watch, and the watch ends its workout. The WHOOP 5.0 accepts a second connection, so the phone reconnects while the watch is still connected. This assumption was never checked, and is unverified for the 4.0 too.

**Proposed fix (small, covered by tests):**
1. **Phone:** when the selected strap is a WHOOP 5.0/MG, don't hand the strap over when the watch starts a workout. The phone stays connected and keeps collecting, and the watch connects alongside it. Samples from both land in the same history, and inserts already dedupe to one row per second. The 4.0 path is unchanged.
2. **Watch:** ignore the phone's "took the strap back" notice while the watch itself is connected to the strap. With a one-connection strap the phone can't reconnect while the watch holds it, so this only removes the false positive.
3. **Tests:** add coordinator tests for "shared strap: start/stop is a no-op and never reports a reclaim", alongside the existing 4.0 tests.
4. **Rebuild** as 2.8.6 (51) and upload to TestFlight the same way.

**Requirement changes:**
- **R4:** for a WHOOP 5.0/MG, the phone stays connected during a watch workout instead of disconnecting. Both devices stay connected. The watch records HR and R-R with the wrist down for 30 min or more, and End workout leaves the phone's connection untouched. For the 4.0 nothing changes.
- **R1:** "Watch Ultra 2" becomes "Watch Ultra 4", installed via TestFlight.

**Not changed:** the 25 s grace before a 4.0 phone re-arms is short for a first-time strap tap on the watch. This is P2, recorded here and not fixed, because the user's strap is a 5.0.

## Revision r4 (2026-10-28, approved)

Approved by the user on 2026-10-28: "approved, go ahead with r4".


**Finding: NOOP's iPhone app never asks for Apple Health permission, so nothing reaches Apple Health or Muse.**
- `HealthKitBridge.requestAuthorization()` exists, but nothing in the iOS app calls it. A repo-wide search finds only its definition.
- `HealthKitBridge.sync()` does both the import and the write-back, and it returns immediately unless `auth == .authorized`. So it never runs.
- `auth` lives only in memory, so even a granted permission would be forgotten on relaunch.
- The Apple Health screen tells iPhone users to export and import a .zip instead.
- r2's statement that NOOP "already writes" resting HR, HRV, SpO₂ and respiratory rate to Apple Health was wrong. The code exists but can't be reached. As built, R6 cannot pass.

**Proposed fix (needed for R6, iPhone only):**
1. **Connect card on the Apple Health screen.** Add a card at the top of the screen (More → Data → Apple Health).
   - *Not connected:* one sentence saying what NOOP reads and what it saves, and a **Connect Apple Health** button. The button opens the system permission sheet, then syncs.
   - *Connected:* "Connected to Apple Health" with the last sync time, and the last error in orange if there is one.
   - *Empty state:* on iPhone it points at Connect rather than the export and import steps.
   - This asks for permission only on a tap, after explaining why, which follows Apple's guidance and the existing code comment.
2. **Remember the permission.** At launch the bridge checks HealthKit's *write* authorization for NOOP's four write types. If any is granted it treats Health as connected, so syncing carries on after a relaunch. HealthKit never reveals read permission, but write status is visible.
3. **Tests:** cover the launch-time status decision as a pure function.
4. **Rebuild** as 2.8.6 (52) and upload to TestFlight.

**Limits (unchanged code paths):**
- The sync runs when NOOP comes to the foreground. Apple Health, and so Muse, gets each day's values the next time NOOP is opened, not in the background.
- Muse sees only the four daily vitals (see r2).

**UI/UX research:** Mobbin still requires a paid plan (checked again 2026-10-28), and Refero was not used. The design follows Apple's HealthKit guidance: explain before asking, and ask only on a user action. It reuses the existing `NoopCard` and `StrandFont` tokens. The rendered screen gets the frontend-skill and frontend-design review before the PR.

**R6 check after the fix:**
1. Connect in NOOP.
2. Health app → Browse → Heart → Resting Heart Rate → Data Sources & Access lists NOOP, and the values match NOOP.
3. Connect Muse's Apple Health connector on the iPhone.
4. Ask Muse about this week's resting HR and HRV. The answer matches NOOP.

## Revision r5 (2026-10-29, approved)

Approved by the user on 2026-10-29 ("yes"). They also created API key `HZNAHNPC3A` and downloaded it as a file, which checks as a valid private key without being printed.


The user asked: "can we do the upload and install programatically? so i dont have to do manual steps".

**What becomes automatic:**
1. **Upload: `Tools/testflight.sh`.** The script:
   - Archives the app.
   - Uploads it with an App Store Connect API key (`xcodebuild -exportArchive`, `destination=upload`). Xcode picks the next build number itself (`manageAppVersionAndBuildNumber`).
   - Waits until App Store Connect finishes processing.
   - Adds the build to the internal testing group, if the group doesn't pick it up automatically.
   - Takes the key ID, issuer ID and key path from the environment or a git-ignored config, and never prints the key.
2. **Encryption question: answered in the app.** Set `ITSAppUsesNonExemptEncryption = NO` in the iPhone app's Info.plist. This is the same answer the user gave for builds 50 to 52: only Apple's standard HTTPS, no custom cryptography. App Store Connect then stops asking. It remains the user's declaration to Apple.
3. **Install: TestFlight automatic updates.** A one-time toggle in TestFlight on the iPhone, so each new build installs by itself. The watch app updates with the iPhone app. Timing is up to iOS, and opening TestFlight speeds it up.

**One-time steps that stay with the user:**
- Create an App Store Connect API key (Admin) and **download** the .p8 file. Don't copy its text.
- Turn on Automatic Updates for NOOP Vinh in TestFlight.

**Not possible:** installing a TestFlight build with `devicectl`. That only installs development builds, and the watch can't run those.

**Check:** run the script once, upload build 52, then confirm:
- The build shows as ready to test with no compliance prompt.
- It appears in the TestFlight app.
- It installs on its own.

**Fallback:** if API-key signing fails (for example because the key can't create a distribution certificate), the Organizer upload still works.

## Context

- **Classification:** feature (watch companion completion + install), plus configuration (signing), plus an integration (Muse, scope pending D1). Severity: not a defect. Urgency is set by when the user wants to cancel.
- **Inspected:** README, `docs/IOS.md`, `docs/BUILD.md`, `project.yml` and its diff, every uncommitted watch file, the `BLEManager` background and standard-HR paths, the CHANGELOG, the Mac NOOP database (a read-only copy), Xcode teams and profiles, connected devices, and the Muse app bundle.
- **External research:** Apple program-enrollment and capabilities pages. Neither states Personal Team limits for HealthKit or App Groups. Third-party reports say Personal Teams get 7-day profiles and up to 10 App IDs per 7 days, without HealthKit. watchOS extended-runtime and workout-session references cover background Bluetooth. Muse headband protocol references are community-made (muse-js, muse-lsl, muse-rs).
- **UI/UX research limit:** Mobbin returned "requires a paid plan" and Refero was not reachable. The watch UI follows Apple's watchOS HIG for glanceable single-metric screens and complication families, plus the existing NOOP design tokens in `StrandDesign`. No competitor screenshots were compared.
- **Out of scope:** WHOOP 5.0/MG specifics, App Store or TestFlight distribution, Android, changing the scoring math, and any upstream release.
- **Subscription risk (for the user, not code):** export the WHOOP CSV before cancelling and import it into NOOP. After cancelling, keep the official app from updating the strap firmware, because a firmware update can reset pairing (NOOP shows a re-pair guide when that happens). Using third-party apps may conflict with WHOOP's terms. That is the user's call.

## Requirements and acceptance criteria

| ID | Requirement | Acceptance criteria |
|---|---|---|
| R1 | Signed install on both devices | NOOP launches on the iPhone 17 Pro and NOOPWatch launches on the Watch Ultra 2, both signed by the D2 team. The profile expiry date is recorded. |
| R2 | Phone stays connected in background | With the app backgrounded and the phone locked for 2 h or more, new HR samples keep landing in the store. After a Bluetooth toggle or the strap going out of range and back, it reconnects without opening the app. |
| R3 | Watch glance + complication | The watch shows Charge, live HR, battery, and "updated N min ago" from the phone. It flags stale data after 15 min. The complication renders in circular, inline, and rectangular families. The copy says "Charge", not "Recovery". |
| R4 | Watch workout mode survives wrist-down | Starting a workout on the watch takes over the strap (the phone disconnects), records HR and R-R, and keeps receiving with the wrist down for 30 min or more. Ending it hands the strap back to the phone, which reconnects. Without HealthKit (D2 = b), the UI says workout mode is unavailable rather than failing silently. |
| R5 | Watch samples reach phone history | After a watch workout, its HR and R-R samples appear in the phone store within 1 min of the watch reaching the phone. Re-delivery creates no duplicates. Tests cover the encode/decode and dedupe logic. |
| R6 | Muse can read NOOP data | With the D2-signed build, NOOP's Apple Health write-back succeeds (no `lastError`), and NOOP-sourced resting HR, HRV, SpO₂ and respiratory rate samples appear in Apple Health. After connecting Muse's Apple Health connector on the iPhone, Muse answers a question about recent HRV or resting HR with values matching NOOP. |
| R7 | Repeatable install runbook | `docs/plans/` or `docs/IOS.md` gains steps to re-sign and re-install on both devices, including how to bring the watch online for Xcode. |
| R8 | No regressions | Existing package tests and the macOS + iOS builds still pass. The upstream bundle-ID default is unchanged for other builders (team and bundle overrides sit in a local, git-ignored config). |

## Design

- **Signing (R1, R8):** add `Config/Local.xcconfig` (git-ignored) with `DEVELOPMENT_TEAM` and `BUNDLE_ID_PREFIX`. `project.yml` then uses `$(BUNDLE_ID_PREFIX)` for the 4 bundle IDs, the App Groups, and `WKCompanionAppBundleIdentifier`, defaulting to `com.noopapp`. This avoids hard-coding the user's team into shared files. *Alternative:* edit the IDs in place on a personal fork. That is simpler but leaks into any upstream PR.
- **Phone background (R2):** no new mechanism is planned. The existing restoration and auto-rescan get verified on device. Fixes happen only if R2 fails.
- **Watch workout mode (R4):** replace "Start Live" with "Start Workout". It starts an `HKWorkoutSession` (activity type `other`), then the existing `WatchDirectBLEClient`. The `scenePhase` auto-stop is removed while a session runs. The existing `WatchDirectHandoffCoordinator` already disconnects and reconnects the phone. *Alternative:* `WKExtendedRuntimeSession`. Rejected because its session types are time-capped and do not fit open-ended workouts.
- **Sample hand-back (R5):** the watch buffers `(timestamp, bpm, rr[])` in memory. Every 60 s, and on workout end, it sends batches with `WCSession.transferUserInfo`, which the system persists and delivers once the phone is reachable. *(r2 note: the buffer is not written to a file. A watch-app crash can lose up to the last 60 s of samples. That is disclosed as P3.)* The phone inserts through existing `WhoopStore` insert paths, keyed on timestamp, so duplicates are dropped. The codec lives in `StrandiOSShared` so the iOS test target can test it.
- **UI (R3, R4):** keep the current single-scroll layout. Rename the score to Charge. Make the primary action one full-width button. Show workout state with elapsed time, large HR, R-R count, and battery. Use the system green/yellow/red Charge bands the app already uses.
- **Muse (R6):** use NOOP's existing Apple Health write-back plus Muse's iPhone Apple Health connector. No code change unless verification finds a write-back defect.

## Task breakdown

| # | Task | Depends on | Likely files | Reqs | Verification seam |
|---|---|---|---|---|---|
| T1 | Branch and fork per D3. Commit the existing watch work as its own commit. | D3 | git | R8 | Clean build as found |
| T2 | Local signing override and parameterized bundle IDs | D2 | `project.yml`, `Config/Local.xcconfig`, `.gitignore` | R1, R8 | Signed build for device |
| T3 | Spike: HKWorkoutSession + BLE with wrist down on the real watch | T2 | `StrandWatch/*` | R4 | 30 min on-wrist test |
| T4 | Workout mode + HealthKit entitlement on the watch | T3 | `StrandWatch/*`, `project.yml` | R4 | Unit tests (reducer) + device |
| T5 | Watch sample buffer, codec, phone ingest with dedupe | T4 | `StrandiOSShared/WatchSamples.swift`, `StrandiOS/Watch/*`, tests | R5 | Unit tests + device |
| T6 | Watch UI copy and polish (Charge, workout state) | T4 | `WatchGlanceView.swift`, `NOOPWatchWidget.swift` | R3 | Screenshots on the watch and simulator |
| T7 | Install on both devices; 2 h background soak on the phone | T2 | none | R1, R2 | Device logs + store row counts |
| T8 | Muse via Apple Health: enable write-back, connect Muse on iPhone | T7 | none expected | R6 | Health app shows NOOP as source; Muse answer matches |
| T9 | Runbook | T7 | `docs/IOS.md` | R7 | Follow it from a clean state |

## Validation and delivery

- **Implementation checks:** `swift test` in the 5 packages, the `NOOPiOSTests` target, and builds for the `Strand` (macOS), `NOOPiOS`, and `NOOPWatch` schemes.
- **Independent behavior checks (verifier):** R1 to R5 on the real iPhone 17 Pro and Watch Ultra 2 with the user's WHOOP 4.0. The user has to wear the watch for the R4 soak and keep the strap nearby for R2. Simulator screenshots alone do not count for R3.
- **UI/UX review:** `frontend-skill` + `frontend-design` review of the watch glance, workout, and complication screens, using rendered screenshots.
- **Delivery:** a PR per D3 (default: a private fork, `feat/watch-always-connected` into the fork's `main`). No upstream PR, merge, or release without separate approval. Upstream CI (`app-build.yml`, `swift-packages.yml`) runs only if D3 = b.
- **Risk to watch:** if T3 shows watchOS drops the strap link with the wrist down even inside a workout session, R4 falls back to "watch live view while the app is open". The phone stays the 24/7 collector either way.

## Task and evidence record (updated during implementation)

- **Stage:** verification in progress. The signed iPhone install is done (2026-10-26). The watch install and the on-device checks R2 to R6 are waiting on the user (see Blockers).
- **Branch:** `feat/watch-always-connected` from `37b660a`. The June watch work is commit `1fbb607` and this plan is `9f07c10`. Later changes sit on top of those.
- **Not in the candidate:** `Strand/Resources/Localizable.xcstrings` has an uncommitted Xcode re-extraction diff from before this task. It is left untouched and unstaged.

### Checks run

| Check | Result |
|---|---|
| `NOOPiOSTests` (iPhone 17 Pro simulator) | 22 tests, 0 failures. Covers sample batching and dedupe, the phone's 10-minute watch timeout, stale-message drop, app-group fallback, and the reconnecting state. |
| `swift test` in the five packages | WhoopProtocol 156, WhoopStore 93, StrandAnalytics 213, StrandImport 88, StrandDesign 19. All pass. |
| `xcodebuild` NOOPiOS (device, unsigned) and Strand (macOS) | Both build. |
| Simulator: Ultra 3 (49 mm) watch paired with an iPhone 17 Pro | The phone-to-watch snapshot sync works. Not-synced, synced-empty, Bluetooth-failed and workout-permission states were rendered and inspected. |
| Signed device build (`-allowProvisioningUpdates`) | **Blocked.** Xcode error: "Unable to log in with account 'vnguyendc@gmail.com'. The login details … were rejected." No signing identity is in the keychain. |
| Signed device build, 2026-10-26, Xcode 27.1 (`-allowProvisioningUpdates`, iPhone 17 Pro) | **Succeeds.** All four bundles are signed by team `LNXKQ7ULUL`: `com.vnguyendc.noop`, `.widgets`, `.watchkitapp` and `.watchkitapp.widgets`. Entitlements: HealthKit on the phone and watch apps; App Groups `group.com.vnguyendc.noop` and `.noop.watch`. Info keys: phone `UIBackgroundModes` = bluetooth-central; watch `WKBackgroundModes` = workout-processing and `WKCompanionAppBundleIdentifier` = `com.vnguyendc.noop`. Earlier attempts failed with `No Account for Team "LNXKQ7ULUL"` because the team's Apple Developer membership had lapsed. The user renewed it. |
| Install on iPhone (`devicectl device install app`) | **Installed.** `com.vnguyendc.noop` 2.8.6 is on the iPhone 17 Pro. The watch was "unavailable" to the Mac, so the watch app is installed from the iPhone's Watch app instead (it is embedded in `NOOP.app/Watch`). |
| Re-run on Xcode 27.1 (Xcode updated itself on 2026-10-24) | `NOOPiOSTests` 28 tests, 0 failures. `swift test`: WhoopProtocol 156, WhoopStore 93, StrandAnalytics 213, StrandImport 88, StrandDesign 19. All pass. The device build shows no new warnings; only the existing BLEManager actor-isolation notes and a watch app-icon "unassigned child" warning. |
| TestFlight build 2.8.6 (50), 2026-10-27 | **Uploaded and installed.** Release archive with opaque 1024 icons for the phone and the watch, all four bundles at 2.8.6 (50), and no icon warnings. `xcodebuild -exportArchive` failed with "No Accounts" both inside and outside the sandbox, although the account is signed in to Xcode. The user uploaded from Organizer instead (TestFlight Internal Only); the log says "UPLOAD SUCCEEDED with no errors", delivery `49edb6b0-8732-4cbd-877a-ff058bdd25bc`. The App Store Connect record "NOOP Vinh" (6827622152) was created; "NOOP" was taken by another account. Installed through TestFlight on the iPhone and the Ultra 4. |
| R4 on device, build 50, 2026-10-27 | **Failed.** Start workout on the watch: the watch connected briefly, then showed "Your iPhone took the strap back after the watch lost it." The phone strap log shows 4 attempts, each with the pending connect re-armed 1 to 3 s after letting go and completing immediately. Root cause: see r3. |
| Second-central probe from the Mac, 2026-10-27 14:00 | The WHOOP 5.0 advertised as connectable (service 180D) and accepted the Mac as a second central: 35 HR notifications in 35 s, R-R included, then a clean disconnect. |
| r3 fix: `NOOPiOSTests` (iPhone 17 Pro simulator) | 30 tests, 0 failures. That is the 28 existing plus `testStrapThatTakesTwoConnectionsIsNeverHandedOver` and `testOneConnectionStrapStillReportsReclaim`. With the coordinator guard removed, the first new test fails with 4 assertions (`disconnectPhone`, then `armPhoneFallback`, then a reported reclaim). So it reproduces the bug. |
| r3 fix: Release archive 2.8.6 (51) and macOS `Strand` build | Both succeed. All four bundles are at 2.8.6 (51). The changed files add no new warnings. The packages are unchanged since the last `swift test` run (569 tests, all pass). |
| R4 on device, build 51 (TestFlight, uploaded 2026-10-27 15:47, delivery `c830fbe0-c1d5-4c7e-a34d-eeca3048fb07`) | **Pass, by the user's report** ("yes awesome it works!", 2026-10-28). Start workout on the Ultra 4 stayed live, and End workout returned to the normal screen. No screenshots or strap log came with it, so there is no independent record. |
| r4 fix: `NOOPiOSTests` (iPhone 17 Pro simulator) | 35 tests, 0 failures. That is the 30 from r3 plus 5 `AppleHealthConnectionTests`: no Health, never asked, granted earlier, asked but saving denied, and a new type to ask for after an update. |
| r4 fix: Release archive 2.8.6 (52), macOS `Strand` build, simulator Debug build | All succeed. All four bundles are at 2.8.6 (52), and the phone app keeps the HealthKit entitlement. The changed files add no new warnings; the remaining ones (one deprecated `onChange` on the range control, two unused `try?`, two `dayString` isolation) were already there. Self-review fix: write-back now saves only the types the user allowed, because a partial grant would otherwise make HealthKit reject the whole save. |
| r4 rendered UI in the simulator | **Blocked.** Computer use was held by another Claude session (84ed9e52), so the simulator couldn't be tapped past the What's new sheet to the Apple Health screen. The rendered review moves to the user's device screenshots of build 52. |
| r5: `Tools/testflight.py`, first run 2026-10-29 21:11 | **Uploaded, wrong number.** The API key (HZNAHNPC3A, Admin) signed and uploaded from the command line, which the Xcode account login never managed. But Xcode's `manageAppVersionAndBuildNumber` kept the project's own build number (49), and App Store Connect accepted it. 49 is below the installed 51, so TestFlight never offered it. Fix: the script reads the highest build number from App Store Connect and passes `CURRENT_PROJECT_VERSION=<max+1>`. |
| r5: second run 2026-10-29 | **Pass.** Build 52 uploaded, processed (`VALID`) and released through the "Me" group, which gets every build. `usesNonExemptEncryption` was already `false` on the build, so no compliance prompt. Install on the iPhone and watch is still the user's to confirm. |

### UI/UX review (frontend-skill + frontend-design, applied to watchOS)

- **Approach:** one dominant number per screen (Charge on the glance, heart rate in the workout), utility copy, NOOP green as the single accent, and red only for the destructive action.
- **Fixed during review:**
  - The ring label was truncated ("Char…") and duplicated the heading. The label was removed.
  - The watch and complication showed an invented Charge of 72 before the first sync. They now show dashes and "Open NOOP on your iPhone to sync."
  - "End workout" inherited the green tint. It is now red.
  - **P1:** a Bluetooth failure hid the live screen while the phone stayed disconnected. The screen now follows the session, with "Search again" and "End workout".
- **Not yet seen rendered:** the connected heart-rate reading, the scanning list and the elapsed timer. The simulator has no Bluetooth, and the workout permission sheet needs a tap. These are covered on device.
- **Evidence:** screenshots in the session scratchpad: `01-glance-not-synced.png`, `02-glance-synced.png`, `03-workout-start.png`, `05-live-bluetooth-failed.png`.

### Independent review, round 1 (feature-dev code-reviewer agent; reads code only, cannot run it)

Findings and resolutions:

- **P1:** the phone's 10-minute timeout can't run while iOS has the app suspended after hand-off. **Fixed.** Once the watch holds the strap (or after a 25 s grace), the phone arms a pending Bluetooth connect to the known strap (`BLEManager.awaitStrapReturn`). The system completes it in the background the moment the watch lets go, for any reason.
- **P2:** an out-of-order start or stop across the three delivery channels. **Fixed.** Changes are timestamped, and anything not newer than the last applied change is ignored.
- **P2:** heartbeats kept flowing while the watch never held the strap. **Fixed.**
  - Heartbeats are sent only while connected.
  - A watch watchdog hands the strap back after 3 minutes without it.
  - On first use, the watch auto-picks a strap when it is the only WHOOP in range.
- **P2:** the phone skipped disconnecting when it was mid-reconnect. **Fixed.** It always lets go.
- **P2:** no reconnect after a Bluetooth power cycle. **Fixed.**
- **P2:** `stop()` could miss the live peripheral after a rescan. **Fixed.**
- **P2:** an orphaned workout session after a watch-app relaunch. **Fixed** with a recovery handler that ends it.
- **P3s fixed:**
  - The value is copied in the Bluetooth callback.
  - Main-thread access is fixed in the snapshot store.
  - The post-workout snapshot no longer claims the iPhone holds the strap.
  - An immediate restart after End now works.
  - The macOS targets are pinned to no team.
- **Also found while fixing:** the phone lacked the reply-less `didReceiveMessage` delegate, so the watch's wake-up messages were dropped. **Fixed.**
- **Accepted P3s:**
  - The watch buffer is memory-only.
  - The phone ingest task has no background assertion.

### Independent review, round 2 (same reviewer, on the fixed tree)

- **P1:** after a fresh phone launch, the phone let go of the strap but did not count itself as wanting it back. **Fixed.** The phone is the 24/7 collector, so it always reclaims the strap after a watch session.
- **P2:** the phone never passed its Bluetooth restore identifier, so `willRestoreState` was dead code and a pending connect died if iOS terminated the app. **Fixed.** The identifier is now passed on iOS only, as `docs/IOS.md` already specified. This is the riskiest change in the candidate, because it switches on a restore path that has never run. Device check R2 must cover it.
- **P2:** a queued notice from an earlier session could arm the fallback early. **Fixed.**
- **P2:** a failed pending connect was never retried. **Fixed** with a 3 s retry, skipped when the bond was wiped.
- **P2:** the phone could win the strap after a watch link blip, and the watch was never told. **Fixed.** The phone now messages the watch, which ends its workout and shows why.
- **P3s fixed:**
  - The pending connect no longer touches a live link.
  - The watch ignores callbacks for a strap released by a rescan.
  - The grace check fits the background time iOS grants.
- **Accepted P3s:**
  - On first use, if the user takes more than 25 s to pick a strap that isn't auto-picked, the phone may take it back first.
  - First-use name-based auto-pick was **removed** after an automated security review: a spoofed "WHOOP" device could inject readings. The first connection is a tap, and only that user-picked strap is reconnected automatically.
- **Checks after round 2:**
  - `NOOPiOSTests`: 28 tests, 0 failures.
  - The iOS + watch and macOS builds succeed with no new warnings.

### Blockers

1. ~~**Re-sign in to Xcode**~~ Resolved 2026-10-26: the user signed in and renewed the RevitalizedAI membership. What remains needs the user's hands: install the watch app from the iPhone's Watch app, finish onboarding and pair the strap, turn on Apple Health in NOOP and in Muse, and run a watch workout. These block R1 (watch), R2, R4, R5 and R6.
2. **Watch reachability:** the Watch Ultra 2 shows "unavailable" to Xcode. It must be unlocked, on its charger near the phone, with Developer Mode on.
