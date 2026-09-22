# P0 Physical Qualification Runbook

P0 qualifies the Apple Watch capture path before any external equipment sensor is introduced.

## What P0 can establish

A passing P0 receipt supports the narrow claim that:

- MotionOS can launch a real Watch workout from the paired iPhone.
- Watch motion samples survive as an append-only local journal.
- heart-rate samples are present when HealthKit provides them.
- the journal preserves stream sequence continuity and monotonic device time.
- the closed journal can be recovered on iPhone after the workout.

P0 does **not** qualify cross-device synchronization, biomechanics, pose reconstruction, pressure sensing, or physiological accuracy.

## Before the first run

On your Mac:

```bash
git checkout feat/m0b-apple-host-p0
brew install xcodegen

cd apple/MotionOSHost
xcodegen generate
open MotionOSHost.xcodeproj
```

In Xcode:

1. Select your Apple Developer Team for both targets.
2. Confirm the iOS bundle ID and Watch bundle ID are accepted by your account.
3. Confirm HealthKit is enabled for both targets.
4. Select your paired iPhone as the iOS run destination.
5. Build/run `MotionOS-iOS`.
6. Install/open the Watch companion and tap **Enable Health** once.

The workout-mirroring path requires real paired devices. Simulator builds only qualify compilation.

## P0-A — 10-minute shakedown

Start from the iPhone.

### Block A — stationary baseline
- 60 s sitting/standing still.
- Do not intentionally move the Watch.

### Block B — orientation excitation
Perform five slow repetitions around each wrist/device axis:
- roll
- pitch
- yaw

Return to neutral for several seconds between axes.

### Block C — deliberate impulses
Perform three easily identifiable wrist impulses, separated by about five seconds.

These are not yet cross-device synchronization events. They simply create obvious landmarks for checking continuity.

### Block D — walking
Walk normally for two minutes.

### Block E — background behavior
While the workout continues:
1. lock the iPhone for one minute;
2. unlock it;
3. background MotionOS for one minute;
4. return to MotionOS.

The Watch must continue recording.

### Block F — temporary separation
Walk far enough from the phone to lose immediate reachability, while remaining in a safe test environment.

Continue for about one minute, then return.

P0 does not require live telemetry to remain uninterrupted. It requires the **Watch journal** to remain intact.

### Block G — finish
Stop from Apple Watch.

Expected Watch result:
- Motion capture stops.
- HealthKit workout ends.
- journal closes.
- if WatchConnectivity is activated, transfer queues;
- otherwise the Watch shows **Journal safe on Watch** and a Retry Transfer control.

Expected iPhone result:
- recovered journal card appears;
- session ID is visible;
- raw journal is available through Share and the Files app.

## Export and process the journal

Share `watch.jsonl` to your Mac or copy it from the MotionOS Documents folder.

From the repository root:

```bash
python -m venv .venv
source .venv/bin/activate
pip install -e '.[dev]'

bash scripts/process_p0_watch.sh /path/to/watch.jsonl data/p0 600
```

The command creates:

```text
data/p0/<session-id>/
  manifest.json
  index.json
  metadata/
  streams/
  p0-receipt.json
```

## P0-B — 30-minute qualification

Only after P0-A passes, repeat with at least 30 minutes of total capture.

Include:
- >=5 minutes stationary
- repeated wrist rotations
- walking
- phone lock/background
- temporary separation
- normal foreground use

Process with:

```bash
bash scripts/process_p0_watch.sh /path/to/watch.jsonl data/p0 1800
```

The P0 gate deliberately does not hard-code a 50 Hz accuracy tolerance. It reports the observed effective rate. Freeze a rate tolerance only after real-device data shows the Watch's actual sampling behavior.

## What to inspect manually

Even if the receipt passes, inspect:
- observed IMU rate
- maximum acquisition gaps
- missing sequence count
- duration
- HR sample count
- journal size
- start/end behavior around phone separation

Any real failure becomes a permanent fixture or fault-injection regression test before moving to P1.
