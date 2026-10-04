# MotionOS product data strategy

Status: product direction for M0 -> early beta. This document does not expand the scientific claims of the current qualification gates.

## Product thesis

MotionOS should become a longitudinal movement-intelligence layer rather than a collection of sensor dashboards.

The core loop is:

1. capture a movement session with the smallest useful sensor set;
2. preserve source-native evidence and timing;
3. verify the evidence before deleting the wearable copy;
4. derive compact, interpretable session features;
5. compare the athlete primarily against their own prior baseline;
6. use richer cameras or equipment sensors periodically to recalibrate the lightweight everyday model.

The default product should feel simple even when the evidence system underneath it is rigorous.

## Connectivity contract

Apple Watch connectivity has three distinct meanings and the UI must not collapse them:

- **Ready**: the active paired Watch has MotionOS installed or has recently proved its presence.
- **Connected**: the counterpart is currently reachable for immediate messaging.
- **Recording**: an active mirrored workout/capture is in progress.

Live reachability is not a pairing test. Immediate messages are opportunistic. State synchronization and evidence transfer use durable WatchConnectivity channels.

### Watch -> iPhone journal lifecycle

```text
capturing
  -> journal sealed on Watch
  -> transfer queued
  -> file received on iPhone
  -> iPhone verifies byte count + SHA-256
  -> iPhone persists canonical copy
  -> durable receipt returned to Watch
  -> Watch verifies receipt hash
  -> Watch local copy becomes eligible for deletion
```

Retrying the same session must be idempotent. A retransferred journal with the same digest is accepted as a duplicate; a different digest for the same session is a conflict.

## Evidence hierarchy

MotionOS must make measurement trust legible.

1. **Raw source evidence**: authoritative source-native sensor journal/video plus immutable digest.
2. **Source metadata**: device identity, source battery, requested/configured sample rate, permissions, native timestamps.
3. **Derived session features**: summaries and calibrated metrics produced from verified evidence.
4. **Live UI telemetry**: useful operator preview, never the evidence authority.
5. **Coaching interpretation**: personalized suggestions with the model/version and supporting measurements traceable back to a session.

A polished graph must never silently promote an unqualified signal into a scientific measurement.

## HealthKit boundary

HealthKit is the right home for standardized health and fitness records that fit Apple's data model, such as workouts and permitted physiology. MotionOS should continue to request only the HealthKit types needed for a user-facing feature.

HealthKit is **not** the MotionOS raw evidence store. High-rate IMU journals, synchronized camera evidence, equipment-pod logs, calibration artifacts, manifests, and model features remain MotionOS data.

Apple's current App Review Guidelines state that personal health information may not be stored in iCloud. MotionOS therefore should not use iCloud/CloudKit as the archive for personal health evidence. Any future server-side archive must have a separate privacy review, explicit user consent, encryption, access controls, export/deletion support, and a narrowly stated user benefit.

References:
- https://developer.apple.com/documentation/watchconnectivity/wcsession
- https://developer.apple.com/documentation/healthkit/hkliveworkoutbuilder
- https://developer.apple.com/app-store/review/guidelines/

## Storage architecture

### Tier 0: Watch transient cache

Keep only what is necessary to survive disconnection. A verified iPhone receipt is the deletion boundary.

### Tier 1: iPhone canonical session bundle

Each session has one manifest that points to immutable source artifacts and derived products.

Suggested shape:

```text
MotionOSRuns/<run-id>/
  product-session.json
  watch/
    watch.jsonl
    watch-summary.json
    host-receipt.json
  phone-camera/
    original.mov
    frame-timing.jsonl
    camera-metadata.json
  external/
    action4/
      original-*.mp4
      external-camera-metadata.json
      action4-sync-proposal.json
      video-alignment.json
      action4-pose-track.json
  operator/
    protocol.jsonl
    metadata.json
  derived/
    session-features.json
    quality-report.json
    model-output.json
```

### Tier 2: compact longitudinal index

The app should be able to render years of history without opening raw videos. Persist a small session summary containing:

- sport / drill / protocol;
- duration and timestamps;
- source-quality scores;
- key validated features;
- subjective effort and optional athlete notes;
- equipment/context labels;
- links to raw evidence;
- model/version identifiers.

### Tier 3: optional non-iCloud archive

A later beta can upload encrypted session artifacts to an app-controlled object store and keep searchable metadata/features in a database. Cloud state should be explicit:

```text
local_only
  -> upload_queued
  -> cloud_verified
  -> local_raw_eligible_for_eviction
```

Never delete the only verified copy.

## Retention policy

The biggest storage cost will be video, not Watch IMU.

Recommended default:

- keep compact summaries/features until the user deletes them;
- keep raw Watch/equipment IMU for long-term longitudinal research where practical;
- keep full video for calibration sessions, personal bests, flagged sessions, and a rolling recent window;
- allow ordinary video to become locally evictable only after any configured archive is hash-verified;
- preserve short event clips and derived pose/features longer than unremarkable full-length video;
- give the user a visible storage budget and one-tap export/delete controls.

## High-value personal dataset

Do not optimize for the maximum number of sensors per session. Optimize for **information gained per unit of friction**.

### Everyday sessions

Use the lowest-friction stack, normally Watch plus the phone when video is useful. Collect enough repetitions to observe true within-person change.

### Gold calibration sessions

Periodically add the external camera, equipment pod, insoles, or other reference sensors. These sessions are expensive but create teacher data for recalibrating lighter everyday inference.

### Repeated anchors

Every sport should have a small set of repeatable benchmark tasks. The current two-minute Indo Board protocol is the first example. Repeating the same task under comparable conditions creates a much more valuable longitudinal signal than continuously changing drills.

### Labels that create learning value

A session becomes substantially more useful when raw sensor data is paired with context and outcome. Capture a small post-session annotation such as:

- intended drill;
- perceived effort;
- success / completion outcome;
- confidence or control;
- equipment and relevant environment;
- optional discomfort or recovery note;
- one short free-text observation.

Keep this lightweight enough that it is actually completed.

## Product surface

The product navigation should converge toward four jobs:

- **Today**: what should I do and what changed?
- **Capture**: one obvious start path, with optional sources revealed only when useful.
- **Progress**: longitudinal skill, consistency, load, and validated movement trends.
- **Sessions**: evidence, replay, comparison, export, and debugging.

Detailed hardware diagnostics belong under Devices/Developer rather than the primary athlete workflow.

## Market wedge

Strava already supports many sports. MotionOS should not position itself merely as "Strava for sports other than running."

The sharper wedge is **technique and movement quality for sports where route, pace, and distance miss most of the performance signal**.

A useful one-line framing:

> MotionOS turns the sensors and cameras you already own into a personalized movement model that shows how your technique changes over time.

The long-term platform can span sports, rehabilitation-adjacent movement tracking, coaching, and sensor integrations, but early product claims should stay inside validated performance measurements.

## Dataset moat

The defensible asset is not raw IMU volume by itself. It is the aligned longitudinal graph:

```text
person
  x body profile
  x sport/task
  x movement state
  x equipment
  x environment
  x physiology
  x outcome
  x coaching intervention
  x later improvement
```

That graph can eventually answer a much more valuable question than "what happened?":

**What change is most likely to improve this specific athlete's next session?**

## Near-term founder milestones

Before broad fundraising, make the product produce an undeniable loop:

1. reliable Watch/iPhone capture with zero evidence loss in repeated interruption tests;
2. a meaningful personal longitudinal dataset from repeated protocols;
3. one sport workflow where MotionOS surfaces an insight that ordinary workout apps do not;
4. a visually compelling before/after progression story grounded in measured sessions;
5. a small external beta showing that people repeat the workflow without developer supervision;
6. storage/privacy/export behavior that looks like a real product rather than a research prototype.

That becomes the foundation for an investor story: **consumer wedge -> unique longitudinal movement data -> personalized models -> multisport movement platform**.
