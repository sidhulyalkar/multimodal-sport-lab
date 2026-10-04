# MotionOS Apple Host — M0-B / P0

This directory contains the first installable iPhone + Apple Watch host applications for physical MotionOS qualification.

## Architecture

The iPhone is the coordinator. It launches/wakes the paired Watch with a HealthKit workout configuration. Apple Watch owns the primary workout session and mirrors workout state back to iPhone. MotionOS raw wrist samples are written independently to an append-only JSONL journal on Watch. When the session ends, the closed journal is queued to iPhone with WatchConnectivity.

This intentionally separates:

- **HealthKit mirroring:** workout lifecycle + live companion state.
- **MotionOS journal:** canonical raw capture evidence.
- **WatchConnectivity file transfer:** durable post-session handoff.

Live mirroring is never treated as the only copy of raw samples.

## Field observability

The native apps expose live diagnostics so an operator can catch obvious
capture failures while they are still fixable:

- Watch timestamp-derived recent/effective IMU rate;
- maximum observed Watch device-time gap;
- non-monotonic timestamp count;
- HR event count and Watch battery;
- iPhone battery and free-storage preflight margins;
- live camera delivered/written frames, PTS-derived FPS, writer
  backpressure, AVFoundation drops, and Vision pose outcomes;
- camera framing preview before recording.

These values are **operator feedback only**. They do not replace the sealed
journals, native timestamps, file hashes, or repository-side qualification
receipts.

## Apple toolchain baseline

The shared `MotionOSAppleCapture` package declares
`swift-tools-version: 6.0`. The default product build is intentionally lean:
it uses the local MotionOS package and does **not** resolve the optional
MetaWear/NordicDFU/ZIPFoundation sensor-lab graph.

- **Compile/package minimum:** Xcode 16 or newer.
- **Recommended physical MotionOS toolchain in 2026:** Xcode 26 or newer.
- For current iOS/watchOS 26 devices, use the Xcode 26 family for physical
  qualification rather than treating an older compile-only toolchain as
  equivalent evidence.

The bootstrap script checks the active developer toolchain before generation
and reports the detected Xcode version explicitly.

If multiple Xcode installations coexist, select one per-run without changing
global system state:

```bash
export MOTIONOS_DEVELOPER_DIR="/Applications/Xcode-26.app/Contents/Developer"
bash bootstrap.sh --reset-packages
```

Or point the system default at the desired installation with `xcode-select`.

## macOS protected-folder workspace policy

Do not keep an actively built MotionOS checkout under
`~/Documents`, `~/Desktop`, or `~/Downloads` unless you intentionally
grant Xcode Files & Folders access. Those locations are protected by macOS
privacy controls; Xcode, SwiftPM, source indexing, and build helpers may each
need repeated workspace access and can produce a stream of system permission
prompts.

The recommended development location is a normal code root such as:

```bash
mkdir -p "$HOME/Developer"
mv "$HOME/Documents/Projects/multimodal-sport-lab" "$HOME/Developer/"
cd "$HOME/Developer/multimodal-sport-lab/apple/MotionOSHost"
bash bootstrap.sh --reset-packages
```

The bootstrap script now fails early when it detects a protected workspace
rather than opening Xcode into a permission loop. If the location is
intentional, first grant Xcode access in the macOS prompt and then bypass the
guard explicitly:

```bash
bash bootstrap.sh --reset-packages --allow-protected-workspace
```

This is a macOS developer-workspace permission. It is unrelated to the
MotionOS app's Camera, HealthKit, or iOS signing permissions.

## Generate the Xcode project

Install XcodeGen 2.46+:

```bash
brew install xcodegen
cd apple/MotionOSHost
bash bootstrap.sh
```

`bootstrap.sh` is the preferred entry point. It:

1. verifies the installed Xcode, Swift, and XcodeGen toolchains;
2. validates the local `MotionOSAppleCapture` Swift package;
3. regenerates `MotionOSHost.xcodeproj`;
4. resolves the local and remote Swift packages into the repo-local
   `.build/apple-source-packages` cache;
5. verifies that the generated schemes are readable before opening Xcode.

This keeps package resolution deterministic and makes the first SwiftPM error
visible instead of leaving Xcode with only downstream “Missing package
product” diagnostics.

If package resolution is stale:

```bash
cd apple/MotionOSHost
bash bootstrap.sh --reset-packages
```

The reset removes only the generated MotionOS Xcode project and the repo-local
Swift package cache. It does not touch global Xcode caches or user signing
configuration.

For manual generation:

```bash
cd apple/MotionOSHost
xcodegen generate
xcodebuild -resolvePackageDependencies \
  -project MotionOSHost.xcodeproj \
  -scheme MotionOS-iOS \
  -clonedSourcePackagesDirPath ../../.build/apple-source-packages
open MotionOSHost.xcodeproj
```

XcodeGen has a currently open Xcode 26 issue that embeds modern single-target watch apps in the legacy `Watch/` location. The project spec contains a guarded post-generation patch to place Watch content in `PlugIns/` instead. Remove this workaround when upstream fixes the issue.

## Watch app install metadata

MotionOS uses the modern single-target watchOS app architecture. The generated
Watch Info.plist declares `WKApplication=true`, alongside the companion bundle
identifier. Physical watchOS installation rejects a single-target app bundle
that lacks the application marker even when simulator builds succeed.

## HealthKit capability policy

The generated project intentionally enables the base HealthKit entitlement on
the iPhone and Watch targets. Do **not** enable Clinical Health Records for
P0. MotionOS does not read clinical/FHIR records, and that entitlement is
outside the capture contract.

HealthKit Background Delivery is also not required for the P0 workout path.
P0 uses an active Watch workout session for workout lifecycle and live
collection. The Watch target does enable the `workout-processing` background
mode because Apple requires it for an active workout session to continue while
the watchOS app is in the background. This is separate from HealthKit
Background Delivery. Add the latter only when MotionOS introduces a concrete
observer-query feature that requires it.

Treat `project.yml` and the checked-in entitlement files as the source of
truth. Manual capability toggles in the generated Xcode project are disposable
and may be removed the next time XcodeGen runs.

## Before running on real devices

1. Connect the physical iPhone and let Xcode finish preparing the device.
2. Select your Apple Developer Team for **both** targets.
3. Confirm bundle identifiers are unique for your developer account.
4. Confirm the base HealthKit capability is present on both targets.
5. Keep Clinical Health Records disabled.
6. Pair the iPhone and Apple Watch.
7. Select **MotionOS-iOS + the physical iPhone** as the run destination.
8. Install the iPhone app; the paired Watch app should also become available.
9. Open the Watch app once and grant HealthKit authorization.
10. Start P0 from the iPhone.

Simulator builds verify compile-time contracts, but workout mirroring and real motion qualification require physical paired devices.

### Xcode versus Command Line Tools

If Terminal reports:

```text
xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer
directory '/Library/Developer/CommandLineTools' is a command line tools instance
```

the full Xcode app is installed but Terminal is still pointed at the smaller
Command Line Tools bundle. The bootstrap script now detects the standard
`/Applications/Xcode.app` installation and uses it for the current run without
changing global system configuration.

You can also make the full Xcode toolchain the global default:

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
xcodebuild -version
```

If Xcode is installed elsewhere, set
`MOTIONOS_DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer` before running
the bootstrap script.

### Signing versus package resolution

These are independent failure classes:

- **“Missing package product”** means SwiftPM resolution failed. Run
  `bash bootstrap.sh --reset-packages` and use the first resolver error.
- **“Communication with Apple failed” / “team has no devices”** is signing and
  provisioning. Confirm the physical iPhone appears in
  **Window → Devices and Simulators**, refresh the Apple ID in
  **Xcode → Settings → Accounts**, then retry automatic signing.
- Do not delete package dependencies to work around a signing error, and do
  not change bundle identifiers to work around a SwiftPM resolver error.

## P0 expected flow

```text
iPhone
  Start P0
     │
     ▼
HKHealthStore.startWatchApp
     │
     ▼
Apple Watch launched/woken
     │
     ├─ HKWorkoutSession primary
     ├─ mirrored session → iPhone
     ├─ Core Motion → watch.jsonl
     └─ heart rate → watch.jsonl
                  │
                  ▼
               Stop on Watch
                  │
                  ▼
        close + hash journal
                  │
                  ▼
             transfer queued
                  │
                  ▼
       WatchConnectivity finished
                  │
                  ▼
     iPhone verifies SHA-256 + size
                  │
                  ▼
       durable receipt ack → Watch
```

After transfer, run the Python P0 importer/validator from the repository to create a reproducible qualification receipt.


## Verified Watch evidence handoff

The Watch never labels a journal "verified" merely because
`WCSession.transferFile` accepted it.

The UI distinguishes:

1. **Journal safe on Watch**
2. **Transfer queued**
3. **Sent to iPhone / waiting for receipt**
4. **Verified on iPhone**

The iPhone recomputes SHA-256 and byte count before accepting the journal.
An identical retry for the same session is idempotent. The same session ID
with different bytes fails closed instead of overwriting prior evidence.

The source journal remains on Watch if transfer or acknowledgment fails.

## Guided P0 mode

The iPhone app contains a guided P0-A / P0-B runner backed by the versioned
`GuidedProtocolPlan` contract.

P0-A encodes the real runbook requirements, including:

- 60 s stationary baseline;
- five roll/pitch/yaw repetitions, manually confirmed;
- three deliberate impulses;
- 2 min walking;
- >=1 min phone lock;
- >=1 min app background;
- >=1 min temporary phone separation;
- >=10 min total guided capture.

P0-B requires >=5 min stationary and >=30 min total guided capture while
retaining the dynamic/background/separation challenges.

Minimum-duration gates use the monotonic MotionOS clock, not wall time.
The user still explicitly completes each step. A timer is never treated as
proof that the requested motion occurred.

The guided runner writes a separate append-only operator journal. Those
annotations document protocol execution only and are not cross-device
synchronization authority.

When WatchConnectivity is immediately reachable, the iPhone also sends the
newly active step title to Watch for a best-effort haptic/display cue. Cue
delivery is not required for protocol validity and is never synchronization
evidence.
