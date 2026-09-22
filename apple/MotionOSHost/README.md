# MotionOS Apple Host — M0-B / P0

This directory contains the first installable iPhone + Apple Watch host applications for physical MotionOS qualification.

## Architecture

The iPhone is the coordinator. It launches/wakes the paired Watch with a HealthKit workout configuration. Apple Watch owns the primary workout session and mirrors workout state back to iPhone. MotionOS raw wrist samples are written independently to an append-only JSONL journal on Watch. When the session ends, the closed journal is queued to iPhone with WatchConnectivity.

This intentionally separates:

- **HealthKit mirroring:** workout lifecycle + live companion state.
- **MotionOS journal:** canonical raw capture evidence.
- **WatchConnectivity file transfer:** durable post-session handoff.

Live mirroring is never treated as the only copy of raw samples.

## Generate the Xcode project

Install XcodeGen 2.46+:

```bash
brew install xcodegen
cd apple/MotionOSHost
xcodegen generate
open MotionOSHost.xcodeproj
```

XcodeGen has a currently open Xcode 26 issue that embeds modern single-target watch apps in the legacy `Watch/` location. The project spec contains a guarded post-generation patch to place Watch content in `PlugIns/` instead. Remove this workaround when upstream fixes the issue.

## Before running on real devices

1. Select your Apple Developer Team for **both** targets.
2. Confirm bundle identifiers are unique for your developer account.
3. Confirm the HealthKit capability is present on both targets.
4. Pair the iPhone and Apple Watch.
5. Install the iPhone app; the paired Watch app should also become available.
6. Open the Watch app once and grant HealthKit authorization.
7. Start P0 from the iPhone.

Simulator builds verify compile-time contracts, but workout mirroring and real motion qualification require physical paired devices.

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
        close + transferFile
                  │
                  ▼
           iPhone journal inbox
```

After transfer, run the Python P0 importer/validator from the repository to create a reproducible qualification receipt.
