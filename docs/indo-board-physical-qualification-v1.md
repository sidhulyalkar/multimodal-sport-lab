# INDO BOARD Physical Beta Qualification v1

Status: pre-merge physical qualification for the iPhone + Apple Watch beta

## Purpose

This qualification answers one narrow question:

**Can a rider set the iPhone down, start from Apple Watch, complete the two-minute protocol, receive one evidence-linked coaching experiment, and seal a session whose body and optional deck/roller evidence remain auditable?**

It does not qualify medical, injury-risk, force, center-of-mass, pressure, or calibrated biomechanics claims.

## Test configuration

Use:

- physical iPhone running the current MotionOS beta
- physical paired Apple Watch running the embedded Watch companion
- INDO BOARD + roller
- stable iPhone support/tripod
- clear riding area
- stable support or spotter for early runs
- optional MotionOS QR marker kit:
  - deck left
  - deck right
  - roller center

Run the body-only path once and the marker-backed path at least three times.

## A. Installation + connectivity

Pass only if all are true:

- iPhone app launches without a crash
- Watch app remains installed after launch
- Watch app can reach the iPhone host
- iPhone reports Watch workout access ready
- camera permission is granted
- camera preview starts
- no stale previous session remains marked active
- a failed/restarted setup does not reuse a previous run ID or sealed camera bundle

Record screenshots or a short screen recording for any failure.

## B. Camera-first setup

Pass only if:

- full body and both feet can be kept inside the framing guide
- framing state reaches ready
- neutral stance reaches stable after roughly two seconds of genuinely new Vision frames
- temporarily covering the camera causes the stance/framing state to leave ready rather than remaining falsely green
- restoring the view lets the setup reacquire without restarting the app

This specifically checks that repeated polling of one old Vision frame cannot manufacture stability.

## C. Optional board + roller tracking

### C1. Marker setup

Open **Beta board + roller tracking** and share/print the marker kit.

Pass if:

- the marker kit contains one printable PDF plus individual PNGs
- all three marker payloads are distinct
- markers can be mounted without affecting footing, deck stops, roller contact, or creating a snag hazard
- QR size is treated only as a visibility aid, never as camera calibration

### C2. Live tracking

With the three markers visible, pass if:

- iPhone preflight transitions from body-only/intermittent to **Board tracking stable**
- Watch transitions to **Board + roller stable**
- the rolling window reports at least:
  - 60% recent visibility
  - 55% mean board-state confidence
- the live roller gauge moves in the expected left/right direction
- covering one marker makes readiness decay instead of preserving a stale green state
- uncovering the marker allows readiness to recover
- session start remains possible in body-only mode because board tracking is optional

Do not tune thresholds during the same qualification run unless there is a documented detector failure mode.

## D. Watch-controlled start

From a ready setup:

1. Tap Start on Watch.
2. Confirm iPhone begins camera pre-roll.
3. Confirm Watch gives the five-second countdown.
4. Confirm protocol time begins only after countdown.
5. Confirm the Watch advances through the guided blocks.

Pass if there is only one active product session and one camera recording.

## E. Two-minute protocol

Complete the full protocol without manually interacting with the iPhone.

Pass if the run includes:

- neutral settle
- first natural-balance block
- controlled shifts
- partial squats
- second natural-balance / coached retry block
- neutral finish
- expected sync cues

For the marker-backed path, deliberately move the roller far enough during the first balance block to create a measurable deck-relative excursion, but remain within a safe comfortable range.

## F. Adaptive coaching experiment

Before the second natural-balance block, MotionOS should select one cue based only on evidence already observed in that run.

Pass if:

- one cue is delivered on Watch
- intervention ID, target metric, desired direction, confidence, and evidence label are journaled
- the second balance block is used as the coached retry
- MotionOS reports exactly one of:
  - improved
  - no clear change
  - opposite direction
  - insufficient evidence
- sparse marker visibility yields **insufficient evidence** rather than a fabricated board-relative result

For board-relative scoring, both natural-balance blocks must have at least 60% qualified board tracking coverage.

## G. Session-level board evidence gate

Board-relative session coaching is considered usable only when all are true:

- at least 60 qualified board-state samples
- mean board-state confidence >= 55%
- session board-state coverage >= 50%

The session review must visibly report:

- board sample count
- session tracking coverage
- mean confidence
- first natural-balance block coverage
- coached retry coverage

If these gates fail, pass only if the session explicitly falls back to body-pose coaching while preserving the raw board observations.

## H. Evidence sealing

After the run:

- iPhone camera video exists
- camera JSONL journal exists
- camera metadata exists
- operator journal exists
- operator metadata exists
- Watch journal transfers to iPhone
- hashes/byte counts can be read
- product-session manifest exists
- intervention and experiment result are present when coaching ran
- Watch cue acknowledgment/sync evidence is preserved
- aborted attempts remain inspectable but are excluded from longitudinal comparison

Pass if no source is silently rewritten to make another source look synchronized.

## I. User feedback loop

Open the completed Session review.

Record:

- perceived stability
- perceived effort
- whether the Watch cue was actually tried
- whether coaching felt helpful
- movement notes
- app/workflow notes

These remain self-reported context and must never be promoted to sensor ground truth.

## J. First-party detector data flywheel

For a marker-backed run, export QR teacher labels from the camera journal:

    motionos indo-extract-fiducial-teacher-labels \
      camera-journal.jsonl \
      fiducial-teacher-labels.json

Pass if:

- only fiducial-measured deck/roller events are exported
- original camera frame index is preserved
- camera monotonic timestamp is preserved
- non-fiducial/model-estimated equipment events are not silently relabeled as teacher truth

This dataset is image-space supervision for the future markerless detector, not calibrated biomechanics ground truth.

## Minimum evidence package for beta approval

Before marking PR #101 ready for merge, preserve:

1. one successful body-only two-minute run
2. three successful marker-backed runs
3. one deliberate marker-occlusion/reacquisition test
4. one board-tracking-dropout run demonstrating fail-closed coaching
5. Watch + iPhone screenshots showing stable tracking
6. one sealed product-session manifest with adaptive cue result
7. one exported fiducial teacher-label dataset
8. short notes for any mismatch between felt stability and measured metrics

## Stop conditions

Stop the run rather than forcing completion if:

- board or roller setup feels mechanically unsafe
- marker placement affects footing or roller travel
- Watch session cannot be stopped
- camera recording remains stuck active
- the app reports stale board tracking after markers are no longer visible
- the rider needs to interact with the iPhone in a way that compromises safe balance

Preserve the aborted run evidence whenever possible.

## Release gate

PR #101 can move out of draft when:

- CI is green for shared Swift tests, iPhone host, embedded Watch companion, Watch host, Python, and replay UI
- the minimum physical evidence package above is complete
- no physical test reveals a stale-state, duplicate-sample, session-lifecycle, or evidence-sealing defect
- board-relative claims remain explicitly image-space proxies
- marker-backed data can enter the detector-training pipeline without manual schema translation

At that point the next milestone is not “more metrics.” It is **markerless equipment detection trained against the evidence this beta now generates**.
