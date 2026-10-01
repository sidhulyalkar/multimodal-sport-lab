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

Use the release-candidate branch after its CI is green:

```bash
cd ~/Documents/Projects/multimodal-sport-lab
git switch product/motionos-m0-release-candidate
git pull --ff-only
open apple/MotionOSHost/MotionOSHost.xcodeproj
```

Do not run `bootstrap.sh --reset-packages` as part of this physical pass.
Preserve the locally selected Development Team unless regeneration is actually
required.

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

For the first pass choose **Standard / Watch + iPhone**.

Run preflight and require:

- Watch paired;
- MotionOS Watch companion confirmed by system state or MotionOS handshake;
- live Watch link;
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

Press **Start Complete Session**.

MotionOS should:

1. start / mirror the Watch workout;
2. start the sealed iPhone camera capture;
3. arm operator evidence;
4. keep the phone awake;
5. advance the shared Indo Board protocol automatically;
6. send protocol instructions to the Watch;
7. generate three journal-backed sync opportunities;
8. stop and seal all available evidence at the end.

The current product protocol is:

| Time | Product block |
| ---: | --- |
| 0–20 s | neutral settle |
| 20–55 s | natural free balance |
| 55–95 s | five comfortable tilt-and-recover cycles |
| 95–110 s | natural free balance |
| 110–120 s | neutral finish |

SYNC windows are intentionally separate from board perturbations:

- START: preferred ~12 s;
- MIDDLE: preferred ~50 s;
- END: preferred ~110 s.

When the Watch presents **SYNC · MOVE NOW**, make one sharp arm gesture while
trying to keep the board near neutral. The Watch acknowledgment counts only
after the sync event has been appended to the Watch journal.

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
