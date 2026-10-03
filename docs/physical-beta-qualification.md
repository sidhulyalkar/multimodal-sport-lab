# MotionOS physical beta qualification

This protocol qualifies the current integrated beta on real paired Apple hardware.

Target branch:

`product/motionos-m0-integrated-beta-v1`

The protocol deliberately separates:

- **authoritative evidence**: sealed Watch journal and camera evidence;
- **live preview**: disposable Observatory telemetry;
- **systems characterization**: sensing, battery, preview, and transfer measurements;
- **3D interpretation**: Vision-derived geometry with explicit provenance.

Passing simulator/CI builds is necessary but not sufficient.

## 0. Preflight

Before each physical run:

- iPhone and Apple Watch charged above 40%;
- MotionOS installed on both devices from the same branch/build;
- Health access granted for the requested workout and heart-rate data;
- at least 5 GB free on iPhone;
- both apps opened once after installation;
- iPhone **Devices** shows Apple Watch ready;
- Apple Watch advanced details and iPhone advanced details agree that the two MotionOS apps have detected each other;
- iPhone **Devices -> Qualification -> Systems Lab** is available.

Record the app commit/build used for the test.

## 1. P0: 2-minute live sensing smoke test

1. Open MotionOS on Watch and iPhone.
2. Start **Sensor Check** on Watch.
3. Open **Observe** on iPhone.
4. Confirm the Observatory reaches **LIVE** after genuinely fresh telemetry arrives.
5. Perform:
   - 10 s still;
   - 10 s slow wrist rotations;
   - 10 s brisk wrist motion;
   - 10 s still.
6. Pause on Watch.
7. Confirm iPhone shows **PAUSED**, not LIVE.
8. Resume.
9. Confirm a new fresh trace appears without old-session contamination.
10. Stop.
11. Confirm Watch shows the saved/completed state and can return to Ready.

### Expected evidence

Systems Lab should show:

- IMU sample count increasing throughout capture;
- effective IMU rate near the configured Watch rate;
- non-monotonic IMU increase of 0;
- no duplicate/out-of-order preview packets in the normal connected case;
- journal byte count and SHA-256 after verified transfer.

Do not create a hard power/pass threshold from this short run.

## 2. P0.5: live-link interruption

Start another 2–5 minute Sensor Check.

While recording:

1. Observe LIVE for at least 20 s.
2. Lock/background the iPhone for 30–60 s.
3. Continue moving the Watch during part of that period.
4. Reopen MotionOS.
5. Confirm the app reports reconnecting until a fresh packet arrives.
6. Confirm LIVE resumes from new packets only.
7. Stop the Watch recording.
8. Wait for verified journal receipt.

### Pass conditions

- Watch capture never stops because live preview disappears.
- No crash or stuck transfer screen.
- Observatory never displays stale data as LIVE.
- The sealed journal arrives and verifies.
- Systems Lab report can be shared as JSON.

Preview coverage may fall during the interruption. That is expected and is not equivalent to evidence loss.

## 3. P0.6: back-to-back capture and deletion

1. Finish recording A.
2. Tap **Done** while recording A is still syncing, if applicable.
3. Immediately start recording B.
4. Confirm B records while A continues its background lifecycle.
5. Stop B.
6. Delete one test recording from the Watch before transfer completion.
7. Delete another recovered test recording from iPhone **Sessions**.

### Pass conditions

- A pending transfer cannot block B.
- Transfer/report state stays associated with the correct session ID.
- A late receipt for recording A cannot overwrite recording B's qualification report.
- Deletion returns the UI to a usable state.
- No other recording is deleted accidentally.

## 4. P1: 30-minute sensing + power characterization

Use Watch Sensor Check for the first long run.

Recommended protocol:

- 5 min normal foreground use;
- 20 min iPhone locked/backgrounded;
- 5 min foreground Observatory.

Move the wrist naturally every few minutes and include two short vigorous-motion windows.

Systems Lab should automatically capture:

- duration;
- IMU samples observed;
- mean/min effective IMU rate;
- maximum IMU gap;
- non-monotonic count delta;
- live preview sequence behavior;
- Watch battery start/end;
- iPhone battery start/end;
- verified journal size/hash;
- stop-to-receipt transfer latency.

The Watch battery-per-hour value is explicitly experimental. Percentage readout is quantized and should be compared across repeated runs, not treated as a precise energy measurement.

### Follow-up A/B runs

After the first successful long run, repeat under controlled conditions:

A. Watch recording, iPhone mostly backgrounded.

B. Watch recording, iPhone Observatory foreground.

C. Watch + iPhone Vision capture.

Compare battery slope, thermal behavior, storage growth, and transfer latency across conditions.

## 5. P2: Vision 3D body-scene qualification

Use a clear, stable camera position with the whole body and both feet visible.

Start an Indo Board capture.

Verify:

1. scene begins as **REFERENCE** when no measured pose exists;
2. it changes to **VISION 3D** only after actual pose output exists;
3. left/right arms move with the correct sides;
4. knee bends correspond visually;
5. torso lean direction is correct;
6. Front, Side, and interactive 3D viewpoints are physically interpretable;
7. foot/ankle support geometry follows the detected stance;
8. the orange pelvis marker is understandable as a geometric reference;
9. pelvis-to-support offset is not labeled center of mass or balance;
10. partial occlusion causes **REACQUIRING** rather than invented motion;
11. reacquisition returns cleanly;
12. after stop, the scene becomes **LAST FRAME**, not LIVE.

Do not qualify:

- center of mass;
- force distribution;
- muscle recruitment;
- injury risk;
- a balance/stability score

from this test.

Those require separate models and validation.

## 6. Evidence to retain after every beta run

Keep:

- Systems Lab JSON;
- relevant Watch session/journal;
- session summary;
- screenshots of unexpected UI states;
- short screen recording for visual bugs;
- exact commit SHA;
- device model + OS versions;
- concise notes about what happened.

For a failure, record the approximate clock time and session ID before retrying. Do not delete the failed evidence until the failure is understood.

## 7. Merge gate

Do not call the integrated beta physically qualified until:

- P0 passes twice consecutively;
- P0.5 passes with no journal loss;
- P0.6 passes with two back-to-back sessions;
- at least one P1 long run completes;
- P2 verifies Vision orientation and reacquisition on the intended iPhone;
- no failure requires force-quitting either app to resume normal use.

Once these pass, merge the stack in dependency order and preserve the qualification JSON files as release evidence.
