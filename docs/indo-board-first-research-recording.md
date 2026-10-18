# Indo Board first research recording: operator checklist

Status: **software-ready instructions, pending physical qualification**. This guide describes the October 18, 2026 `main` capture architecture plus the recording-readiness branch. Do **not** treat successful simulator/CI output as proof that Watch capture or Action 4 timing is physically qualified.

## What actually works in this build

- **iPhone**: MotionOS rear wide-angle evidence recording at **1920×1080, locked 30 fps**, stabilization off; native video PTS, frame journal, pose processing, MOV sealing, capture diagnostics.
- **Watch**: paired companion with HealthKit/workout and motion journal, Watch cues and synchronized product-session flow; physical pairing/permission and post-run transfer must be tested on your devices.
- **Indo Board**: optional QR deck-left, deck-right and roller marker tracking. These are **image-plane proxies**, not full calibrated 3D forces.
- **Action 4**: **manual** camera start/stop, import original via Photos/Files, START/MIDDLE/END video alignment review and local Action 4 pose-track processing after import.
- **Not yet qualified**: Siri/voice-initiated MotionOS start, automatic DJI camera control, iPhone 1080p/60 or 4K/60 within MotionOS, arbitrary-length product protocols, metric 3D muscle activation/force, or a muscle overlay.

## 0. Install this branch (Mac)

Move to a normal development folder, not `~/Documents` (macOS protected-folder permission prompts can prevent builds).

```bash
cd "$HOME/Developer/multimodal-sport-lab"
git status --short
git fetch origin
git switch --track origin/feat/indo-recording-readiness-20261018
python3 --version
cd apple/MotionOSHost
bash bootstrap.sh --no-open
open MotionOSHost.xcodeproj
```

If the worktree has local changes, commit or stash them **before** switching branches; do not overwrite your data. If that tracked branch was already created locally, use `git switch feat/indo-recording-readiness-20261018` and `git pull --ff-only`. Bootstrap requires full Xcode and XcodeGen. Use `bash bootstrap.sh --reset-packages --no-open` **only** for a diagnosed package-resolution failure, not as an everyday step.

In Xcode select `MotionOS-iOS`, choose the **physical iPhone** as run destination, check the same personal Development Team on the iPhone/Watch targets, and press Cmd-R. Open MotionOS on the paired Watch and grant the requested workout/HealthKit access. Check the embedded Watch companion actually remains installed. If you hit signing trouble, distinguish it from SwiftPM resolution; see `apple/MotionOSHost/README.md`.

## 1. Safe physical setup

1. Set board and roller on a non-slip, stable, flat surface, with a clear recovery/fall area and an easy handhold or spotter. Start with neutral balance, not rotational tricks.
2. Mount the **iPhone in landscape**, rear wide camera, on a rigid tripod **outside** the fall zone. Prefer a front-oblique angle; include entire rider, feet, deck, roller and both sides of likely corrections. Record without moving the tripod.
3. Provide bright, even, diffuse continuous lighting from two angles; remove strong backlighting, glare, dark regions, and flickering LEDs. Inspect motion blur during a deliberate arm or foot movement. **The current app checks body-framing confidence, not actual image exposure, sharpness or illumination quality.**
4. If using Action 4, mount it at a second fixed oblique angle roughly 45–90 degrees away from the iPhone view, with full rider and equipment coverage. As an initial research profile set **4K, 16:9, 60 fps**, Standard/Dewarp FOV, no zoom, and electronic stabilization off for calibration recordings. Confirm the clip is recording before mounting the board. Do not assume MotionOS can start DJI remotely.
5. Charge devices and ensure **at least 5 GB free and iPhone battery at least 20%** for MotionOS preflight. For multiple 4K trials allow substantially more external-camera storage.
6. Optional marker study: in MotionOS open **Beta board + roller tracking**. Attach distinct deck-left and deck-right markers off the riding surface and a roller-end marker that both cameras can see. Never obstruct stops, roller contact or footing. QR sizes are visibility aids, **not** metric camera calibration.

## 2. App readiness and 15-second dry run

1. In the iPhone app open **Capture → Indo Board**. Use the standard Watch + iPhone session first; enable **Add an external camera** only if Action 4 is **already recording** and confirm its toggle.
2. Tap **Check My Setup**; inspect the **Ready check** for Watch presence, workout access, camera, battery, storage. You should see a prepared iPhone profile of **1920×1080 at 30 fps**, stabilization off.
3. Step into the preview with both feet visible. Verify the framing status is **Body framing is ready** and the subject has lateral/head/foot margins. **Manually** inspect deck/roller visibility and lighting.
4. Cover the lens momentarily. Framing must leave ready after the latest pose becomes stale; uncover it and verify reacquisition. Failure indicates a stale-state problem: **do not perform the study**.
5. In multiview, confirm the Action 4 red recording indicator and enough storage again. The action camera is not automatically synchronized yet.

## 3. First data collection: exactly 120 seconds

Use **Start Session** in the iPhone Indo Board screen (or a verified Watch remote control if explicitly shown and tested). Expect the Watch/iPhone handshakes and a countdown; check that a **new** session and camera recording begin before riding. The standard product protocol **automatically stops at 120 seconds**. Do not try to use it as an unbounded freestyle recorder.

These blocks come from `IndoBoardProductProtocol.swift` in the repository, not from an older v1 runbook:

| Elapsed time | Block | Movement |
|---|---|---|
| 0–15 s | Neutral settle | Comfortable natural balance |
| 15–35 s | Natural free balance | Do not exaggerate corrections |
| 35–60 s | Controlled side shifts | Five slow left/right shifts with pauses at center |
| 60–85 s | Partial squat control | Three shallow controlled squats with brief bottom holds |
| 85–105 s | Natural balance repeat | Resume normal corrections |
| 105–120 s | Neutral finish | Quiet, comfortable balance |

**Synchronization cues (v2)**: START window **8–14 s**, preferred **10 s**; MIDDLE **61–66 s**, preferred **63 s**; END **110–119 s**, preferred **114 s**. When the Watch cues, make *one* distinguishable sharp arm gesture near neutral stance, with a safe handhold available. Avoid similar sharp gestures close to those cues. Physical motion, not the cue timestamp alone, is the sync landmark.

For the very first run perform this exact protocol, without adding 180s or risky transitions. It is an integration/calibration run, not a trick showcase.

## 4. Trick dataset: use multiple labeled 2-minute sessions

After one clean baseline and marker-backed sessions, collect separate *exploratory* runs for controlled carves, waves, squats, and (only when safely mastered) 180/body rotations or board rotation tricks. Capture several clear repetitions with neutral pauses in each run. The guided protocol still issues its original prompts and its coached comparison; **do not relabel these exploratory runs as protocol-compliant**. Record deviations in your session notes.

Suggested initial labels: `neutral_balance`, `lateral_shift`, `carve_left`, `carve_right`, `wave`, `partial_squat`, `body_180`, `deck_rotation`, `recovery`, `bailout`. Distinguish board angle, body yaw, and relative roller travel. Note stance, trick direction, success/failure, camera placement, lighting change, perceived effort, and unusual occlusions.

Do not infer training success by comparing adjacent frames or unbalanced trials. Compare matched attempts across sessions and days, with camera remounts documented.

## 5. After each run: integrity check

1. Wait for `sealed` / `evidence ready`. Do not kill the app during finalization.
2. If MotionOS says **Finish Watch capture**, stop on Watch and tap **Recheck Watch**; preserve the partially sealed evidence rather than forcing another session.
3. Open **Sessions** and verify this run displays source availability, iPhone MOV and frame journal, Watch evidence status, protocol/cue information, replay and self-report fields. Review dropped frames, actual delivered fps, written-frame fraction, pose coverage and any backpressure.
4. In multiview, stop the Action 4 **after** the run, import the original movie in MotionOS via Files/Photos. In **Replay** choose Action 4 → **Analyze Action 4 Sync** → **Review Three Landmarks**; accept only if the same physical gesture is visible in both sources. Seal the reviewed alignment. If confidence is poor, do not fabricate alignment.
5. Preview **Compare Both Cameras** and source-specific overlays. Frame geometry in the iPhone and Action 4 is separate until calibrated. Keep the original files intact.
6. Enter a short self-report: intended activity, trial outcome, perceived stability/effort, recording abnormalities, and whether all three sync landmarks were verifiable.
7. Back up the sealed evidence and original Action 4 footage before deleting anything from your devices.

## 6. Release gate before claiming reliable operation

- One body-only 120 s baseline passes camera/Watch setup, recording, sealing and replay.
- Three marker-backed repetitions demonstrate board/roller tracking and reacquisition.
- Lens-occlusion test removes stale framing readiness.
- A deliberate QR dropout degrades tracking to body-only instead of inventing values.
- Dual-video import preserves original hashes; all three landmarks are reviewed and aligned.
- CI success is reported separately from device test evidence; no muscle activation, tissue stress, joint load, or accurate full-3D metric claim without calibrated validation.

## Next development tranche

After these physical results, prioritize camera illumination/sharpness metrics, a user-selected 1080p/60 research capture **only when a supported AVCaptureDevice format has been explicitly qualified**, configurable long freestyle protocols, App Intents-based Siri start with acknowledged device state, model-guided trial segmentation, Pose2Sim/OpenSim offline adapter, then defensible muscle-demand overlays.
