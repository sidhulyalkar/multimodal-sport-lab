# INDO BOARD Tracking Beta v1

Status: beta bootstrap for MotionOS iPhone + Apple Watch

## Why this exists

The camera-only body coach is already useful for posture, movement phases, and within-session experiments. The next useful state is the relationship between the INDO BOARD deck and roller.

A markerless detector is the end goal. The beta should not wait for a large labeled equipment dataset before collecting high-value board-relative evidence.

MotionOS therefore supports an optional three-QR-marker bootstrap:

- deck left endpoint
- deck right endpoint
- camera-facing roller end

The existing Vision pass reads these QR codes alongside body pose. No extra camera, network service, or separate scanning flow is required.

## Setup

In the iPhone INDO BOARD screen:

1. Open Beta board + roller tracking.
2. Share or print the generated marker PNGs.
3. Attach the deck-left and deck-right markers near the visible ends of the deck.
4. Attach the roller marker to the center of the roller end cap facing the camera.
5. Keep all three markers visible from the normal camera position.

Markers should not cover the riding surface, interfere with deck stops, change roller contact, or create a snag/trip hazard.

The normal body-only beta remains available without markers.

## Rider UX

The setup loop becomes:

phone on tripod -> Watch setup -> body framing -> stable stance -> board tracking status -> Start

The Watch reports one of two evidence modes:

- Board + roller tracked: deck-centered metrics can be computed.
- Body-only beta mode: the session still runs, but balance claims remain body-pose proxies.

Board tracking is additive rather than a brittle start gate.

## Measurement contract

A QR observation produces normalized image-space evidence:

- deck left/right endpoints
- roller marker center
- observation confidence
- provenance = fiducial_measured

From those values MotionOS derives:

- image-plane deck angle
- normalized roller position along deck
- center proximity
- roller excursion
- center-time fraction
- edge-zone entries
- direction-change count
- recovery timing

These are image-plane balance proxies, not force, pressure, center-of-mass, or calibrated physical-distance measurements.

## Shared thresholds

The on-device Swift evaluator mirrors the offline Python evaluator:

- center zone: |roller position| <= 0.20
- recovery departure: >= 0.35
- recovery complete: <= 0.15
- edge zone: >= 0.75

Keeping the definitions identical prevents a training/evaluation metric from silently meaning something different inside the app.

## Data flywheel

The QR bootstrap serves two jobs at once.

### Immediate product value

The first beta session can compare true deck-relative roller motion rather than only pelvis motion.

### Markerless-model teacher data

Every marker-backed beta session can produce:

- video
- QR-derived deck/roller geometry
- body pose
- Watch IMU
- protocol block
- recovery events
- coaching cue
- cue response

Those marker-derived trajectories become inexpensive teacher labels for a later markerless detector.

The progression is:

QR teacher -> reviewed labels -> markerless detector -> CoreML deployment -> QR markers disappear from normal use

## Markerless qualification

The research pipeline already separates model proposals from human-reviewed labels and evaluates:

- deck endpoint error
- roller endpoint error
- roller center error
- roller position-along-deck error
- center-zone classification agreement
- edge-zone classification agreement
- reference coverage

The markerless detector should replace QR evidence in coaching only after it performs reliably on creator/viewpoint-separated evaluation data and physical beta sessions.

## Beta success criterion

For this stage, success is not perfect board reconstruction.

Success is:

the rider can set the phone down, see Board + roller tracked on the Watch, complete the two-minute protocol, receive a deck-relative coaching cue, and generate a session that is simultaneously useful training data for the markerless system.
