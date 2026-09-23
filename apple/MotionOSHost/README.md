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
