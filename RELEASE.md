# Releasing Lumen

Lumen is developed, tested and used without spending money. Nothing in this repository requires
a paid Apple Developer Program membership: every feature is fully implemented and runs in the iOS
Simulator and on your own iPhone with a free Apple ID. App Store distribution is an optional
future milestone; everything it needs that can be prepared for free is already in the repository.

## Tiers at a glance

| | Cost | What you get |
| --- | --- | --- |
| **1. iOS Simulator** | free, no Apple account | the whole app on your Mac |
| **2. Your iPhone, free Apple ID** | free | the app on your own device, re-signed weekly |
| **3. Unsigned IPA** | free | a Release build for re-signing tools; built by CI on every push |
| **4. TestFlight / App Store** | paid program, optional | distribution to other people |

## What works where

| Feature | Simulator | iPhone, free Apple ID | Paid program |
| --- | --- | --- | --- |
| Tasks, projects, calendar, notes, documents, search, automations, insights, assistant (with your API key), plugins, iPad sidebar and keyboard shortcuts | ✅ | ✅ | ✅ |
| Focus sessions, Live Activities, Spotlight, App Shortcuts, local notifications, background refresh, system calendars, Keychain | ✅ | ✅ | ✅ |
| Widgets with live data (App Group) | ✅ | ✅ if your team can provision App Groups, otherwise widgets show "Open Lumen" | ✅ |
| iCloud sync | — | — (personal teams can't use iCloud) | ✅ after the steps in `DEVELOPMENT.md` |
| Installing on other people's devices | — | — | ✅ TestFlight / App Store |

iCloud sync is fully built and tested against an in-memory database; it switches itself on in a
build that names an iCloud container. Until then every change is kept in the local change log, so
nothing is lost when sync is turned on later.

## 1. Run in the iOS Simulator (no account)

1. Open `Lumen.xcodeproj` in Xcode 16 or newer.
2. Select the **Lumen** scheme and any iOS 18+ simulator. Leave the team empty.
3. Run (⌘R). Run the tests with ⌘U, or from a terminal:

```sh
scripts/ios-ui-tests.sh        # UI smoke tests + screenshots on the newest iPhone simulator
```

Background refresh can be triggered from the debugger (see `DEVELOPMENT.md`).

## 2. Run on your iPhone with a free Apple ID

1. Xcode › Settings › Accounts: add your Apple ID. Xcode creates a free personal team.
2. Copy `App/Configuration/Signing.local.xcconfig.example` to
   `App/Configuration/Signing.local.xcconfig` (ignored by git) and set:
   - `DEVELOPMENT_TEAM`: your personal team's ID (Accounts › your Apple ID › Team ID).
   - `LUMEN_BUNDLE_PREFIX`: a prefix only you use, such as `com.yourname.lumen`. Bundle
     identifiers are unique across all of Apple, so the repository's `app.lumen` is not yours to
     register. The App Group follows the prefix (`group.<prefix>`) automatically.
3. Connect the iPhone, select it as the run destination and run. The first time:
   - Turn on Developer Mode on the iPhone (Settings › Privacy & Security › Developer Mode) and
     restart when asked.
   - Trust your developer certificate (Settings › General › VPN & Device Management).
4. If Xcode reports that your team can't use App Groups, uncomment
   `LUMEN_ENTITLEMENTS_VARIANT = -NoAppGroup` in your `Signing.local.xcconfig`. The app keeps its
   data in its own container and the widgets show "Open Lumen"; everything else is unchanged.

Limits of a free team: the provisioning profile expires after 7 days (run from Xcode again to
renew; your data stays), and Apple limits how many apps and App IDs a personal team may use at a
time. Lumen uses two App IDs (app and widget), three when running the UI tests on the device.

## 3. Unsigned IPA

CI builds the Release configuration for real devices without signing on every push and keeps
`Lumen-unsigned.ipa` as a workflow artifact; locally:

```sh
scripts/build-unsigned-ipa.sh   # → build/Lumen-unsigned.ipa
```

It proves the optimized device build compiles, and third-party re-signing tools can install it on
your own device with a free Apple ID (the same 7-day limit applies). Those tools are not part of
Lumen; use them at your discretion.

## 4. TestFlight and the App Store (optional, paid)

Prepared without a paid account:

| Item | Where |
| --- | --- |
| App icon (default, dark, tinted) | `App/Lumen/Assets.xcassets`, rendered by `Tools/AppIcon/render.py` |
| Privacy manifests (no tracking, no collection, no required-reason APIs) | `App/*/PrivacyInfo.xcprivacy`, checked by `scripts/audit-privacy-apis.sh` in CI |
| Export compliance (`ITSAppUsesNonExemptEncryption = NO`: HTTPS and signature checks only) | `App/Configuration/Lumen-Info.plist` |
| Privacy policy | `PRIVACY.md` |
| Store listing text | `Release/metadata/en-US/` |
| Screenshots | CI artifact `screenshots`; `scripts/ios-ui-tests.sh` then `scripts/export-screenshots.sh` |
| Version and build number | `scripts/set-version.sh` (`App/Configuration/Lumen.xcconfig`) |
| Release-configuration device build | `scripts/build-unsigned-ipa.sh`, run by CI |

Remaining steps, when and if you join the program:

1. Set `DEVELOPMENT_TEAM` and your `LUMEN_BUNDLE_PREFIX`; register the App IDs and App Group.
2. Optionally turn on iCloud sync (`DEVELOPMENT.md` › iCloud sync).
3. Take screenshots on the sizes App Store Connect asks for (run the screenshot test on, for
   example, an iPhone Pro Max and a 13-inch iPad simulator with `LUMEN_SIMULATOR=<udid>`).
4. Publish `PRIVACY.md` at a public URL (a GitHub page works) for the privacy policy field.
5. Product › Archive in Xcode, then distribute to App Store Connect for TestFlight and review.
