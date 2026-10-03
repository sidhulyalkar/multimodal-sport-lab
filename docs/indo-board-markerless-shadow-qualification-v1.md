# INDO BOARD Markerless Shadow Qualification v1

Status: engineering qualification for the first markerless deck/roller detector

This gate begins **after** the QR-backed physical beta is working. A model may enter shadow evaluation before it is authorized for live tracking or coaching.

## Core rule

A markerless model starts as an observer, not a decision maker.

The physical runtime must preserve these independent states:

- **shadow-only**: model runs and is measured, but cannot drive UI or coaching
- **tracking-authorized**: model may drive live board visualization when QR is unavailable
- **coaching-authorized**: model may contribute board-relative coaching evidence

Promotion between states is explicit and receipt-backed. Model confidence alone never promotes the model.

## 1. Install the detector as shadow-only

Implement `IndoBoardEquipmentFrameDetector` and pass it into `CameraCapturePipeline` with either:

- no qualification registry entry, or
- an `evaluation_only` entry

The detector must return the shared `IndoBoardEquipmentObservation` contract with:

- deck left/right endpoints
- roller center
- optional deck polygon
- optional roller axis
- confidence
- `model_estimated` provenance
- stable model ID

Do not special-case the coaching engine for the new detector.

## 2. Collect paired QR + markerless evidence

Keep all three beta QR markers visible and complete the same two-minute INDO protocol used for PR #101.

For every analyzed camera frame, MotionOS should preserve:

- QR equipment observation
- markerless candidate observation, when available
- selected tracking source
- selected coaching source
- detector execution status and latency
- frame-level QR-to-markerless shadow comparison

The QR measurement must continue to win source arbitration even when the model reports higher confidence.

## 3. Verify fail-closed behavior

Deliberately exercise these conditions:

1. markerless detector returns no observation
2. markerless detector throws an error
3. only part of the board is detected
4. QR disappears while the model remains visible
5. model confidence spikes while QR confidence is lower
6. the qualification registry is missing
7. the registry schema is unknown
8. an authorization receipt is incomplete

Expected behavior:

- body-pose capture continues
- detector failures are journaled
- no incomplete model candidate becomes board state
- QR remains authoritative while present
- an unqualified model never becomes coaching evidence
- a tracking-only model never enters `IndoBoardCoachEngine`

## 4. Build the shadow evaluation report

After each marker-backed run:

    motionos indo-summarize-shadow-equipment-eval \
      camera-journal.jsonl \
      generated/shadow-equipment-eval.json

Review, per model:

- reference-frame comparison count
- deck endpoint mean and P90 error
- roller-center mean and P90 error
- roller position-along-reference-deck mean and P90 error
- center-zone agreement
- edge-zone agreement
- detector observation fraction
- detector error fraction
- detector latency mean and P90

The projection for roller-position error uses the **reference deck axis**, preventing correlated deck + roller drift from canceling itself.

## 5. Performance gate

The current camera stack analyzes pose every third delivered frame at 30 fps, giving a nominal 100 ms analysis interval.

For the first model qualification:

- detector P90 latency must remain below the analysis interval
- adding the detector must not create sustained camera writer backpressure
- adding the detector must not materially increase AVCapture dropped frames versus the QR-only baseline
- body-pose success must remain comparable to the QR-only baseline
- detector exceptions must not terminate video or body-pose capture

Treat 100 ms as an upper scheduling boundary, not a product performance target. Once real-device measurements exist, tighten the budget from evidence rather than guesswork.

## 6. Leakage-safe evaluation

Do not promote a model using the same rider/session slices that were used to tune it.

Hold out at minimum by:

- session
- acquisition day
- camera setup/viewpoint

As the dataset grows, also hold out riders and board/roller instances.

Public-video examples remain useful for robustness and vocabulary, but physical MotionOS QR sessions are the primary source for product-coordinate evaluation.

## 7. Tracking-only promotion

When a held-out report is acceptable, build an explicit registry entry:

    motionos indo-build-equipment-model-qualification \
      generated/shadow-equipment-eval.json \
      generated/equipment-model-qualification.json \
      --model-id indo-equipment-v1 \
      --status qualified_for_beta_tracking \
      --evaluation-dataset-id indo-heldout-v1 \
      --authorization-note "Approved after held-out shadow and physical beta review."

Tracking authorization permits the model to drive live deck/roller visualization when a stronger reference is absent.

It does **not** permit the model to influence board-relative coaching.

## 8. Coaching promotion

Coaching authorization requires another physical tranche with the model already running in tracking mode.

Verify that:

- board-state coverage remains stable across the full protocol
- center/edge classifications remain reliable near threshold boundaries
- recovery timing is stable enough to preserve before/after intervention direction
- QR-backed and markerless coaching outcomes agree on held-out runs
- removing QR does not create systematic changes in cue selection

Only then issue `qualified_for_beta_coaching`.

## 9. What not to claim

Passing this gate establishes a markerless **image-space equipment tracker** for the declared beta use.

It does not establish:

- force
- pressure
- true center of mass
- physical roller distance
- injury risk
- medical validity
- camera metric calibration

Those require separate evidence contracts.

## Exit criterion

The QR markers can disappear from normal use when the markerless model is:

1. physically shadow-qualified,
2. performance-qualified on device,
3. explicitly tracking-authorized,
4. separately coaching-authorized if board-relative coaching is enabled,
5. still auditable through the same routing and qualification receipts.

At that point the QR path remains valuable as a periodic recalibration / regression-test instrument rather than a user requirement.
