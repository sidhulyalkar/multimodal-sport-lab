# INDO BOARD Markerless Runtime Contract v1

Status: interface milestone only. No markerless model is authorized by this document.

## Goal

The QR beta gives MotionOS useful deck/roller state immediately and creates teacher labels for a future markerless detector.

The next engineering risk is not model architecture. It is evidence substitution: a model could quietly begin driving coaching before its accuracy, dataset coverage, and physical behavior have been qualified.

This contract makes that transition explicit.

## Runtime evidence sources

MotionOS may encounter several deck/roller observations for the same camera frame:

1. Human-reviewed reference
   - offline/evaluation use
   - provenance: manual_annotated
   - highest authority for labeled-reference workflows

2. QR fiducial measurement
   - physical beta use
   - provenance: fiducial_measured
   - currently preferred over markerless inference

3. Markerless model estimate
   - provenance: model_estimated
   - authorization depends on an explicit model qualification registry

4. Geometric proxy
   - useful for exploratory analysis
   - never silently promoted to qualified markerless evidence

## Two authorization levels

A markerless model can be authorized separately for beta tracking and beta coaching.

Tracking-only status: qualified_for_beta_tracking
Coaching-authorized status: qualified_for_beta_coaching

A model with evaluation_only or no registry entry fails closed.

## Source arbitration

For a complete deck + roller observation, MotionOS selects evidence in this order:

1. human-reviewed reference
2. QR fiducial measurement
3. qualified markerless model
4. nothing

A higher-confidence model does not outrank a visible QR measurement. Confidence is a detector-local quantity, not proof that two different evidence sources are equally calibrated.

Incomplete observations are rejected before arbitration.

## Qualification registry

The shared Swift schema is motionos.indo-equipment-model-qualification-registry.v1.

Each model entry records:

- model ID
- authorization status
- evaluation dataset ID
- SHA-256 of the evaluation report
- explicit authorization note
- copied evaluation metrics
- claim boundary

A registry is an authorization boundary, not a score leaderboard.

## Promotion is intentionally manual

The research pipeline can build an evaluation-only registry:

    motionos indo-build-equipment-model-qualification \
      runtime-equipment-evaluation.json \
      equipment-model-qualification.json \
      --model-id indo-equipment-v1 \
      --status evaluation_only

No metric automatically promotes a model.

A runtime-authorized state requires an explicit authorization note:

    motionos indo-build-equipment-model-qualification \
      runtime-equipment-evaluation.json \
      equipment-model-qualification.json \
      --model-id indo-equipment-v1 \
      --status qualified_for_beta_tracking \
      --evaluation-dataset-id indo-heldout-2026-10 \
      --authorization-note "Approved after held-out geometry and physical beta review."

The same applies when moving from tracking-only to coaching.

## Audit receipt

Every runtime arbitration can emit motionos.indo-equipment-selection-receipt.v1.

The receipt records:

- intended use: display tracking or coaching evidence
- selected detector ID
- selected model ID
- selected provenance
- selected confidence
- selection reason
- rejected detector IDs

This lets a later product-session report answer a crucial question: Which detector was allowed to influence this coaching result, and why?

## Markerless evaluation path

First-party marker-backed sessions follow this path:

camera journal -> fiducial teacher labels -> train/tune markerless detector -> runtime-format predictions -> QR-to-markerless held-out evaluation -> explicit qualification registry -> tracking-only beta -> physical comparison against QR -> coaching authorization

Public footage remains useful for viewpoint diversity and robustness, but does not replace first-party physical qualification.

## Non-goals

This contract does not define:

- a CoreML architecture
- an automatic promotion threshold
- force or pressure estimation
- center of mass
- medical or injury-risk claims
- camera metric calibration
- a claim that QR measurements are perfect ground truth

## Next implementation tranche

After the first marker-backed physical runs:

1. freeze a small held-out QR-labeled first-party test set
2. train the smallest markerless keypoint/segmentation baseline
3. emit runtime equipment observations from that model
4. run both QR and model on the same frames
5. keep model output display-only
6. inspect failure modes by lighting, camera angle, occlusion, deck position, and roller position
7. authorize coaching only after a separate physical comparison gate

The markerless model should enter the product through this contract, not by bypassing it.
