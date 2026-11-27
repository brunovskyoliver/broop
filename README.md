<h1 align="center">Broop</h1>

<p align="center"><b>An offline iPhone app for WHOOP straps. Your strap, your data, your phone.</b></p>

Broop pairs with a WHOOP 4.0 or 5.0/MG strap over Bluetooth, stores everything in SQLite on the
phone, and computes recovery, strain, HRV and sleep locally. It needs no WHOOP account, runs no
server and sends no telemetry.

Broop is a fork of [NOOP](https://github.com/ryanbr/noop). It keeps NOOP's protocol, storage and
analytics packages and replaces the iPhone interface with the Broop tab shell: Home, Health and
More. The app installs under the name **Broop**; the Xcode scheme and several internal names still
say NOOP.

> **Not affiliated with WHOOP.** Broop is an independent, unofficial interoperability project.
> "WHOOP" is used only to identify the hardware it talks to. Use it only with a strap you own.
> **Broop is not a medical device**; every metric is an approximation. See
> [`DISCLAIMER.md`](DISCLAIMER.md).

## Contents

- [Install on an iPhone](#install-on-an-iphone)
- [Pair your strap](#pair-your-strap)
- [Updating](#updating)
- [Troubleshooting](#troubleshooting)
- [Android](#android)
- [Development](#development)
- [Privacy](#privacy)
- [Attribution and license](#attribution-and-license)

## Install on an iPhone

Broop has no App Store listing and no pre-built download. You build it on a Mac and install it on
your own iPhone, signed with your own Apple ID.

### What you need

- A Mac with Xcode 26.4 or newer. Running the unit tests needs Xcode 27 and an iOS 27 simulator.
- An iPhone on iOS 17 or newer, and a cable for the first install.
- An Apple ID added under Xcode > Settings > Accounts. A free one works; see the limits below.
- [Homebrew](https://brew.sh), to install XcodeGen.

### Steps

1. Get the code and XcodeGen.

   ```bash
   git clone https://github.com/brunovskyoliver/broop.git
   cd broop
   brew install xcodegen
   ```

2. Set your own bundle id prefix and signing team. Apple requires both to be unique to your
   account.

   ```bash
   cp Config/BundleIdSecrets.example.xcconfig Config/BundleIdSecrets.xcconfig
   ```

   Open `Config/BundleIdSecrets.xcconfig` and set these two lines:

   ```
   BUNDLE_ID_PREFIX = com.yourname
   DEVELOPMENT_TEAM = ABCDE12345
   ```

   Your Team ID is listed at [developer.apple.com/account](https://developer.apple.com/account)
   under Membership details. The file is gitignored, so it stays on your Mac.

3. Generate the Xcode project and open it.

   ```bash
   xcodegen generate
   open Strand.xcodeproj
   ```

   `Strand.xcodeproj` is generated from [`project.yml`](project.yml). Re-run `xcodegen generate`
   after every `git pull`.

4. Prepare the iPhone. Connect it by cable, unlock it and tap **Trust**. Then turn on
   Settings > Privacy & Security > **Developer Mode** and restart when asked.

5. In Xcode, pick the **NOOPiOS** scheme and your iPhone as the destination, then press Run
   (Cmd-R). The first build takes a few minutes.

6. If the app installs but will not open, trust your signing profile. On the iPhone, open
   Settings > General > VPN & Device Management, select your developer profile and tap **Trust**.
   Then launch **Broop** from the home screen.

### Free Apple ID or paid developer account

| Account | App keeps working for | Limits |
|---|---|---|
| Free Apple ID | 7 days, then build again from Xcode | Apple Health and the Live Activity widgets can be limited |
| Apple Developer Program (99 USD per year) | 1 year per signing profile | None |

Your data survives a rebuild. It is lost only if you delete the app.

### Try it without an iPhone

```bash
Tools/ios.sh build   # builds for the simulator and prints the .app path
```

Install the printed `.app` on an iOS simulator. Bluetooth does not work there, so import a WHOOP
CSV export or an Apple Health export under More > Data Sources to get data in.

## Pair your strap

A WHOOP strap keeps an encrypted Bluetooth bond with one device at a time. It is normally bonded
to the official WHOOP app, and Broop's pairing is refused while that bond is held.

1. Quit the official WHOOP app, or turn off Bluetooth on the phone that runs it.
2. Put the strap in pairing mode. On a 5.0/MG, tap the sensor firmly until the LEDs flash blue.
3. In Broop, follow the first-run wizard, choose your strap model and connect. It can take two or
   three attempts.

If heart rate shows but alarms, haptics and history do not work, the strap is not bonded to this
phone. Free it from the other device and pair again.

| Strap | Status |
|---|---|
| WHOOP 4.0 | Supported: live heart rate, recovery, strain, sleep and history sync. |
| WHOOP 5.0 / MG | Experimental. Live heart rate and history sync work; sleep stages, SpO₂ and skin temperature are incomplete. |
| Oura Ring | Experimental and limited. See [`docs/OURA_PROTOCOL.md`](docs/OURA_PROTOCOL.md). |

Live heart rate appears as soon as the strap connects. Strain and sleep fill in after the first
sync. Recovery needs a few nights to learn your baseline.

## Updating

```bash
git pull
xcodegen generate
```

Then press Run in Xcode again. The new build installs over the old one and keeps your data.

## Troubleshooting

| Problem | Fix |
|---|---|
| "No account for team" or a signing error | Add your Apple ID in Xcode > Settings > Accounts, and check `DEVELOPMENT_TEAM`. |
| "Failed to register bundle identifier" or an App Group error | Change `BUNDLE_ID_PREFIX` to something unique, then run `xcodegen generate` again. |
| "Developer disk image could not be mounted" | Unlock the iPhone, keep it awake and retry. |
| "Untrusted Developer" on launch | Trust the profile under Settings > General > VPN & Device Management. |
| The app stops opening after a week | A free Apple ID signs for 7 days. Press Run in Xcode again. |
| Xcode asks for a team after every `xcodegen generate` | Set `DEVELOPMENT_TEAM` in `Config/BundleIdSecrets.xcconfig`. |

More detail on signing and iOS 27 devices is in [`docs/IOS.md`](docs/IOS.md).

## Android

The Android app from NOOP is still in [`android/`](android/) and builds with
`./gradlew installFullDebug`; see [`android/README.md`](android/README.md). Broop's work goes into
the iPhone app, so the Android side can lag behind it.

## Development

Core logic lives in Swift packages; the iPhone app is a thin layer over them.

```
Strand/                  shared iOS app code (BLE, collection, data, screens)
StrandiOS/               iOS app shell and the Broop interface
StrandiOSWidgets/        widgets and Live Activity
Packages/
  WhoopProtocol/         BLE frame parsing, CRC, command and packet decode
  WhoopStore/            GRDB/SQLite persistence
  StrandAnalytics/       HRV, recovery, strain and sleep math
  StrandImport/          WHOOP CSV and Apple Health importers
  StrandDesign/          SwiftUI design system
android/                 Android app
```

```bash
cd Packages/WhoopProtocol && swift test   # package tests, no Xcode project needed
Tools/ios.sh test                         # app unit tests on an iOS 27 simulator
```

[`AGENTS.md`](AGENTS.md) is the contributor map. [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md),
[`docs/PROTOCOL.md`](docs/PROTOCOL.md) and [`docs/SCOPE.md`](docs/SCOPE.md) go deeper.

## Privacy

Broop is offline by default. Strap data, imports and computed metrics stay in a local SQLite
database on the phone. Data leaves only through an export or an optional network feature that you
turn on, such as the AI Coach with your own API key. The full list of network paths is in
[`docs/PRIVACY_SECURITY.md`](docs/PRIVACY_SECURITY.md#11-network-paths-canonical-inventory).

## Attribution and license

Broop is built on [NOOP](https://github.com/ryanbr/noop), the canonical home of the underlying
project and its releases. NOOP in turn builds on `johnmiddleton12/my-whoop` (WHOOP 4.0 protocol),
`b-nnett/goose` (WHOOP 5.0/MG protocol documentation), `groue/GRDB.swift` and
`weichsel/ZIPFoundation`. Full credits are in [`ATTRIBUTION.md`](ATTRIBUTION.md) and
[`NOTICE`](NOTICE).

The code is source-available under the
[PolyForm Noncommercial License 1.0.0](LICENSE): free for personal and other non-commercial use,
with the `Copyright 2026 NoopApp` notice kept intact. Commercial use is not granted.

Broop contains no WHOOP proprietary code, firmware, logos or assets, and performs no DRM
circumvention. It is provided as-is, with no warranty.
