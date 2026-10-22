# MotionOS M0 Product First Indo Board Session

This runbook validates the **intended MotionOS product experience** on real
iPhone + Apple Watch hardware. It is deliberately different from scientific
M0-Vision qualification.

A successful product session means the app can guide one complete capture,
preserve the evidence, and make the result inspectable. It does **not** certify
biomechanical accuracy, physiological accuracy, camera calibration, or
cross-device synchronization.

## Hardware

Required:

- paired Apple Watch running MotionOS;
- iPhone running MotionOS;
- Indo Board in a clear indoor area;
- stable hand support or spotter available for the first run.

Optional for the first product pass:

- DJI Osmo Action 4 on a rigid tripod.

Use the Action 4 only in **Multiview** mode. MotionOS represents it honestly as
an external recorded source: start it manually and import the untouched movie
after the MotionOS session.

## Build under test

Use the field-guide branch for the first physical run once its CI is green.
From your existing repository checkout:

```bash
git status --short
git fetch origin
git switch feat/first-indo-field-guide
git pull --ff-only origin feat/first-indo-field-guide
cd apple/MotionOSHost
bash bootstrap.sh --no-open
open MotionOSHost.xcodeproj
```

If `git status --short` shows your own uncommitted edits, preserve them
before switching branches. Bootstrap regenerates the XcodeGen project after
new Swift sources are added, but does not use `--reset-packages` by default.
If the repository lives under Documents/Desktop/Downloads, the bootstrap
guard may ask you to move it under `~/Developer` or explicitly opt in to
the macOS protected-folder permission prompts. Do not bypass that guard
unintentionally. Confirm both targets still use your Development Team.

In Xcode:

1. select the `MotionOS-iOS` scheme;
2. select the physical iPhone;
3. confirm iPhone + Watch targets use the same Development Team;
4. press **Cmd-R**;
5. open MotionOS on the Watch after the iPhone app launches.

## Gate 1 · Product shell

Before capturing, briefly inspect all four tabs:

- **Observe**: source strip + live movement observatory;
- **Capture**: Indo Board is the primary workflow;
- **Sessions**: run history / empty state is usable;
- **Devices**: Watch, iPhone camera, Action 4, and equipment-source state are
  understandable without developer knowledge.

Record any clipping, confusing terminology, unreachable controls, or stale
status.

## Gate 2 · Companion + camera preflight

Open **Capture → Indo Board**.

For the first pass choose **Watch + iPhone**. You do not need an
external camera, insole, printed markers, or body scan to get a useful
first-session capture. The optional **First recording guide** in the app
summarizes the physical setup, while device readiness remains a separate
automatic preflight.

Run preflight and require:

- Watch paired;
- MotionOS Watch companion confirmed by system state or MotionOS handshake;
- live Watch link;
- no other Watch capture already active;
- Health/workout access enabled;
- iPhone rear camera ready;
- 1920×1080 capture;
- 30 fps locked;
- stabilization off;
- iPhone battery >= 20%;
- free storage >= 5 GB.

Use the live framing card. The complete body, both feet, and Indo Board should
stay inside the guide during the expected balance envelope.

Do not begin if a tripod or phone position creates a fall hazard.

## Gate 3 · Complete 120 second session

Press **Start Session**. The complete-session path is hands-free after
start unless you intentionally finish early.

MotionOS should:

1. start / mirror a fresh Watch workout;
2. wait for a fresh Watch capture session ID and bind all product controls to it;
3. start the sealed iPhone camera capture;
4. arm operator evidence;
5. keep the phone awake;
6. advance the shared Indo Board protocol automatically;
7. send protocol instructions to the Watch;
8. generate three journal-backed sync opportunities;
9. automatically stop and seal all available evidence at the 120 s target.

The current product protocol is:

| Time | Product block |
| ---: | --- |
| 0–15 s | neutral settle |
| 15–35 s | natural free balance A |
| 35–60 s | five slow side shifts with clear center pauses |
| 60–85 s | three shallow controlled squats |
| 85–105 s | natural free balance B |
| 105–120 s | neutral finish |

The table reflects the canonical `IndoBoardProductProtocol` version
`motionos.indo-board-product-session.v2`, which is authoritative if
the app's protocol changes. Keep movements within a comfortable range.

SYNC windows are separate cues, not new blocks:

- START: 8–14 s (preferred 10 s);
- MIDDLE: 61–66 s (preferred 63 s, near the start of squats);
- END: 110–119 s (preferred 114 s).

When the Watch presents **SYNC · MOVE NOW**, make one sharp arm gesture while
trying to keep the board near neutral. The Watch acknowledgment counts only
after the sync event has been appended to the Watch journal. Product cues,
sync cues, and the remote stop are accepted only when they target the current
Watch capture session ID and the current product run.

Do not deliberately make the board unstable just to create a larger signal.

## What to watch during capture

### Apple Watch

The wrist UI should make the current task obvious at a glance:

- elapsed time;
- LIVE / STALE signal;
- product block title + short instruction;
- distinct sync haptic;
- heart rate when available;
- effective IMU rate;
- IMU sample count;
- maximum gap;
- compact motion trace;
- iPhone-link status;
- battery.

The Watch should remain useful without requiring scrolling during the most
important active state.

### iPhone

The active capture surface should prioritize:

- current product state;
- protocol progress;
- live Watch user acceleration;
- angular-rate magnitude;
- heart-rate trend;
- timing continuity;
- camera framing / camera health where appropriate.

Live plots are operator telemetry, not performance scores.

## Gate 4 · Stop, seal, recover

At the end, MotionOS should reach a safe state even if transfer is delayed.

Watch evidence should progress through the equivalent of:

```text
FINISHING
→ SAFE
→ QUEUED
→ VERIFYING
→ VERIFIED
```

The iPhone product session should preserve:

- operator JSONL + metadata;
- iPhone MOV + frame/pose journal + camera metadata;
- Watch journal after transfer;
- Watch summary derived from the verified journal;
- `product-session.json` linking product-run/source provenance.

If the Watch cannot be confirmed stopped, MotionOS must enter its explicit
**Finish Watch capture** recovery state rather than pretending the run is
complete.

A failed start should become an **aborted** inspectable attempt rather than
leaving a hidden armed run.

## Gate 5 · Session review

Open **Sessions** and inspect the just-completed Indo Board run.

Expected surfaces:

- capture mode and source completeness;
- protocol / sync evidence;
- Watch Session Lens;
- motion fingerprint;
- user-acceleration + rotation traces;
- timing continuity;
- exact source hash/provenance;
- evidence exports;
- self-report feedback.

Fill in:

- perceived stability, 1–5;
- perceived effort, 1–5;
- movement notes;
- product/workflow notes.

Those fields are subjective product context and never replace sensor evidence.

After at least two completed comparable runs, MotionOS may show descriptive
longitudinal deltas. It must not call a higher/lower value “better” without a
validated task-specific interpretation.

## Optional Gate 6 · Multiview product pass

After the Standard run works, repeat using **Multiview** only if the Action 4
setup is ready.

Before pressing start, manually confirm:

- 4K 16:9;
- 60 fps;
- EIS off;
- no digital zoom;
- Standard (Dewarp) FOV;
- rigid tripod;
- camera position unchanged from the intended calibration geometry.

After sealing the MotionOS run, import the untouched Action 4 movie. The product
manifest should update with the external-media hash while preserving the
original session creation time and already-sealed source hashes.

This product pass proves capture/provenance UX only. Full multiview clock fit,
camera calibration, 3D skeleton, Indo Board pose, and the five camera-rich M0
metrics remain separate downstream qualification work.

## First-session evidence handoff

Once the run is sealed, save the original evidence before editing or cropping
any video. In **Sessions**, confirm:

- one new run appears with the expected completion/abort state;
- the iPhone video opens and covers the full body, board, and recovery motion;
- Watch journal transfer reaches a verified state, or record the exact pending state;
- start/middle/end sync cues were captured where possible;
- the original Action 4 MP4 was imported into the same run if Multiview was used;
- your short perceived-effort/stability note and camera position are captured.

If an app control fails, send a screenshot of the **Capture** preflight,
**active Watch** status, or **Sessions** evidence detail and the exact first
error message. Do not delete or overwrite an unverified original just because
an export or sync step fails.

For research interpretation, a standard Watch + camera run supplies video,
pose and IMU evidence but **not** independently measured EMG, plantar load,
muscle force, body composition or fatigue. Those need separate reference
measurements and qualification. The initial run is valuable for capture
reliability, pose coverage, technique observation and repeatable baseline work.

## Feedback to capture after the run

The most valuable feedback is concrete:

- which screen felt crowded or empty;
- which status was confusing;
- whether the Watch instruction could be understood in <1 second;
- whether the sync haptic was unmistakable;
- whether the phone could be read from the tripod position;
- whether live plots were useful or distracting;
- whether any metric lacked an obvious unit/meaning;
- whether stop/seal/transfer felt trustworthy;
- whether Session review answered “what happened?”;
- what you wanted to inspect next but could not.

Screenshots of **preflight**, **active capture**, **Watch active capture**, and
**sealed Session review** are especially useful for the next UI pass.
